//! **A ROC CRASH IS A 500, AND THE SERVER GOES ON**: the server, end to end,
//! with the planted crashes (app/test/crash.roc) linked in place of the
//! chat. For each way the Roc can die: the client gets a 500 with the host's
//! fixed body and nothing of the Roc's; the next request, on a new
//! connection, is served; the turn is free again, and a client waiting on it
//! is answered.

const std = @import("std");
const Io = std.Io;
const server = @import("server.zig");
const call = @import("call.zig");
const files = @import("files.zig");
const bus = @import("bus.zig");
const StubLog = @import("stub_log.zig").StubLog;
const abi = @import("seam/chat_abi.zig");
const h = @import("test_http.zig");

const io = h.io;
const gpa = h.gpa;
const Running = h.Running;
const Response = h.Response;
const exchange = h.exchange;
const has = h.has;

/// One way the Roc dies: the request that plants it, and the message the
/// Roc's crash says (a part of it), which must never reach the client.
const Plant = struct {
    name: []const u8,
    request: []const u8,
    said: []const u8,
};

const plants = [_]Plant{
    .{ .name = "a crash in the handler", .request = get("/crash"), .said = "a planted crash" },
    .{ .name = "an out-of-bounds List.get unwrapped by crash", .request = get("/crash-get"), .said = "List.get past the end" },
    .{ .name = "a U8 overflow", .request = get("/crash-overflow"), .said = "Integer multiplication overflowed" },
    .{ .name = "a U64 divided by zero", .request = get("/crash-divide"), .said = "U64 division by zero" },
    .{
        .name = "a crash in read_header!'s continuation",
        .request = "GET /crash-after-header HTTP/1.1\r\nhost: t\r\nx-probe: secret-header-value\r\nconnection: close\r\n\r\n",
        .said = "after read_header!",
    },
    .{
        .name = "a crash in read_body!'s continuation",
        .request = "POST /crash-after-body HTTP/1.1\r\nhost: t\r\ncontent-length: 11\r\nconnection: close\r\n\r\nsecret-body",
        .said = "after read_body!",
    },
    .{
        .name = "a crash after the host answered the body (a 413 in the Roc's place)",
        .request = "POST /crash-after-body HTTP/1.1\r\nhost: t\r\ncontent-length: 2000\r\nconnection: close\r\n\r\n" ++ big_body,
        .said = "after the host answered the body",
    },
    .{ .name = "a crash after the host served a script", .request = get("/crash-after-script"), .said = "after serve_script!" },
    .{ .name = "a crash after write!", .request = get("/crash-after-write"), .said = "after write!" },
    .{ .name = "a crash after many allocations", .request = get("/crash-big"), .said = "after a big list" },
    .{ .name = "a crash longer than the host keeps", .request = get("/crash-long"), .said = "long long" },
    .{ .name = "a crash whose message holds a line break", .request = get("/crash-forged"), .said = "a forged line" },
    .{ .name = "a dbg reached in a served build", .request = get("/crash-dbg"), .said = "a `dbg` was reached" },
    .{ .name = "an inline expect failed in a served build", .request = get("/crash-expect"), .said = "an inline `expect` failed" },
    .{ .name = "a recursion past the stack", .request = get("/crash-deep"), .said = "the stack overflowed" },
};

/// Past the 1024 bytes /crash-after-body asks read_body! for.
const big_body: [2000]u8 = @splat('b');

fn get(comptime path: []const u8) []const u8 {
    return "GET " ++ path ++ " HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n";
}

const ok = get("/ok");

/// **THE CRASH'S 500, AND NOTHING OF THE ROC'S**: the host's fixed body,
/// whole, and no word of the crash's message, the request's secrets, or a
/// stack, in the head or the body.
fn expectCrash500(p: Plant, bytes: []const u8) !void {
    const got = Response.of(bytes) catch |e| {
        std.debug.print("{s}: not a response: {t}\n{s}\n", .{ p.name, e, bytes });
        return e;
    };
    errdefer std.debug.print("{s}: answered\n{s}\n", .{ p.name, bytes });
    try std.testing.expectEqual(500, got.status);
    try std.testing.expectEqualStrings(call.failed.body, got.body);
    try std.testing.expectEqualStrings(std.fmt.comptimePrint("{d}", .{call.failed.body.len}), got.header("content-length") orelse "");
    for ([_][]const u8{ p.said, "planted", "crash", "secret", "roc_", "panic", ".zig", "0x" }) |leak|
        try std.testing.expect(!has(bytes, leak));
    // The host's own headers alone: no content type, no cache rule, no
    // script's ETag from an answer begun before the crash.
    inline for (.{ "content-type", "etag", "cache-control", "set-cookie", "location" }) |name|
        try std.testing.expect(!has(got.head, "\r\n" ++ name ++ ":"));
}

