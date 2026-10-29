//! **THE SERVER, END TO END**: a server on a port of its own (port 0) in
//! this process, the chat's Roc linked, and clients that speak HTTP by hand
//! over TCP, so a test can send half a head, stall a body or pipeline two
//! requests. Each test starts its own server, with deadlines short enough
//! to wait out.

const std = @import("std");
const Io = std.Io;
const server = @import("server.zig");

test {
    _ = @import("call.zig");
    _ = @import("config.zig");
    _ = @import("assets.zig");
    _ = @import("seam/roc_abi.zig");
    _ = @import("seam/sljmp.zig");
}

const io = std.testing.io;
const gpa = std.testing.allocator;

const RunResult = @typeInfo(@TypeOf(server.Server.run)).@"fn".return_type.?;

/// A server running on its own task, on a port of its own.
const Running = struct {
    server: server.Server,
    run: Io.Future(RunResult),
    /// The server's data root, a folder of the test's own.
    data: std.testing.TmpDir,

    fn start(limits: server.Limits) !*Running {
        const r = try gpa.create(Running);
        errdefer gpa.destroy(r);
        r.data = std.testing.tmpDir(.{});
        errdefer r.data.cleanup();
        r.server = try .init(io, gpa, try .parse("127.0.0.1", 0), limits, r.data.dir);
        r.run = try io.concurrent(server.Server.run, .{&r.server});
        return r;
    }

    fn stop(r: *Running) void {
        r.server.stop();
        r.run.await(io) catch |e| std.debug.print("the server's run: {t}\n", .{e});
        r.data.cleanup();
        gpa.destroy(r);
    }

    fn port(r: *const Running) u16 {
        return r.server.port();
    }

    fn turns(r: *const Running) u32 {
        return r.server.stats.turns.load(.acquire);
    }
};

/// A client's connection: bytes written as the test says, read to the end.
const Client = struct {
    stream: Io.net.Stream,

    fn open(port: u16) !Client {
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
        return .{ .stream = try addr.connect(io, .{ .mode = .stream }) };
    }

    fn send(c: Client, bytes: []const u8) !void {
        var w = c.stream.writer(io, &.{});
        try w.interface.writeAll(bytes);
    }

    /// Everything the server sends until it closes.
    fn rest(c: Client, arena: std.mem.Allocator) ![]u8 {
        var buf: [4096]u8 = undefined;
        var r = c.stream.reader(io, &buf);
        return r.interface.allocRemaining(arena, .limited(4 * 1024 * 1024));
    }

    fn close(c: Client) void {
        c.stream.close(io);
    }
};

/// One request on a connection of its own, and all the server sends back.
fn exchange(arena: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    const c = try Client.open(port);
    defer c.close();
    try c.send(request);
    return c.rest(arena);
}

/// A response as the tests read it.
const Response = struct {
    status: u16,
    head: []const u8,
    body: []const u8,

    fn of(bytes: []const u8) !Response {
        if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 ") or bytes.len < 12) return error.NotAResponse;
        const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.NoHeadEnd;
        return .{
            .status = try std.fmt.parseInt(u16, bytes[9..12], 10),
            .head = bytes[0 .. end + 2],
            .body = bytes[end + 4 ..],
        };
    }

    /// Header `name`'s value (lowercase, as std writes them), or null.
    fn header(r: Response, comptime name: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, r.head, "\r\n" ++ name ++ ": ") orelse return null;
        const from = at + name.len + 4;
        const to = std.mem.indexOfPos(u8, r.head, from, "\r\n") orelse return null;
        return r.head[from..to];
    }
};

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn msSince(t0: Io.Timestamp) i64 {
    return t0.untilNow(io, .awake).toMilliseconds();
}

const get_root = "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n";

test "GET / is the Roc's hello page, rendered by roc-markdown, with the Roc's own cache-control header" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try Running.start(.{});
    defer r.stop();
    const got = try Response.of(try exchange(arena.allocator(), r.port(), get_root));
    try std.testing.expectEqual(200, got.status);
    try std.testing.expect(has(got.body, "<strong>Hello</strong> from roc-chat."));
    try std.testing.expectEqualStrings("no-store", got.header("cache-control").?);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", got.header("content-type").?);
    try std.testing.expectEqual(1, r.turns());
}

