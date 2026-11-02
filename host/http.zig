//! **THE HTTP LAYER, WITH NO ROUTING**: a request read and parsed (its
//! method, path, query, headers and body), handed whole to the Roc
//! (`roc_handle_http_request`), and the Roc's response written as given.
//! Which path means what is the Roc's alone (app/Route.roc).
//!
//! **ONE REQUEST AT A TIME, ONE REQUEST A CONNECTION**: a connection is
//! accepted, its one request read, answered and closed before the next is
//! accepted. So no two requests ever run at once, and two writes of one
//! file never meet, with no lock; at a handful of users this costs
//! nothing. Every answer says `connection: close`.
//!
//! **NO CLIENT HOLDS THE SERVER FOR LONG**: the request's head and body
//! must arrive whole within `Limits.read_ms`, and the response must be
//! written within `Limits.write_ms`; past either, a watchdog shuts the
//! socket, which ends the read or write blocked on it. A head past its cap
//! is a 431, a body past its cap a 413, a request past its deadline a 408.
//!
//! **A TRUST BOUNDARY: 127.0.0.1 ONLY** (`listen`). Until sign-in exists,
//! the app takes every request as Steve's (app/main.roc's `acting`), so
//! anyone who can reach the server can post as him. The bind address is
//! not an option, so nothing but this machine can reach it. A browser here
//! still carries other sites' requests to it: app/RequestOrigin.roc, the
//! other half of this boundary, refuses any not from the server's own
//! origin, by the headers and the port this layer hands it.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const seam = @import("seam.zig");
const files = @import("file_primitives.zig");

const log = std.log.scoped(.http);

/// The port when none is given.
pub const default_port: u16 = 9611;

pub const Limits = struct {
    /// The request, head and body, read whole from the accept.
    read_ms: u32 = 10_000,
    /// The response, written whole.
    write_ms: u32 = 10_000,
    /// The most a body may be: a message's form, with room to spare.
    body_most: usize = 64 * 1024,
};

/// The most a request's head may be: past it, a 431.
pub const head_most = 16 * 1024;

pub const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    limits: Limits,
    listener: net.Server,
    /// The data root the file primitives answer from, the caller's, open
    /// for the server's life.
    root: *const files.DataRoot,

    /// **LISTENING ON 127.0.0.1 ALONE**, at `port` (0: any free port, a
    /// test's).
    pub fn listen(io: Io, gpa: std.mem.Allocator, at_port: u16, limits: Limits, root: *const files.DataRoot) !Server {
        const addr: net.IpAddress = try .parse("127.0.0.1", at_port);
        return .{
            .io = io,
            .gpa = gpa,
            .limits = limits,
            .listener = try addr.listen(io, .{ .reuse_address = true }),
            .root = root,
        };
    }

    /// The port it listens on.
    pub fn port(s: *const Server) u16 {
        return s.listener.socket.address.getPort();
    }

    /// Serves a connection at a time until `stop`.
    pub fn run(s: *Server) !void {
        defer s.listener.deinit(s.io);
        while (true) {
            const connection = s.listener.accept(s.io) catch |e| switch (e) {
                // `stop`, or the task's own cancel.
                error.SocketNotListening, error.Canceled => return,
                else => {
                    log.warn("accept failed: {t}", .{e});
                    continue;
                },
            };
            s.serve(connection);
        }
    }

    /// `run` returns: no more connections are accepted.
    pub fn stop(s: *Server) void {
        const listening: net.Stream = .{ .socket = s.listener.socket };
        listening.shutdown(s.io, .both) catch {};
    }

    /// One connection: its request read under the read deadline, answered
    /// by the Roc, the answer written under the write deadline, closed.
    fn serve(s: *Server, connection: net.Stream) void {
        defer connection.close(s.io);
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var read_buf: [head_most]u8 = undefined;
        var write_buf: [16 * 1024]u8 = undefined;
        var sr = connection.reader(s.io, &read_buf);
        var sw = connection.writer(s.io, &write_buf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);

        var fired = std.atomic.Value(bool).init(false);
        const request = blk: {
            var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.read_ms, net.ShutdownHow.recv, &fired }) catch |e| {
                log.warn("no task for the read's watchdog ({t}): closed", .{e});
                return;
            };
            defer watchdog.cancel(s.io);
            break :blk read_request(arena, &http, .{ .limits = s.limits, .port = s.port() }, &fired);
        };
        if (request == .gone) return;
        var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.write_ms, net.ShutdownHow.both, &fired }) catch |e| {
            log.warn("no task for the write's watchdog ({t}): closed", .{e});
            return;
        };
        defer watchdog.cancel(s.io);
        switch (request) {
            .gone => unreachable,
            .parsed => |p| {
                var req = p.req;
                const response = answer(arena, s.root, s.io, p.parsed);
                req.respond(response.body, .{ .status = response.status, .keep_alive = false, .extra_headers = response.headers }) catch |e|
                    log.warn("the answer to {f} was not written ({t})", .{ files.loggable(p.parsed.path), e });
            },
            .refused => |r| {
                if (r.req) |req| {
                    var refused = req;
                    refused.head.expect = null;
                    refused.respond(r.body, .{ .status = r.status, .keep_alive = false }) catch return;
                } else raw(&http, r.status);
                linger(s.io, connection);
            },
        }
    }
};

