//! **THE SMALLEST END TO END** (the host design's step 6, metal-vmm QUEUE
//! 314): the real server in this process with the chat's Roc linked, its
//! data root and secrets under .zig-cache/e2e, the fake GitHub
//! (host/github/fake_github.zig) on another port as both of GitHub's bases,
//! and clients that speak HTTP by hand, carrying the cookies the server set,
//! as browsers would:
//!
//!   1. A and B sign in (and C, the third user)
//!   2. A starts a conversation with B
//!   3. B opens its stream
//!   4. A posts, a message of many lines
//!   5. B's stream gets the message exactly once
//!   6. A reads the transcript and sees it, its markdown exactly as posted
//!   7. B reconnects with Last-Event-ID and gets nothing twice
//!   8. a forged session cookie is refused
//!   9. a third user cannot post to it
//!  10. a third user cannot read it, nor stream it
//!  11. a post landing between a stream's backlog read and its subscribe
//!      arrives exactly once
//!
//! It prints a line a step, `PASS` or `FAIL`, its number, its name and its
//! time, then `e2e: N of N passed` or `e2e: FAILED`, and exits 0 only on
//! the first: `zig build e2e`, and `zig build test` runs it too.
//! tools/verify.shale plants a fault for each refusal and requires its
//! step red.

const std = @import("std");
const Io = std.Io;
const server = @import("server.zig");
const signin = @import("signin.zig");
const secrets = @import("auth/secrets.zig");
const fake_github = @import("github/fake_github.zig");

const RunResult = @typeInfo(@TypeOf(server.Server.run)).@"fn".return_type.?;

const paths: secrets.Paths = .{ .client_id = "client_id", .client_secret = "client_secret", .signing_key = "signing_key" };
const data_path = ".zig-cache/e2e";
/// The longest a stream's read waits for what a step expects.
const wait_ms = 3000;

var io: Io = undefined;
var gpa: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    gpa = init.gpa;
    const ok = try run(init.arena.allocator());
    if (!ok) std.process.exit(1);
}

/// A server with sign-in, the fake GitHub, and a data root with secrets.
const Rig = struct {
    fake: *fake_github.Fake,
    data: Io.Dir,
    auth: signin.Auth,
    server: server.Server,
    run: Io.Future(RunResult),

    fn start(r: *Rig) !void {
        r.fake = try fake_github.Fake.start(io, gpa);
        const cwd = Io.Dir.cwd();
        cwd.deleteTree(io, data_path) catch {};
        r.data = try cwd.createDirPathOpen(io, data_path, .{});
        try r.data.createDir(io, secrets.folder, .fromMode(0o700));
        var dir = try r.data.openDir(io, secrets.folder, .{});
        defer dir.close(io);
        try put(dir, paths.client_id, fake_github.client_id);
        try put(dir, paths.client_secret, fake_github.client_secret);
        var diag: secrets.Diagnostic = .{};
        const held = try secrets.load(io, gpa, r.data, paths, &diag);
        r.auth = .{
            .secrets = held,
            .github = .{ .oauth_base = r.fake.base(), .api_base = r.fake.base(), .connect_timeout_ms = 1000, .whole_timeout_ms = 3000 },
            .origin = "http://chat.test",
        };
        r.server = try .init(io, gpa, try .parse("127.0.0.1", 0), .{}, r.data);
        r.server.auth = &r.auth;
        r.run = try io.concurrent(server.Server.run, .{&r.server});
    }

    fn stop(r: *Rig) void {
        r.server.stop();
        r.run.await(io) catch |e| std.debug.print("the server's run: {t}\n", .{e});
        r.fake.stop();
        r.auth.secrets.deinit(gpa);
        r.data.close(io);
        Io.Dir.cwd().deleteTree(io, data_path) catch {};
    }

    fn port(r: *const Rig) u16 {
        return r.server.port();
    }
};

fn put(dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    const f = try dir.createFile(io, path, .{ .permissions = .fromMode(0o600) });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
    try f.setPermissions(io, .fromMode(0o600));
}

/// A response as a browser reads it.
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

    fn header(r: Response, comptime name: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, r.head, "\r\n" ++ name ++ ": ") orelse return null;
        const from = at + name.len + 4;
        const to = std.mem.indexOfPos(u8, r.head, from, "\r\n") orelse return null;
        return r.head[from..to];
    }

    /// The value cookie `__Host-<name>` is set to, or null.
    fn cookie(r: Response, comptime name: []const u8) ?[]const u8 {
        const key = "\r\nset-cookie: __Host-" ++ name ++ "=";
        const at = std.mem.indexOf(u8, r.head, key) orelse return null;
        const from = at + key.len;
        const to = std.mem.indexOfAnyPos(u8, r.head, from, ";\r") orelse return null;
        return r.head[from..to];
    }
};