/// The next request, on a new connection: served.
fn expectServed(a: std.mem.Allocator, r: *Running) !void {
    const next = try Response.of(try exchange(a, r.port(), ok));
    try std.testing.expectEqual(200, next.status);
    try std.testing.expectEqualStrings("ok\n", next.body);
}

test "each planted crash is a 500 with the host's fixed body and nothing of the Roc's, and the next request on a new connection is served" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    // The crashes' warnings are the point: quiet here.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    try expectServed(a, r);
    for (plants, 0..) |p, k| {
        try expectCrash500(p, try exchange(a, r.port(), p.request));
        try expectServed(a, r);
        // Each crash and each next request reached the Roc, once.
        try std.testing.expectEqual(1 + 2 * (k + 1), r.turns());
    }
}

test "each planted crash is logged once, on one line, with its turn, method, path and the Roc's message" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    for (plants, 0..) |p, k| {
        try expectCrash500(p, try exchange(a, r.port(), p.request));
        const turn = r.turns();
        try std.testing.expectEqual(k + 1, r.server.stats.crashes.load(.acquire));
        try expectServed(a, r);
        // The next request, served, is not a crash.
        try std.testing.expectEqual(k + 1, r.server.stats.crashes.load(.acquire));
        const line = try saidCrash(a, r);
        errdefer std.debug.print("{s}: logged `{s}`\n", .{ p.name, line });
        const method = p.request[0..std.mem.indexOfScalar(u8, p.request, ' ').?];
        const path_end = std.mem.indexOfScalarPos(u8, p.request, method.len + 1, ' ').?;
        const target = p.request[0..path_end];
        try std.testing.expect(has(line, target));
        try std.testing.expect(has(line, try std.fmt.allocPrint(a, "(turn {d})", .{turn})));
        try std.testing.expect(has(line, "): ")); // the message after its own separator
        try std.testing.expect(has(line, p.said));
        // **ONE LINE**: a message's line break cannot forge another; the
        // forged one's is said, escaped.
        try std.testing.expect(std.mem.indexOfAny(u8, line, "\r\n") == null);
        if (has(p.request, "/crash-forged ")) try std.testing.expect(has(line, "a planted crash\\x0awarning(roc_chat)"));
    }
}

/// The last crash's line, read holding the turn.
fn saidCrash(a: std.mem.Allocator, r: *Running) ![]const u8 {
    r.server.turn.lockUncancelable(io);
    defer r.server.turn.unlock(io);
    return a.dupe(u8, r.server.crash_said[0..r.server.crash_said_len]);
}

test "after each planted crash the turn is free, and a client waiting on it while the Roc crashed is answered" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    // Each request holds the turn 150 ms before its Roc call: the crash's
    // request takes it first, and the waiting one asks while it is held.
    r.server.hold_turn_ms_for_test = 150;
    for (plants) |p| {
        var crashed: Answer = .{};
        var waited: Answer = .{};
        var group: Io.Group = .init;
        try group.concurrent(io, ask, .{ r.port(), p.request, &crashed });
        sleepMs(50);
        try group.concurrent(io, ask, .{ r.port(), ok, &waited });
        try group.await(io);
        try expectCrash500(p, crashed.bytes() orelse return error.NoAnswerToTheCrash);
        const next = try Response.of(waited.bytes() orelse return error.TheWaitingClientWasNotAnswered);
        try std.testing.expectEqual(200, next.status);
        try std.testing.expectEqualStrings("ok\n", next.body);
        try std.testing.expectEqual(1, r.server.stats.most_in_turn.load(.acquire));
        // **THE TURN IS FREE**: no request is in it, and it can be taken.
        try std.testing.expect(r.server.turn.tryLock());
        r.server.turn.unlock(io);
    }
    _ = a;
}

/// What a client task was answered, kept in a buffer of its own.
const Answer = struct {
    buf: [4096]u8 = undefined,
    len: ?usize = null,

    fn bytes(an: *const Answer) ?[]const u8 {
        return an.buf[0 .. an.len orelse return null];
    }
};

