//! **THE SMALLEST END TO END**: the real server in this process with the
//! chat's Roc linked, its data root and secrets under .zig-cache/e2e, the
//! fake GitHub (host/github/fake_github.zig) on another port as both of
//! GitHub's bases, and clients that speak HTTP by hand, carrying the cookies
//! the server set, as browsers would. Its steps, in order, are the `steps`
//! table at the end of this file, each named for what it proves.
//!
//! It prints a line a step, `PASS` or `FAIL`, its number, its name and its
//! time, then `e2e: N of N passed` or `e2e: FAILED`, and exits 0 only on
//! the first: `zig build e2e`, and `zig build test` runs it too. Each
//! refusal is asserted beside a near-miss that is taken, in its own step
//! or an earlier one it builds on, so a check that stopped seeing fails
//! on one side or the other.

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
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const hold = args.len > 1 and std.mem.eql(u8, args[1], "--hold");
    const ok = try run(init.arena.allocator(), hold);
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
            // Ivy (step 65 on), the first admin: no earlier step signs her up.
            .first_admin = "1014",
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
/// its body, and the whole response.
fn request(a: std.mem.Allocator, port: u16, method: []const u8, target: []const u8, cookie: []const u8, body: []const u8) !Response {
    return send(a, port, method, target, .{ .cookie = cookie }, body);
}

/// What a request carries to say who it is: a browser's cookie, an agent's
/// key (its secret, in hex, for `Authorization: Bearer`), each when not
/// empty.
const Credential = struct { cookie: []const u8 = "", key: []const u8 = "", origin: []const u8 = own_origin };

/// The origin a browser on the chat's own pages sends with a write (the
/// rig's `.origin`); a request's own when not empty.
const own_origin = "http://chat.test";

/// One request on a connection of its own, with `credential`.
fn send(a: std.mem.Allocator, port: u16, method: []const u8, target: []const u8, credential: Credential, body: []const u8) !Response {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const cookie_line = if (credential.cookie.len > 0) try std.fmt.allocPrint(a, "cookie: {s}\r\n", .{credential.cookie}) else "";
    const key_line = if (credential.key.len > 0) try std.fmt.allocPrint(a, "authorization: Bearer {s}\r\n", .{credential.key}) else "";
    const origin_line = if (credential.origin.len > 0) try std.fmt.allocPrint(a, "origin: {s}\r\n", .{credential.origin}) else "";
    const text = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nhost: chat.test\r\nconnection: close\r\n{s}{s}{s}content-length: {d}\r\n\r\n{s}", .{ method, target, cookie_line, key_line, origin_line, body.len, body });
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
    return signUpAs(a, port, n, try std.fmt.allocPrint(a, "Person+{d}", .{n}));
}

/// The same, with the display name `name`, form-encoded.
fn signUpAs(a: std.mem.Allocator, port: u16, n: u64, name: []const u8) ![]const u8 {
    const made = try nameFormAnswer(a, port, n, name);
    if (made.status != 303) return error.NotSignedIn;
    const cookie = try std.fmt.allocPrint(a, "__Host-session={s}", .{made.cookie("session") orelse return error.NoSessionCookie});
    // Who the chat made them: its own id, from its counter, never `n`.
    const me = try get(a, port, "/me", cookie);
    const said = "signed in as human:";
    if (me.status != 200 or !std.mem.startsWith(u8, me.body, said) or !std.mem.endsWith(u8, me.body, "\n")) return error.NotAHuman;
    const id = try std.fmt.parseInt(u64, me.body[said.len .. me.body.len - 1], 10);
    if (id == n) return error.GitHubIdAsHumanId;
    if (n < 1000 or n - 1000 >= human_ids.len or human_ids[n - 1000] != 0) return error.SignedUpTwice;
    human_ids[n - 1000] = id;
    return cookie;
}

/// **EACH HUMAN'S OWN ID, BY THE GITHUB ID THEY SIGNED UP AS** (`n`, at
/// `n - 1000`): what /me said then. The chat gives a human its own id, the
/// next of its counter from 1, so no human here is named by the GitHub id
/// they signed in with, and a step that took one for the other fails.
var human_ids: [32]u64 = @splat(0);

/// GitHub user `n`'s human id, as a wire id's number; an error if `n`
/// never signed up.
fn hid(a: std.mem.Allocator, n: u64) ![]const u8 {
    if (n < 1000 or n - 1000 >= human_ids.len or human_ids[n - 1000] == 0) return error.NotSignedUp;
    return std.fmt.allocPrint(a, "{d}", .{human_ids[n - 1000]});
}

/// GitHub user `n` through the sign-in, then the name form's answer to
/// `name`: a 303 with a session, or the form again saying why not.
fn nameFormAnswer(a: std.mem.Allocator, port: u16, n: u64, name: []const u8) !Response {
    const login = try get(a, port, "/login", "");
    if (login.status != 303) return error.LoginNotARedirect;
    const location = login.header("location") orelse return error.NoLocation;
    const at = std.mem.indexOf(u8, location, "&state=") orelse return error.NoState;
    const state_cookie = try std.fmt.allocPrint(a, "__Host-state={s}", .{login.cookie("state") orelse return error.NoStateCookie});
    const target = try std.fmt.allocPrint(a, "/login/github?code=user-id-{d}&state={s}", .{ n, location[at + "&state=".len ..] });
    const named = try get(a, port, target, state_cookie);
    if (named.status != 200) return error.NoNameForm;
    const both = try std.fmt.allocPrint(a, "{s}; __Host-pending={s}", .{ state_cookie, named.cookie("pending") orelse return error.NoPendingCookie });
    return request(a, port, "POST", "/login/name", both, try std.fmt.allocPrint(a, "name={s}", .{name}));
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
        return openAs(arena, port, target, .{ .cookie = cookie }, last_id);
    }

    /// The same, with `credential`: a cookie, a key, or both.
    fn openAs(arena: std.mem.Allocator, port: u16, target: []const u8, credential: Credential, last_id: []const u8) !*Listener {
        const l = try arena.create(Listener);
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
        l.* = .{ .stream = try addr.connect(io, .{ .mode = .stream }), .arena = arena };
        // **A READ THAT WAITS PAST `wait_ms` FAILS**, so a message that never
        // comes is a step's failure, never a hang.
        const wait: std.posix.timeval = .{ .sec = wait_ms / 1000, .usec = (wait_ms % 1000) * 1000 };
        std.posix.setsockopt(l.stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&wait)) catch {};
        l.reader = l.stream.reader(io, &l.buf);
        const resume_line = if (last_id.len > 0) try std.fmt.allocPrint(arena, "last-event-id: {s}\r\n", .{last_id}) else "";
        const cookie_line = if (credential.cookie.len > 0) try std.fmt.allocPrint(arena, "cookie: {s}\r\n", .{credential.cookie}) else "";
        const key_line = if (credential.key.len > 0) try std.fmt.allocPrint(arena, "authorization: Bearer {s}\r\n", .{credential.key}) else "";
        var w = l.stream.writer(io, &.{});
        try w.interface.writeAll(try std.fmt.allocPrint(arena, "GET {s} HTTP/1.1\r\nhost: chat.test\r\n{s}{s}{s}\r\n", .{ target, cookie_line, key_line, resume_line }));
        try l.until("\r\n\r\n");
        const head = try Response.of(l.got.items);
        if (head.status != 200) return error.NotAStream;
        if (!std.mem.eql(u8, head.header("content-type") orelse "", "text/event-stream")) return error.NotAStream;
        const body_len = head.body.len;
        std.mem.copyForwards(u8, l.got.items, head.body);
        l.got.shrinkRetainingCapacity(body_len);
        return l;
    }

    /// Reads until `needle` has arrived, within `wait_ms`; `NeverCame`
    /// when it has not.
    fn until(l: *Listener, needle: []const u8) !void {
        const t0 = Io.Clock.now(.awake, io);
        while (!has(l.got.items, needle)) {
            if (!l.readable(t0)) return error.NeverCame;
            try l.more();
        }
    }

    /// Whether a read would find bytes before `wait_ms` from `t0` is up.
    /// **EACH READ WAITS ON `poll` FIRST**, never on the socket's receive
    /// timeout: std's Io takes that timeout's EAGAIN for a programmer's
    /// bug and panics, so a read past the wait would abort the run instead
    /// of failing its step.
    fn readable(l: *Listener, t0: Io.Timestamp) bool {
        if (l.reader.interface.bufferedLen() > 0) return true;
        const left = wait_ms - t0.untilNow(io, .awake).toMilliseconds();
        if (left <= 0) return false;
        var fds = [_]std.posix.pollfd{.{ .fd = l.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, @intCast(left)) catch return false;
        return ready > 0;
    }

    fn more(l: *Listener) !void {
        const r = &l.reader.interface;
        const bytes = try r.peekGreedy(1);
        try l.got.appendSlice(l.arena, bytes);
        r.toss(bytes.len);
    }

    /// Reads until the server ends the stream: whether it ended within
    /// `wait_ms` (each read waiting as `readable` says).
    fn ends(l: *Listener) bool {
        const t0 = Io.Clock.now(.awake, io);
        while (true) {
            if (!l.readable(t0)) return false;
            l.more() catch |e| return e == error.EndOfStream;
        }
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
    /// Steve, his agent (`agent:N`), its key's public id and secret, and
    /// the conversation the agent started with him.
    steve: []const u8 = "",
    agent: []const u8 = "",
    key_id: []const u8 = "",
    key: []const u8 = "",
    agents_conv: []const u8 = "",
    /// The code of the invite step 22 redeemed.
    code: []const u8 = "",
    /// The conversation of more than a page (step 45 on).
    paged: []const u8 = "",
    /// Fay, the human who reaches each cap (step 49 on).
    fay: []const u8 = "",
    /// Gil, who works the agents page (step 55 on), the agent he made
    /// there and his invite for it; Hal, a human with nothing of Gil's.
    gil: []const u8 = "",
    gil_agent: []const u8 = "",
    gil_invite: []const u8 = "",
    hal: []const u8 = "",
    /// Ivy, the admin who works the channels (step 65 on), and her own key.
    ivy: []const u8 = "",
    ivy_key: []const u8 = "",

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
    w.bea = try signUpAs(w.a, w.port(), 1002, bea_name_form);
    w.cal = try signUp(w.a, w.port(), 1003);
}

fn start(w: *World) !void {
    // Bea named by her GitHub id, which is no human's id here: refused, as
    // a nobody is, and nothing started.
    const by_github = try request(w.a, w.port(), "POST", "/conversations", w.ann, "with=human%3A1002");
    if (by_github.status != 400) return error.GitHubIdTakenForAHuman;
    const r = try request(w.a, w.port(), "POST", "/conversations", w.ann, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)})));
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

/// A's own cookie with its last byte changed: a forgery one byte from a
/// real session's.
fn nearForgery(w: *World) ![]const u8 {
    const near = try w.a.dupe(u8, w.ann);
    near[near.len - 1] = if (near[near.len - 1] == '0') '1' else '0';
    return near;
}

fn forgedCookie(w: *World) !void {
    if ((try get(w.a, w.port(), try w.path(""), forged)).status != 401) return error.ReadWithForgery;
    if ((try w.postAs(forged, "forged")).status != 401) return error.PostedWithForgery;
    if ((try get(w.a, w.port(), try w.path(""), try nearForgery(w))).status != 401) return error.ReadWithNearForgery;
    // The real cookie, beside them, still reads.
    if ((try get(w.a, w.port(), try w.path(""), w.ann)).status != 200) return error.RealRefused;
}

fn thirdPosts(w: *World) !void {
    const before = try w.messages();
    const r = try w.postAs(w.cal, "let me in");
    if (r.status != 403 and r.status != 404) return error.ThirdPosted;
    if (try w.messages() != before) return error.TranscriptGrew;
    // B, a participant who did not start it, posts.
    if ((try w.postAs(w.bea, "B's turn")).status != 201) return error.ParticipantRefused;
    if (try w.messages() != before + 1) return error.NotAppended;
}

fn thirdReads(w: *World) !void {
    if ((try get(w.a, w.port(), try w.path(""), w.cal)).status != 404) return error.ThirdRead;
    // B, a participant who did not start it, reads.
    if ((try get(w.a, w.port(), try w.path(""), w.bea)).status != 200) return error.ParticipantRefused;
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
    const last = try std.fmt.allocPrint(w.a, "{d}", .{try w.messages()});
    var opened = try io.concurrent(Listener.open, .{ w.a, w.port(), try w.path("/stream"), w.bea, last });
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

/// The text after `"<field>":` up to the next `"`, `,` or `}`, quotes
/// dropped: a JSON answer's field, for the flat objects the chat writes.
fn field(body: []const u8, comptime name: []const u8) ![]const u8 {
    const key = "\"" ++ name ++ "\":";
    const at = std.mem.indexOf(u8, body, key) orelse return error.NoField;
    var from = at + key.len;
    if (from < body.len and body[from] == '"') {
        from += 1;
        const to = std.mem.indexOfScalarPos(u8, body, from, '"') orelse return error.NoField;
        return body[from..to];
    }
    const to = std.mem.indexOfAnyPos(u8, body, from, ",}") orelse return error.NoField;
    return body[from..to];
}

// ── the pages ──

/// B's name holds markup, and the page must write it as text.
const bea_name_form = "Bea+%3Ci%3Ex%3C%2Fi%3E+%26+%22co%22";
const bea_name_raw = "Bea <i>x</i> & \"co\"";
const bea_name_escaped = "Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot;";

fn listPage(w: *World) !void {
    // A conversation A is not in: C's, with B.
    const other = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.cal, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)}))));
    const page = try get(w.a, w.port(), "/chat", w.ann);
    if (page.status != 200) return error.NoListPage;
    if (!has(page.body, try std.fmt.allocPrint(w.a, "href=\"/chat/{s}\"", .{w.conv}))) return error.OwnMissing;
    if (has(page.body, try std.fmt.allocPrint(w.a, "href=\"/chat/{s}\"", .{other}))) return error.OthersShown;
}