test "the files through the Roc (the /stub/notes stub): append!'s size after, read!, and a failed sync or a 000 folder a 500" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    const get = "GET /stub/notes HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n";
    const post = "POST /stub/notes HTTP/1.1\r\nhost: t\r\nconnection: close\r\ncontent-length: 6\r\n\r\nhello\n";
    try std.testing.expectEqual(404, (try Response.of(try exchange(a, r.port(), get))).status);
    try std.testing.expectEqualStrings("size 6\n", (try Response.of(try exchange(a, r.port(), post))).body);
    try std.testing.expectEqualStrings("size 12\n", (try Response.of(try exchange(a, r.port(), post))).body);
    try std.testing.expectEqualStrings("hello\nhello\n", (try Response.of(try exchange(a, r.port(), get))).body);

    // The warnings are the point: quiet here.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    r.server.files.fault_for_test = .sync_fails;
    try std.testing.expectEqual(500, (try Response.of(try exchange(a, r.port(), post))).status);
    r.server.files.fault_for_test = .none;

    // **AN UNREADABLE FOLDER IS NEVER "NOTHING THERE"**: a 500, not the 404.
    var stub = try r.data.dir.openDir(io, "stub", .{ .iterate = true });
    defer stub.close(io);
    try stub.setPermissions(io, .fromMode(0o000));
    defer stub.setPermissions(io, .fromMode(0o700)) catch {};
    if (std.os.linux.geteuid() != 0) {
        try std.testing.expectEqual(500, (try Response.of(try exchange(a, r.port(), get))).status);
        try std.testing.expectEqual(500, (try Response.of(try exchange(a, r.port(), post))).status);
    }
}

test "a path the Roc has no route for is a 404; a method its route does not take, a 405 naming the one it does" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    const missing = try Response.of(try exchange(a, r.port(), "GET /nowhere HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(404, missing.status);
    const wrong = try Response.of(try exchange(a, r.port(), "GET /echo HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(405, wrong.status);
    try std.testing.expectEqualStrings("POST", wrong.header("allow").?);
}

test "the turn holds one handler at a time: 20 clients at once, each held 20 ms in the turn, are answered one after another (probe (a))" {
    const r = try Running.start(.{});
    defer r.stop();
    r.server.hold_turn_ms_for_test = 20;
    const clients = 20;
    var ok: std.atomic.Value(u32) = .init(0);
    const t0 = Io.Clock.now(.awake, io);
    var group: Io.Group = .init;
    for (0..clients) |_| try group.concurrent(io, oneHello, .{ r.port(), &ok });
    try group.await(io);
    try std.testing.expectEqual(clients, ok.load(.acquire));
    try std.testing.expectEqual(clients, r.turns());
    try std.testing.expectEqual(1, r.server.stats.most_in_turn.load(.acquire));
    // Twenty holds of 20 ms, one after another.
    try std.testing.expect(msSince(t0) >= clients * 20);
}

fn oneHello(port: u16, ok: *std.atomic.Value(u32)) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bytes = exchange(arena.allocator(), port, get_root) catch return;
    const got = Response.of(bytes) catch return;
    if (got.status == 200) _ = ok.fetchAdd(1, .acq_rel);
}

test "a slow client holds no turn: a body stalled halfway and a head half sent, while another client is answered at once; each slow one a 408 at its deadline" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{ .head_ms = 400, .body_ms = 400 });
    defer r.stop();

    const stalled_body = try Client.open(r.port());
    defer stalled_body.close();
    try stalled_body.send("POST /echo HTTP/1.1\r\nhost: t\r\ncontent-length: 100\r\n\r\nten bytes!");
    const half_head = try Client.open(r.port());
    defer half_head.close();
    try half_head.send("GET / HT");

    const t0 = Io.Clock.now(.awake, io);
    const quick = try Response.of(try exchange(a, r.port(), get_root));
    try std.testing.expectEqual(200, quick.status);
    try std.testing.expect(msSince(t0) < 300);
    try std.testing.expectEqual(1, r.turns());

    const body_late = try Response.of(try stalled_body.rest(a));
    try std.testing.expectEqual(408, body_late.status);
    const head_late = try Response.of(try half_head.rest(a));
    try std.testing.expectEqual(408, head_late.status);
    try std.testing.expect(msSince(t0) >= 300);
    // Neither slow one ever reached the Roc.
    try std.testing.expectEqual(1, r.turns());
}

