//! **THE SERVER, END TO END**: a server on a port of its own (port 0) in
//! this process, the server's probe linked (app/test/probe.roc: the
//! plainest routes that drive each part of the host, so no test here signs
//! in; the chat's own routes are host/chat_test.zig's), and clients that speak HTTP by hand
//! over TCP, so a test can send half a head, stall a body or pipeline two
//! requests. Each test starts its own server, with deadlines short enough
//! to wait out.

const std = @import("std");
const Io = std.Io;
const server = @import("server.zig");
const h = @import("test_http.zig");

test {
    _ = @import("call.zig");
    _ = @import("config.zig");
    _ = @import("assets.zig");
    _ = @import("seam/roc_abi.zig");
    _ = @import("seam/sljmp.zig");
}

const io = h.io;
const gpa = h.gpa;
const Running = h.Running;
const Client = h.Client;
const Response = h.Response;
const exchange = h.exchange;
const has = h.has;
const msSince = h.msSince;

const get_root = "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n";

test "the files through the Roc (the probe's /notes): append!'s size after, read!, and a failed sync or a 000 folder a 500" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    const get = "GET /notes HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n";
    const append = "POST /notes HTTP/1.1\r\nhost: t\r\nconnection: close\r\ncontent-length: 6\r\n\r\nhello\n";
    try std.testing.expectEqual(404, (try Response.of(try exchange(a, r.port(), get))).status);
    try std.testing.expectEqualStrings("size 6\n", (try Response.of(try exchange(a, r.port(), append))).body);
    try std.testing.expectEqualStrings("size 12\n", (try Response.of(try exchange(a, r.port(), append))).body);
    try std.testing.expectEqualStrings("hello\nhello\n", (try Response.of(try exchange(a, r.port(), get))).body);

    // The warnings are the point: quiet here.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    r.server.files.fault_for_test = .sync_fails;
    try std.testing.expectEqual(500, (try Response.of(try exchange(a, r.port(), append))).status);
    r.server.files.fault_for_test = .none;

    // **AN UNREADABLE FOLDER IS NEVER "NOTHING THERE"**: a 500, not the 404.
    var probe = try r.data.dir.openDir(io, "probe", .{ .iterate = true });
    defer probe.close(io);
    try probe.setPermissions(io, .fromMode(0o000));
    defer probe.setPermissions(io, .fromMode(0o700)) catch {};
    if (std.os.linux.geteuid() != 0) {
        try std.testing.expectEqual(500, (try Response.of(try exchange(a, r.port(), get))).status);
        try std.testing.expectEqual(500, (try Response.of(try exchange(a, r.port(), append))).status);
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

test "the turn holds one handler at a time: 20 clients at once, each held 20 ms in the turn, are answered one after another" {
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
    // The probe's /echo reads at most 32 KiB (app/test/probe.roc `echo_most`).
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

test "a POST's path and headers survive its body's read, which reuses the buffer the head was in" {
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

// ── the bus and SSE, through the probe's /stream and /post ─────────────────

/// A held stream as a browser reads it: its head, then what it says, kept
/// in `got` as it arrives.
const Listener = struct {
    stream: Io.net.Stream,
    buf: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    got: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,

    /// A stream of `key`, its head read: subscribed, and its backlog on
    /// the way. `rcvbuf` (0: the kernel's) shrinks what it takes unread.
    fn open(arena: std.mem.Allocator, port: u16, key: []const u8, rcvbuf: u32) !*Listener {
        const l = try arena.create(Listener);
        l.* = .{ .stream = (try Client.open(port)).stream, .arena = arena };
        if (rcvbuf > 0) server.setBuffer(l.stream, std.posix.SO.RCVBUF, rcvbuf);
        l.reader = l.stream.reader(io, &l.buf);
        const c: Client = .{ .stream = l.stream };
        try c.send(try std.fmt.allocPrint(arena, "GET /stream/{s} HTTP/1.1\r\nhost: t\r\n\r\n", .{key}));
        try l.until("\r\n\r\n");
        const head = try Response.of(l.got.items);
        if (head.status != 200) return error.NotAStream;
        if (!std.mem.eql(u8, head.header("content-type") orelse "", "text/event-stream")) return error.NotAStream;
        // Keep only what came after the head.
        const body_len = head.body.len;
        std.mem.copyForwards(u8, l.got.items, head.body);
        l.got.shrinkRetainingCapacity(body_len);
        return l;
    }

    /// Reads until `needle` has arrived.
    fn until(l: *Listener, needle: []const u8) !void {
        while (!has(l.got.items, needle)) try l.more();
    }

    /// Reads until the server ends the stream.
    fn toEnd(l: *Listener) !void {
        while (true) l.more() catch |e| switch (e) {
            error.EndOfStream => return,
            else => return e,
        };
    }

    fn more(l: *Listener) !void {
        const r = &l.reader.interface;
        const bytes = try r.peekGreedy(1);
        try l.got.appendSlice(l.arena, bytes);
        r.toss(bytes.len);
    }

    fn close(l: *Listener) void {
        l.stream.close(io);
    }
};

fn post(arena: std.mem.Allocator, port: u16, key: []const u8, data: []const u8) !void {
    const got = try Response.of(try exchange(arena, port, try std.fmt.allocPrint(
        arena,
        "POST /post/{s} HTTP/1.1\r\nhost: t\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
        .{ key, data.len, data },
    )));
    if (got.status != 200) return error.PostRefused;
}

fn postOrPanic(port: u16, key: []const u8, data: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    post(arena.allocator(), port, key, data) catch |e| std.debug.panic("post {s}: {t}", .{ data, e });
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

/// Polls `f` until it is true, at most `ms`.
fn eventually(ms: i64, ctx: anytype, comptime f: fn (@TypeOf(ctx)) bool) !void {
    const t0 = Io.Clock.now(.awake, io);
    while (!f(ctx)) {
        if (msSince(t0) > ms) return error.NeverHappened;
        Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(5) }, io) catch {};
    }
}

test "streams: two held streams get the backlog, then 12 concurrent posts live, each once and in the turn's order" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    try post(a, r.port(), "room", "before");
    const one = try Listener.open(a, r.port(), "room", 0);
    defer one.close();
    const two = try Listener.open(a, r.port(), "room", 0);
    defer two.close();
    const posts = 12;
    var group: Io.Group = .init;
    for (0..posts) |i| try group.concurrent(io, postOrPanic, .{ r.port(), "room", try std.fmt.allocPrint(a, "m{d}", .{i}) });
    try group.await(io);
    for ([_]*Listener{ one, two }) |l| {
        try l.until(try std.fmt.allocPrint(a, "id: {d}\n", .{posts}));
        try std.testing.expect(std.mem.startsWith(u8, l.got.items, "id: 0\ndata: before\n\n"));
        // Every id once, in order: the turn numbered them as it published.
        var at: usize = 0;
        for (0..posts + 1) |id| {
            const frame = try std.fmt.allocPrint(a, "id: {d}\ndata: ", .{id});
            try std.testing.expectEqual(1, count(l.got.items, frame));
            const here = std.mem.indexOf(u8, l.got.items, frame).?;
            try std.testing.expect(here >= at);
            at = here;
        }
    }
    try std.testing.expectEqualStrings(one.got.items, two.got.items);
}

fn holdsBegun(r: *Running) bool {
    return r.server.stats.subscribe_holds.load(.acquire) == 1;
}

test "streams: backlog xor live: a post landing between the Roc's backlog read and the subscribe arrives exactly once" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    try post(a, r.port(), "gap", "old");
    r.server.hold_before_subscribe_ms_for_test = 150;
    // The stream's request, its head read on a task of its own: it reads
    // the backlog, then sleeps before its subscribe.
    var opened = try io.concurrent(Listener.open, .{ a, r.port(), "gap", 0 });
    try eventually(2000, r, holdsBegun);
    // In the gap: the post waits for the turn, or (were the subscribe out
    // of it) lands where neither the backlog nor the live stream sees it.
    try post(a, r.port(), "gap", "between");
    const l = try opened.await(io);
    defer l.close();
    try post(a, r.port(), "gap", "after");
    try l.until("data: after\n\n");
    try std.testing.expectEqual(1, count(l.got.items, "data: old\n"));
    try std.testing.expectEqual(1, count(l.got.items, "data: between\n"));
    try std.testing.expectEqual(1, count(l.got.items, "data: after\n"));
}