fn namesEscaped(w: *World) !void {
    const page = try get(w.a, w.port(), "/chat", w.ann);
    if (page.status != 200) return error.NoListPage;
    if (!has(page.body, bea_name_escaped)) return error.NameNotEscaped;
    if (has(page.body, bea_name_raw)) return error.NameRaw;
    const conv = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/{s}", .{w.conv}), w.ann);
    if (!has(conv.body, bea_name_escaped) or has(conv.body, bea_name_raw)) return error.NameRawOnConversation;
}

fn conversationPage(w: *World) !void {
    const target = try std.fmt.allocPrint(w.a, "/chat/{s}", .{w.conv});
    const mine = try get(w.a, w.port(), target, w.bea);
    if (mine.status != 200) return error.ParticipantRefused;
    if (!has(mine.body, try std.fmt.allocPrint(w.a, "data-conv=\"{s}\"", .{w.conv}))) return error.NotTheConversation;
    const theirs = try get(w.a, w.port(), target, w.cal);
    if (theirs.status != 404 and theirs.status != 403) return error.ThirdGotPage;
    // A page is a browser's: Steve's own key, live, is a 403 at both.
    const own = try mint(w, "");
    for ([_][]const u8{ "/chat", target }) |t| {
        if ((try send(w.a, w.port(), "GET", t, .{ .key = own.secret }, "")).status != 403) return error.KeyGotPage;
    }
}

fn signedOutPage(w: *World) !void {
    for ([_][]const u8{ "/chat", try std.fmt.allocPrint(w.a, "/chat/{s}", .{w.conv}) }) |target| {
        const r = try get(w.a, w.port(), target, "");
        if (r.status != 303) return error.NotARedirect;
        // To /login, naming the page, so the sign-in ends back on it.
        const want = try std.fmt.allocPrint(w.a, "/login?next=%2Fchat{s}", .{if (std.mem.eql(u8, target, "/chat")) "" else try std.fmt.allocPrint(w.a, "%2F{s}", .{w.conv})});
        if (!std.mem.eql(u8, r.header("location") orelse "", want)) return error.NotToLogin;
    }
}

/// A JSON string's text: `\"`, `\\`, `\n` and `\u00XX` undone (the chat's
/// JSON writes no other escape).
fn unjson(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\') {
            try out.append(a, s[i]);
            continue;
        }
        i += 1;
        if (i >= s.len) return error.BadEscape;
        switch (s[i]) {
            '"' => try out.append(a, '"'),
            '\\' => try out.append(a, '\\'),
            'n' => try out.append(a, '\n'),
            'u' => {
                if (i + 4 >= s.len) return error.BadEscape;
                try out.append(a, try std.fmt.parseInt(u8, s[i + 3 .. i + 5], 16));
                i += 4;
            },
            else => return error.BadEscape,
        }
    }
    return out.items;
}

/// **AGENTS ARE CAPPED PER HUMAN**: a new human, Dee, makes twenty,
/// and the twenty-first is a 403. The cap is app/Limits.roc's.
const agents_per_human = 20;

fn agentsCapped(w: *World) !void {
    const dee = try signUp(w.a, w.port(), 1006);
    // Each its own name: no two principals hold one.
    for (0..agents_per_human) |i| {
        if ((try request(w.a, w.port(), "POST", "/agents", dee, try std.fmt.allocPrint(w.a, "name=Many+{d}", .{i}))).status != 201) return error.NotMade;
    }
    const r = try request(w.a, w.port(), "POST", "/agents", dee, "name=Many+more");
    if (r.status != 403) return error.Uncapped;
    if (!has(r.body, "as many agents")) return error.NotSaid;
}

/// **ONLY ITS OWNER NAMES AN AGENT**, and an unknown id is refused
/// in the same words.
fn othersAgentUnnamed(w: *World) !void {
    // Step 28 retired Steve's first agent: a fresh one.
    const made = try request(w.a, w.port(), "POST", "/agents", w.steve, "name=Own");
    if (made.status != 201) return error.NotMade;
    const form = try std.fmt.allocPrint(w.a, "with={s}", .{try field(made.body, "id")});
    const theirs = try request(w.a, w.port(), "POST", "/conversations", w.cal, form);
    if (theirs.status != 400) return error.AnothersAgentNamed;
    const nobody = try request(w.a, w.port(), "POST", "/conversations", w.cal, "with=human%3A999999");
    if (nobody.status != 400) return error.NobodyNamed;
    if (!std.mem.eql(u8, theirs.body, nobody.body)) return error.RefusalsDiffer;
    const own = try request(w.a, w.port(), "POST", "/conversations", w.steve, form);
    if (own.status != 201) return error.OwnAgentRefused;
}

/// **A WRITE FROM ANOTHER ORIGIN IS REFUSED**, whatever cookie it
/// carries.
fn crossOrigin(w: *World) !void {
    const before = try w.messages();
    const target = try w.path("/messages");
    const evil = try send(w.a, w.port(), "POST", target, .{ .cookie = w.ann, .origin = "http://evil.chat.test" }, "from elsewhere");
    if (evil.status != 403) return error.CrossOriginAccepted;
    const bare = try send(w.a, w.port(), "POST", target, .{ .cookie = w.ann, .origin = "" }, "from nowhere");
    if (bare.status != 403) return error.NoOriginAccepted;
    if (try w.messages() != before) return error.Posted;
    // The same post from the chat's own origin goes through.
    if ((try w.postAs(w.ann, "from home")).status != 201) return error.OwnRefused;
}

/// **LOGOUT ENDS THE SESSION**, behind the origin check.
fn logout(w: *World) !void {
    const eve = try signUp(w.a, w.port(), 1007);
    if ((try get(w.a, w.port(), "/me", eve)).status != 200) return error.NotSignedIn;
    const evil = try send(w.a, w.port(), "POST", "/logout", .{ .cookie = eve, .origin = "http://evil.chat.test" }, "");
    if (evil.status != 403) return error.CrossOriginLogout;
    if ((try get(w.a, w.port(), "/me", eve)).status != 200) return error.LoggedOutByAnother;
    const out = try request(w.a, w.port(), "POST", "/logout", eve, "");
    if (out.status != 303) return error.NotLoggedOut;
    if (!std.mem.eql(u8, out.cookie("session") orelse "-", "")) return error.CookieKept;
    if ((try get(w.a, w.port(), "/me", eve)).status != 401) return error.SessionLives;
}

/// **A STREAM ENDS AT ITS LIFETIME**: Steve's own key holds a
/// stream; the key is revoked while it is open, and the stream ends at its
/// lifetime (half a second here, `stream_lifetime_ms_for_test`), never
/// carrying on for the revoked key; resumed, the key is a 401.
const lifetime_ms_for_test = 500;

fn streamLifetime(w: *World) !void {
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.steve, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1001)}))));
    const k = try mint(w, "");
    w.rig.server.stream_lifetime_ms_for_test.store(lifetime_ms_for_test, .release);
    defer w.rig.server.stream_lifetime_ms_for_test.store(0, .release);
    const target = try agentPath(w, conv, "/stream");
    const t0 = Io.Clock.now(.awake, io);
    const l = try Listener.openAs(w.a, w.port(), target, .{ .key = k.secret }, "");
    defer l.close();
    const revoked = try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "/keys/{s}/revoke", .{k.id}), w.steve, "");
    if (revoked.status != 200) return error.NotRevoked;
    if (!l.ends()) return error.StreamOutlived;
    if (t0.untilNow(io, .awake).toMilliseconds() < lifetime_ms_for_test) return error.EndedEarly;
    const again = Listener.openAs(w.a, w.port(), target, .{ .key = k.secret }, "") catch |e| switch (e) {
        error.NotAStream => return,
        else => return e,
    };
    again.close();
    return error.RevokedKeyStreamed;
}

/// **A HOLDER'S STREAMS ARE CAPPED, AND ONLY ITS OWN END**: B holds a
/// stream of the conversation; A opens nine, and the ninth ends A's own
/// first, never B's.
const streams_per_holder = 8;

fn streamsPerHolder(w: *World) !void {
    const target = try w.path("/stream");
    // From after the last message, so each stream starts empty.
    const last = try std.fmt.allocPrint(w.a, "{d}", .{try w.messages()});
    const bea = try Listener.open(w.a, w.port(), target, w.bea, last);
    defer bea.close();
    var ann: [streams_per_holder + 1]*Listener = undefined;
    var opened: usize = 0;
    defer for (ann[0..opened]) |l| l.close();
    while (opened < ann.len) : (opened += 1) ann[opened] = try Listener.open(w.a, w.port(), target, w.ann, last);
    if ((try w.postAs(w.ann, "to the held")).status != 201) return error.NotPosted;
    try bea.until("\"markdown\":\"to the held\"");
    try ann[1].until("\"markdown\":\"to the held\"");
    try ann[streams_per_holder].until("\"markdown\":\"to the held\"");
    if (has(ann[0].got.items, "to the held") or !ann[0].ends()) return error.OwnFirstKept;
}

/// `bytes` written over the data root's file at `path`.
fn overwrite(w: *World, path: []const u8, bytes: []const u8) !void {
    const f = try w.rig.data.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

/// **A POST LEARNS ITS ID FROM THE TALLY**, never by reading the
/// transcript whole: a conversation's transcript is made unreadable whole
/// (its one line junk, its size the same), so a read is a 500, and the
/// next post still answers id 2.
fn postByTally(w: *World) !void {
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.ann, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)}))));
    if ((try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), w.ann, "one")).status != 201) return error.NotPosted;
    const path = try std.fmt.allocPrint(w.a, "chat/transcripts/{s}", .{conv});
    const was = try w.rig.data.readFileAlloc(io, path, w.a, .limited(1024 * 1024));
    const junk = try w.a.alloc(u8, was.len);
    @memset(junk, 'x');
    try overwrite(w, path, junk);
    if ((try get(w.a, w.port(), try agentPath(w, conv, ""), w.ann)).status != 500) return error.TranscriptStillReads;
    const r = try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), w.ann, "two");
    if (r.status != 201) return error.PostReadTheTranscript;
    if (!std.mem.startsWith(u8, r.body, "{\"id\":2,")) return error.NotTheSecond;
}

/// **A FULL TRANSCRIPT REFUSES A POST** (Limits.transcript_bytes_most):
/// a conversation's transcript and tally made so A's post of `x` would end
/// one byte past the cap, and it is a 413 that says so, its transcript
/// unchanged; made so it ends one byte short of the cap, and exactly at
/// it, and the post is taken.
const transcript_bytes_most = 4_000_000;
fn transcriptFull(w: *World) !void {
    // A's post of `x`, its transcript line, the first of a tally of none:
    // `at` is the server's clock in seconds, ten digits until 2286.
    const x_line_len = (try std.fmt.allocPrint(w.a, "message v1 id=1 at=1761600000 by=human:{s} body=x\n", .{try hid(w.a, 1001)})).len;
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.ann, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)}))));
    const over = transcript_bytes_most - x_line_len + 1;
    try fillTranscript(w, conv, over);
    const r = try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), w.ann, "x");
    if (r.status != 413) return error.FullAccepted;
    if (!has(r.body, "full")) return error.NotSaid;
    if ((try transcriptLen(w, conv)) != over) return error.Appended;
    for ([_]usize{ transcript_bytes_most - x_line_len - 1, transcript_bytes_most - x_line_len }) |room| {
        try fillTranscript(w, conv, room);
        if ((try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), w.ann, "x")).status != 201) return error.RoomRefused;
        if ((try transcriptLen(w, conv)) != room + x_line_len) return error.NotAppended;
    }
}

/// Conversation `conv`'s transcript made `n` bytes of junk, its tally `n`
/// bytes of no message, and its offsets file gone (as a tally of none
/// has none).
fn fillTranscript(w: *World, conv: []const u8, n: usize) !void {
    const junk = try w.a.alloc(u8, n);
    @memset(junk, 'x');
    try overwrite(w, try std.fmt.allocPrint(w.a, "chat/transcripts/{s}", .{conv}), junk);
    try overwrite(w, try std.fmt.allocPrint(w.a, "chat/tallies/{s}", .{conv}), try std.fmt.allocPrint(w.a, "0 {d}\n", .{n}));
    w.rig.data.deleteFile(io, try std.fmt.allocPrint(w.a, "chat/offsets/{s}", .{conv})) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

fn transcriptLen(w: *World, conv: []const u8) !usize {
    const bytes = try w.rig.data.readFileAlloc(io, try std.fmt.allocPrint(w.a, "chat/transcripts/{s}", .{conv}), w.a, .limited(8 * 1024 * 1024));
    return bytes.len;
}

/// **A READ IS A PAGE** (Limits.page_messages): A posts a page and
/// five more; a read answers the newest page, ids 6 to 105, and `earlier`;
/// `before=6` answers 1 to 5, and no earlier; a `before` that is no id is
/// a 400. The conversation's page shows the same newest page, and the
/// button that loads the one before.
const page_messages = 100;
const paged_posts = page_messages + 5;

fn pagesBack(w: *World) !void {
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.ann, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)}))));
    w.paged = conv;
    const posts = try agentPath(w, conv, "/messages");
    for (1..paged_posts + 1) |n| {
        if ((try request(w.a, w.port(), "POST", posts, w.ann, try std.fmt.allocPrint(w.a, "paged {d}", .{n}))).status != 201) return error.NotPosted;
    }
    try holdsPage(w, try pageOf(w, conv, ""), 6, paged_posts, true);
    try holdsPage(w, try pageOf(w, conv, "6"), 1, 5, false);
    for ([_][]const u8{ "0", "x", "06", "6&before=7" }) |bad| {
        const r = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/conversations/{s}?before={s}", .{ conv, bad }), w.ann);
        if (r.status != 400) return error.BadBeforeTaken;
    }
    const page = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/{s}", .{conv}), w.ann);
    if (page.status != 200) return error.NoPage;
    if (!has(page.body, "<article id=m6>") or has(page.body, "<article id=m5>")) return error.PageNotNewest;
    if (!has(page.body, "<button id=earlier type=button>")) return error.NoEarlierButton;
}