/// One request on a connection of its own: its `cookie` when not empty,
/// `extra` header lines, its body, and the whole response.
fn request(a: std.mem.Allocator, port: u16, method: []const u8, target: []const u8, cookie: []const u8, body: []const u8) !Response {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const cookie_line = if (cookie.len > 0) try std.fmt.allocPrint(a, "cookie: {s}\r\n", .{cookie}) else "";
    const text = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nhost: chat.test\r\nconnection: close\r\n{s}content-length: {d}\r\n\r\n{s}", .{ method, target, cookie_line, body.len, body });
    var w = stream.writer(io, &.{});
    try w.interface.writeAll(text);
    var buf: [4096]u8 = undefined;
    var r = stream.reader(io, &buf);
    return .of(try r.interface.allocRemaining(a, .limited(4 * 1024 * 1024)));
}

fn get(a: std.mem.Allocator, port: u16, target: []const u8, cookie: []const u8) !Response {
    return request(a, port, "GET", target, cookie, "");
}

/// **A NEW HUMAN SIGNS IN**: /login, GitHub's callback with a code the fake
/// knows as GitHub id `n`, the name form, and the session cookie.
fn signUp(a: std.mem.Allocator, port: u16, n: u64) ![]const u8 {
    const login = try get(a, port, "/login", "");
    if (login.status != 303) return error.LoginNotARedirect;
    const location = login.header("location") orelse return error.NoLocation;
    const at = std.mem.indexOf(u8, location, "&state=") orelse return error.NoState;
    const state_cookie = try std.fmt.allocPrint(a, "__Host-state={s}", .{login.cookie("state") orelse return error.NoStateCookie});
    const target = try std.fmt.allocPrint(a, "/login/github?code=user-id-{d}&state={s}", .{ n, location[at + "&state=".len ..] });
    const named = try get(a, port, target, state_cookie);
    if (named.status != 200) return error.NoNameForm;
    const both = try std.fmt.allocPrint(a, "{s}; __Host-pending={s}", .{ state_cookie, named.cookie("pending") orelse return error.NoPendingCookie });
    const made = try request(a, port, "POST", "/login/name", both, try std.fmt.allocPrint(a, "name=Person+{d}", .{n}));
    if (made.status != 303) return error.NotSignedIn;
    return std.fmt.allocPrint(a, "__Host-session={s}", .{made.cookie("session") orelse return error.NoSessionCookie});
}

