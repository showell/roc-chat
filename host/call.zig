//! **THE BRIDGE**: a request handed to the Roc (host/seam/chat_abi.zig's
//! `decide`) and its answer made into what the server writes. The server
//! calls `copy` before it reads a body, `decide` under the turn, and
//! `replyOf` after it, outside the turn.
//!
//! **ONE ANSWER, AND ONLY ONE**: the Roc answers, or the host answered for
//! it inside the call (`Ctx.own`: a 413, a script); `answered` with nothing
//! the host answered, and a header off the list, are the Roc's bugs, each a
//! 500.

const std = @import("std");
const abi = @import("seam/chat_abi.zig");
const route = @import("seam/chat_route.zig");
const assets = @import("assets.zig");
const files = @import("files.zig");

/// A Roc bug is said on stderr as a warning: the request's 500 is its
/// failure, and the server goes on.
const log = std.log.scoped(.roc_chat);

/// **WHAT THE ROC MAY READ OF A REQUEST, COPIED BEFORE ITS BODY IS READ**:
/// the head's strings point into the connection's read buffer, and reading
/// the body reuses that buffer (probe (a) sent every POST to the 404 until
/// the target was copied). So the path and every header are copied first.
pub const Copied = struct {
    /// The target up to its query.
    path: []const u8,
    method: std.http.Method,
    headers: []const std.http.Header,
    /// Read whole before the turn (the server's `body_most` at most).
    body: []const u8 = "",

    /// The values of header `name`, in any case, as sent.
    pub fn values(c: *const Copied, arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (c.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) try out.append(arena, h.value);
        return out.items;
    }

    /// The first value of header `name`, or null.
    pub fn first(c: *const Copied, name: []const u8) ?[]const u8 {
        for (c.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        return null;
    }
};

/// The request's path, method and headers, copied into `arena`.
pub fn copy(arena: std.mem.Allocator, req: *const std.http.Server.Request) !Copied {
    const target = req.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    var headers: std.ArrayList(std.http.Header) = .empty;
    var it = req.iterateHeaders();
    while (it.next()) |h| try headers.append(arena, .{
        .name = try arena.dupe(u8, h.name),
        .value = try arena.dupe(u8, h.value),
    });
    return .{
        .path = try arena.dupe(u8, path),
        .method = req.head.method,
        .headers = headers.items,
    };
}

/// What the host answered inside the call, in the Roc's place.
pub const Own = union(enum) {
    /// The body was longer than the Roc's limit (Host.read_body!).
    too_large,
    /// A script of the chat client's (Host.serve_script!).
    script: *const assets.Bundle,
};

/// **THE HOST THE ROC'S CALL ASKS** (chat_abi.Host.of): the request as
/// copied, and what the host answered in the Roc's place.
pub const Ctx = struct {
    req: *const Copied,
    arena: std.mem.Allocator,
    own: ?Own = null,
    /// The data root's files (Host.read! and its kin).
    files: *const files.Files,
    /// **THE REQUEST HAS FAILED** (a file the host could not read or
    /// write, or a path that leaves the data root): its answer is a 500,
    /// whatever the Roc answers.
    failure: ?anyerror = null,

    /// Once the host has answered, or the request has failed, the Roc's
    /// later asks do nothing: no write follows a failed read.
    pub fn dead(c: *Ctx) bool {
        return c.own != null or c.failure != null;
    }

    pub fn read_body(c: *Ctx, limit: u64) ?[]const u8 {
        if (c.req.body.len > limit) {
            c.own = .too_large;
            return null;
        }
        return c.req.body;
    }

    pub fn read_header(c: *Ctx, name: []const u8) []const []const u8 {
        // Out of memory here is the call's crash, as a Roc allocation's is.
        return c.req.values(c.arena, name) catch @panic("read_header: out of memory");
    }

    pub fn serve_script(c: *Ctx, name: []const u8) route.ScriptServed {
        const b = assets.find(name) orelse return .missing;
        c.own = .{ .script = b };
        return .served;
    }

    // ── the files: a failure is the request's, but a cache's ──────────────

    pub fn read(c: *Ctx, path: []const u8) route.Read {
        const r = c.files.read(c.arena, path);
        if (r == .failed) c.fail(path, error.ReadFailed);
        return r;
    }

    /// A cache's read: a failure is logged, never the request's.
    pub fn read_at(c: *Ctx, path: []const u8, offset: u64, max: u64) route.Read {
        const r = c.files.readAt(c.arena, path, offset, max);
        if (r == .failed) log.warn("{s}: read_at {s} failed (a cache's read; the request goes on)", .{ c.req.path, path });
        return r;
    }

    pub fn read_stat(c: *Ctx, path: []const u8) route.Stat {
        const r = c.files.stat(path);
        if (r == .failed) c.fail(path, error.StatFailed);
        return r;
    }

    pub fn list(c: *Ctx, path: []const u8) route.Listing {
        const r = c.files.list(c.arena, path);
        if (r == .failed) c.fail(path, error.ListFailed);
        return r;
    }

    pub fn write(c: *Ctx, path: []const u8, bytes: []const u8) route.Written {
        c.files.write(path, bytes) catch |e| {
            c.fail(path, e);
            return .failed;
        };
        return .written;
    }

    pub fn append(c: *Ctx, path: []const u8, bytes: []const u8) route.Appended {
        const size = c.files.append(path, bytes) catch |e| {
            c.fail(path, e);
            return .failed;
        };
        return .{ .appended = size };
    }

    pub fn remove(c: *Ctx, path: []const u8) route.Removed {
        c.files.remove(path) catch |e| {
            c.fail(path, e);
            return .failed;
        };
        return .removed;
    }

    /// A cache written: a failure is a miss, logged, never the request's.
    pub fn write_cache(c: *Ctx, path: []const u8, bytes: []const u8) void {
        c.files.write(path, bytes) catch |e| log.warn("{s}: write_cache {s} failed: {t} (a cache; the request goes on)", .{ c.req.path, path, e });
    }

    /// The request failed on `path`: the first failure is kept and said.
    fn fail(c: *Ctx, path: []const u8, e: anyerror) void {
        if (c.failure != null) return;
        c.failure = e;
        log.warn("{s}: the file {s} failed: {t}", .{ c.req.path, path, e });
    }
};

/// What the server writes: a status, its body and its headers.
pub const Reply = struct {
    status: std.http.Status,
    body: []const u8 = "",
    headers: []const std.http.Header = &.{},
};

pub const failed: Reply = .{ .status = .internal_server_error, .body = "The server failed to answer.\n" };
pub const too_large: Reply = .{ .status = .payload_too_large, .body = "request body too large\n" };
pub const too_slow: Reply = .{ .status = .request_timeout, .body = "request too slow\n" };

/// **THE HEADERS AN ANSWER MAY SET**, by the Roc's choice of value: a
/// cookie (sign-in, sign-out), a cache rule, a redirect's place. Any other
/// is refused, so the Roc cannot set a header the host owns
/// (`content-length`, `connection`, `transfer-encoding`).
pub const allowed_headers = [_][]const u8{ "set-cookie", "cache-control", "location" };

/// Whether `h` may be sent: its name on the list (in any case), and no CR,
/// LF or NUL in its name or value (which would split the response).
pub fn headerAllowed(h: route.Header) bool {
    const on_list = for (allowed_headers) |name| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) break true;
    } else false;
    return on_list and std.mem.indexOfAny(u8, h.name, "\r\n\x00") == null and std.mem.indexOfAny(u8, h.value, "\r\n\x00") == null;
}