/// A read of conversation `conv`, `before` it when not empty.
fn pageOf(w: *World, conv: []const u8, before: []const u8) ![]const u8 {
    const target = if (before.len == 0)
        try agentPath(w, conv, "")
    else
        try std.fmt.allocPrint(w.a, "/conversations/{s}?before={s}", .{ conv, before });
    const r = try get(w.a, w.port(), target, w.ann);
    if (r.status != 200) return error.NotRead;
    return r.body;
}

/// Whether `body` holds exactly the messages `first` to `last`, and says
/// `earlier` as given.
fn holdsPage(w: *World, body: []const u8, first: usize, last: usize, earlier: bool) !void {
    if (count(body, "{\"id\":") - 1 != last - first + 1) return error.NotAPage;
    if (!has(body, try std.fmt.allocPrint(w.a, "{{\"id\":{d},", .{first}))) return error.NoFirst;
    if (!has(body, try std.fmt.allocPrint(w.a, "{{\"id\":{d},", .{last}))) return error.NoLast;
    if (!std.mem.endsWith(u8, body, if (earlier) "],\"earlier\":true}" else "],\"earlier\":false}")) return error.EarlierWrong;
}

/// **A STREAM'S BACKLOG IS AT MOST THE NEWEST PAGE**: B resumes from
/// message 1, and is told of the gap before 6, then sent 6 to 105; from 5
/// there is no gap; from 103, 104 and 105 alone.
fn streamGap(w: *World) !void {
    const target = try agentPath(w, w.paged, "/stream");
    const behind = try Listener.open(w.a, w.port(), target, w.bea, "1");
    defer behind.close();
    try behind.until("\"markdown\":\"paged 105\"");
    if (!has(behind.got.items, "event: gap\ndata: {\"before\":6}\n")) return error.NoGap;
    if (has(behind.got.items, "\"markdown\":\"paged 5\"") or !has(behind.got.items, "\"markdown\":\"paged 6\"")) return error.NotTheNewestPage;
    const level = try Listener.open(w.a, w.port(), target, w.bea, "5");
    defer level.close();
    try level.until("\"markdown\":\"paged 105\"");
    if (has(level.got.items, "event: gap")) return error.GapWithout;
    const near = try Listener.open(w.a, w.port(), target, w.bea, "103");
    defer near.close();
    try near.until("\"markdown\":\"paged 105\"");
    if (has(near.got.items, "\"markdown\":\"paged 103\"") or !has(near.got.items, "\"markdown\":\"paged 104\"")) return error.NotAfter;
}

/// **A PAGE AND A BACKLOG ARE READ FROM THEIR FIRST MESSAGE'S OFFSET**
/// (Store.load_span!), never the transcript whole: message 1's line made
/// junk (its size the same), the newest page still reads and streams, and
/// only the page that holds message 1 is a 500.
fn readFromOffset(w: *World) !void {
    const path = try std.fmt.allocPrint(w.a, "chat/transcripts/{s}", .{w.paged});
    const was = try w.rig.data.readFileAlloc(io, path, w.a, .limited(8 * 1024 * 1024));
    const end = std.mem.indexOfScalar(u8, was, '\n') orelse return error.NoLine;
    @memset(was[0..end], 'x');
    try overwrite(w, path, was);
    try holdsPage(w, try pageOf(w, w.paged, ""), 6, paged_posts, true);
    const l = try Listener.open(w.a, w.port(), try agentPath(w, w.paged, "/stream"), w.bea, "103");
    defer l.close();
    try l.until("\"markdown\":\"paged 105\"");
    const first = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/conversations/{s}?before=6", .{w.paged}), w.ann);
    if (first.status != 500) return error.JunkRead;
}

/// **AN OFFSETS FILE IS WRITTEN AGAIN WHEN IT IS WRONG**: a conversation's
/// offsets removed (a transcript from before them), its read still right
/// (the transcript read whole), and the next post writes a record for
/// every message.
const offset_width = 11;

fn offsetsRebuilt(w: *World) !void {
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.ann, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)}))));
    const posts = try agentPath(w, conv, "/messages");
    for (0..3) |_| if ((try request(w.a, w.port(), "POST", posts, w.ann, "before")).status != 201) return error.NotPosted;
    const path = try std.fmt.allocPrint(w.a, "chat/offsets/{s}", .{conv});
    try w.rig.data.deleteFile(io, path);
    try holdsPage(w, try pageOf(w, conv, ""), 1, 3, false);
    if ((try request(w.a, w.port(), "POST", posts, w.ann, "after")).status != 201) return error.NotPosted;
    const offsets = try w.rig.data.readFileAlloc(io, path, w.a, .limited(1024));
    if (offsets.len != 4 * offset_width) return error.OffsetsNotRebuilt;
    try holdsPage(w, try pageOf(w, conv, "4"), 1, 3, false);
}

/// **THE CAPS ON WHAT ONE HUMAN MAKES**: each step sets the host's
/// small cap for the end to end (`cap_for_test`, Limits.load_cap!), reaches it,
/// and the next one is a 403 that names the cap.
const small_cap = 3;

fn conversationsCapped(w: *World) !void {
    w.fay = try signUp(w.a, w.port(), 1010);
    w.rig.auth.cap_for_test.store(small_cap, .release);
    defer w.rig.auth.cap_for_test.store(0, .release);
    for (0..small_cap) |_| {
        if ((try request(w.a, w.port(), "POST", "/conversations", w.fay, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)})))).status != 201) return error.NotStarted;
    }
    const r = try request(w.a, w.port(), "POST", "/conversations", w.fay, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)})));
    if (r.status != 403) return error.Uncapped;
    if (!has(r.body, "as many conversations")) return error.NotSaid;
}

fn keysCapped(w: *World) !void {
    w.rig.auth.cap_for_test.store(small_cap, .release);
    defer w.rig.auth.cap_for_test.store(0, .release);
    for (0..small_cap) |_| {
        if ((try request(w.a, w.port(), "POST", "/keys", w.fay, "")).status != 201) return error.NotMinted;
    }
    const r = try request(w.a, w.port(), "POST", "/keys", w.fay, "");
    if (r.status != 403) return error.Uncapped;
    if (!has(r.body, "as many keys")) return error.NotSaid;
}

fn invitesCapped(w: *World) !void {
    const made = try request(w.a, w.port(), "POST", "/agents", w.fay, "name=Fay%27s");
    if (made.status != 201) return error.NotMade;
    const form = try std.fmt.allocPrint(w.a, "as={s}", .{try field(made.body, "id")});
    w.rig.auth.cap_for_test.store(small_cap, .release);
    defer w.rig.auth.cap_for_test.store(0, .release);
    for (0..small_cap) |_| {
        if ((try request(w.a, w.port(), "POST", "/invites", w.fay, form)).status != 201) return error.NotInvited;
    }
    const r = try request(w.a, w.port(), "POST", "/invites", w.fay, form);
    if (r.status != 403) return error.Uncapped;
    if (!has(r.body, "as many invites")) return error.NotSaid;
}

/// **A MISSING INDEX IS REBUILT** from the full scan: Fay's key and
/// conversation indexes, and their marks, removed (a store from before
/// them), and her listings are whole again, and the indexes back.
fn indexRebuilt(w: *World) !void {
    for ([_][]const u8{ "auth/keys-indexed", (try std.fmt.allocPrint(w.a, "auth/keys-by-human/{s}", .{try hid(w.a, 1010)})), "chat/indexed", (try std.fmt.allocPrint(w.a, "chat/by-human/{s}", .{try hid(w.a, 1010)})) }) |path| {
        try w.rig.data.deleteFile(io, path);
    }
    const keys = try get(w.a, w.port(), "/keys", w.fay);
    if (keys.status != 200) return error.KeysUnlisted;
    if (count(keys.body, "\"acts_as\":") != small_cap) return error.KeysLost;
    const convs = try get(w.a, w.port(), "/conversations", w.fay);
    if (convs.status != 200) return error.ConversationsUnlisted;
    if (count(convs.body, "\"with\":[") != small_cap) return error.ConversationsLost;
    for ([_][]const u8{ "auth/keys-indexed", (try std.fmt.allocPrint(w.a, "auth/keys-by-human/{s}", .{try hid(w.a, 1010)})), "chat/indexed", (try std.fmt.allocPrint(w.a, "chat/by-human/{s}", .{try hid(w.a, 1010)})) }) |path| {
        _ = w.rig.data.statFile(io, path, .{}) catch return error.NotRebuilt;
    }
}

/// **A LISTING READS ITS OWN INDEX ALONE**: a conversation Fay is
/// not in made unreadable, and her listing still answers, as a scan of
/// every conversation would not.
fn ownIndexOnly(w: *World) !void {
    try overwrite(w, try std.fmt.allocPrint(w.a, "chat/conversations/{s}", .{w.agents_conv}), "junk\n");
    const convs = try get(w.a, w.port(), "/conversations", w.fay);
    if (convs.status != 200) return error.ReadEveryone;
    if (count(convs.body, "\"with\":[") != small_cap) return error.ConversationsLost;
}

/// **A MESSAGE'S MEDIA LOADS ONLY FROM THE CHAT'S UPLOADS**: the chat tells
/// the renderer its uploads are `/user_uploads/` (Conversations.markdown),
/// so an upload's image renders, and one of the chat's own routes as a src
/// is text.
fn mediaFromUploads(w: *World) !void {
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.ann, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)}))));
    const r = try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), w.ann, "<img src=\"/user_uploads/a.png\">\n\n<img src=\"/conversations/1/stream\">");
    if (r.status != 201) return error.NotPosted;
    if (!has(r.body, "<img src=\\\"/user_uploads/a.png\\\">")) return error.UploadNotShown;
    if (!has(r.body, "&lt;img src=&quot;/conversations/1/stream&quot;&gt;")) return error.RouteShownAsMedia;
}

fn pageHtml(w: *World) !void {
    const t = try get(w.a, w.port(), try w.path(""), w.ann);
    const key = "\"id\":1,";
    const at = std.mem.indexOf(u8, t.body, key) orelse return error.NoFirstMessage;
    const html_key = "\"html\":\"";
    const from = (std.mem.indexOfPos(u8, t.body, at, html_key) orelse return error.NoHtml) + html_key.len;
    const to = std.mem.indexOfPos(u8, t.body, from, "\"}") orelse return error.NoHtmlEnd;
    const html = try unjson(w.a, t.body[from..to]);
    const page = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/{s}", .{w.conv}), w.ann);
    if (page.status != 200) return error.NoPage;
    if (!has(page.body, try std.fmt.allocPrint(w.a, "<div class=body>{s}</div>", .{html}))) return error.HtmlDiffers;
}

// ── the agents page ──

/// A form post as the agents page's script makes it: urlencoded, from
/// the page's own origin.
fn pagePost(w: *World, cookie: []const u8, path: []const u8, body: []const u8) !Response {
    return request(w.a, w.port(), "POST", path, cookie, body);
}

fn agentsPageOf(w: *World, cookie: []const u8) ![]const u8 {
    const r = try get(w.a, w.port(), "/chat/agents", cookie);
    if (r.status != 200) return error.NoAgentsPage;
    return r.body;
}

/// Steve's page lists his agent Own, not CC (retired), and not Fay's;
/// Fay's lists hers, its name escaped, and none of his.
fn agentsPageOwn(w: *World) !void {
    const steves = try agentsPageOf(w, w.steve);
    if (!has(steves, "<b>Own</b>")) return error.OwnAgentNotListed;
    if (has(steves, try std.fmt.allocPrint(w.a, "data-id=\"{s}\"", .{w.agent}))) return error.RetiredAgentListed;
    if (has(steves, "Fay&#39;s")) return error.AnothersAgentListed;
    const fays = try agentsPageOf(w, w.fay);
    if (!has(fays, "<b>Fay&#39;s</b>")) return error.OwnAgentNotListed;
    if (has(fays, "<b>Own</b>")) return error.AnothersAgentListed;
}

/// Gil, new, finds the page from `/chat`, makes an agent as its form
/// does, and the next load lists it.
fn agentMadeFromPage(w: *World) !void {
    w.gil = try signUp(w.a, w.port(), 1011);
    const list = try get(w.a, w.port(), "/chat", w.gil);
    if (!has(list.body, "href=\"/chat/agents\"")) return error.NoLinkToAgents;
    const before = try agentsPageOf(w, w.gil);
    if (!has(before, "None yet.")) return error.NotEmpty;
    if (!has(before, "post(\"/agents\", \"name=\"")) return error.FormPostsElsewhere;
    const made = try pagePost(w, w.gil, "/agents", "name=Pal");
    if (made.status != 201) return error.NotMade;
    w.gil_agent = try field(made.body, "id");
    const after = try agentsPageOf(w, w.gil);
    if (!has(after, try std.fmt.allocPrint(w.a, "<li data-id=\"{s}\"><b>Pal</b>", .{w.gil_agent}))) return error.MadeNotListed;
}

/// The agent's invite button makes an invite, its code in that answer
/// alone; the next load lists the invite, and no code.
fn inviteFromPage(w: *World) !void {
    const page = try agentsPageOf(w, w.gil);
    if (!has(page, try std.fmt.allocPrint(w.a, "class=invite data-for=\"{s}\"", .{w.gil_agent}))) return error.NoInviteButton;
    if (!has(page, "post(\"/invites\", \"as=\"")) return error.ButtonPostsElsewhere;
    const r = try pagePost(w, w.gil, "/invites", try std.fmt.allocPrint(w.a, "as={s}", .{w.gil_agent}));
    if (r.status != 201) return error.NotInvited;
    w.gil_invite = try field(r.body, "id");
    const code = try field(r.body, "code");
    const after = try agentsPageOf(w, w.gil);
    if (!has(after, try std.fmt.allocPrint(w.a, "<li data-invite={s}>For Pal", .{w.gil_invite}))) return error.InviteNotListed;
    if (has(after, code)) return error.CodeOnPage;
    const listed = try get(w.a, w.port(), "/invites", w.gil);
    if (has(listed.body, code)) return error.CodeListed;
}