test "the body cap: a length past it is a 413, never read and never in the turn; a chunked body past it the same; one under it but past the Roc's limit is the Roc's 413" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The Roc's /echo reads at most 32 KiB (app/main.roc `echo_most`).
    const r = try Running.start(.{ .body_most = 40 * 1024 });
    defer r.stop();

    // Said too long in its head: refused before a byte of it is read.
    const said = try Response.of(try exchange(a, r.port(), "POST /echo HTTP/1.1\r\nhost: t\r\ncontent-length: 50000\r\n\r\n"));
    try std.testing.expectEqual(413, said.status);
    try std.testing.expectEqual(0, r.turns());

    // Chunked, so known too long only once read past the cap.
    var chunked: std.ArrayList(u8) = .empty;
    try chunked.appendSlice(a, "POST /echo HTTP/1.1\r\nhost: t\r\ntransfer-encoding: chunked\r\n\r\n");
    for (0..41) |_| {
        try chunked.appendSlice(a, "400\r\n");
        try chunked.appendNTimes(a, 'c', 1024);
        try chunked.appendSlice(a, "\r\n");
    }
    try chunked.appendSlice(a, "0\r\n\r\n");
    const read_past = try Response.of(try exchange(a, r.port(), chunked.items));
    try std.testing.expectEqual(413, read_past.status);
    try std.testing.expectEqual(0, r.turns());

    // Under the host's cap, past the Roc's: read, then refused by the Roc.
    const body = try a.alloc(u8, 36 * 1024);
    @memset(body, 'r');
    const request = try std.fmt.allocPrint(a, "POST /echo HTTP/1.1\r\nhost: t\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ body.len, body });
    const roc_said = try Response.of(try exchange(a, r.port(), request));
    try std.testing.expectEqual(413, roc_said.status);
    try std.testing.expectEqual(1, r.turns());
}

test "a POST's path and headers survive its body's read, which reuses the buffer the head was in (probe (a)'s trap)" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    // Well past the read buffer (server.head_most, 16 KiB), so the body's
    // read refills it over where the head was. Measured with the path left
    // uncopied: 20,000 bytes did not trip it on loopback, 30,000 do.
    const body = try a.alloc(u8, 30_000);
    @memset(body, 'b');
    const request = try std.fmt.allocPrint(a, "POST /echo?q=1 HTTP/1.1\r\nhost: t\r\nX-Probe: kept\r\nx-probe: twice\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ body.len, body });
    const got = try Response.of(try exchange(a, r.port(), request));
    try std.testing.expectEqual(200, got.status);
    try std.testing.expect(std.mem.startsWith(u8, got.body, "path /echo\nx-probe kept twice \nbody 30000 bytes\nbbbb"));
    try std.testing.expectEqualStrings("nosniff", got.header("x-content-type-options").?);
}

test "keep-alive: two pipelined requests answered in order on one connection, the second's close honored" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try Running.start(.{});
    defer r.stop();
    const both = try exchange(arena.allocator(), r.port(), "GET / HTTP/1.1\r\nhost: t\r\n\r\n" ++
        "POST /echo HTTP/1.1\r\nhost: t\r\ncontent-length: 3\r\nconnection: close\r\n\r\nabc");
    const second_at = std.mem.indexOfPos(u8, both, 1, "HTTP/1.1 ") orelse return error.OneAnswer;
    const first = try Response.of(both[0..second_at]);
    const second = try Response.of(both[second_at..]);
    try std.testing.expectEqual(200, first.status);
    try std.testing.expect(has(first.body, "Hello"));
    try std.testing.expectEqual(null, first.header("connection"));
    try std.testing.expectEqual(200, second.status);
    try std.testing.expect(has(second.body, "body 3 bytes\nabc"));
    try std.testing.expectEqualStrings("close", second.header("connection").?);
    try std.testing.expectEqual(2, r.turns());
}

test "an idle kept-open connection is closed at its timeout, with no answer" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try Running.start(.{ .idle_ms = 300 });
    defer r.stop();
    const t0 = Io.Clock.now(.awake, io);
    const bytes = try exchange(arena.allocator(), r.port(), "GET / HTTP/1.1\r\nhost: t\r\n\r\n");
    try std.testing.expect(msSince(t0) >= 250);
    const got = try Response.of(bytes);
    try std.testing.expectEqual(200, got.status);
    // One answer, the page's, and no 408 after it.
    try std.testing.expect(std.mem.indexOfPos(u8, bytes, 1, "HTTP/1.1 ") == null);
}

test "a chat client script: a 200 with its ETag, then a 304 when the browser has those bytes; a script there is not, a 404" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    const first = try Response.of(try exchange(a, r.port(), "GET /chat.js HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(200, first.status);
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", first.header("content-type").?);
    try std.testing.expect(first.body.len > 1000);
    const etag = first.header("etag").?;
    const again = try std.fmt.allocPrint(a, "GET /chat.js HTTP/1.1\r\nhost: t\r\nif-none-match: {s}\r\nconnection: close\r\n\r\n", .{etag});
    const second = try Response.of(try exchange(a, r.port(), again));
    try std.testing.expectEqual(304, second.status);
    try std.testing.expectEqual(0, second.body.len);
    const none = try Response.of(try exchange(a, r.port(), "GET /nope.js HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(404, none.status);
}