fn twoStalled(r: *Running) bool {
    return r.server.stats.stream_stalls.load(.acquire) == 2;
}

test "streams: a stalled stream takes 16 more frames and keeps going; the 17th ends it, with none of the 17 sent" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    const kept = try Listener.open(a, r.port(), "sixteen", 0);
    defer kept.close();
    const ended = try Listener.open(a, r.port(), "seventeen", 0);
    defer ended.close();
    // Each stream's task takes its first frame and stalls before writing
    // it, as a write to a reader that stopped reading does; what comes
    // next waits in its mailbox.
    r.server.stall_streams_for_test.store(true, .release);
    try post(a, r.port(), "sixteen", "first");
    try post(a, r.port(), "seventeen", "first");
    try eventually(2000, r, twoStalled);
    for (0..16) |i| try post(a, r.port(), "sixteen", try std.fmt.allocPrint(a, "s{d}", .{i}));
    for (0..17) |i| try post(a, r.port(), "seventeen", try std.fmt.allocPrint(a, "s{d}", .{i}));
    r.server.stall_streams_for_test.store(false, .release);

    try ended.toEnd();
    try std.testing.expectEqualStrings("id: 0\ndata: first\n\n", ended.got.items);
    try std.testing.expectEqual(0, count(ended.got.items, "data: s"));

    try kept.until("id: 16\ndata: s15\n\n");
    try post(a, r.port(), "sixteen", "still here");
    try kept.until("data: still here\n\n");
    try std.testing.expectEqual(17, count(kept.got.items, "data: s"));
}