/// A key and the invite, each revoked by its button's route, are gone
/// from the next load.
fn revokeFromPage(w: *World) !void {
    const minted = try pagePost(w, w.gil, "/keys", "");
    if (minted.status != 201) return error.NotMinted;
    const key = try field(minted.body, "id");
    const page = try agentsPageOf(w, w.gil);
    const key_path = try std.fmt.allocPrint(w.a, "/keys/{s}/revoke", .{key});
    const invite_path = try std.fmt.allocPrint(w.a, "/invites/{s}/revoke", .{w.gil_invite});
    if (!has(page, try std.fmt.allocPrint(w.a, "<li data-key={s}>", .{key}))) return error.KeyNotListed;
    if (!has(page, try std.fmt.allocPrint(w.a, "data-path=\"{s}\"", .{key_path}))) return error.NoKeyRevoke;
    if (!has(page, try std.fmt.allocPrint(w.a, "data-path=\"{s}\"", .{invite_path}))) return error.NoInviteRevoke;
    if ((try pagePost(w, w.gil, key_path, "")).status != 200) return error.KeyNotRevoked;
    if ((try pagePost(w, w.gil, invite_path, "")).status != 200) return error.InviteNotRevoked;
    const after = try agentsPageOf(w, w.gil);
    if (has(after, try std.fmt.allocPrint(w.a, "<li data-key={s}>", .{key}))) return error.RevokedKeyListed;
    if (has(after, try std.fmt.allocPrint(w.a, "<li data-invite={s}>", .{w.gil_invite}))) return error.RevokedInviteListed;
}

/// Hal, another human, sees none of Gil's agent, keys or invites on his
/// page, and revokes none of them: each is the 404 of one not there.
fn othersSeeNoneOnPage(w: *World) !void {
    w.hal = try signUp(w.a, w.port(), 1012);
    const inv = try pagePost(w, w.gil, "/invites", try std.fmt.allocPrint(w.a, "as={s}", .{w.gil_agent}));
    if (inv.status != 201) return error.NotInvited;
    const invite_id = try field(inv.body, "id");
    const minted = try pagePost(w, w.gil, "/keys", "");
    if (minted.status != 201) return error.NotMinted;
    const key = try field(minted.body, "id");
    const hals = try agentsPageOf(w, w.hal);
    if (has(hals, w.gil_agent) or has(hals, "Pal")) return error.AnothersAgentShown;
    if (has(hals, "data-invite=") or has(hals, "data-key=")) return error.AnothersListed;
    if ((try pagePost(w, w.hal, try std.fmt.allocPrint(w.a, "/invites/{s}/revoke", .{invite_id}), "")).status != 404) return error.RevokedAnothersInvite;
    if ((try pagePost(w, w.hal, try std.fmt.allocPrint(w.a, "/keys/{s}/revoke", .{key}), "")).status != 404) return error.RevokedAnothersKey;
    const gils = try agentsPageOf(w, w.gil);
    if (!has(gils, try std.fmt.allocPrint(w.a, "<li data-invite={s}>", .{invite_id}))) return error.InviteLost;
    if (!has(gils, try std.fmt.allocPrint(w.a, "<li data-key={s}>", .{key}))) return error.KeyLost;
}

/// A key asking for the agents page is the 403 every page gives one.
fn agentsPageRefusesKey(w: *World) !void {
    const r = try send(w.a, w.port(), "GET", "/chat/agents", .{ .key = w.key }, "");
    if (r.status != 403) return error.KeyGivenPage;
    if ((try get(w.a, w.port(), "/chat/agents", "")).status != 303) return error.SignedOutGivenPage;
}

/// `/chat`'s start form offers Gil his agent to tick, Hal nothing of his;
/// and what the script sends for a tick and a typed id starts one.
fn startPicksAgents(w: *World) !void {
    const tick = try std.fmt.allocPrint(w.a, "<input type=checkbox name=agent value=\"{s}\"> Pal", .{w.gil_agent});
    const gils = try get(w.a, w.port(), "/chat", w.gil);
    if (!has(gils.body, tick)) return error.OwnAgentNotOffered;
    const hals = try get(w.a, w.port(), "/chat", w.hal);
    if (has(hals.body, w.gil_agent)) return error.AnothersAgentOffered;
    const form = try std.fmt.allocPrint(w.a, "with={s}%2Chuman%3A{s}", .{ w.gil_agent, try hid(w.a, 1012) });
    _ = try startedId(try pagePost(w, w.gil, "/conversations", form));
}

/// The id a start answers (`{"id":N}`).
fn startedId(r: Response) ![]const u8 {
    if (r.status != 201) return error.NotStarted;
    return field(r.body, "id");
}

/// Steve mints a key with `form`; its public id and its secret.
fn mint(w: *World, form: []const u8) !struct { id: []const u8, secret: []const u8 } {
    const r = try request(w.a, w.port(), "POST", "/keys", w.steve, form);
    if (r.status != 201) return error.NotMinted;
    return .{ .id = try field(r.body, "id"), .secret = try field(r.body, "secret") };
}

/// Steve invites with `form`: the invite's id and its code.
fn invite(w: *World, form: []const u8) !struct { id: []const u8, code: []const u8 } {
    const r = try request(w.a, w.port(), "POST", "/invites", w.steve, form);
    if (r.status != 201) return error.NotInvited;
    return .{ .id = try field(r.body, "id"), .code = try field(r.body, "code") };
}

/// The agent redeems `code`, with no other credential.
fn redeem(w: *World, code: []const u8) !Response {
    return send(w.a, w.port(), "POST", "/invites/redeem", .{}, try std.fmt.allocPrint(w.a, "code={s}", .{code}));
}

/// **AN AGENT'S KEY, BY AN INVITE**: Steve invites with `form`, the agent
/// redeems the code; the key's public id and its secret.
fn agentKey(w: *World, form: []const u8) !struct { id: []const u8, secret: []const u8 } {
    const inv = try invite(w, form);
    const r = try redeem(w, inv.code);
    if (r.status != 201) return error.NotRedeemed;
    return .{ .id = try field(r.body, "id"), .secret = try field(r.body, "secret") };
}

/// **THE TEST'S RETIREMENT**: the agent `agent:N`'s line gone from the
/// accounts, as Admin's plan removes it.
fn retire(w: *World, agent: []const u8) !void {
    const before = try w.rig.data.readFileAlloc(io, "auth/accounts", w.a, .limited(1024 * 1024));
    const prefix = try std.fmt.allocPrint(w.a, "account v1 kind=agent id={s} ", .{agent["agent:".len..]});
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, before, '\n');
    var dropped: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, prefix)) {
            dropped += 1;
            continue;
        }
        try kept.appendSlice(w.a, line);
        try kept.append(w.a, '\n');
    }
    if (dropped != 1) return error.NotRetired;
    const f = try w.rig.data.createFile(io, "auth/accounts", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, kept.items);
}

fn agentPath(w: *const World, conv: []const u8, comptime tail: []const u8) ![]const u8 {
    return std.fmt.allocPrint(w.a, "/conversations/{s}" ++ tail, .{conv});
}

fn makeAgent(w: *World) !void {
    w.steve = try signUp(w.a, w.port(), 1004);
    if ((try request(w.a, w.port(), "POST", "/agents", w.steve, "name=")).status != 400) return error.EmptyNameTaken;
    if ((try request(w.a, w.port(), "POST", "/agents", "", "name=CC")).status != 401) return error.MadeSignedOut;
    const r = try request(w.a, w.port(), "POST", "/agents", w.steve, "name=CC");
    if (r.status != 201) return error.NotMade;
    w.agent = try field(r.body, "id");
    if (!std.mem.startsWith(u8, w.agent, "agent:")) return error.NotAnAgent;
    if (!std.mem.eql(u8, try field(r.body, "owner"), (try std.fmt.allocPrint(w.a, "human:{s}", .{try hid(w.a, 1004)})))) return error.NotSteves;
}

fn inviteForAgent(w: *World) !void {
    const form = try std.fmt.allocPrint(w.a, "as={s}", .{w.agent});
    // C, another human, is no owner of Steve's agent.
    if ((try request(w.a, w.port(), "POST", "/invites", w.cal, form)).status != 403) return error.InvitedForAnothersAgent;
    const k = try agentKey(w, form);
    w.key_id = k.id;
    w.key = k.secret;
    if (w.key.len != 64) return error.NotASecret;
    // Listed, with no secret.
    const listed = try get(w.a, w.port(), "/keys", w.steve);
    if (listed.status != 200) return error.NotListed;
    if (!has(listed.body, try std.fmt.allocPrint(w.a, "\"acts_as\":\"{s}\"", .{w.agent}))) return error.NotListed;
    if (has(listed.body, "secret") or has(listed.body, w.key)) return error.SecretListed;
}

fn agentStarts(w: *World) !void {
    const started = try send(w.a, w.port(), "POST", "/conversations", .{ .key = w.key }, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1004)})));
    w.agents_conv = try startedId(started);
    const l = try Listener.open(w.a, w.port(), try agentPath(w, w.agents_conv, "/stream"), w.steve, "");
    defer l.close();
    const posted = try send(w.a, w.port(), "POST", try agentPath(w, w.agents_conv, "/messages"), .{ .key = w.key }, "hello from **CC**");
    if (posted.status != 201) return error.NotPosted;
    if (!has(posted.body, try std.fmt.allocPrint(w.a, "\"by\":\"{s}\"", .{w.agent}))) return error.NotByTheAgent;
    try l.until("\n\n");
    sleepMs(100);
    if (count(l.got.items, "event: message\nid: 1\n") != 1) return error.NotOnce;
    if (!has(l.got.items, "hello from **CC**")) return error.NotTheMessage;
}

fn agentReads(w: *World) !void {
    if ((try request(w.a, w.port(), "POST", try agentPath(w, w.agents_conv, "/messages"), w.steve, "hi CC, it's Steve")).status != 201) return error.NotPosted;
    const r = try send(w.a, w.port(), "GET", try agentPath(w, w.agents_conv, ""), .{ .key = w.key }, "");
    if (r.status != 200) return error.NotRead;
    if (!has(r.body, (try std.fmt.allocPrint(w.a, "\"by\":\"human:{s}\",\"kind\":\"human\",\"login\":\"person1004\",\"markdown\":\"hi CC, it's Steve\"", .{try hid(w.a, 1004)})))) return error.NotSeen;
}

/// **MENTIONS, AS THE SERVER PARSES THEM** (app/Mentions.roc): each
/// message carries the participants its markdown names as a word, by their
/// names now, in the post's answer, the transcript and the stream alike.
fn mentions(w: *World) !void {
    // Steve, his agent and Ann: more than a human and one agent, so a
    // post names whom its words name, and no one else (dmNamesTheAgent is
    // the rule for two).
    const group = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.steve, try std.fmt.allocPrint(w.a, "with={s}%2Chuman%3A{s}", .{ w.agent, try hid(w.a, 1001) })));
    const path = try agentPath(w, group, "/messages");
    const l = try Listener.open(w.a, w.port(), try agentPath(w, group, "/stream"), w.steve, "");
    defer l.close();
    const named = try std.fmt.allocPrint(w.a, "\"mentions\":[\"{s}\"]", .{w.agent});
    const to_cc = try request(w.a, w.port(), "POST", path, w.steve, "@CC, a mention");
    if (to_cc.status != 201 or !has(to_cc.body, named)) return error.NotNamed;
    // A name that goes on, and an `@` inside a word, name nobody.
    const near = try request(w.a, w.port(), "POST", path, w.steve, "see @CCX, and mail a@CC.com");
    if (near.status != 201 or !has(near.body, "\"mentions\":[]")) return error.NamedByAPart;
    // A name no participant goes by is text.
    const stranger = try request(w.a, w.port(), "POST", path, w.steve, "@Bea, are you here?");
    if (stranger.status != 201 or !has(stranger.body, "\"mentions\":[]")) return error.NamedAStranger;
    // A display name with a space, named by the agent.
    const back = try send(w.a, w.port(), "POST", path, .{ .key = w.key }, "thanks, @Person 1004!");
    if (back.status != 201 or !has(back.body, (try std.fmt.allocPrint(w.a, "\"mentions\":[\"human:{s}\"]", .{try hid(w.a, 1004)})))) return error.NotNamedBack;
    // Quoting a post that named the agent names nobody again: the chat's
    // quote-reply fence, and a `>` quote, are skipped.
    const quoted = try request(w.a, w.port(), "POST", path, w.steve, "In MSG_1 you said:\n~~~ quote\n@CC, a mention\n~~~\n\n> @CC again\n\nagreed");
    if (quoted.status != 201 or !has(quoted.body, "\"mentions\":[]")) return error.NamedByAQuote;
    try l.until("thanks, @Person 1004!");
    if (!has(l.got.items, named) or !has(l.got.items, (try std.fmt.allocPrint(w.a, "\"mentions\":[\"human:{s}\"]", .{try hid(w.a, 1004)})))) return error.NotOnTheStream;
    const read = try send(w.a, w.port(), "GET", try agentPath(w, group, ""), .{ .key = w.key }, "");
    if (count(read.body, named) != 1 or count(read.body, (try std.fmt.allocPrint(w.a, "\"mentions\":[\"human:{s}\"]", .{try hid(w.a, 1004)}))) != 1) return error.NotInTheTranscript;
}