fn ask(port: u16, request: []const u8, out: *Answer) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const got = exchange(arena.allocator(), port, request) catch return;
    const n = @min(got.len, out.buf.len);
    @memcpy(out.buf[0..n], got[0..n]);
    out.len = n;
}

fn sleepMs(ms: u32) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch {};
}

test "a crash on a kept-open connection: its 500, then the next request pipelined behind it served on the same connection" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try Running.start(.{});
    defer r.stop();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const both = try exchange(arena.allocator(), r.port(), "POST /crash-after-body HTTP/1.1\r\nhost: t\r\ncontent-length: 5\r\n\r\nhello" ++ ok);
    const second_at = std.mem.indexOfPos(u8, both, 1, "HTTP/1.1 ") orelse return error.OneAnswer;
    try expectCrash500(plants[5], both[0..second_at]);
    const second = try Response.of(both[second_at..]);
    try std.testing.expectEqual(200, second.status);
    try std.testing.expectEqualStrings("ok\n", second.body);
    try std.testing.expectEqual(2, r.turns());
}

test "a crash after write!: the 500, and the file written before it stays written" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    try expectCrash500(plants[8], try exchange(a, r.port(), plants[8].request));
    const kept = try r.data.dir.readFileAlloc(io, "planted/written", a, .limited(100));
    try std.testing.expectEqualStrings("before the crash\n", kept);
}

test "a HEAD of a crash is the 500's head, and no body" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try Running.start(.{});
    defer r.stop();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const bytes = try exchange(arena.allocator(), r.port(), "HEAD /crash HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n");
    const got = try Response.of(bytes);
    try std.testing.expectEqual(500, got.status);
    try std.testing.expectEqual(0, got.body.len);
    try std.testing.expect(!has(bytes, "planted"));
}

// ── memory that runs out inside the call ──────────────────────────────────

/// **EVERY ALLOCATION OF THE CALL, MADE TO FAIL IN TURN**, the one in a
/// hosted function's answer among them: each is the call's crash
/// (`error.RocCrashed`, Roc's "out of memory"), never the process's, until
/// the call gets past them all to its own planted crash.
fn everyAllocationFails(path: []const u8, method: std.http.Method, req: *const call.Copied, planted: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store: files.Files = .{ .io = io, .root = tmp.dir };
    var hub = bus.Hub.init(io, gpa);
    var stub_log: StubLog = .{ .gpa = gpa };
    var k: usize = 0;
    while (k < 10_000) : (k += 1) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = k });
        const fa = failing.allocator();
        var ctx: call.Ctx = .{ .req = req, .arena = fa, .files = &store, .hub = &hub, .stub_log = &stub_log };
        const got = abi.decide(fa, path, method, .not_asked, .of(&ctx));
        try std.testing.expectError(error.RocCrashed, got);
        const said = abi.last_crash[0..abi.last_crash_len];
        if (!failing.has_induced_failure) {
            // Past every allocation the call makes: its own planted crash.
            try std.testing.expectEqualStrings(planted, said);
            try std.testing.expect(k > 0);
            return;
        }
        try std.testing.expect(has(said, "out of memory"));
    }
    return error.NeverPastItsAllocations;
}

test "memory that runs out at any allocation of a call is that call's crash, in the Roc and in a hosted function's answer" {
    try everyAllocationFails("/crash-big", .GET, &.{ .path = "/crash-big", .method = .GET, .headers = &.{} }, "a planted crash, after a big list");
    try everyAllocationFails("/crash-after-header", .GET, &.{ .path = "/crash-after-header", .method = .GET, .headers = &.{.{ .name = "x-probe", .value = "one" }} }, "a planted crash, after read_header!");
    try everyAllocationFails("/crash-after-body", .POST, &.{ .path = "/crash-after-body", .method = .POST, .headers = &.{}, .body = "a body for read_body!" }, "a planted crash, after read_body!");
}

test "a recursion past the stack, three times over on one server: each the call's 500, the fault never left blocked" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const deep: Plant = .{ .name = "a recursion past the stack", .request = get("/crash-deep"), .said = "the stack overflowed" };
    for (0..3) |_| {
        try expectCrash500(deep, try exchange(a, r.port(), deep.request));
        try std.testing.expect(has(try saidCrash(a, r), "GET /crash-deep (turn "));
        try std.testing.expect(has(try saidCrash(a, r), "): the stack overflowed"));
        try expectServed(a, r);
    }
    try std.testing.expectEqual(3, r.server.stats.crashes.load(.acquire));
}