/// The reply to `decided` (the Roc's decision, or its call's error), with
/// what the host answered inside the call (`ctx.own`). Anything wrong is a
/// 500, said on stderr.
pub fn replyOf(arena: std.mem.Allocator, decided: anyerror!route.Decision, ctx: *const Ctx) !Reply {
    const d = decided catch |e| {
        log.warn("the Roc call for {s} failed: {t}{s}", .{ ctx.req.path, e, if (e == error.RocCrashed) abi.last_crash[0..abi.last_crash_len] else "" });
        return failed;
    };
    if (ctx.failure != null) return failed;
    switch (d) {
        .respond => |r| {
            if (r.status < 100 or r.status > 599) {
                log.warn("the Roc answered {s} with status {d}", .{ ctx.req.path, r.status });
                return failed;
            }
            var headers: std.ArrayList(std.http.Header) = .empty;
            if (r.content_type.len > 0) {
                if (std.mem.indexOfAny(u8, r.content_type, "\r\n\x00") != null) {
                    log.warn("the Roc answered {s} with a content type holding a line break", .{ctx.req.path});
                    return failed;
                }
                try headers.append(arena, .{ .name = "content-type", .value = r.content_type });
            }
            if (r.nosniff) try headers.append(arena, .{ .name = "x-content-type-options", .value = "nosniff" });
            for (r.headers) |h| {
                if (!headerAllowed(h)) {
                    log.warn("the Roc answered {s} with the header `{s}`, which the host does not send", .{ ctx.req.path, h.name });
                    return failed;
                }
                try headers.append(arena, .{ .name = h.name, .value = h.value });
            }
            return .{ .status = @fromBackingInt(@as(u10, @intCast(r.status))), .body = r.body, .headers = headers.items };
        },
        .not_allowed => |m| {
            const headers = try arena.alloc(std.http.Header, 1);
            headers[0] = .{ .name = "allow", .value = @tagName(m) };
            return .{ .status = .method_not_allowed, .body = "method not allowed\n", .headers = headers };
        },
        .not_found => return .{ .status = .not_found, .body = "not found\n" },
        .answered => {
            const own = ctx.own orelse {
                log.warn("the Roc said {s} was answered, and the host answered nothing", .{ctx.req.path});
                return failed;
            };
            return switch (own) {
                .too_large => too_large,
                .script => |b| try scriptReply(arena, b, ctx.req.first("if-none-match")),
            };
        },
    }
}