/// **A HUMAN'S POST IN A DM WITH ONE AGENT NAMES THE AGENT** (Mentions.of_post):
/// Steve's plain "back at you" to his agent names it, and so does a post
/// of his that is all quote; the agent's own post names nobody; the same
/// plain post with a second human, or a second agent, names nobody.
fn dmNamesTheAgent(w: *World) !void {
    // A human of their own (so no earlier step's caps are in the way), and
    // their agent, keyed by an invite.
    const owner = try signUp(w.a, w.port(), 1022);
    const agent = try field((try request(w.a, w.port(), "POST", "/agents", owner, "name=Pal+1022")).body, "id");
    const inv = try request(w.a, w.port(), "POST", "/invites", owner, try std.fmt.allocPrint(w.a, "as={s}", .{agent}));
    if (inv.status != 201) return error.NotInvited;
    const redeemed = try redeem(w, try field(inv.body, "code"));
    if (redeemed.status != 201) return error.NotRedeemed;
    const key = try field(redeemed.body, "secret");
    const named = try std.fmt.allocPrint(w.a, "\"mentions\":[\"{s}\"]", .{agent});

    const dm = try agentPath(w, try startedId(try request(w.a, w.port(), "POST", "/conversations", owner, try std.fmt.allocPrint(w.a, "with={s}", .{agent}))), "/messages");
    const plain = try request(w.a, w.port(), "POST", dm, owner, "back at you");
    if (plain.status != 201 or !has(plain.body, named)) return error.PlainPostNamedNobody;
    const quoted = try request(w.a, w.port(), "POST", dm, owner, "> what you said");
    if (quoted.status != 201 or !has(quoted.body, named)) return error.QuoteNamedNobody;
    const own = try send(w.a, w.port(), "POST", dm, .{ .key = key }, "noted");
    if (own.status != 201 or !has(own.body, "\"mentions\":[]")) return error.AgentNamedItself;

    const with_human = try startedId(try request(w.a, w.port(), "POST", "/conversations", owner, try std.fmt.allocPrint(w.a, "with={s}%2Chuman%3A{s}", .{ agent, try hid(w.a, 1002) })));
    const three = try request(w.a, w.port(), "POST", try agentPath(w, with_human, "/messages"), owner, "back at you");
    if (three.status != 201 or !has(three.body, "\"mentions\":[]")) return error.NamedWithASecondHuman;
    const second = try field((try request(w.a, w.port(), "POST", "/agents", owner, "name=Second+1022")).body, "id");
    const with_agents = try startedId(try request(w.a, w.port(), "POST", "/conversations", owner, try std.fmt.allocPrint(w.a, "with={s}%2C{s}", .{ agent, second })));
    const two_agents = try request(w.a, w.port(), "POST", try agentPath(w, with_agents, "/messages"), owner, "back at you");
    if (two_agents.status != 201 or !has(two_agents.body, "\"mentions\":[]")) return error.NamedWithASecondAgent;
}

/// **THE SERVER'S BACKSTOP AGAINST RUNAWAY AGENTS**
/// (Limits.agent_hops_per_window, fifteen an hour, each agent its own):
/// Ping answers Pong fifteen times and Pong answers three, Pong's never
/// counting toward Ping's; Ping's sixteenth post, even a status, is a 429
/// naming the cap, nothing is stored, and its key is audited. An hour on,
/// Ping's fifteen have left the window and it posts again; back at the
/// hour's start they count once more, and a human's post resets them.
fn agentHops(w: *World) !void {
    const ping = try field((try request(w.a, w.port(), "POST", "/agents", w.steve, "name=Ping")).body, "id");
    const pong = try field((try request(w.a, w.port(), "POST", "/agents", w.steve, "name=Pong")).body, "id");
    const ping_key = (try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}", .{ping}))).secret;
    const pong_key = (try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}", .{pong}))).secret;
    const form = try std.fmt.allocPrint(w.a, "with=agent%3A{s}%2Cagent%3A{s}", .{ ping["agent:".len..], pong["agent:".len..] });
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.steve, form));
    const path = try agentPath(w, conv, "/messages");
    for (0..15) |i| {
        const text = try std.fmt.allocPrint(w.a, "@Pong hop {d}", .{i + 1});
        if ((try send(w.a, w.port(), "POST", path, .{ .key = ping_key }, text)).status != 201) return error.HopRefused;
        if (i % 5 == 0 and (try send(w.a, w.port(), "POST", path, .{ .key = pong_key }, "@Ping back")).status != 201) return error.OthersHopsCounted;
    }
    const sixteenth = try send(w.a, w.port(), "POST", path, .{ .key = ping_key }, "status: still here");
    if (sixteenth.status != 429) return error.RunawayAccepted;
    if (!has(sixteenth.body, "at most 15 times in 60 minutes") or !has(sixteenth.body, "a human's post resets it")) return error.CapNotNamed;
    const read = try send(w.a, w.port(), "GET", try agentPath(w, conv, ""), .{ .key = ping_key }, "");
    if (has(read.body, "still here") or !has(read.body, "@Pong hop 15")) return error.RunawayStored;
    const log = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    if (!has(log, try std.fmt.allocPrint(w.a, "who={s} via=key:", .{ping})) or !has(log, try std.fmt.allocPrint(w.a, "action=post:{s} verdict=refused:agent-hops", .{conv}))) return error.NotAudited;
    // An hour and a second on, on the server's clock: the fifteen are out
    // of the window.
    w.rig.server.clock_ahead_s_for_test.store(3601, .release);
    const later = try send(w.a, w.port(), "POST", path, .{ .key = ping_key }, "@Pong an hour on");
    w.rig.server.clock_ahead_s_for_test.store(0, .release);
    if (later.status != 201) return error.OldHopsCounted;
    if ((try send(w.a, w.port(), "POST", path, .{ .key = ping_key }, "@Pong too soon")).status != 429) return error.RunawayAccepted;
    if ((try request(w.a, w.port(), "POST", path, w.steve, "carry on")).status != 201) return error.HumanRefused;
    if ((try send(w.a, w.port(), "POST", path, .{ .key = ping_key }, "@Pong five")).status != 201) return error.NotLetGoOn;
}

fn keyCannotMint(w: *World) !void {
    const form = try std.fmt.allocPrint(w.a, "as={s}", .{w.agent});
    if ((try send(w.a, w.port(), "POST", "/keys", .{ .key = w.key }, form)).status != 403) return error.KeyMinted;
    if ((try send(w.a, w.port(), "POST", "/agents", .{ .key = w.key }, "name=Rogue")).status != 403) return error.KeyMadeAnAgent;
    if ((try send(w.a, w.port(), "GET", "/keys", .{ .key = w.key }, "")).status != 403) return error.KeyListedKeys;
}

fn revoke(w: *World) !void {
    const target = try std.fmt.allocPrint(w.a, "/keys/{s}/revoke", .{w.key_id});
    // C cannot revoke it; Steve can.
    if ((try request(w.a, w.port(), "POST", target, w.cal, "")).status != 404) return error.RevokedByAnother;
    if ((try send(w.a, w.port(), "GET", try agentPath(w, w.agents_conv, ""), .{ .key = w.key }, "")).status != 200) return error.NotLiveBefore;
    const r = try request(w.a, w.port(), "POST", target, w.steve, "");
    if (r.status != 200 or !has(r.body, "\"revoked\":true")) return error.NotRevoked;
    if ((try send(w.a, w.port(), "GET", try agentPath(w, w.agents_conv, ""), .{ .key = w.key }, "")).status != 401) return error.RevokedKeyWorks;
    if ((try send(w.a, w.port(), "POST", try agentPath(w, w.agents_conv, "/messages"), .{ .key = w.key }, "still here")).status != 401) return error.RevokedKeyPosts;
}

fn expired(w: *World) !void {
    const k = try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}&lifetime=1", .{w.agent}));
    // Past its one second, on the host's clock of whole seconds.
    sleepMs(2100);
    if ((try send(w.a, w.port(), "GET", try agentPath(w, w.agents_conv, ""), .{ .key = k.secret }, "")).status != 401) return error.ExpiredKeyWorks;
}

fn scoped(w: *World) !void {
    // A second conversation, Steve's with his agent: the one the key reads.
    const x = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.steve, try std.fmt.allocPrint(w.a, "with={s}", .{w.agent})));
    const k = try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}&read=only%3A{s}&post=off", .{ w.agent, x }));
    if ((try send(w.a, w.port(), "GET", try agentPath(w, x, ""), .{ .key = k.secret }, "")).status != 200) return error.ScopedNotRead;
    const posted = try send(w.a, w.port(), "POST", try agentPath(w, x, "/messages"), .{ .key = k.secret }, "out of scope");
    if (posted.status != 403) return error.ScopedPosted;
    if ((try send(w.a, w.port(), "GET", try agentPath(w, w.agents_conv, ""), .{ .key = k.secret }, "")).status != 404) return error.ScopedReadAnother;
    w.key = k.secret;
    w.agents_conv = x;
}

fn bothCredentials(w: *World) !void {
    const target = try agentPath(w, w.agents_conv, "");
    if ((try send(w.a, w.port(), "GET", target, .{ .key = w.key }, "")).status != 200) return error.KeyNotLive;
    if ((try send(w.a, w.port(), "GET", target, .{ .cookie = w.steve }, "")).status != 200) return error.CookieNotLive;
    if ((try send(w.a, w.port(), "GET", target, .{ .cookie = w.steve, .key = w.key }, "")).status != 400) return error.BothTaken;
    if ((try send(w.a, w.port(), "POST", try agentPath(w, w.agents_conv, "/messages"), .{ .cookie = w.steve, .key = w.key }, "which one?")).status != 400) return error.BothTaken;
}

fn audited(w: *World) !void {
    const log = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    const wanted = [_][]const u8{
        "action=grant:agent:", // C's mint for Steve's agent
        "verdict=refused:not-the-granters-own",
        "verdict=refused:granted-by-key", // the key's mint and its agent
        "action=read:", // the revoked key's read, the expired one's, the scoped one's
        "verdict=refused:revoked",
        "verdict=refused:expired",
        "verdict=refused:out-of-scope",
    };
    for (wanted) |line| if (!has(log, line)) return error.NotAudited;
    // A secret is never in it.
    if (has(log, w.key)) return error.SecretAudited;
}

fn inviteRedeemPost(w: *World) !void {
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.steve, try std.fmt.allocPrint(w.a, "with={s}", .{w.agent})));
    const inv = try invite(w, try std.fmt.allocPrint(w.a, "as={s}", .{w.agent}));
    if (inv.code.len != 64) return error.NotACode;
    // Listed, live, with no code.
    const listed = try get(w.a, w.port(), "/invites", w.steve);
    if (listed.status != 200 or !has(listed.body, try std.fmt.allocPrint(w.a, "{{\"id\":{s},\"for\":\"{s}\"", .{ inv.id, w.agent }))) return error.NotListed;
    if (has(listed.body, "code") or has(listed.body, inv.code)) return error.CodeListed;
    // The code is the credential: sent with a cookie or a key, refused, and
    // the invite not spent by it.
    const body = try std.fmt.allocPrint(w.a, "code={s}", .{inv.code});
    if ((try request(w.a, w.port(), "POST", "/invites/redeem", w.steve, body)).status != 401) return error.RedeemedWithCookie;
    if ((try send(w.a, w.port(), "POST", "/invites/redeem", .{ .key = w.key }, body)).status != 401) return error.RedeemedWithKey;
    const r = try redeem(w, inv.code);
    if (r.status != 201) return error.NotRedeemed;
    if (!std.mem.eql(u8, try field(r.body, "acts_as"), w.agent)) return error.NotTheAgents;
    const secret = try field(r.body, "secret");
    // Kept for the steps after, whatever this one finds next.
    w.code = inv.code;
    w.key = secret;
    const posted = try send(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), .{ .key = secret }, "hello, by invite");
    if (posted.status != 201 or !has(posted.body, try std.fmt.allocPrint(w.a, "\"by\":\"{s}\"", .{w.agent}))) return error.NotPosted;
    // Spent: no longer listed.
    if (has((try get(w.a, w.port(), "/invites", w.steve)).body, try std.fmt.allocPrint(w.a, "{{\"id\":{s},", .{inv.id}))) return error.SpentListed;
}

fn redeemSecretAlone(w: *World) !void {
    // A human of their own, so no earlier step's caps are in the way.
    const hal = try signUp(w.a, w.port(), 1013);
    const made = try request(w.a, w.port(), "POST", "/agents", hal, "name=LC");
    if (made.status != 201) return error.NotMade;
    const made_inv = try request(w.a, w.port(), "POST", "/invites", hal, try std.fmt.allocPrint(w.a, "as={s}", .{try field(made.body, "id")}));
    if (made_inv.status != 201) return error.NotInvited;
    const inv = .{ .code = try field(made_inv.body, "code") };
    // An unknown format is refused before the code is read, and the invite
    // is still live after it.
    const bad = try send(w.a, w.port(), "POST", "/invites/redeem", .{}, try std.fmt.allocPrint(w.a, "code={s}&format=json", .{inv.code}));
    if (bad.status != 400) return error.UnknownFormatTaken;
    const r = try send(w.a, w.port(), "POST", "/invites/redeem", .{}, try std.fmt.allocPrint(w.a, "code={s}&format=secret", .{inv.code}));
    if (r.status != 201) return error.NotRedeemed;
    // The secret alone, one line: 64 hex digits and a newline.
    if (r.body.len != 65 or r.body[64] != '\n') return error.NotTheSecretAlone;
    for (r.body[0..64]) |c| if (!std.ascii.isHex(c)) return error.NotTheSecretAlone;
    const listed = try send(w.a, w.port(), "GET", "/conversations", .{ .key = r.body[0..64] }, "");
    if (listed.status != 200) return error.SecretDoesNotWork;
}

fn redeemTwice(w: *World) !void {
    if ((try redeem(w, w.code)).status != 401) return error.RedeemedTwice;
    // An unknown code too, and none at all.
    const unknown: [64]u8 = @splat('d');
    if ((try redeem(w, &unknown)).status != 401) return error.UnknownRedeemed;
    if ((try send(w.a, w.port(), "POST", "/invites/redeem", .{}, "")).status != 401) return error.NothingRedeemed;
}

fn inviteExpired(w: *World) !void {
    const form = try std.fmt.allocPrint(w.a, "as={s}", .{w.agent});
    const late = try invite(w, form);
    const soon = try invite(w, form);
    defer w.rig.server.clock_ahead_s_for_test.store(0, .release);
    // Ten minutes and a second later, on the server's clock.
    w.rig.server.clock_ahead_s_for_test.store(601, .release);
    if ((try redeem(w, late.code)).status != 401) return error.ExpiredRedeemed;
    // Two seconds short of ten minutes (a second's tick of slack), live.
    w.rig.server.clock_ahead_s_for_test.store(598, .release);
    if ((try redeem(w, soon.code)).status != 201) return error.LiveRefused;
}