/// The parts of a request the Roc is handed, copied out of the read
/// buffer, which the body's read reuses.
pub const Parsed = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
    /// The port the server listens on, so the app knows its own origin.
    port: u16,
};

/// What a read needs of its server: the limits, and the port it listens on.
const Reading = struct { limits: Limits, port: u16 };

/// A response as the host writes it: a status std knows, and headers each
/// free of CR, LF and NUL.
const Written = struct {
    status: std.http.Status,
    headers: []const std.http.Header,
    body: []const u8,
};

const Read = union(enum) {
    parsed: struct { req: std.http.Server.Request, parsed: Parsed },
    /// Refused before the Roc is asked: `req` when the head was read.
    refused: struct { req: ?std.http.Server.Request, status: std.http.Status, body: []const u8 },
    /// Nothing to answer: the client went.
    gone,
};

/// The request on `http`, head and body, copied into `arena`; or the
/// refusal to send.
fn read_request(arena: std.mem.Allocator, http: *std.http.Server, reading: Reading, fired: *std.atomic.Value(bool)) Read {
    const limits = reading.limits;
    var req = http.receiveHead() catch |e| return switch (e) {
        error.HttpHeadersOversize => .{ .refused = .{ .req = null, .status = .request_header_fields_too_large, .body = "" } },
        error.HttpHeadersInvalid => .{ .refused = .{ .req = null, .status = .bad_request, .body = "" } },
        error.HttpRequestTruncated, error.HttpConnectionClosing, error.ReadFailed => if (fired.load(.acquire))
            .{ .refused = .{ .req = null, .status = .request_timeout, .body = "" } }
        else
            .gone,
    };
    const parsed = copy_head(arena, &req, reading.port) catch return .{ .refused = .{ .req = req, .status = .internal_server_error, .body = "failed\n" } };
    var with_body = parsed;
    if (req.head.method.requestHasBody()) {
        // No length and not chunked: no body (std asserts one or the other).
        if (req.head.transfer_encoding == .none and req.head.content_length == null) req.head.content_length = 0;
        if (req.head.content_length) |n| if (n > limits.body_most) return too_large(req);
        var body_buf: [256]u8 = undefined;
        const body = req.readerExpectContinue(&body_buf) catch return .gone;
        with_body.body = body.allocRemaining(arena, .limited(limits.body_most + 1)) catch |e| return switch (e) {
            error.StreamTooLong => too_large(req),
            error.OutOfMemory => .{ .refused = .{ .req = req, .status = .internal_server_error, .body = "failed\n" } },
            error.ReadFailed => if (fired.load(.acquire)) timed_out(req) else .gone,
        };
        // **A BODY CUT SHORT IS NO BODY**: std's reader ends a body at the
        // socket's end with no error, and the watchdog's shut is such an end.
        if (fired.load(.acquire)) return timed_out(req);
        if (req.head.content_length) |n| if (with_body.body.len != n) return .gone;
    }
    return .{ .parsed = .{ .req = req, .parsed = with_body } };
}