fn scriptReply(arena: std.mem.Allocator, b: *const assets.Bundle, if_none_match: ?[]const u8) !Reply {
    const etag = try arena.dupe(u8, &assets.etagOf(b.body));
    const headers = try arena.alloc(std.http.Header, 3);
    headers[0] = .{ .name = "etag", .value = etag };
    headers[1] = .{ .name = "cache-control", .value = assets.cache_control };
    headers[2] = .{ .name = "content-type", .value = assets.content_type };
    if (if_none_match) |tags| if (assets.notModified(tags, etag)) return .{ .status = .not_modified, .headers = headers[0..2] };
    return .{ .status = .ok, .body = b.body, .headers = headers };
}

test "a failed sync fails the request: the write answers failed, and the Roc's 200 is a 500" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req: Copied = .{ .path = "/stub/file", .method = .POST, .headers = &.{} };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store: files.Files = .{ .io = std.testing.io, .root = tmp.dir };
    var ctx: Ctx = .{ .req = &req, .arena = a, .files = &store };
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const ok: route.Decision = .{ .respond = .{ .status = 200, .body = "stored\n" } };
    try std.testing.expectEqual(route.Written.written, ctx.write("n", "one"));
    try std.testing.expectEqual(std.http.Status.ok, (try replyOf(a, ok, &ctx)).status);
    store.fault_for_test = .sync_fails;
    try std.testing.expectEqual(route.Appended.failed, ctx.append("n", "two"));
    try std.testing.expect(ctx.dead());
    try std.testing.expectEqual(std.http.Status.internal_server_error, (try replyOf(a, ok, &ctx)).status);
    // A cache's failure is not the request's.
    var cache_ctx: Ctx = .{ .req = &req, .arena = a, .files = &store };
    cache_ctx.write_cache("c", "1");
    try std.testing.expect(!cache_ctx.dead());
    // A path out of the data root fails the request, never "missing".
    store.fault_for_test = .none;
    var bad_ctx: Ctx = .{ .req = &req, .arena = a, .files = &store };
    try std.testing.expectEqual(route.Read.failed, bad_ctx.read("../etc/passwd"));
    try std.testing.expectEqual(std.http.Status.internal_server_error, (try replyOf(a, ok, &bad_ctx)).status);
}

test "a header off the list, or one with a line break in it, is never sent" {
    try std.testing.expect(headerAllowed(.{ .name = "Set-Cookie", .value = "__Host-s=1; Secure; HttpOnly" }));
    try std.testing.expect(headerAllowed(.{ .name = "cache-control", .value = "no-store" }));
    try std.testing.expect(!headerAllowed(.{ .name = "content-length", .value = "3" }));
    try std.testing.expect(!headerAllowed(.{ .name = "set-cookie", .value = "a=1\r\nx-evil: 1" }));
    try std.testing.expect(!headerAllowed(.{ .name = "location\n", .value = "/" }));
}

test "a Roc answer with a refused header is a 500; answered with nothing the host answered is a 500" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req: Copied = .{ .path = "/", .method = .GET, .headers = &.{} };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store: files.Files = .{ .io = std.testing.io, .root = tmp.dir };
    var ctx: Ctx = .{ .req = &req, .arena = a, .files = &store };
    // The warnings are the point: quiet here.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const bad: route.Decision = .{ .respond = .{ .status = 200, .headers = &.{.{ .name = "connection", .value = "close" }} } };
    try std.testing.expectEqual(std.http.Status.internal_server_error, (try replyOf(a, bad, &ctx)).status);
    try std.testing.expectEqual(std.http.Status.internal_server_error, (try replyOf(a, .answered, &ctx)).status);
    const good: route.Decision = .{ .respond = .{ .status = 201, .content_type = "text/plain", .nosniff = true, .headers = &.{.{ .name = "set-cookie", .value = "a=1" }} } };
    const r = try replyOf(a, good, &ctx);
    try std.testing.expectEqual(std.http.Status.created, r.status);
    try std.testing.expectEqual(3, r.headers.len);
}