fn othersCannotInvite(w: *World) !void {
    const form = try std.fmt.allocPrint(w.a, "as={s}", .{w.agent});
    if ((try request(w.a, w.port(), "POST", "/invites", w.cal, form)).status != 403) return error.InvitedForAnothersAgent;
    if ((try request(w.a, w.port(), "POST", "/invites", "", form)).status != 401) return error.InvitedSignedOut;
    // Nor see or revoke Steve's.
    const inv = try invite(w, form);
    if (has((try get(w.a, w.port(), "/invites", w.cal)).body, try std.fmt.allocPrint(w.a, "{{\"id\":{s},", .{inv.id}))) return error.ListedToAnother;
    const target = try std.fmt.allocPrint(w.a, "/invites/{s}/revoke", .{inv.id});
    if ((try request(w.a, w.port(), "POST", target, w.cal, "")).status != 404) return error.RevokedByAnother;
    if ((try request(w.a, w.port(), "POST", target, w.steve, "")).status != 200) return error.NotRevoked;
    if ((try redeem(w, inv.code)).status != 401) return error.RevokedRedeemed;
}

fn keyCannotInvite(w: *World) !void {
    const r = try send(w.a, w.port(), "POST", "/invites", .{ .key = w.key }, try std.fmt.allocPrint(w.a, "as={s}", .{w.agent}));
    if (r.status != 403) return error.KeyInvited;
    if (has(r.body, "code")) return error.KeyGotACode;
}

fn mintAsAgentRefused(w: *World) !void {
    const r = try request(w.a, w.port(), "POST", "/keys", w.steve, try std.fmt.allocPrint(w.a, "as={s}", .{w.agent}));
    if (r.status != 403 or !has(r.body, "invite")) return error.MintedForAnAgent;
    // A human's key for themselves is as it was.
    const own = try mint(w, "");
    if (own.secret.len != 64) return error.NotASecret;
}

fn retiredInviteDead(w: *World) !void {
    const inv = try invite(w, try std.fmt.allocPrint(w.a, "as={s}", .{w.agent}));
    try retire(w, w.agent);
    const r = try redeem(w, inv.code);
    if (r.status != 401) return error.RetiredRedeemed;
    if (has(r.body, "secret")) return error.RetiredGotAKey;
}

/// The id of an agent Steve makes, named `name`.
fn madeAgent(w: *World, comptime name: []const u8) ![]const u8 {
    const r = try request(w.a, w.port(), "POST", "/agents", w.steve, "name=" ++ name);
    if (r.status != 201) return error.NotMade;
    return field(r.body, "id");
}

fn agentIdFresh(w: *World) !void {
    const first = try madeAgent(w, "One");
    // The highest agent now, and retired.
    try retire(w, first);
    const second = try madeAgent(w, "Two");
    if (std.mem.eql(u8, first, second)) return error.IdGivenTwice;
    const n1 = try std.fmt.parseInt(u64, first["agent:".len..], 10);
    const n2 = try std.fmt.parseInt(u64, second["agent:".len..], 10);
    if (n2 != n1 + 1) return error.NotTheNextId;
}

fn invitesAudited(w: *World) !void {
    const log = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    const wanted = [_][]const u8{
        "verdict=created:session:",
        "verdict=redeemed:key:",
        "verdict=revoked:session:",
        "verdict=refused:spent",
        "verdict=refused:expired",
        "verdict=refused:revoked",
        "verdict=refused:no-longer-holds",
    };
    for (wanted) |line| if (!has(log, line)) return error.NotAudited;
    if (has(log, w.code)) return error.CodeAudited;
    // A refusal naming no stored invite is anyone's to repeat, and never
    // audited.
    if (has(log, "invite=unknown")) return error.AnonymousAudited;
}

/// **AN ANONYMOUS REFUSAL WRITES NO AUDIT**: junk invite codes, a
/// GitHub callback with no state, and a name with no pending sign-up,
/// each several times, leave the audit file as it was.
fn anonymousUnaudited(w: *World) !void {
    const before = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    const junk: [64]u8 = @splat('e');
    for (0..5) |_| {
        if ((try redeem(w, &junk)).status != 401) return error.JunkRedeemed;
        if ((try redeem(w, "not-hex")).status != 401) return error.JunkRedeemed;
        if ((try get(w.a, w.port(), "/login/github?code=user-id-1&state=forged", "")).status != 403) return error.ForgedStateTaken;
        if ((try request(w.a, w.port(), "POST", "/login/name", "", "name=Mallory")).status != 403) return error.NoPendingTaken;
    }
    const after = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    if (after.len != before.len) return error.AuditGrew;
}

/// **A MESSAGE SAYS ITS POSTER'S KIND, AND AN AGENT'S OWNER**
/// (app/Conversations.roc's message_json): an agent named as a look-alike
/// of its owner (a Cyrillic `е`: its very name is taken, by the one
/// namespace) posts, and its post's answer and the transcript say
/// `"kind":"agent"` and the human it answers to; its owner's post says
/// `"kind":"human"`, with no owner.
fn authorKind(w: *World) !void {
    // A human of their own, so no earlier step's caps are in the way.
    const ivy = try signUp(w.a, w.port(), 1015);
    const made = try request(w.a, w.port(), "POST", "/agents", ivy, "name=P%D0%B5rson+1015");
    if (made.status != 201) return error.NotMade;
    const agent = try field(made.body, "id");
    const made_inv = try request(w.a, w.port(), "POST", "/invites", ivy, try std.fmt.allocPrint(w.a, "as={s}", .{agent}));
    if (made_inv.status != 201) return error.NotInvited;
    const redeemed = try redeem(w, try field(made_inv.body, "code"));
    if (redeemed.status != 201) return error.NotRedeemed;
    const key = try field(redeemed.body, "secret");
    const conv = try startedId(try send(w.a, w.port(), "POST", "/conversations", .{ .key = key }, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1015)}))));
    const path = try agentPath(w, conv, "/messages");
    const said = try std.fmt.allocPrint(w.a, "\"by\":\"{s}\",\"kind\":\"agent\",\"owner\":\"human:{s}\",\"login\":\"person1015\",\"markdown\":\"I am Person 1015\"", .{ agent, try hid(w.a, 1015) });
    const posted = try send(w.a, w.port(), "POST", path, .{ .key = key }, "I am Person 1015");
    if (posted.status != 201 or !has(posted.body, said)) return error.NotSaidAnAgents;
    const owners = try request(w.a, w.port(), "POST", path, ivy, "no, I am");
    if (owners.status != 201 or !has(owners.body, (try std.fmt.allocPrint(w.a, "\"by\":\"human:{s}\",\"kind\":\"human\",\"login\":\"person1015\",\"markdown\":\"no, I am\"", .{try hid(w.a, 1015)})))) return error.NotSaidAHumans;
    const read = try get(w.a, w.port(), try agentPath(w, conv, ""), ivy);
    if (read.status != 200 or !has(read.body, said) or count(read.body, "\"owner\":") != 1) return error.NotInTheTranscript;
}

// ── the channels, an admin's ──

/// The channels page as `cookie` gets it.
fn channelsPage(w: *World, cookie: []const u8) !Response {
    return get(w.a, w.port(), "/chat/channels", cookie);
}

/// **AN ADMIN MAKES A CHANNEL**: Ivy, the rig's first admin, signs up;
/// /chat links her to the channels page, and no member; she makes Lobby
/// with Ann and Bea, and general with no one, and the page lists both, by
/// key, with their members.
fn adminMakesChannel(w: *World) !void {
    w.ivy = try signUp(w.a, w.port(), 1014);
    if (!has((try get(w.a, w.port(), "/chat", w.ivy)).body, "<a href=\"/chat/channels\">")) return error.NoLink;
    if (has((try get(w.a, w.port(), "/chat", w.ann)).body, "/chat/channels")) return error.LinkedForAMember;
    const r = try pagePost(w, w.ivy, "/channels", (try std.fmt.allocPrint(w.a, "name=Lobby&members=human%3A{s}%2Chuman%3A{s}", .{ try hid(w.a, 1001), try hid(w.a, 1002) })));
    if (r.status != 201) return error.NotMade;
    if (!has(r.body, (try std.fmt.allocPrint(w.a, "{{\"name\":\"Lobby\",\"members\":[\"human:{s}\",\"human:{s}\"]}}", .{ try hid(w.a, 1001), try hid(w.a, 1002) })))) return error.NotTheChannel;
    if ((try pagePost(w, w.ivy, "/channels", "name=general&members=")).status != 201) return error.NotMade;
    const page = try channelsPage(w, w.ivy);
    if (page.status != 200) return error.NoPage;
    const lobby = std.mem.indexOf(u8, page.body, "<li data-channel=\"Lobby\">") orelse return error.NotListed;
    const general = std.mem.indexOf(u8, page.body, "<li data-channel=\"general\">") orelse return error.NotListed;
    if (general > lobby) return error.NotSortedByKey;
    if (!has(page.body[lobby..], (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1001)}))) or !has(page.body[lobby..], (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1002)})))) return error.MembersNotListed;
    if (!has(page.body, "data-path=\"/channels/Lobby/admit\"") or !has(page.body, "data-path=\"/channels/Lobby/remove\"")) return error.NoForms;
}

/// **A HUMAN WHO IS NO ADMIN IS REFUSED**: Ann gets a 403 for the page and
/// for each write, a channel that is not there no different; signed out,
/// the page is a 303 to /login and a write a 401; nothing changes.
fn memberRefusedChannels(w: *World) !void {
    const page = try channelsPage(w, w.ann);
    if (page.status != 403 or has(page.body, "Lobby")) return error.PageGiven;
    if ((try pagePost(w, w.ann, "/channels", "name=Annex")).status != 403) return error.MadeByAMember;
    if ((try pagePost(w, w.ann, "/channels/Lobby/admit", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})))).status != 403) return error.AdmittedByAMember;
    if ((try pagePost(w, w.ann, "/channels/Lobby/remove", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1002)})))).status != 403) return error.RemovedByAMember;
    if ((try pagePost(w, w.ann, "/channels/Nowhere/admit", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})))).status != 403) return error.MissingSaid;
    if ((try channelsPage(w, "")).status != 303) return error.SignedOutGivenPage;
    if ((try send(w.a, w.port(), "POST", "/channels", .{}, "name=Annex")).status != 401) return error.MadeSignedOut;
    const listed = (try channelsPage(w, w.ivy)).body;
    if (has(listed, "Annex") or has(listed, (try std.fmt.allocPrint(w.a, "human:{s}", .{try hid(w.a, 1003)}))) or !has(listed, (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1002)})))) return error.Changed;
}

/// **A KEY CHANGES NO CHANNEL**: Ivy's own key, acting as an admin with
/// admin scope, is refused the page (the 403 every page gives a key) and
/// each write (`needs-session`); nothing changes.
fn keyRefusedChannels(w: *World) !void {
    const minted = try request(w.a, w.port(), "POST", "/keys", w.ivy, "admin=on");
    if (minted.status != 201) return error.NotMinted;
    w.ivy_key = try field(minted.body, "secret");
    if ((try send(w.a, w.port(), "GET", "/chat/channels", .{ .key = w.ivy_key }, "")).status != 403) return error.KeyGivenPage;
    const made = try send(w.a, w.port(), "POST", "/channels", .{ .key = w.ivy_key }, "name=Keyed");
    if (made.status != 403 or !has(made.body, "key")) return error.MadeByKey;
    if ((try send(w.a, w.port(), "POST", "/channels/Lobby/admit", .{ .key = w.ivy_key }, (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})))).status != 403) return error.AdmittedByKey;
    if ((try send(w.a, w.port(), "POST", "/channels/Lobby/remove", .{ .key = w.ivy_key }, (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1001)})))).status != 403) return error.RemovedByKey;
    const listed = (try channelsPage(w, w.ivy)).body;
    if (has(listed, "Keyed") or has(listed, (try std.fmt.allocPrint(w.a, "human:{s}", .{try hid(w.a, 1003)}))) or !has(listed, (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1001)})))) return error.Changed;
}

/// **ADMIT AND REMOVE CHANGE WHO IS IN**: Cal let in (the channel named in
/// another spelling), Ann let go, each answered with the channel and shown
/// on the page; one already in, one not in, an agent, an unknown human and
/// a channel that is not there refused, each by name.
fn admitRemove(w: *World) !void {
    const in = try pagePost(w, w.ivy, "/channels/lobby/admit", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})));
    if (in.status != 200 or !has(in.body, (try std.fmt.allocPrint(w.a, "\"human:{s}\"", .{try hid(w.a, 1003)})))) return error.NotAdmitted;
    const out = try pagePost(w, w.ivy, "/channels/Lobby/remove", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1001)})));
    if (out.status != 200 or has(out.body, (try std.fmt.allocPrint(w.a, "human:{s}", .{try hid(w.a, 1001)})))) return error.NotRemoved;
    const listed = (try channelsPage(w, w.ivy)).body;
    if (!has(listed, (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1003)}))) or has(listed, (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1001)})))) return error.PageUnchanged;
    const twice = try pagePost(w, w.ivy, "/channels/Lobby/admit", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})));
    if (twice.status != 409 or !has(twice.body, "already")) return error.AdmittedTwice;
    const gone = try pagePost(w, w.ivy, "/channels/Lobby/remove", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1001)})));
    if (gone.status != 409 or !has(gone.body, "not in")) return error.RemovedTwice;
    const agent = try pagePost(w, w.ivy, "/channels/Lobby/admit", try std.fmt.allocPrint(w.a, "member={s}", .{w.gil_agent}));
    if (agent.status != 400 or !has(agent.body, "no human")) return error.AgentAdmitted;
    const nobody = try pagePost(w, w.ivy, "/channels/Lobby/admit", "member=human%3A999999");
    if (nobody.status != 400 or !has(nobody.body, "no account")) return error.NobodyAdmitted;
    if ((try pagePost(w, w.ivy, "/channels/Nowhere/admit", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})))).status != 404) return error.NowhereChanged;
}