fn too_large(req: std.http.Server.Request) Read {
    return .{ .refused = .{ .req = req, .status = .payload_too_large, .body = "the body is too large\n" } };
}

fn timed_out(req: std.http.Server.Request) Read {
    return .{ .refused = .{ .req = req, .status = .request_timeout, .body = "the request was too slow\n" } };
}

fn copy_head(arena: std.mem.Allocator, req: *const std.http.Server.Request, port: u16) !Parsed {
    const target = req.head.target;
    const at = std.mem.indexOfScalar(u8, target, '?');
    var headers: std.ArrayList(std.http.Header) = .empty;
    var it = req.iterateHeaders();
    while (it.next()) |h| try headers.append(arena, .{
        .name = try arena.dupe(u8, h.name),
        .value = try arena.dupe(u8, h.value),
    });
    return .{
        .method = @tagName(req.head.method),
        .path = try arena.dupe(u8, target[0 .. at orelse target.len]),
        .query = try arena.dupe(u8, if (at) |q| target[q + 1 ..] else ""),
        .headers = headers.items,
        .body = "",
        .port = port,
    };
}

/// **THE ROC'S ANSWER TO `parsed`**, copied into `arena` with the call
/// ended; a 500 when it names no status std knows, or a header holding a
/// CR, an LF or a NUL (the app's bug, never written).
pub fn answer(arena: std.mem.Allocator, root: *const files.DataRoot, io: Io, parsed: Parsed) Written {
    seam.begin(arena, root, io);
    const r = seam.roc_handle_http_request(.{
        .body = .from(parsed.body),
        .headers = .from(parsed.headers),
        .method = .from(parsed.method),
        .path = .from(parsed.path),
        .query = .from(parsed.query),
        .port = parsed.port,
    });
    seam.end();
    const failed: Written = .{ .status = .internal_server_error, .headers = &.{}, .body = "failed\n" };
    const status = std.enums.fromInt(std.http.Status, r.status) orelse {
        log.warn("the app answered {f} with the status {d}, which is none", .{ files.loggable(parsed.path), r.status });
        return failed;
    };
    const recs = r.headers.slice();
    const headers = arena.alloc(std.http.Header, recs.len) catch return failed;
    for (recs, headers) |rec, *h| {
        h.* = .{ .name = rec.name.slice(), .value = rec.value.slice() };
        if (!header_safe(h.name) or !header_safe(h.value) or h.name.len == 0) {
            log.warn("the app answered {f} with a header holding CR, LF or NUL", .{files.loggable(parsed.path)});
            return failed;
        }
    }
    return .{ .status = status, .headers = headers, .body = r.body.slice() };
}

pub fn header_safe(bytes: []const u8) bool {
    return std.mem.indexOfAny(u8, bytes, "\r\n\x00") == null;
}

/// **THE WATCHDOG**: after `ms`, the socket shut `how` (a read's `.recv`,
/// so a 408 can still be written; a write's `.both`), and `fired` set.
/// Canceled when the work it guards is done in time.
fn shut_after(io: Io, connection: net.Stream, ms: u32, how: net.ShutdownHow, fired: *std.atomic.Value(bool)) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch return;
    fired.store(true, .release);
    connection.shutdown(io, how) catch {};
}

/// **A REFUSED REQUEST'S UNREAD BYTES ARE DRAINED BEFORE THE CLOSE**:
/// closed with the client's bytes unread, the socket resets, and the client
/// may lose the refusal it was sent. So the server's side is shut, and what
/// the client still sends is read and dropped, until it closes or the write
/// deadline's watchdog shuts the socket.
fn linger(io: Io, connection: net.Stream) void {
    connection.shutdown(io, .send) catch return;
    var buf: [4096]u8 = undefined;
    var r = connection.reader(io, &buf);
    _ = r.interface.discardRemaining() catch {};
}

/// A status written with no request to answer (a head that never came
/// whole, or was too big), then the close.
fn raw(http: *std.http.Server, status: std.http.Status) void {
    http.out.print("HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{ @intFromEnum(status), status.phrase() orelse "" }) catch return;
    http.out.flush() catch {};
}