test "streams: a quiet stream pings at the configured keepalive" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try Running.start(.{ .stream_ping_ms = 150 });
    defer r.stop();
    const l = try Listener.open(arena.allocator(), r.port(), "quiet", 0);
    defer l.close();
    const t0 = Io.Clock.now(.awake, io);
    try l.until(": ping\n\n");
    const waited = msSince(t0);
    try std.testing.expect(waited >= 140 and waited < 1000);
    try std.testing.expectEqualStrings(": ping\n\n", l.got.items);
}

test "streams: the 65th stream held ends the oldest, and the rest stay live" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The probe names one holder for every stream: the global cap alone.
    const r = try Running.start(.{ .streams_per_holder = 64 });
    defer r.stop();
    var held: [65]*Listener = undefined;
    for (&held) |*l| l.* = try Listener.open(a, r.port(), "many", 0);
    defer for (held) |l| l.close();
    try held[0].toEnd();
    try std.testing.expectEqual(64, r.server.slots.count(io));
    try post(a, r.port(), "many", "to the rest");
    try held[1].until("data: to the rest\n\n");
    try held[64].until("data: to the rest\n\n");
}

fn noStreams(r: *Running) bool {
    return r.server.hub.count() == 0 and r.server.slots.count(io) == 0;
}

test "streams: a reader that stops reading is shut at the write deadline" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{ .write_ms = 300 });
    defer r.stop();
    r.server.stream_sndbuf_for_test = 4096;
    const l = try Listener.open(a, r.port(), "stuck", 4096);
    defer l.close();
    const big = try a.alloc(u8, 30_000);
    @memset(big, 'B');
    const t0 = Io.Clock.now(.awake, io);
    // Past what the two small buffers between them hold, so a write blocks.
    for (0..10) |_| try post(a, r.port(), "stuck", big);
    try eventually(3000, r, noStreams);
    try std.testing.expect(msSince(t0) >= 250);
}