/// **A NAME IS TAKEN IN ANY SPELLING**: Lobby again, as made, in lower and
/// upper case, and general in capitals, each a 409 that says so; a name
/// the rule refuses, a 400; still two channels.
fn takenName(w: *World) !void {
    for ([_][]const u8{ "Lobby", "lobby", "LOBBY", "GENERAL" }) |name| {
        const r = try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name={s}", .{name}));
        if (r.status != 409 or !has(r.body, "there already")) return error.MadeTwice;
    }
    if ((try pagePost(w, w.ivy, "/channels", "name=1st")).status != 400) return error.BadNameTaken;
    if (count((try channelsPage(w, w.ivy)).body, "<li data-channel=") != 2) return error.NotTwo;
}

/// **EVERY CHANNEL CHANGE, AND EVERY REFUSAL OF A NAMED ASKER, IS
/// AUDITED**, with no secret; a signed-out write names no one and is not.
fn channelsAudited(w: *World) !void {
    const log = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    const wanted = [_][]const u8{
        (try std.fmt.allocPrint(w.a, "who=human:{s} via=session:", .{try hid(w.a, 1014)})),
        (try std.fmt.allocPrint(w.a, "action=make channel=Lobby members=human:{s},human:{s} verdict=permitted", .{ try hid(w.a, 1001), try hid(w.a, 1002) })),
        "action=make channel=general members= verdict=permitted",
        (try std.fmt.allocPrint(w.a, "action=admit channel=Lobby members=human:{s} verdict=permitted", .{try hid(w.a, 1003)})),
        (try std.fmt.allocPrint(w.a, "action=remove channel=Lobby members=human:{s} verdict=permitted", .{try hid(w.a, 1001)})),
        (try std.fmt.allocPrint(w.a, "who=human:{s} via=session:", .{try hid(w.a, 1001)})),
        "action=make channel=Annex members= verdict=refused:not-admin",
        (try std.fmt.allocPrint(w.a, "action=admit channel=Nowhere members=human:{s} verdict=refused:not-admin", .{try hid(w.a, 1003)})),
        "via=key:",
        "action=make channel=Keyed members= verdict=refused:needs-session",
        "action=make channel=lobby members= verdict=refused:taken",
        "action=make channel=LOBBY members= verdict=refused:taken",
        "action=make channel= members= verdict=refused:not-a-channel-name",
        (try std.fmt.allocPrint(w.a, "action=admit channel=Lobby members=human:{s} verdict=refused:already-in", .{try hid(w.a, 1003)})),
        (try std.fmt.allocPrint(w.a, "action=remove channel=Lobby members=human:{s} verdict=refused:not-in", .{try hid(w.a, 1001)})),
        "verdict=refused:not-a-human",
        "verdict=refused:no-account",
        (try std.fmt.allocPrint(w.a, "action=admit channel=Nowhere members=human:{s} verdict=refused:no-such-channel", .{try hid(w.a, 1003)})),
    };
    for (wanted) |line| if (!has(log, line)) return error.NotAudited;
    if (count(log, "channel=Annex") != 1) return error.SignedOutAudited;
    if (has(log, w.ivy_key)) return error.SecretAudited;
}

fn loginBeside(w: *World) !void {
    // A human of their own (login person1016), and an agent named as a
    // look-alike of them (a Cyrillic `е`; their very name is taken).
    const una = try signUp(w.a, w.port(), 1016);
    const made = try request(w.a, w.port(), "POST", "/agents", una, "name=P%D0%B5rson+1016");
    if (made.status != 201) return error.NotMade;
    const agent = try field(made.body, "id");
    const made_inv = try request(w.a, w.port(), "POST", "/invites", una, try std.fmt.allocPrint(w.a, "as={s}", .{agent}));
    if (made_inv.status != 201) return error.NotInvited;
    const redeemed = try redeem(w, try field(made_inv.body, "code"));
    if (redeemed.status != 201) return error.NotRedeemed;
    const key = try field(redeemed.body, "secret");
    const conv = try startedId(try send(w.a, w.port(), "POST", "/conversations", .{ .key = key }, (try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1016)}))));
    // The agent's message: its kind, its owner, and its owner's login.
    const said = try std.fmt.allocPrint(w.a, "\"by\":\"{s}\",\"kind\":\"agent\",\"owner\":\"human:{s}\",\"login\":\"person1016\",", .{ agent, try hid(w.a, 1016) });
    const posted = try send(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), .{ .key = key }, "I am Person 1016");
    if (posted.status != 201 or !has(posted.body, said)) return error.NoOwnersLogin;
    // The human's own: their login.
    const theirs = try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), una, "no, I am");
    if (theirs.status != 201 or !has(theirs.body, (try std.fmt.allocPrint(w.a, "\"by\":\"human:{s}\",\"kind\":\"human\",\"login\":\"person1016\",", .{try hid(w.a, 1016)})))) return error.NoOwnLogin;
    // The page: the server's header, and the people list the live script draws from.
    const page = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/{s}", .{conv}), una);
    if (page.status != 200) return error.NoPage;
    const label = "P\xd0\xb5rson 1016 · agent of @person1016";
    if (!has(page.body, "<header>" ++ label ++ " · <time")) return error.NoLabelOnTheMessage;
    if (!has(page.body, "\">" ++ label ++ "</li>")) return error.NoLabelForTheScript;
    if (!has(page.body, "<header>Person 1016 · @person1016 · <time")) return error.NoLoginBesideTheHuman;
}

/// **ONE NAMESPACE: A NAME IS HELD ONCE** (app/DisplayName.roc's
/// `same`, Accounts.name_holder): a second human signing up as a name a
/// human holds, in another case and spacing, gets the form again saying it
/// is taken, and no account; a near miss is signed up.
fn humanNameTaken(w: *World) !void {
    _ = try signUpAs(w.a, w.port(), 1017, "Debbie+Benton");
    const again = try nameFormAnswer(w.a, w.port(), 1018, "debbie++BENTON");
    if (again.status != 400 or !has(again.body, "That name is taken")) return error.NameTakenTwice;
    if (again.cookie("session") != null) return error.SignedInAnyway;
    _ = try signUpAs(w.a, w.port(), 1018, "Debbie+Benton+2");
}

/// The same for an agent: one named as a human (another's, in another
/// case), or as another's agent, is a 409 saying so; a near miss is made.
fn agentNameTaken(w: *World) !void {
    const owner = try signUp(w.a, w.port(), 1019);
    const as_human = try request(w.a, w.port(), "POST", "/agents", owner, "name=DEBBIE+benton");
    if (as_human.status != 409 or !has(as_human.body, "that name is taken")) return error.AgentTookAHumansName;
    if ((try request(w.a, w.port(), "POST", "/agents", owner, "name=Mine+1019")).status != 201) return error.NotMade;
    if ((try request(w.a, w.port(), "POST", "/agents", owner, "name=mine+1019")).status != 409) return error.AgentNameTwice;
    if ((try request(w.a, w.port(), "POST", "/agents", owner, "name=Debbie+Bentons")).status != 201) return error.NearMissRefused;
}

/// **AN AGENT'S OWNER RENAMES IT** (Agents.rename), on /chat/agents: to a
/// free name, and its old name is free for anyone; to a name another
/// holds in another spelling, a 409; to its own in a new spelling, taken;
/// by another human, a 403; by a key, even its owner's, a 403. Each is an
/// `audit-rename` line.
fn agentRenamed(w: *World) !void {
    const owner = try signUp(w.a, w.port(), 1020);
    const other = try signUp(w.a, w.port(), 1021);
    const made = try request(w.a, w.port(), "POST", "/agents", owner, "name=Rhee+1020");
    if (made.status != 201) return error.NotMade;
    const id = try field(made.body, "id");
    if (!std.mem.startsWith(u8, id, "agent:")) return error.NotAnAgent;
    if ((try request(w.a, w.port(), "POST", "/agents", other, "name=Other+1021")).status != 201) return error.NotMade;
    const path = try std.fmt.allocPrint(w.a, "/agents/{s}/rename", .{id["agent:".len..]});

    // The page offers it, beside its invite button.
    const page = try agentsPageOf(w, owner);
    if (!has(page, try std.fmt.allocPrint(w.a, "<form class=rename data-path=\"{s}\">", .{path})) or !has(page, "value=\"Rhee 1020\"")) return error.NoRenameForm;

    const free = try pagePost(w, owner, path, "name=Lee+1020");
    if (free.status != 200 or !has(free.body, try std.fmt.allocPrint(w.a, "\"id\":\"{s}\",\"name\":\"Lee 1020\"", .{id}))) return error.NotRenamed;
    if (!has(try agentsPageOf(w, owner), "<b>Lee 1020</b>")) return error.PageUnchanged;
    // The old name is free again, for anyone's agent.
    if ((try request(w.a, w.port(), "POST", "/agents", other, "name=rhee+1020")).status != 201) return error.OldNameHeld;
    // Another's name in another spelling: refused, the name kept.
    const taken = try pagePost(w, owner, path, "name=OTHER++1021");
    if (taken.status != 409 or !has(taken.body, "that name is taken")) return error.TakenRenamed;
    // Its own name in a new spelling: its own to take.
    const own = try pagePost(w, owner, path, "name=LEE+1020");
    if (own.status != 200 or !has(own.body, "\"name\":\"LEE 1020\"")) return error.OwnSpellingRefused;
    // Not the owner's: refused, the name unchanged.
    const theirs = try pagePost(w, other, path, "name=Mine+1021");
    if (theirs.status != 403 or !has(theirs.body, "only its owner")) return error.RenamedByAnother;
    // By a key, even the owner's own: refused.
    const minted = try request(w.a, w.port(), "POST", "/keys", owner, "");
    if (minted.status != 201) return error.NotMinted;
    const by_key = try send(w.a, w.port(), "POST", path, .{ .key = try field(minted.body, "secret") }, "name=Keyed+1020");
    if (by_key.status != 403 or !has(by_key.body, "owner's own session")) return error.RenamedByKey;
    if (!has(try agentsPageOf(w, owner), "<b>LEE 1020</b>")) return error.NameChangedByARefusal;

    const log = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    for ([_][]const u8{ "verdict=permitted name=Lee 1020\n", "verdict=refused:name-taken name=OTHER  1021\n", "verdict=permitted name=LEE 1020\n", "verdict=refused:not-the-owner name=Mine 1021\n", "verdict=refused:needs-session name=Keyed 1020\n" }) |tail| {
        if (!has(log, try std.fmt.allocPrint(w.a, "agent={s} {s}", .{ id, tail }))) return error.NotAudited;
    }
    if (count(log, "audit-rename v1 ") != 5) return error.AuditedOtherwise;
}

/// The `id:` of the event whose data holds `needle`, in what a stream
/// said (the id line comes before the data, Sse.frame's order).
fn eventId(got: []const u8, needle: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, got, needle) orelse return error.NoSuchEvent;
    const line = std.mem.lastIndexOf(u8, got[0..at], "\nid: ") orelse return error.NoEventId;
    const from = line + "\nid: ".len;
    const to = std.mem.indexOfScalarPos(u8, got, from, '\n') orelse return error.NoEventId;
    return got[from..to];
}

/// An agent of `owner`'s own, named `name`, and its key, by an invite;
/// `form` is the invite's other fields (a scope), or empty.
fn ownAgent(w: *World, owner: []const u8, name: []const u8, form: []const u8) !struct { id: []const u8, key: []const u8, key_id: []const u8 } {
    const made = try request(w.a, w.port(), "POST", "/agents", owner, try std.fmt.allocPrint(w.a, "name={s}", .{name}));
    if (made.status != 201) return error.NotMade;
    const id = try field(made.body, "id");
    const inv = try request(w.a, w.port(), "POST", "/invites", owner, try std.fmt.allocPrint(w.a, "as={s}{s}", .{ id, form }));
    if (inv.status != 201) return error.NotInvited;
    const redeemed = try redeem(w, try field(inv.body, "code"));
    if (redeemed.status != 201) return error.NotRedeemed;
    return .{ .id = id, .key = try field(redeemed.body, "secret"), .key_id = try field(redeemed.body, "id") };
}

