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
const sign_in = @import("sign_in_primitives.zig");

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
        return start_on(limits, gpa);
    }

    /// A server whose own allocations are `server_gpa`'s.
    pub fn start_on(limits: http.Limits, server_gpa: std.mem.Allocator) !*Running {
        const r = try gpa.create(Running);
        errdefer gpa.destroy(r);
        r.data = testing.tmpDir(.{});
        errdefer r.data.cleanup();
        r.root = .{ .io = io, .dir = r.data.dir };
        r.server = try .listen(io, server_gpa, .{ .port = 0, .limits = limits, .root = &r.root });
        r.run = try io.concurrent(http.Server.run, .{&r.server});
        try sign_in_steve(r);
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

/// The cookie header that signs Steve in to the server the test runs, as
/// the app reads a session (app/Session.roc): his id, the second it was
/// signed at and its HMAC under the server's secret. The tests run one at
/// a time, so the running server's is the one here.
var steve_cookie_buf: [256]u8 = undefined;
var steve_cookie: []const u8 = "";

/// Steve signed in to `r`'s server: a password file, which a session needs
/// its human to have, and a session signed now.
fn sign_in_steve(r: *Running) !void {
    try r.data.dir.writeFile(io, .{ .sub_path = "auth/1/password", .data = "a hash the tests never check" });
    const now = files.current_utc_seconds_since_epoch(io);
    var signed_buf: [32]u8 = undefined;
    const signed = try std.fmt.bufPrint(&signed_buf, "1\n{d}", .{now});
    const mac = sign_in.hmac_sha256(r.server.secret.slice(), signed);
    var mac_text: [64]u8 = undefined;
    const b64 = std.base64.url_safe_no_pad.Encoder;
    steve_cookie = try std.fmt.bufPrint(&steve_cookie_buf, "cookie: __Host-gopher_auth=MQ.{d}.{s}\r\n", .{ now, b64.encode(&mac_text, &mac) });
}

/// A request to the server at `port`, by Steve: `line`, its request line,
/// then the Host that names this server (the app refuses any other,
/// app/RequestOrigin.roc) and Steve's session, then `rest`, the other
/// headers, the empty line and any body.
fn ours(a: std.mem.Allocator, port: u16, comptime line: []const u8, comptime rest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, line ++ "\r\nhost: 127.0.0.1:{d}\r\n{s}" ++ rest, .{ port, steve_cookie });
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

/// The app's caps on a body (app/main.roc's allowances): a form's, and an
/// upload's, an image of 10 MiB and 64 KiB for its form.
const form_most = 64 * 1024;
const upload_most = 10 * 1024 * 1024 + 64 * 1024;

test "a body over the app's cap is a 413, one at it is read; a head over the cap is a 431" {
    const r = try Running.start(.{});
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    // Refused by its length alone, its body never sent.
    const over = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", std.fmt.comptimePrint("content-length: {d}\r\n\r\n", .{form_most + 1})));
    try testing.expectEqual(413, try status(over));
    // At the cap: read, and the Roc refuses the form (no `markdown`).
    const at = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", std.fmt.comptimePrint("content-length: {d}\r\n\r\n", .{form_most}) ++ @as([form_most]u8, @splat('m'))));
    try testing.expectEqual(400, try status(at));
    try testing.expect(has(at, "The form has no field `markdown`."));
    const head = try exchange(a, port, "GET / HTTP/1.1\r\nx-big: " ++ @as([http.head_most]u8, @splat('h')) ++ "\r\n\r\n");
    try testing.expectEqual(431, try status(head));
}

test "an upload's own cap: a routed upload at it reaches the Roc; past it, a 413; past a form's cap, a 413 for a message, a PUT, and a path ending /upload that is no conversation's" {
    const r = try Running.start(.{});
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const at_most = try a.alloc(u8, upload_most);
    @memset(at_most, 'u');
    // Read whole, and the Roc refuses it as no form of one file.
    const upload = try exchange(a, port, try std.fmt.allocPrint(a, "POST /chat/dm/1_1/plans/upload HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\n{s}content-length: {d}\r\n\r\n{s}", .{ port, steve_cookie, upload_most, at_most }));
    try testing.expectEqual(400, try status(upload));
    try testing.expect(has(upload, "no file"));
    // Each refused by its length alone, its body never sent.
    const past_form = std.fmt.comptimePrint("content-length: {d}\r\n\r\n", .{form_most + 1});
    const over = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans/upload HTTP/1.1", std.fmt.comptimePrint("content-length: {d}\r\n\r\n", .{upload_most + 1})));
    try testing.expectEqual(413, try status(over));
    const message = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", past_form));
    try testing.expectEqual(413, try status(message));
    const put = try exchange(a, port, try ours(a, port, "PUT /chat/dm/1_1/plans/upload HTTP/1.1", past_form));
    try testing.expectEqual(413, try status(put));
    const unrouted = try exchange(a, port, try ours(a, port, "POST /x/upload HTTP/1.1", past_form));
    try testing.expectEqual(413, try status(unrouted));
}

test "a request from elsewhere is refused from its head, its body never waited for; one from here waits for its body" {
    const r = try Running.start(.{ .read_ms = 2_000 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    // A head whose body never comes: a page elsewhere, then this server's.
    const began = Io.Clock.now(.awake, io);
    const foreign = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans/upload HTTP/1.1", "origin: http://evil.example\r\ncontent-length: 1000\r\n\r\n"));
    try testing.expectEqual(403, try status(foreign));
    try testing.expect(has(foreign, "another origin"));
    try testing.expect(has(foreign, "cross-origin-resource-policy: same-origin"));
    try testing.expect(began.untilNow(io, .awake).toMilliseconds() < 1_000);
    const rebound = try exchange(a, port, "POST /chat/dm/1_1/plans HTTP/1.1\r\nhost: rebound.example\r\ncontent-length: 1000\r\n\r\n");
    try testing.expectEqual(403, try status(rebound));
    const own = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "origin: http://127.0.0.1:0\r\ncontent-length: 1000\r\n\r\n"));
    try testing.expectEqual(403, try status(own));
    const here = try exchange(a, port, try std.fmt.allocPrint(a, "POST /chat/dm/1_1/plans HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\norigin: http://127.0.0.1:{d}\r\ncontent-length: 1000\r\n\r\n", .{ port, port }));
    try testing.expectEqual(408, try status(here));
}

test "the body bytes in flight are capped across connections: past the cap a 503, its body unread; at it, read; once answered, given back" {
    const r = try Running.start(.{ .body_bytes_in_flight_most = 100 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    // A message of 60 bytes, held part sent.
    const held_form = "markdown=" ++ @as([51]u8, @splat('h'));
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const held = try addr.connect(io, .{ .mode = .stream });
    defer held.close(io);
    var w = held.writer(io, &.{});
    try w.interface.writeAll(try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 60\r\n\r\n" ++ held_form[0..9]));
    try wait_until_in_flight(r, 60);
    const sixty = "markdown=" ++ @as([51]u8, @splat('s'));
    const busy = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 60\r\n\r\n" ++ sixty));
    try testing.expectEqual(503, try status(busy));
    const forty = "markdown=" ++ @as([31]u8, @splat('f'));
    const fits = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 40\r\n\r\n" ++ forty));
    try testing.expectEqual(303, try status(fits));
    try w.interface.writeAll(held_form[9..]);
    var buf: [4096]u8 = undefined;
    var rd = held.reader(io, &buf);
    try testing.expectEqual(303, try status(try rd.interface.allocRemaining(a, .limited(64 * 1024))));
    try wait_until_in_flight(r, 0);
    const after = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 60\r\n\r\n" ++ sixty));
    try testing.expectEqual(303, try status(after));
}

/// Waits, at most 2 s, for the server's body bytes in flight to be `n`.
fn wait_until_in_flight(r: *Running, n: usize) !void {
    for (0..200) |_| {
        if (r.server.body_bytes_in_flight.load(.monotonic) == n) return;
        try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io);
    }
    return error.TestInFlightNeverReached;
}

test "an upload's body has its own time: one that pauses past the read's time is read whole; a message's is a 408" {
    const r = try Running.start(.{ .read_ms = 200 });
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
    const slow_body = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 20\r\n\r\nmarkdown=x"));
    try testing.expectEqual(408, try status(slow_body));
    const next = try exchange(a, port, try ours(a, port, "GET /nowhere HTTP/1.1", "\r\n"));
    try testing.expectEqual(404, try status(next));
}

test "a refused client that never closes holds its own connection, not the server" {
    const r = try Running.start(.{ .write_ms = 5_000, .linger_ms = 1_000 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const held = try addr.connect(io, .{ .mode = .stream });
    defer held.close(io);
    var w = held.writer(io, &.{});
    try w.interface.writeAll(try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", std.fmt.comptimePrint("content-length: {d}\r\n\r\n", .{form_most + 1})));
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

test "a stream held its longest is ended, so its client reconnects and is asked again who it is; one younger is held" {
    const r = try Running.start(.{ .stream_most_ms = 300 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const started = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 10\r\n\r\nmarkdown=x"));
    try testing.expectEqual(303, try status(started));
    var stream: HeldStream = undefined;
    const began = Io.Clock.now(.awake, io);
    try stream.open(a, port, "1");
    defer stream.connection.close(io);
    // A stream never ended by the server is shut here, so the test fails
    // on its time rather than hang.
    var watchdog = try io.concurrent(shut_after, .{ stream.connection, 3_000 });
    defer watchdog.cancel(io);
    // Within its age a frame still comes.
    const posted = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 10\r\n\r\nmarkdown=y"));
    try testing.expectEqual(303, try status(posted));
    try testing.expectEqualStrings("id: 2\n", (try stream.line()).?);
    while (try stream.line()) |_| {}
    const held = began.untilNow(io, .awake).toMilliseconds();
    try testing.expect(held >= 300 and held < 2_000);
}

fn shut_after(connection: Io.net.Stream, ms: u32) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch return;
    connection.shutdown(io, .both) catch {};
}

test "a public name is a stranger's when the server has no public origin" {
    const r = try Running.start(.{});
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const public = try exchange(a, port, try std.fmt.allocPrint(a, "GET /chat/dm/1_1/plans HTTP/1.1\r\nhost: chat.example.test\r\norigin: https://chat.example.test\r\n{s}\r\n", .{steve_cookie}));
    try testing.expectEqual(403, try status(public));
    try testing.expect(has(public, "Host is not this server"));
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

/// A stream of the conversation `/chat/dm/1_1/plans` after its `after`
/// messages, held open, its head read. The conversation needs its
/// transcript: a stream of one with none is a 404.
const HeldStream = struct {
    connection: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    buf: [16 * 1024]u8,

    fn open(s: *HeldStream, a: std.mem.Allocator, port: u16, comptime after: []const u8) !void {
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
        s.connection = try addr.connect(io, .{ .mode = .stream });
        var w = s.connection.writer(io, &.{});
        try w.interface.writeAll(try ours(a, port, "GET /chat/dm/1_1/plans/stream?after=" ++ after ++ " HTTP/1.1", "\r\n"));
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
    // A conversation's stream needs its transcript, so the first message
    // starts it.
    const started = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 10\r\n\r\nmarkdown=x"));
    try testing.expectEqual(303, try status(started));
    var streams: [3]HeldStream = undefined;
    for (&streams) |*s| try s.open(a, port, "1");
    defer for (&streams) |*s| s.connection.close(io);
    const posted = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 10\r\n\r\nmarkdown=y"));
    try testing.expectEqual(303, try status(posted));
    // The first was ended for the third, before the post: closed, no frame.
    try testing.expectEqual(null, try streams[0].line());
    for (streams[1..]) |*s| try testing.expectEqualStrings("id: 2\n", (try s.line()).?);
}

test "a stream ended for a newer one of its holder lets go of its subscriber and its slot at once" {
    const r = try Running.start(.{ .streams_per_holder = 1 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const started = try exchange(a, port, try ours(a, port, "POST /chat/dm/1_1/plans HTTP/1.1", "content-length: 10\r\n\r\nmarkdown=x"));
    try testing.expectEqual(303, try status(started));
    var streams: [2]HeldStream = undefined;
    try streams[0].open(a, port, "1");
    defer streams[0].connection.close(io);
    try testing.expectEqual(1, r.server.hub.count());
    try streams[1].open(a, port, "1");
    defer streams[1].connection.close(io);
    try testing.expectEqual(null, try streams[0].line());
    // Its task wakes now, not at its keepalive, 25 s on.
    for (0..200) |_| {
        if (r.server.hub.count() == 1) break;
        try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io);
    }
    try testing.expectEqual(1, r.server.hub.count());
    try testing.expectEqual(1, r.server.slots.count(io));
}

/// An allocator that counts the bytes its child holds for it, so a test can
/// see how much a server keeps.
const Counting = struct {
    child: std.mem.Allocator,
    held: std.atomic.Value(usize) = .init(0),

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn of(ctx: *anyopaque) *Counting {
        return @ptrCast(@alignCast(ctx));
    }

    fn moved(c: *Counting, from: usize, to: usize) void {
        if (to >= from) _ = c.held.fetchAdd(to - from, .monotonic) else _ = c.held.fetchSub(from - to, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const p = of(ctx).child.rawAlloc(len, alignment, ret) orelse return null;
        of(ctx).moved(0, len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        if (!of(ctx).child.rawResize(memory, alignment, new_len, ret)) return false;
        of(ctx).moved(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const p = of(ctx).child.rawRemap(memory, alignment, new_len, ret) orelse return null;
        of(ctx).moved(memory.len, new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        of(ctx).child.rawFree(memory, alignment, ret);
        of(ctx).moved(memory.len, 0);
    }
};

test "a held stream keeps none of its call's arena: the transcript read, decoded and rendered is freed once its backlog is sent" {
    var counting: Counting = .{ .child = gpa };
    const r = try Running.start_on(.{}, counting.allocator());
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    // A transcript of 100 messages of 4,000 bytes each.
    const messages = 100;
    var transcript: std.ArrayList(u8) = .empty;
    for (1..messages + 1) |n| try transcript.print(a, "-------------\nMSG_plans_{d}\nfrom: Steve\ndate: 2026-11-02T18:02:11Z\n\n{s}\n\n", .{ n, @as([4000]u8, @splat('x')) });
    try r.data.dir.createDirPath(io, "chat/dm/1_1/plans");
    try r.data.dir.writeFile(io, .{ .sub_path = "chat/dm/1_1/plans/transcript", .data = transcript.items });
    var stream: HeldStream = undefined;
    try stream.open(a, port, "0");
    defer stream.connection.close(io);
    // The backlog whole: every message's frame.
    var frames: usize = 0;
    while (frames < messages) {
        const line = (try stream.line()) orelse return error.TestStreamEnded;
        if (std.mem.startsWith(u8, line, "id: ")) frames += 1;
    }
    // What the server holds while the stream stays open: a few small
    // records, none of the transcript.
    for (0..200) |_| {
        if (counting.held.load(.monotonic) < 64 * 1024) break;
        try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(10) }, io);
    }
    try testing.expect(counting.held.load(.monotonic) < 64 * 1024);
    try testing.expect(transcript.items.len > 400_000);
}

test "the app's start: an empty data folder gets the first chat; one holding part of a chat, or a broken one, is refused, and the server doesn't listen" {
    var empty = testing.tmpDir(.{});
    defer empty.cleanup();
    const empty_root: files.DataRoot = .{ .io = io, .dir = empty.dir };
    try http.start_app(io, gpa, &empty_root);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("2\n", try empty.dir.readFile(io, "auth/next-id.txt", &buf));
    // Started again, it reads the chat it made.
    try http.start_app(io, gpa, &empty_root);

    // An account and no counter of ids: part of a chat.
    var partial = testing.tmpDir(.{});
    defer partial.cleanup();
    try partial.dir.createDirPath(io, "auth/1");
    try partial.dir.writeFile(io, .{ .sub_path = "auth/1/name", .data = "Steve" });
    const partial_root: files.DataRoot = .{ .io = io, .dir = partial.dir };
    try testing.expectError(error.AppStartFailed, http.start_app(io, gpa, &partial_root));
    try testing.expectError(error.AppStartFailed, http.Server.listen(io, gpa, .{ .port = 0, .root = &partial_root }));

    // A counter behind its users: no chat.
    try partial.dir.writeFile(io, .{ .sub_path = "auth/next-id.txt", .data = "1\n" });
    try testing.expectError(error.AppStartFailed, http.start_app(io, gpa, &partial_root));
    // Mended, it starts.
    try partial.dir.writeFile(io, .{ .sub_path = "auth/next-id.txt", .data = "2\n" });
    try http.start_app(io, gpa, &partial_root);

    // An account cut short as it was made, its owner written and no name:
    // no account, and the chat still starts. Its name written, it is one.
    try partial.dir.createDirPath(io, "auth/2");
    try partial.dir.writeFile(io, .{ .sub_path = "auth/2/owner", .data = "1" });
    try partial.dir.writeFile(io, .{ .sub_path = "auth/next-id.txt", .data = "3\n" });
    try http.start_app(io, gpa, &partial_root);
    try partial.dir.writeFile(io, .{ .sub_path = "auth/2/name", .data = "CC" });
    try http.start_app(io, gpa, &partial_root);
    // A name that is no name still stops the start: only a missing one is
    // an account cut short.
    try partial.dir.writeFile(io, .{ .sub_path = "auth/2/name", .data = "C!C" });
    try testing.expectError(error.AppStartFailed, http.start_app(io, gpa, &partial_root));
}

/// A sign-in by no one, the form `form`, on a connection of its own, with
/// memory of its own, so several can run at once: its status, and how long
/// its answer took.
fn sign_in_by_form(port: u16, form: []const u8) !SignIn {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const began = Io.Clock.now(.awake, io);
    const bytes = try exchange(a, port, try std.fmt.allocPrint(a, "POST /login HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\ncontent-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\n{s}", .{ port, form.len, form }));
    return .{ .status = try status(bytes), .ms = began.untilNow(io, .awake).toMilliseconds() };
}

const SignIn = struct { status: u16, ms: i64 };

const SignInAnswer = @typeInfo(@TypeOf(sign_in_by_form)).@"fn".return_type.?;

/// Steve's password file holding a bcrypt hash, at the cost the server
/// writes one, of `password`.
fn set_steve_password(r: *Running, password: []const u8) !void {
    var buf: [sign_in.bcrypt_hash_length]u8 = undefined;
    try r.data.dir.writeFile(io, .{ .sub_path = "auth/1/password", .data = sign_in.bcrypt_hash_of_password(io, password, &buf) });
}

test "the checks' bucket: a burst at once is checked, the one past it a 429 with no check run, and any after it too until the bucket refills" {
    const r = try Running.start(.{ .password_check_burst = 5, .password_check_refill_ms = 600_000 });
    defer r.stop();
    const port = r.server.port();
    try set_steve_password(r, "right");
    var burst: [6]Io.Future(SignInAnswer) = undefined;
    for (&burst) |*f| f.* = try io.concurrent(sign_in_by_form, .{ port, "name=Nobody&password=guess" });
    var checked: usize = 0;
    var refused: usize = 0;
    for (&burst) |*f| {
        const answer = try f.await(io);
        if (answer.status == 401) checked += 1;
        if (answer.status == 429) refused += 1;
    }
    try testing.expectEqual(5, checked);
    try testing.expectEqual(1, refused);
    try testing.expectEqual(5, r.server.password_checks.spent.load(.monotonic));
    // The right password for a human: still a 429, nothing checked.
    try testing.expectEqual(429, (try sign_in_by_form(port, "name=Steve&password=right")).status);
    try testing.expectEqual(5, r.server.password_checks.spent.load(.monotonic));
}

test "a sign-in runs a check on every path a name can take, each as slow as a wrong password's; a stored hash that is no hash answers as a wrong password" {
    const r = try Running.start(.{ .password_check_burst = 20 });
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    const made = try exchange(a, port, try ours(a, port, "POST /agents HTTP/1.1", "content-type: application/x-www-form-urlencoded\r\ncontent-length: 7\r\n\r\nname=CC"));
    try testing.expectEqual(303, try status(made));
    const spent = &r.server.password_checks.spent;
    // Running's own password file, which holds no hash: the host refuses
    // it unchecked, then the dummy hash is checked.
    const no_hash = try sign_in_by_form(port, "name=Steve&password=guess");
    try testing.expectEqual(401, no_hash.status);
    try testing.expectEqual(2, spent.load(.monotonic));
    try set_steve_password(r, "right");
    const wrong = try sign_in_by_form(port, "name=Steve&password=guess");
    try testing.expectEqual(401, wrong.status);
    try testing.expectEqual(303, (try sign_in_by_form(port, "name=Steve&password=right")).status);
    try testing.expectEqual(4, spent.load(.monotonic));
    const nobody = try sign_in_by_form(port, "name=Nobody&password=guess");
    const agent = try sign_in_by_form(port, "name=CC&password=guess");
    try r.data.dir.deleteFile(io, "auth/1/password");
    const no_file = try sign_in_by_form(port, "name=Steve&password=guess");
    try testing.expectEqual(7, spent.load(.monotonic));
    for ([_]SignIn{ no_hash, nobody, agent, no_file }) |answer| {
        try testing.expectEqual(401, answer.status);
        try testing.expect(answer.ms * 2 >= wrong.ms);
    }
    // A form that names no one at all is refused by its spelling, unchecked.
    try testing.expectEqual(401, (try sign_in_by_form(port, "name=No%20one!&password=guess")).status);
    try testing.expectEqual(401, (try sign_in_by_form(port, "name=Nobody&password=")).status);
    try testing.expectEqual(7, spent.load(.monotonic));
}

test "a password's check lets the turn go: a page is answered while bcrypt runs" {
    const r = try Running.start(.{});
    defer r.stop();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const port = r.server.port();
    try set_steve_password(r, "right");
    const began = Io.Clock.now(.awake, io);
    var check = try io.concurrent(sign_in_by_form, .{ port, "name=Steve&password=guess" });
    const head_start_ms = 50;
    try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(head_start_ms) }, io);
    const page_began = Io.Clock.now(.awake, io);
    const page = try exchange(a, port, try std.fmt.allocPrint(a, "GET /login HTTP/1.1\r\nhost: 127.0.0.1:{d}\r\n\r\n", .{port}));
    const page_ms = page_began.untilNow(io, .awake).toMilliseconds();
    const checked = try check.await(io);
    const check_ms = began.untilNow(io, .awake).toMilliseconds();
    try testing.expectEqual(200, try status(page));
    try testing.expectEqual(401, checked.status);
    // bcrypt took long enough to matter, and the page took a fraction of it.
    try testing.expect(check_ms >= head_start_ms + 30);
    try testing.expect(page_ms * 2 < check_ms - head_start_ms);
}