/// A held stream as a browser reads it: its head, then what it says, kept
/// in `got` as it arrives.
const Listener = struct {
    stream: Io.net.Stream,
    buf: [4096]u8 = undefined,
    reader: Io.net.Stream.Reader = undefined,
    got: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,

    /// The stream at `target`, its head read: subscribed, and its backlog
    /// on the way. `last_id`, when not empty, is its `Last-Event-ID`.
    fn open(arena: std.mem.Allocator, port: u16, target: []const u8, cookie: []const u8, last_id: []const u8) !*Listener {
        const l = try arena.create(Listener);
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
        l.* = .{ .stream = try addr.connect(io, .{ .mode = .stream }), .arena = arena };
        // **A READ THAT WAITS PAST `wait_ms` FAILS**, so a message that never
        // comes is a step's failure, never a hang.
        const wait: std.posix.timeval = .{ .sec = wait_ms / 1000, .usec = (wait_ms % 1000) * 1000 };
        std.posix.setsockopt(l.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&wait)) catch {};
        l.reader = l.stream.reader(io, &l.buf);
        const resume_line = if (last_id.len > 0) try std.fmt.allocPrint(arena, "last-event-id: {s}\r\n", .{last_id}) else "";
        var w = l.stream.writer(io, &.{});
        try w.interface.writeAll(try std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nhost: chat.test\r\ncookie: {s}\r\n{s}\r\n", .{ target, cookie, resume_line }));
        try l.until("\r\n\r\n");
        const head = try Response.of(l.got.items);
        if (head.status != 200) return error.NotAStream;
        if (!std.mem.eql(u8, head.header("content-type") orelse "", "text/event-stream")) return error.NotAStream;
        const body_len = head.body.len;
        std.mem.copyForwards(u8, l.got.items, head.body);
        l.got.shrinkRetainingCapacity(body_len);
        return l;
    }

    /// Reads until `needle` has arrived (a read waits at most `wait_ms`).
    fn until(l: *Listener, needle: []const u8) !void {
        while (!has(l.got.items, needle)) try l.more();
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

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn sleepMs(ms: i64) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch {};
}

/// Text as the chat's JSON spells a string: `"` and `\` escaped, a newline
/// `\n`. (The bodies here hold no other control byte.)
fn jsonString(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
    return out.items;
}

/// The message A posts: many lines, a quote, a table, and markdown.
const first_body = "hello **B**\nthis \"line\" is the second\n\n| a | b |\n| - | - |\n| 1 | 2 |";
const second_body = "and a second message";

/// What the steps share: the rig, the three sessions, the conversation.
const World = struct {
    a: std.mem.Allocator,
    rig: *Rig,
    ann: []const u8 = "",
    bea: []const u8 = "",
    cal: []const u8 = "",
    conv: []const u8 = "",
    bea_stream: ?*Listener = null,

    fn port(w: *const World) u16 {
        return w.rig.port();
    }

    fn path(w: *const World, comptime tail: []const u8) ![]const u8 {
        return std.fmt.allocPrint(w.a, "/conversations/{s}" ++ tail, .{w.conv});
    }

    fn postAs(w: *const World, cookie: []const u8, body: []const u8) !Response {
        return request(w.a, w.port(), "POST", try w.path("/messages"), cookie, body);
    }

    /// The transcript's messages, as A reads them.
    fn messages(w: *const World) !usize {
        const r = try get(w.a, w.port(), try w.path(""), w.ann);
        if (r.status != 200) return error.TranscriptUnread;
        return count(r.body, "{\"id\":") - 1;
    }
};

fn signIn(w: *World) !void {
    w.ann = try signUp(w.a, w.port(), 1001);
    w.bea = try signUp(w.a, w.port(), 1002);
    w.cal = try signUp(w.a, w.port(), 1003);
}

fn start(w: *World) !void {
    const r = try request(w.a, w.port(), "POST", "/conversations", w.ann, "with=human%3A1002");
    if (r.status != 201) return error.NotStarted;
    const prefix = "{\"id\":";
    if (!std.mem.startsWith(u8, r.body, prefix) or !std.mem.endsWith(u8, r.body, "}")) return error.NoId;
    w.conv = r.body[prefix.len .. r.body.len - 1];
}

fn openStream(w: *World) !void {
    w.bea_stream = try Listener.open(w.a, w.port(), try w.path("/stream"), w.bea, "");
    // A new conversation has no backlog.
    if (w.bea_stream.?.got.items.len != 0) return error.BacklogNotEmpty;
}

fn post(w: *World) !void {
    const r = try w.postAs(w.ann, first_body);
    if (r.status != 201) return error.NotPosted;
    if (!std.mem.startsWith(u8, r.body, "{\"id\":1,")) return error.NotTheFirst;
}

fn streamOnce(w: *World) !void {
    const l = w.bea_stream orelse return error.NoStream;
    try l.until("\n\n");
    // A moment for a copy that should not come.
    sleepMs(100);
    if (count(l.got.items, "event: message\nid: 1\n") != 1) return error.NotOnce;
    if (!has(l.got.items, try jsonString(w.a, first_body))) return error.NotTheMessage;
}

fn readBack(w: *World) !void {
    const r = try get(w.a, w.port(), try w.path(""), w.ann);
    if (r.status != 200) return error.TranscriptUnread;
    if (!has(r.body, try std.fmt.allocPrint(w.a, "\"markdown\":{s}", .{try jsonString(w.a, first_body)}))) return error.MarkdownChanged;
    if (!has(r.body, "<strong>B</strong>") or !has(r.body, "<table>")) return error.NotRendered;
    if (try w.messages() != 1) return error.WrongCount;
}

fn reconnect(w: *World) !void {
    if (w.bea_stream) |l| l.close();
    w.bea_stream = null;
    const r = try w.postAs(w.ann, second_body);
    if (r.status != 201) return error.NotPosted;
    const l = try Listener.open(w.a, w.port(), try w.path("/stream"), w.bea, "1");
    defer l.close();
    try l.until("id: 2\n");
    sleepMs(100);
    if (count(l.got.items, "id: 1\n") != 0) return error.SentTwice;
    if (count(l.got.items, "id: 2\n") != 1) return error.NotOnce;
}

const forged_secret: [64]u8 = @splat('c');
const forged = "__Host-session=" ++ forged_secret;

fn forgedCookie(w: *World) !void {
    if ((try get(w.a, w.port(), try w.path(""), forged)).status != 401) return error.ReadWithForgery;
    if ((try w.postAs(forged, "forged")).status != 401) return error.PostedWithForgery;
}

fn thirdPosts(w: *World) !void {
    const before = try w.messages();
    const r = try w.postAs(w.cal, "let me in");
    if (r.status != 403 and r.status != 404) return error.ThirdPosted;
    if (try w.messages() != before) return error.TranscriptGrew;
}

fn thirdReads(w: *World) !void {
    if ((try get(w.a, w.port(), try w.path(""), w.cal)).status != 404) return error.ThirdRead;
    const l = Listener.open(w.a, w.port(), try w.path("/stream"), w.cal, "") catch |e| switch (e) {
        error.NotAStream => return,
        else => return e,
    };
    l.close();
    return error.ThirdStreamed;
}

fn holdBegun(w: *World) bool {
    return w.rig.server.stats.subscribe_holds.load(.acquire) >= 1;
}

fn betweenOnce(w: *World) !void {
    w.rig.server.hold_before_subscribe_ms_for_test = 200;
    defer w.rig.server.hold_before_subscribe_ms_for_test = 0;
    // B's stream, resuming after the last message: it reads the backlog
    // (none), then sleeps before its subscribe.
    var opened = try io.concurrent(Listener.open, .{ w.a, w.port(), try w.path("/stream"), w.bea, "2" });
    const t0 = Io.Clock.now(.awake, io);
    while (!holdBegun(w)) {
        if (t0.untilNow(io, .awake).toMilliseconds() > 3000) return error.NeverHeld;
        sleepMs(5);
    }
    // In the gap: the post waits for the turn, or (were the subscribe out
    // of it) lands where neither the backlog nor the live stream sees it.
    if ((try w.postAs(w.ann, "between")).status != 201) return error.NotPosted;
    const l = try opened.await(io);
    defer l.close();
    if ((try w.postAs(w.ann, "after")).status != 201) return error.NotPosted;
    try l.until("\"markdown\":\"after\"");
    if (count(l.got.items, "\"markdown\":\"between\"") != 1) return error.NotOnce;
}

const Step = struct { name: []const u8, f: *const fn (*World) anyerror!void };

const steps = [_]Step{
    .{ .name = "A and B sign in (and C, the third user)", .f = signIn },
    .{ .name = "A starts a conversation with B", .f = start },
    .{ .name = "B opens its stream", .f = openStream },
    .{ .name = "A posts a message of many lines", .f = post },
    .{ .name = "B's stream gets the message exactly once", .f = streamOnce },
    .{ .name = "A reads the transcript and sees it, its markdown exactly as posted", .f = readBack },
    .{ .name = "B reconnects with Last-Event-ID and gets nothing twice", .f = reconnect },
    .{ .name = "a forged session cookie is refused", .f = forgedCookie },
    .{ .name = "a third user cannot post to it", .f = thirdPosts },
    .{ .name = "a third user cannot read it, nor stream it", .f = thirdReads },
    .{ .name = "a post between a stream's backlog read and its subscribe arrives once", .f = betweenOnce },
};

/// Every step, in order, each timed and said; true when all passed.
pub fn run(a: std.mem.Allocator) !bool {
    var rig: Rig = undefined;
    try rig.start();
    defer rig.stop();
    var w: World = .{ .a = a, .rig = &rig };
    defer if (w.bea_stream) |l| l.close();
    var passed: usize = 0;
    for (steps, 1..) |s, n| {
        const t0 = Io.Clock.now(.awake, io);
        const result = s.f(&w);
        const ms = t0.untilNow(io, .awake).toMilliseconds();
        if (result) |_| {
            passed += 1;
            std.debug.print("PASS  {d:>2}  {s} ({d} ms)\n", .{ n, s.name, ms });
        } else |e| {
            std.debug.print("FAIL  {d:>2}  {s} ({d} ms): {t}\n", .{ n, s.name, ms, e });
        }
    }
    if (passed == steps.len) {
        std.debug.print("e2e: {d} of {d} passed\n", .{ passed, steps.len });
        return true;
    }
    std.debug.print("e2e: FAILED ({d} of {d} passed)\n", .{ passed, steps.len });
    return false;
}
