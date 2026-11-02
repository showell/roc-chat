//! **THE HTTP LAYER'S TESTS**, with the app linked: a server on a port of
//! its own in this process, on its own task, against a temporary data
//! root, and clients that speak HTTP by hand. Each refusal the host makes
//! before the Roc is asked, and the Roc's own answers through the host.

const std = @import("std");

/// **THE TESTS PLANT FAILURES, AND EACH LOGS A WARNING**: the tests check
/// every answer themselves, so only errors are logged while they run.
pub const std_options: std.Options = .{ .log_level = .err };
const Io = std.Io;
const http = @import("http.zig");
const files = @import("file_primitives.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;
const testing = std.testing;

const RunResult = @typeInfo(@TypeOf(http.Server.run)).@"fn".return_type.?;

/// A server on its own task, on a free port, its data a test's folder.
pub const Running = struct {
    server: http.Server,
    run: Io.Future(RunResult),
    data: testing.TmpDir,
    root: files.DataRoot,

    pub fn start(limits: http.Limits) !*Running {
        const r = try gpa.create(Running);
        errdefer gpa.destroy(r);
        r.data = testing.tmpDir(.{});
        errdefer r.data.cleanup();
        r.root = .{ .io = io, .dir = r.data.dir };
        r.server = try .listen(io, gpa, 0, limits, &r.root);
        r.run = try io.concurrent(http.Server.run, .{&r.server});
        return r;
    }

    pub fn stop(r: *Running) void {
        r.server.stop();
        r.run.await(io) catch |e| std.debug.print("the server's run: {t}\n", .{e});
        r.data.cleanup();
        gpa.destroy(r);
    }
};

/// `request` on a connection of its own, and everything sent back.
pub fn exchange(arena: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const connection = try addr.connect(io, .{ .mode = .stream });
    defer connection.close(io);
    var w = connection.writer(io, &.{});
    try w.interface.writeAll(request);
    var buf: [4096]u8 = undefined;
    var r = connection.reader(io, &buf);
    return r.interface.allocRemaining(arena, .limited(4 * 1024 * 1024));
}

/// A request to the server at `port`: `line`, its request line, then the
/// Host that names this server (the app refuses any other, app/RequestOrigin.roc),
/// then `rest`, the other headers, the empty line and any body.
fn ours(a: std.mem.Allocator, port: u16, comptime line: []const u8, comptime rest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, line ++ "\r\nhost: 127.0.0.1:{d}\r\n" ++ rest, .{port});
}

fn status(bytes: []const u8) !u16 {
    if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 ") or bytes.len < 12) return error.NotAResponse;
    return std.fmt.parseInt(u16, bytes[9..12], 10);
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "the Roc routes: no such path is its 404, another method its 405, and each answer closes" {
    const r = try Running.start(.{});
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const nowhere = try exchange(a, port, try ours(a, port, "GET /nowhere HTTP/1.1", "\r\n"));
    try testing.expectEqual(404, try status(nowhere));
    try testing.expect(has(nowhere, "connection: close"));
    try testing.expect(has(nowhere, "content-type: text/html; charset=utf-8"));
    const put = try exchange(a, port, try ours(a, port, "PUT /chat/dm/1_1/plans HTTP/1.1", "content-length: 0\r\n\r\n"));
    try testing.expectEqual(405, try status(put));
    try testing.expect(has(put, "allow: GET, POST"));
    // A conversation with no transcript yet: the Roc's 404, through the host.
    const missing = try exchange(a, port, try ours(a, port, "GET /chat/dm/1_1/plans?x=1 HTTP/1.1", "\r\n"));
    // Another Host: the Roc's 403, through the host.
    const foreign = try exchange(a, port, "GET /chat/dm/1_1/plans HTTP/1.1\r\nhost: x\r\n\r\n");
    try testing.expectEqual(403, try status(foreign));
    try testing.expectEqual(404, try status(missing));
    try testing.expect(has(missing, "No such conversation: /chat/dm/1_1/plans"));
}

test "a body over the cap is a 413, one at it is read; a head over the cap is a 431" {
    const r = try Running.start(.{ .body_most = 64 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const over = try exchange(a, port, "POST /chat/dm/1_1/plans HTTP/1.1\r\nhost: x\r\ncontent-length: 65\r\n\r\n" ++ @as([65]u8, @splat('m')));
    try testing.expectEqual(413, try status(over));
    // At the cap: read, and the Roc refuses the form (no `markdown`).
    const at = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 64\r\n\r\n" ++ @as([64]u8, @splat('m'))));
    try testing.expectEqual(400, try status(at));
    try testing.expect(has(at, "The form has no field `markdown`."));
    const head = try exchange(a, port, "GET / HTTP/1.1\r\nx-big: " ++ @as([http.head_most]u8, @splat('h')) ++ "\r\n\r\n");
    try testing.expectEqual(431, try status(head));
}

test "a request too slow is a 408, and the server serves the next" {
    const r = try Running.start(.{ .read_ms = 100 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    // A head never finished.
    const slow_head = try exchange(a, port, "GET /nowhere HTTP/1.1\r\nhost: x\r\n");
    try testing.expectEqual(408, try status(slow_head));
    // A body shorter than its length says.
    const slow_body = try exchange(a, port, "POST /chat/dm/1_1/plans HTTP/1.1\r\nhost: x\r\ncontent-length: 20\r\n\r\nmarkdown=x");
    try testing.expectEqual(408, try status(slow_body));
    const next = try exchange(a, port, try ours(a, port, "GET /nowhere HTTP/1.1", "\r\n"));
    try testing.expectEqual(404, try status(next));
}

test "it listens on 127.0.0.1 alone" {
    const r = try Running.start(.{});
    defer r.stop();
    var buf: [64]u8 = undefined;
    const said = try std.fmt.bufPrint(&buf, "{f}", .{r.server.listener.socket.address});
    try testing.expect(std.mem.startsWith(u8, said, "127.0.0.1:"));
}

test "a header with a CR, an LF or a NUL is never written" {
    try testing.expect(http.header_safe("text/html; charset=utf-8"));
    for ([_][]const u8{ "a\rb", "a\nb", "a\x00b", "\r\n" }) |v| try testing.expect(!http.header_safe(v));
}