/// **ONE STREAM PER AGENT** (`GET /stream`, AgentStream): a post in each
/// of two conversations the agent is in arrives on its one stream, each
/// naming its conversation; one it is not in never does. Closed and
/// resumed with the last event's id, it is sent what came meanwhile in
/// both, and nothing it had. A session, a human's key, and a key that
/// reads only some conversations are refused; signed out, a 401.
fn agentStream(w: *World) !void {
    const owner = try signUp(w.a, w.port(), 1023);
    const pal = try ownAgent(w, owner, "Pal+1023", "");
    const dm = try startedId(try request(w.a, w.port(), "POST", "/conversations", owner, try std.fmt.allocPrint(w.a, "with={s}", .{pal.id})));
    const group = try startedId(try request(w.a, w.port(), "POST", "/conversations", owner, try std.fmt.allocPrint(w.a, "with={s}%2Chuman%3A{s}", .{ pal.id, try hid(w.a, 1001) })));
    const apart = try startedId(try request(w.a, w.port(), "POST", "/conversations", owner, try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1001)})));
    const in_dm = try std.fmt.allocPrint(w.a, "\"conversation\":{s},\"id\":", .{dm});
    const in_group = try std.fmt.allocPrint(w.a, "\"conversation\":{s},\"id\":", .{group});

    const l = try Listener.openAs(w.a, w.port(), "/stream", .{ .key = pal.key }, "");
    // Live only, with no Last-Event-ID: nothing before it.
    for ([_]struct { conv: []const u8, text: []const u8 }{
        .{ .conv = dm, .text = "dm one" },
        .{ .conv = apart, .text = "apart one" },
        .{ .conv = group, .text = "group one" },
        .{ .conv = dm, .text = "dm two" },
    }) |p| {
        if ((try request(w.a, w.port(), "POST", try agentPath(w, p.conv, "/messages"), owner, p.text)).status != 201) return error.NotPosted;
    }
    try l.until("\"markdown\":\"dm two\"");
    if (!has(l.got.items, try std.fmt.allocPrint(w.a, "{s}1,", .{in_dm})) or !has(l.got.items, try std.fmt.allocPrint(w.a, "{s}2,", .{in_dm}))) return error.DmNotNamed;
    if (!has(l.got.items, try std.fmt.allocPrint(w.a, "{s}1,", .{in_group}))) return error.GroupNotNamed;
    if (has(l.got.items, "apart one")) return error.NotItsConversation;
    if (count(l.got.items, "event: message\n") != 3) return error.NotEachOnce;
    const last = try eventId(l.got.items, "\"markdown\":\"dm two\"");
    if (!std.mem.endsWith(u8, last, try std.fmt.allocPrint(w.a, ".{s}.2", .{dm}))) return error.NotAPlace;
    l.close();

    // Away: two more, and one it is not in; resumed, both, and nothing twice.
    if ((try request(w.a, w.port(), "POST", try agentPath(w, group, "/messages"), owner, "group two")).status != 201) return error.NotPosted;
    if ((try request(w.a, w.port(), "POST", try agentPath(w, apart, "/messages"), owner, "apart two")).status != 201) return error.NotPosted;
    if ((try request(w.a, w.port(), "POST", try agentPath(w, dm, "/messages"), owner, "dm three")).status != 201) return error.NotPosted;
    const back = try Listener.openAs(w.a, w.port(), "/stream", .{ .key = pal.key }, last);
    defer back.close();
    try back.until("\"markdown\":\"dm three\"");
    try back.until("\"markdown\":\"group two\"");
    if (has(back.got.items, "\"markdown\":\"dm two\"") or has(back.got.items, "\"markdown\":\"dm one\"")) return error.SentTwice;
    if (has(back.got.items, "apart")) return error.NotItsConversation;

    // Refused: a session, a human's own key, a key that reads one
    // conversation only; signed out, a 401.
    if ((try get(w.a, w.port(), "/stream", owner)).status != 403) return error.SessionStreamed;
    const human_key = try request(w.a, w.port(), "POST", "/keys", owner, "");
    if ((try send(w.a, w.port(), "GET", "/stream", .{ .key = try field(human_key.body, "secret") }, "")).status != 403) return error.HumanKeyStreamed;
    const narrow = try ownAgent(w, owner, "Scoped+1023", try std.fmt.allocPrint(w.a, "&read=only%3A{s}", .{dm}));
    if ((try send(w.a, w.port(), "GET", "/stream", .{ .key = narrow.key }, "")).status != 403) return error.ScopedKeyStreamed;
    if ((try get(w.a, w.port(), "/stream", "")).status != 401) return error.NobodyStreamed;
}

/// **THE ONE STREAM IS ONE OF THE AGENT'S STREAMS**, under the host's cap of
/// eight a holder: the agent holds it and eight of a conversation's, and
/// its oldest, the one stream, is ended. And it ends at its lifetime, so a
/// key revoked while it is open stops reaching it; resumed, a 401.
fn agentStreamHeld(w: *World) !void {
    const owner = try signUp(w.a, w.port(), 1024);
    const pal = try ownAgent(w, owner, "Pal+1024", "");
    const dm = try startedId(try request(w.a, w.port(), "POST", "/conversations", owner, try std.fmt.allocPrint(w.a, "with={s}", .{pal.id})));
    const one = try Listener.openAs(w.a, w.port(), "/stream", .{ .key = pal.key }, "");
    defer one.close();
    var held: [streams_per_holder]*Listener = undefined;
    var opened: usize = 0;
    defer for (held[0..opened]) |h| h.close();
    while (opened < held.len) : (opened += 1) held[opened] = try Listener.openAs(w.a, w.port(), try agentPath(w, dm, "/stream"), .{ .key = pal.key }, "");
    if ((try request(w.a, w.port(), "POST", try agentPath(w, dm, "/messages"), owner, "to the held")).status != 201) return error.NotPosted;
    try held[streams_per_holder - 1].until("to the held");
    if (has(one.got.items, "to the held") or !one.ends()) return error.OneStreamKept;

    w.rig.server.stream_lifetime_ms_for_test.store(lifetime_ms_for_test, .release);
    defer w.rig.server.stream_lifetime_ms_for_test.store(0, .release);
    for (held[0..opened]) |h| h.close();
    opened = 0;
    const t0 = Io.Clock.now(.awake, io);
    const live = try Listener.openAs(w.a, w.port(), "/stream", .{ .key = pal.key }, "");
    defer live.close();
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "/keys/{s}/revoke", .{pal.key_id}), owner, "")).status != 200) return error.NotRevoked;
    if (!live.ends()) return error.StreamOutlived;
    if (t0.untilNow(io, .awake).toMilliseconds() < lifetime_ms_for_test) return error.EndedEarly;
    if ((try send(w.a, w.port(), "GET", "/stream", .{ .key = pal.key }, "")).status != 401) return error.RevokedKeyStreamed;
}

const Step = struct { name: []const u8, f: *const fn (*World) anyerror!void };

const steps = [_]Step{
    .{ .name = "A and B sign in (and C, the third user)", .f = signIn },
    .{ .name = "A starts a conversation with B, named by her own id (by her GitHub id, refused)", .f = start },
    .{ .name = "B opens its stream", .f = openStream },
    .{ .name = "A posts a message of many lines", .f = post },
    .{ .name = "B's stream gets the message exactly once", .f = streamOnce },
    .{ .name = "A reads the transcript and sees it, its markdown exactly as posted", .f = readBack },
    .{ .name = "B reconnects with Last-Event-ID and gets nothing twice", .f = reconnect },
    .{ .name = "a forged session cookie is refused", .f = forgedCookie },
    .{ .name = "a third user cannot post to it", .f = thirdPosts },
    .{ .name = "a third user cannot read it, nor stream it", .f = thirdReads },
    .{ .name = "a post between a stream's backlog read and its subscribe arrives once", .f = betweenOnce },
    .{ .name = "Steve makes an agent", .f = makeAgent },
    .{ .name = "Steve gets it a key, by an invite (and C cannot invite for it)", .f = inviteForAgent },
    .{ .name = "the agent, by key alone, starts a conversation with Steve and posts; Steve's stream gets it once", .f = agentStarts },
    .{ .name = "Steve posts, and the agent reads it with its key", .f = agentReads },
    .{ .name = "each message names the participants its markdown mentions, as words, by their names now, and not in what it quotes", .f = mentions },
    .{ .name = "an agent's sixteenth post answering agents within the hour is a 429, audited, its own alone counted; an hour-old one no longer counts, and a human's post resets them", .f = agentHops },
    .{ .name = "the agent's key cannot mint a key, nor make an agent", .f = keyCannotMint },
    .{ .name = "Steve revokes the key, and its next use is a 401", .f = revoke },
    .{ .name = "an expired key is a 401", .f = expired },
    .{ .name = "a key read-scoped to one conversation cannot post there, nor read another", .f = scoped },
    .{ .name = "a session cookie and a Bearer key together are a 400", .f = bothCredentials },
    .{ .name = "every key refused in use, and every grant refused, is audited, with no secret", .f = audited },
    .{ .name = "Steve invites his agent; with a cookie the code is refused; alone, the agent redeems it and posts with the key", .f = inviteRedeemPost },
    .{ .name = "redeeming the same code again is a 401", .f = redeemTwice },
    .{ .name = "an invite past its ten minutes is a 401", .f = inviteExpired },
    .{ .name = "another human's session cannot invite for Steve's agent, nor see or revoke his invite", .f = othersCannotInvite },
    .{ .name = "a key cannot make an invite", .f = keyCannotInvite },
    .{ .name = "a mint acting as an agent is refused; Steve's own key is minted", .f = mintAsAgentRefused },
    .{ .name = "after the agent is retired, its invite redeems to nothing", .f = retiredInviteDead },
    .{ .name = "agent ids: make, retire the highest, make, and the id is fresh", .f = agentIdFresh },
    .{ .name = "every invite made, redeemed, revoked and refused is audited, with no code", .f = invitesAudited },
    .{ .name = "the list page shows a conversation the viewer is in, and not one they aren't", .f = listPage },
    .{ .name = "a participant's name is written escaped", .f = namesEscaped },
    .{ .name = "the conversation page is a 200 to a participant, a 404 to a third user; a page is a 403 to a key", .f = conversationPage },
    .{ .name = "signed out, a page redirects to /login", .f = signedOutPage },
    .{ .name = "a message's HTML on the page is exactly step 6's for it", .f = pageHtml },
    .{ .name = "a human's twenty-first agent is refused", .f = agentsCapped },
    .{ .name = "C cannot name Steve's agent in a new conversation, nor an unknown id, in the same words; Steve can", .f = othersAgentUnnamed },
    .{ .name = "a POST with a cookie from another origin, or from none, is a 403", .f = crossOrigin },
    .{ .name = "a logout from another origin is refused; from our own, the old cookie is a 401", .f = logout },
    .{ .name = "a stream ends at its lifetime, so a key revoked while it is open stops reaching it", .f = streamLifetime },
    .{ .name = "junk invite codes, a forged state and no pending sign-up leave the audit as it was", .f = anonymousUnaudited },
    .{ .name = "A opening nine streams ends A's own first, and B's stays", .f = streamsPerHolder },
    .{ .name = "a post learns its id from the tally, never reading the transcript whole", .f = postByTally },
    .{ .name = "a post to a full transcript is a 413, and nothing is appended", .f = transcriptFull },
    .{ .name = "a read is the newest page, and before= pages back to the first; the page shows the newest", .f = pagesBack },
    .{ .name = "a stream's backlog is at most the newest page, a gap before it said", .f = streamGap },
    .{ .name = "a page and a backlog are read from their first message's offset, never the transcript whole", .f = readFromOffset },
    .{ .name = "a missing offsets file is read past, and the next post writes it whole", .f = offsetsRebuilt },
    .{ .name = "a human past the conversations cap is refused, by name", .f = conversationsCapped },
    .{ .name = "a human past the keys cap is refused, by name", .f = keysCapped },
    .{ .name = "a human past the invites cap is refused, by name", .f = invitesCapped },
    .{ .name = "a missing index is rebuilt from the full scan, and the listings are whole", .f = indexRebuilt },
    .{ .name = "a listing reads its own index alone: another's broken conversation is never read", .f = ownIndexOnly },
    .{ .name = "a message's media loads only from the chat's uploads", .f = mediaFromUploads },
    .{ .name = "the agents page lists the viewer's agents, and no one else's", .f = agentsPageOwn },
    .{ .name = "an agent made as the agents page's form does is listed there", .f = agentMadeFromPage },
    .{ .name = "an invite's code is in its answer alone; the page lists the invite, never a code", .f = inviteFromPage },
    .{ .name = "a key and an invite revoked from the page are gone from it", .f = revokeFromPage },
    .{ .name = "another human sees none of it on their page, and revokes none of it", .f = othersSeeNoneOnPage },
    .{ .name = "a key asking for the agents page is a 403", .f = agentsPageRefusesKey },
    .{ .name = "the start form offers the viewer's own agents to tick, no one else's", .f = startPicksAgents },
    .{ .name = "an invite redeemed with format=secret answers the secret alone, and it works; an unknown format spends nothing", .f = redeemSecretAlone },
    .{ .name = "an agent's post says its kind and its owner, though it took a look-alike of its owner's name; a human's says no owner", .f = authorKind },
    .{ .name = "an admin makes channels, linked from /chat for her alone; the channels page lists them by key, with their members", .f = adminMakesChannel },
    .{ .name = "a human who is no admin is refused the channels page and each channel write; signed out, a 303 and a 401", .f = memberRefusedChannels },
    .{ .name = "a key, even an admin's own with admin scope, is refused the channels page and each channel write", .f = keyRefusedChannels },
    .{ .name = "admit and remove change a channel's members; one already in, one not in, an agent, no account and no channel refused by name", .f = admitRemove },
    .{ .name = "a channel's name is taken in any spelling", .f = takenName },
    .{ .name = "every channel change, and every refusal of a named asker, is audited, with no secret", .f = channelsAudited },
    .{ .name = "an agent named as a look-alike of its owner comes with its owner's login, and the page labels it so, in both renderers", .f = loginBeside },
    .{ .name = "a human signing up as a name another holds, in any case and spacing, is refused; a near miss is signed up", .f = humanNameTaken },
    .{ .name = "an agent named as a human, or as another agent, in any case, is a 409; a near miss is made", .f = agentNameTaken },
    .{ .name = "a human's post in a DM with one agent names the agent, a quote too; the agent's own names nobody; with a second human or agent, nobody", .f = dmNamesTheAgent },
    .{ .name = "one stream per agent: each of its conversations' posts, naming the conversation, never another's; resumed with Last-Event-ID, what came meanwhile and nothing twice; a session, a human's key and a scoped key refused", .f = agentStream },
    .{ .name = "the one stream is one of the agent's streams under the cap, and ends at its lifetime once its key is revoked", .f = agentStreamHeld },
    .{ .name = "an agent's owner renames it: a free name, its old name freed; another's in another spelling, a 409; its own in a new spelling, taken; another human or a key, a 403; each audited", .f = agentRenamed },
};

/// Every step, in order, each timed and said; true when all passed. With
/// `hold` (`zig build e2e -- --hold`, for tools/browser_check.js), the
/// server stays up after the steps, its port and A's and B's session
/// cookies said, until the process is stopped.
pub fn run(a: std.mem.Allocator, hold: bool) !bool {
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
    if (hold) {
        std.debug.print("HOLD port={d} conv={s} ann={s} bea={s} hal={s}\n", .{ w.port(), w.conv, w.ann, w.bea, w.hal });
        while (true) sleepMs(1000);
    }
    if (passed == steps.len) {
        std.debug.print("e2e: {d} of {d} passed\n", .{ passed, steps.len });
        return true;
    }
    std.debug.print("e2e: FAILED ({d} of {d} passed)\n", .{ passed, steps.len });
    return false;
}
