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

test "an upload's own cap: a POST to a path ending /upload past the body cap reaches the Roc; the same body elsewhere, or a PUT, is a 413; past the upload cap, a 413 for it too" {
    const r = try Running.start(.{ .body_most = 64, .upload_body_most = 128 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const hundred = "content-length: 100\r\n\r\n" ++ @as([100]u8, @splat('u'));
    // Read, and the Roc refuses it as no form of one file.
    const upload = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans/upload HTTP/1.1", hundred));
    try testing.expectEqual(400, try status(upload));
    const message = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", hundred));
    try testing.expectEqual(413, try status(message));
    const put = try exchange(a, port, try ours(a, port, "PUT /chat/dm/1_1/plans/upload HTTP/1.1", hundred));
    try testing.expectEqual(413, try status(put));
    const over = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans/upload HTTP/1.1", "content-length: 129\r\n\r\n" ++ @as([129]u8, @splat('u'))));
    try testing.expectEqual(413, try status(over));
    try testing.expect(http.is_upload(.{ .method = "POST", .path = "/a/upload", .query = "", .headers = &.{}, .body = "", .port = 1 }));
    try testing.expect(!http.is_upload(.{ .method = "GET", .path = "/a/upload", .query = "", .headers = &.{}, .body = "", .port = 1 }));
    try testing.expect(!http.is_upload(.{ .method = "POST", .path = "/a/uploads", .query = "", .headers = &.{}, .body = "", .port = 1 }));
}

test "an upload's body has its own time: one that pauses past the read's time is read whole; a message's is a 408" {
    const r = try Running.start(.{ .read_ms = 200, .upload_body_read_ms = 5_000 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const upload = try paused(a, port, try ours(a, port, "POST /chat/dm/1_1/plans/upload HTTP/1.1", "content-length: 9\r\n\r\nupl"), "oaded!");
    try testing.expectEqual(400, try status(upload));
    const message = try paused(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 9\r\n\r\nmar"), "kdown=");
    try testing.expectEqual(408, try status(message));
}

/// `first` on a connection of its own, then a pause of 400 ms, then `rest`,
/// and everything sent back.
fn paused(arena: std.mem.Allocator, port: u16, first: []const u8, rest: []const u8) ![]u8 {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const connection = try addr.connect(io, .{ .mode = .stream });
    defer connection.close(io);
    var w = connection.writer(io, &.{});
    try w.interface.writeAll(first);
    try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(400) }, io);
    w.interface.writeAll(rest) catch {};
    var buf: [4096]u8 = undefined;
    var r = connection.reader(io, &buf);
    return r.interface.allocRemaining(arena, .limited(4 * 1024 * 1024));
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

test "a refused client that never closes holds its own connection, not the server" {
    const r = try Running.start(.{ .body_most = 64, .write_ms = 5_000, .linger_ms = 1_000 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const held = try addr.connect(io, .{ .mode = .stream });
    defer held.close(io);
    var w = held.writer(io, &.{});
    try w.interface.writeAll("POST /chat/dm/1_1/plans HTTP/1.1\r\nhost: x\r\ncontent-length: 1000\r\n\r\n");
    var buf: [4096]u8 = undefined;
    var rd = held.reader(io, &buf);
    // The refusal, read to the server's shut of its side; this side stays open.
    try testing.expectEqual(413, try status(try rd.interface.allocRemaining(a, .limited(64 * 1024))));
    const began = Io.Clock.now(.awake, io);
    const next = try exchange(a, port, try ours(a, port, "GET /nowhere HTTP/1.1", "\r\n"));
    const waited = began.untilNow(io, .awake).toMilliseconds();
    try testing.expectEqual(404, try status(next));
    // Answered on its own task while the refused connection lingers.
    try testing.expect(waited < 500);
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

/// A stream of the conversation `path`, held open, its head read.
const HeldStream = struct {
    connection: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    buf: [16 * 1024]u8,

    fn open(s: *HeldStream, a: std.mem.Allocator, port: u16) !void {
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
        s.connection = try addr.connect(io, .{ .mode = .stream });
        var w = s.connection.writer(io, &.{});
        try w.interface.writeAll(try ours(a, port, "GET /chat/dm/1_1/plans/stream?after=0 HTTP/1.1", "\r\n"));
        s.reader = s.connection.reader(io, &s.buf);
        var last: [4]u8 = @splat(0);
        while (!std.mem.eql(u8, &last, "\r\n\r\n")) {
            std.mem.copyForwards(u8, last[0..3], last[1..4]);
            last[3] = try s.reader.interface.takeByte();
        }
    }

    /// The next line the stream sends, or null when the server ended it.
    fn line(s: *HeldStream) !?[]const u8 {
        return s.reader.interface.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => null,
            else => e,
        };
    }
};

test "a holder at its cap ends its own oldest stream, and its newer ones still get every frame" {
    const r = try Running.start(.{ .streams_per_holder = 2 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    var streams: [3]HeldStream = undefined;
    for (&streams) |*s| try s.open(a, port);
    defer for (&streams) |*s| s.connection.close(io);
    const posted = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 10\r\n\r\nmarkdown=x"));
    try testing.expectEqual(303, try status(posted));
    // The first was ended for the third, before the post: closed, no frame.
    try testing.expectEqual(null, try streams[0].line());
    for (streams[1..]) |*s| try testing.expectEqualStrings("id: 1\n", (try s.line()).?);
}
