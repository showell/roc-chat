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
/// empty; and its body's type, when not empty (an upload's form).
const Credential = struct { cookie: []const u8 = "", key: []const u8 = "", origin: []const u8 = own_origin, content_type: []const u8 = "" };

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
    const type_line = if (credential.content_type.len > 0) try std.fmt.allocPrint(a, "content-type: {s}\r\n", .{credential.content_type}) else "";
    const text = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nhost: chat.test\r\nconnection: close\r\n{s}{s}{s}{s}content-length: {d}\r\n\r\n{s}", .{ method, target, cookie_line, key_line, origin_line, type_line, body.len, body });
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
var human_ids: [128]u64 = @splat(0);

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

/// GitHub user `n`, already signed up, signs in again from a browser that
/// holds `held` (its session cookie, or nothing): /login, then GitHub's
/// callback. A returning user's answer: a 303 with a new session.
fn signInAgain(a: std.mem.Allocator, port: u16, n: u64, held: []const u8) !Response {
    const login = try get(a, port, "/login", held);
    if (login.status != 303) return error.LoginNotARedirect;
    const location = login.header("location") orelse return error.NoLocation;
    const at = std.mem.indexOf(u8, location, "&state=") orelse return error.NoState;
    const state = try std.fmt.allocPrint(a, "__Host-state={s}", .{login.cookie("state") orelse return error.NoStateCookie});
    const cookies = if (held.len == 0) state else try std.fmt.allocPrint(a, "{s}; {s}", .{ held, state });
    return get(a, port, try std.fmt.allocPrint(a, "/login/github?code=user-id-{d}&state={s}", .{ n, location[at + "&state=".len ..] }), cookies);
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

/// What the steps share: the rig, the three sessions, and Ann and Bea's
/// topic, `Talk/general` (its path, `/channels/Talk/topics/general`).
const World = struct {
    a: std.mem.Allocator,
    rig: *Rig,
    ann: []const u8 = "",
    bea: []const u8 = "",
    cal: []const u8 = "",
    topic: []const u8 = "",
    bea_stream: ?*Listener = null,
    /// Steve, his agent (`agent:N`), its key's public id and secret, and
    /// the topic the agent made in their channel, `Den/work`.
    steve: []const u8 = "",
    agent: []const u8 = "",
    key_id: []const u8 = "",
    key: []const u8 = "",
    agents_topic: []const u8 = "",
    /// The code of the invite step 22 redeemed.
    code: []const u8 = "",
    /// The topic of more than a page (step 45 on).
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
        return std.fmt.allocPrint(w.a, "{s}" ++ tail, .{w.topic});
    }

    fn postAs(w: *const World, cookie: []const u8, body: []const u8) !Response {
        return request(w.a, w.port(), "POST", try w.path("/messages"), cookie, body);
    }

    /// The transcript's messages, as A reads them.
    fn messages(w: *const World) !usize {
        const r = try get(w.a, w.port(), try w.path(""), w.ann);
        if (r.status != 200) return error.TranscriptUnread;
        return count(r.body, "{\"ref\":");
    }
};

/// Ann, Bea and Cal sign in, and Ivy, the rig's first admin, who makes the
/// channels the steps talk in.
fn signIn(w: *World) !void {
    w.ann = try signUp(w.a, w.port(), 1001);
    w.bea = try signUpAs(w.a, w.port(), 1002, bea_name_form);
    w.cal = try signUp(w.a, w.port(), 1003);
    w.ivy = try signUp(w.a, w.port(), 1014);
}

/// **A TOPIC TO TALK IN** (every conversation is a topic): Ivy makes the
/// channel `name` with `members` (ids, `human:N` or `agent:N`), and
/// `maker`, a member's cookie, makes its topic `talk`; its path.
fn topicOf(w: *World, name: []const u8, members: []const []const u8, maker: []const u8) ![]const u8 {
    var form: std.ArrayList(u8) = .empty;
    try form.appendSlice(w.a, try std.fmt.allocPrint(w.a, "name={s}&members=", .{name}));
    for (members, 0..) |m, i| {
        if (i > 0) try form.appendSlice(w.a, "%2C");
        try form.appendSlice(w.a, m);
    }
    if ((try pagePost(w, w.ivy, "/channels", form.items)).status != 201) return error.ChannelNotMade;
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "/channels/{s}/topics", .{name}), maker, "name=talk")).status != 201) return error.TopicNotMade;
    return std.fmt.allocPrint(w.a, "/channels/{s}/topics/talk", .{name});
}

/// The data root's file `file` (`transcript`, `tally`, `offsets`) of the
/// topic at `path`, `/channels/<name>/topics/<topic>`, by its keys.
fn topicFile(w: *World, path: []const u8, file: []const u8) ![]const u8 {
    const lower = try std.ascii.allocLowerString(w.a, path["/channels/".len..]);
    return std.fmt.allocPrint(w.a, "chat/channels/{s}/{s}", .{ lower, file });
}

/// Ann and Bea's topic, `Talk/general`, made by Ann.
fn start(w: *World) !void {
    if ((try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name=Talk&members=human%3A{s}%2Chuman%3A{s}", .{ try hid(w.a, 1001), try hid(w.a, 1002) }))).status != 201) return error.ChannelNotMade;
    const r = try request(w.a, w.port(), "POST", "/channels/Talk/topics", w.ann, "name=general");
    if (r.status != 201) return error.NotStarted;
    w.topic = "/channels/Talk/topics/general";
}

fn openStream(w: *World) !void {
    w.bea_stream = try Listener.open(w.a, w.port(), try w.path("/stream"), w.bea, "");
    // A new topic has no backlog.
    if (w.bea_stream.?.got.items.len != 0) return error.BacklogNotEmpty;
}

fn post(w: *World) !void {
    const r = try w.postAs(w.ann, first_body);
    if (r.status != 201) return error.NotPosted;
    if (!std.mem.startsWith(u8, r.body, "{\"ref\":\"MSG_Talk.general_1\",\"id\":1,")) return error.NotTheFirst;
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
    const conv = try topicOf(w, "Life", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1004)}), try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1001)}) }, w.steve);
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
/// stream of the topic; A opens nine, and the ninth ends A's own
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
/// transcript whole: a topic's transcript is made unreadable whole
/// (its one line junk, its size the same), so a read is a 500, and the
/// next post still answers id 2.
fn postByTally(w: *World) !void {
    const conv = try topicOf(w, "Tally", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1001)}), try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1002)}) }, w.ann);
    if ((try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), w.ann, "one")).status != 201) return error.NotPosted;
    const path = try topicFile(w, conv, "transcript");
    const was = try w.rig.data.readFileAlloc(io, path, w.a, .limited(1024 * 1024));
    const junk = try w.a.alloc(u8, was.len);
    @memset(junk, 'x');
    try overwrite(w, path, junk);
    if ((try get(w.a, w.port(), try agentPath(w, conv, ""), w.ann)).status != 500) return error.TranscriptStillReads;
    const r = try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), w.ann, "two");
    if (r.status != 201) return error.PostReadTheTranscript;
    if (!std.mem.startsWith(u8, r.body, "{\"ref\":\"MSG_Tally.talk_2\",\"id\":2,")) return error.NotTheSecond;
}

/// **A FULL TRANSCRIPT REFUSES A POST** (Limits.transcript_bytes_most):
/// a topic's transcript and tally made so A's post of `x` would end
/// one byte past the cap, and it is a 413 that says so, its transcript
/// unchanged; made so it ends one byte short of the cap, and exactly at
/// it, and the post is taken.
const transcript_bytes_most = 4_000_000;
fn transcriptFull(w: *World) !void {
    // A's post of `x`, its transcript line, the first of a tally of none:
    // `at` is the server's clock in seconds, ten digits until 2286.
    const x_line_len = (try std.fmt.allocPrint(w.a, "message v1 id=1 at=1761600000 by=human:{s} body=x\n", .{try hid(w.a, 1001)})).len;
    const conv = try topicOf(w, "Full", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1001)}), try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1002)}) }, w.ann);
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

/// The topic at `conv`: its transcript made `n` bytes of junk, its tally
/// `n` bytes of no message, and its offsets file gone (as a tally of none
/// has none).
fn fillTranscript(w: *World, conv: []const u8, n: usize) !void {
    const junk = try w.a.alloc(u8, n);
    @memset(junk, 'x');
    try overwrite(w, try topicFile(w, conv, "transcript"), junk);
    try overwrite(w, try topicFile(w, conv, "tally"), try std.fmt.allocPrint(w.a, "0 {d}\n", .{n}));
    w.rig.data.deleteFile(io, try topicFile(w, conv, "offsets")) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

fn transcriptLen(w: *World, conv: []const u8) !usize {
    const bytes = try w.rig.data.readFileAlloc(io, try topicFile(w, conv, "transcript"), w.a, .limited(8 * 1024 * 1024));
    return bytes.len;
}

/// **A READ IS A PAGE** (Limits.page_messages): A posts a page and
/// five more; a read answers the newest page, ids 6 to 105, and `earlier`;
/// `before=6` answers 1 to 5, and no earlier; a `before` that is no id is
/// a 400. The topic's page shows the same newest page, and the
/// button that loads the one before.
const page_messages = 100;
const paged_posts = page_messages + 5;

fn pagesBack(w: *World) !void {
    const conv = try topicOf(w, "Paged", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1001)}), try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1002)}) }, w.ann);
    w.paged = conv;
    const posts = try agentPath(w, conv, "/messages");
    for (1..paged_posts + 1) |n| {
        if ((try request(w.a, w.port(), "POST", posts, w.ann, try std.fmt.allocPrint(w.a, "paged {d}", .{n}))).status != 201) return error.NotPosted;
    }
    try holdsPage(w, try pageOf(w, conv, ""), 6, paged_posts, true);
    try holdsPage(w, try pageOf(w, conv, "6"), 1, 5, false);
    for ([_][]const u8{ "0", "x", "06", "6&before=7" }) |bad| {
        const r = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "{s}?before={s}", .{ conv, bad }), w.ann);
        if (r.status != 400) return error.BadBeforeTaken;
    }
    const page = try get(w.a, w.port(), "/chat/channel/Paged/talk", w.ann);
    if (page.status != 200) return error.NoPage;
    if (!has(page.body, "<div class=chat-msg id=msg-6 ") or has(page.body, "<div class=chat-msg id=msg-5 ")) return error.PageNotNewest;
    if (!has(page.body, "<button id=earlier type=button>")) return error.NoEarlierButton;
}

/// A read of the topic at `conv`, `before` it when not empty.
fn pageOf(w: *World, conv: []const u8, before: []const u8) ![]const u8 {
    const target = if (before.len == 0)
        try agentPath(w, conv, "")
    else
        try std.fmt.allocPrint(w.a, "{s}?before={s}", .{ conv, before });
    const r = try get(w.a, w.port(), target, w.ann);
    if (r.status != 200) return error.NotRead;
    return r.body;
}

/// Whether `body` holds exactly the messages `first` to `last`, and says
/// `earlier` as given.
fn holdsPage(w: *World, body: []const u8, first: usize, last: usize, earlier: bool) !void {
    if (count(body, "{\"ref\":") != last - first + 1) return error.NotAPage;
    if (!has(body, try std.fmt.allocPrint(w.a, "\"id\":{d},", .{first}))) return error.NoFirst;
    if (!has(body, try std.fmt.allocPrint(w.a, "\"id\":{d},", .{last}))) return error.NoLast;
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
    const path = try topicFile(w, w.paged, "transcript");
    const was = try w.rig.data.readFileAlloc(io, path, w.a, .limited(8 * 1024 * 1024));
    const end = std.mem.indexOfScalar(u8, was, '\n') orelse return error.NoLine;
    @memset(was[0..end], 'x');
    try overwrite(w, path, was);
    try holdsPage(w, try pageOf(w, w.paged, ""), 6, paged_posts, true);
    const l = try Listener.open(w.a, w.port(), try agentPath(w, w.paged, "/stream"), w.bea, "103");
    defer l.close();
    try l.until("\"markdown\":\"paged 105\"");
    const first = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "{s}?before=6", .{w.paged}), w.ann);
    if (first.status != 500) return error.JunkRead;
}

/// **AN OFFSETS FILE IS WRITTEN AGAIN WHEN IT IS WRONG**: a topic's
/// offsets removed (a transcript from before them), its read still right
/// (the transcript read whole), and the next post writes a record for
/// every message.
const offset_width = 11;

fn offsetsRebuilt(w: *World) !void {
    const conv = try topicOf(w, "Offsets", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1001)}), try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1002)}) }, w.ann);
    const posts = try agentPath(w, conv, "/messages");
    for (0..3) |_| if ((try request(w.a, w.port(), "POST", posts, w.ann, "before")).status != 201) return error.NotPosted;
    const path = try topicFile(w, conv, "offsets");
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

fn keysCapped(w: *World) !void {
    w.fay = try signUp(w.a, w.port(), 1010);
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

/// **A MESSAGE'S MEDIA LOADS ONLY FROM THE CHAT'S UPLOADS**: the chat tells
/// the renderer its uploads are under a topic's page (`.../uploads/<name>`,
/// Render.markdown), so an upload's image renders, and one of the chat's
/// other routes as a src, or an old uploads path, is text.
fn mediaFromUploads(w: *World) !void {
    const conv = try topicOf(w, "Media", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1001)}), try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1002)}) }, w.ann);
    const r = try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), w.ann, "<img src=\"/chat/channel/Media/talk/uploads/00000000000000000000000000000000.png\">\n\n<img src=\"/channels/Media/topics/talk/stream\">\n\n<img src=\"/user_uploads/a.png\">");
    if (r.status != 201) return error.NotPosted;
    if (!has(r.body, "<img src=\\\"/chat/channel/Media/talk/uploads/00000000000000000000000000000000.png\\\">")) return error.UploadNotShown;
    if (!has(r.body, "&lt;img src=&quot;/user_uploads/a.png&quot;&gt;")) return error.OldUploadsShownAsMedia;
    if (!has(r.body, "&lt;img src=&quot;/channels/Media/topics/talk/stream&quot;&gt;")) return error.RouteShownAsMedia;
}

fn pageHtml(w: *World) !void {
    const t = try get(w.a, w.port(), try w.path(""), w.ann);
    const key = "\"id\":1,";
    const at = std.mem.indexOf(u8, t.body, key) orelse return error.NoFirstMessage;
    const html_key = "\"html\":\"";
    const from = (std.mem.indexOfPos(u8, t.body, at, html_key) orelse return error.NoHtml) + html_key.len;
    const to = std.mem.indexOfPos(u8, t.body, from, "\"}") orelse return error.NoHtmlEnd;
    const html = try unjson(w.a, t.body[from..to]);
    const page = try get(w.a, w.port(), "/chat/channel/Talk/general", w.ann);
    if (page.status != 200) return error.NoPage;
    if (!has(page.body, try std.fmt.allocPrint(w.a, "<div class=chat-body>{s}</div>", .{html}))) return error.HtmlDiffers;
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
    // Step 28 retired Steve's first agent: a fresh one.
    if ((try request(w.a, w.port(), "POST", "/agents", w.steve, "name=Own")).status != 201) return error.NotMade;
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

/// A topic's route: its path, then `tail`.
fn agentPath(w: *const World, topic: []const u8, comptime tail: []const u8) ![]const u8 {
    return std.fmt.allocPrint(w.a, "{s}" ++ tail, .{topic});
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

/// The agent, a member of Den with Steve, makes its topic `work` by key
/// and posts; Steve's stream of it gets the post once.
fn agentStarts(w: *World) !void {
    if ((try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name=Den&members=human%3A{s}%2C{s}", .{ try hid(w.a, 1004), w.agent }))).status != 201) return error.ChannelNotMade;
    if ((try send(w.a, w.port(), "POST", "/channels/Den/topics", .{ .key = w.key }, "name=work")).status != 201) return error.TopicNotMade;
    w.agents_topic = "/channels/Den/topics/work";
    const l = try Listener.open(w.a, w.port(), try agentPath(w, w.agents_topic, "/stream"), w.steve, "");
    defer l.close();
    const posted = try send(w.a, w.port(), "POST", try agentPath(w, w.agents_topic, "/messages"), .{ .key = w.key }, "hello from **CC**");
    if (posted.status != 201) return error.NotPosted;
    if (!has(posted.body, try std.fmt.allocPrint(w.a, "\"by\":\"{s}\"", .{w.agent}))) return error.NotByTheAgent;
    try l.until("\n\n");
    sleepMs(100);
    if (count(l.got.items, "event: message\nid: 1\n") != 1) return error.NotOnce;
    if (!has(l.got.items, "hello from **CC**")) return error.NotTheMessage;
}

fn agentReads(w: *World) !void {
    if ((try request(w.a, w.port(), "POST", try agentPath(w, w.agents_topic, "/messages"), w.steve, "hi CC, it's Steve")).status != 201) return error.NotPosted;
    const r = try send(w.a, w.port(), "GET", try agentPath(w, w.agents_topic, ""), .{ .key = w.key }, "");
    if (r.status != 200) return error.NotRead;
    if (!has(r.body, (try std.fmt.allocPrint(w.a, "\"by\":\"human:{s}\",\"kind\":\"human\",\"login\":\"person1004\",\"markdown\":\"hi CC, it's Steve\"", .{try hid(w.a, 1004)})))) return error.NotSeen;
}

/// **MENTIONS, AS THE SERVER PARSES THEM** (app/Mentions.roc): each
/// message carries the participants its markdown names as a word, by their
/// names now, in the post's answer, the transcript and the stream alike.
fn mentions(w: *World) !void {
    // Steve, his agent and Ann, a channel's members: a post names whom its
    // words name, and no one else.
    const group = try topicOf(w, "Trio", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1004)}), w.agent, try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1001)}) }, w.steve);
    const path = try agentPath(w, group, "/messages");
    const l = try Listener.open(w.a, w.port(), try agentPath(w, group, "/stream"), w.steve, "");
    defer l.close();
    const named = try std.fmt.allocPrint(w.a, "\"mentions\":[\"{s}\"]", .{w.agent});
    const to_cc = try request(w.a, w.port(), "POST", path, w.steve, "@CC, a mention");
    if (to_cc.status != 201 or !has(to_cc.body, named)) return error.NotNamed;
    // A name that goes on, and an `@` inside a word, name nobody.
    const near = try request(w.a, w.port(), "POST", path, w.steve, "see @CCX, and mail a@CC.com");
    if (near.status != 201 or !has(near.body, "\"mentions\":[]")) return error.NamedByAPart;
    // A name no member goes by is text.
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
    if ((try send(w.a, w.port(), "GET", try agentPath(w, w.agents_topic, ""), .{ .key = w.key }, "")).status != 200) return error.NotLiveBefore;
    const r = try request(w.a, w.port(), "POST", target, w.steve, "");
    if (r.status != 200 or !has(r.body, "\"revoked\":true")) return error.NotRevoked;
    if ((try send(w.a, w.port(), "GET", try agentPath(w, w.agents_topic, ""), .{ .key = w.key }, "")).status != 401) return error.RevokedKeyWorks;
    if ((try send(w.a, w.port(), "POST", try agentPath(w, w.agents_topic, "/messages"), .{ .key = w.key }, "still here")).status != 401) return error.RevokedKeyPosts;
}

fn expired(w: *World) !void {
    const k = try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}&lifetime=1", .{w.agent}));
    // Past its one second, on the host's clock of whole seconds.
    sleepMs(2100);
    if ((try send(w.a, w.port(), "GET", try agentPath(w, w.agents_topic, ""), .{ .key = k.secret }, "")).status != 401) return error.ExpiredKeyWorks;
}

fn bothCredentials(w: *World) !void {
    // A live key of the agent's: step 19 revoked its first.
    const k = try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}", .{w.agent}));
    w.key = k.secret;
    const target = try agentPath(w, w.agents_topic, "");
    if ((try send(w.a, w.port(), "GET", target, .{ .key = w.key }, "")).status != 200) return error.KeyNotLive;
    if ((try send(w.a, w.port(), "GET", target, .{ .cookie = w.steve }, "")).status != 200) return error.CookieNotLive;
    if ((try send(w.a, w.port(), "GET", target, .{ .cookie = w.steve, .key = w.key }, "")).status != 400) return error.BothTaken;
    if ((try send(w.a, w.port(), "POST", try agentPath(w, w.agents_topic, "/messages"), .{ .cookie = w.steve, .key = w.key }, "which one?")).status != 400) return error.BothTaken;
}

fn audited(w: *World) !void {
    const log = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    const wanted = [_][]const u8{
        "action=grant:agent:", // C's mint for Steve's agent
        "verdict=refused:not-the-granters-own",
        "verdict=refused:granted-by-key", // the key's mint and its agent
        // The revoked key's read of the agent's topic, and the expired one's:
        // a refusal comes before the request is known, so each is a `use`.
        "action=use verdict=refused:revoked",
        "action=use verdict=refused:expired",
    };
    for (wanted) |line| if (!has(log, line)) return error.NotAudited;
    // A secret is never in it.
    if (has(log, w.key)) return error.SecretAudited;
}

fn inviteRedeemPost(w: *World) !void {
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
    const posted = try send(w.a, w.port(), "POST", try agentPath(w, w.agents_topic, "/messages"), .{ .key = secret }, "hello, by invite");
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
    // A key that works is someone: a channel it is not in lists it no
    // topic, where a key that is no one's is a 401.
    const listed = try send(w.a, w.port(), "GET", "/channels/Talk/topics", .{ .key = r.body[0..64] }, "");
    if (listed.status != 200 or !std.mem.eql(u8, listed.body, "{\"topics\":[]}")) return error.SecretDoesNotWork;
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
/// (app/Messages.roc's message_json): an agent named as a look-alike
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
    const conv = try topicOf(w, "Kinds", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1015)}), agent }, ivy);
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

/// Lobby's entry on the channels page `page`: from its `<li` to the next
/// channel's, or the end.
fn lobbyOf(page: []const u8) []const u8 {
    const from = std.mem.indexOf(u8, page, "<li data-channel=\"Lobby\">") orelse return "";
    const to = std.mem.indexOfPos(u8, page, from + 1, "<li data-channel=") orelse page.len;
    return page[from..to];
}

/// **AN ADMIN MAKES A CHANNEL**: Ivy, the rig's first admin, signs up;
/// /chat links her to the channels page, and no member; she makes Lobby
/// with Ann and Bea, and general with no one, and the page lists both, by
/// key, with their members.
fn adminMakesChannel(w: *World) !void {
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

/// **A KEY CHANGES NO CHANNEL**: Ivy's own key, acting as an admin, is
/// refused the page (the 403 every page gives a key) and
/// each write (`needs-session`); nothing changes.
fn keyRefusedChannels(w: *World) !void {
    const minted = try request(w.a, w.port(), "POST", "/keys", w.ivy, "");
    if (minted.status != 201) return error.NotMinted;
    w.ivy_key = try field(minted.body, "secret");
    if ((try send(w.a, w.port(), "GET", "/chat/channels", .{ .key = w.ivy_key }, "")).status != 403) return error.KeyGivenPage;
    const made = try send(w.a, w.port(), "POST", "/channels", .{ .key = w.ivy_key }, "name=Keyed");
    if (made.status != 403 or !has(made.body, "key")) return error.MadeByKey;
    if ((try send(w.a, w.port(), "POST", "/channels/Lobby/admit", .{ .key = w.ivy_key }, (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})))).status != 403) return error.AdmittedByKey;
    if ((try send(w.a, w.port(), "POST", "/channels/Lobby/remove", .{ .key = w.ivy_key }, (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1001)})))).status != 403) return error.RemovedByKey;
    const page = (try channelsPage(w, w.ivy)).body;
    const listed = lobbyOf(page);
    if (has(page, "Keyed") or has(listed, (try std.fmt.allocPrint(w.a, "human:{s}", .{try hid(w.a, 1003)}))) or !has(listed, (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1001)})))) return error.Changed;
}

/// **ADMIT AND REMOVE CHANGE WHO IS IN**: Cal let in (the channel named in
/// another spelling), Ann let go, each answered with the channel and shown
/// on the page; an agent let in and let go as a human is; one already in,
/// one not in, an unknown id and a channel that is not there refused, each
/// by name.
fn admitRemove(w: *World) !void {
    const in = try pagePost(w, w.ivy, "/channels/lobby/admit", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})));
    if (in.status != 200 or !has(in.body, (try std.fmt.allocPrint(w.a, "\"human:{s}\"", .{try hid(w.a, 1003)})))) return error.NotAdmitted;
    const out = try pagePost(w, w.ivy, "/channels/Lobby/remove", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1001)})));
    if (out.status != 200 or has(out.body, (try std.fmt.allocPrint(w.a, "human:{s}", .{try hid(w.a, 1001)})))) return error.NotRemoved;
    const listed = lobbyOf((try channelsPage(w, w.ivy)).body);
    if (!has(listed, (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1003)}))) or has(listed, (try std.fmt.allocPrint(w.a, "(<code>human:{s}</code>)", .{try hid(w.a, 1001)})))) return error.PageUnchanged;
    const twice = try pagePost(w, w.ivy, "/channels/Lobby/admit", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})));
    if (twice.status != 409 or !has(twice.body, "already")) return error.AdmittedTwice;
    const gone = try pagePost(w, w.ivy, "/channels/Lobby/remove", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1001)})));
    if (gone.status != 409 or !has(gone.body, "not in")) return error.RemovedTwice;
    // An agent is let in as a human is, shown on the page, and let go again.
    const agent = try pagePost(w, w.ivy, "/channels/Lobby/admit", try std.fmt.allocPrint(w.a, "member={s}", .{w.gil_agent}));
    if (agent.status != 200 or !has(agent.body, try std.fmt.allocPrint(w.a, "\"{s}\"", .{w.gil_agent}))) return error.AgentNotAdmitted;
    if (!has(lobbyOf((try channelsPage(w, w.ivy)).body), try std.fmt.allocPrint(w.a, "(<code>{s}</code>)", .{w.gil_agent}))) return error.AgentNotShown;
    const agent_out = try pagePost(w, w.ivy, "/channels/Lobby/remove", try std.fmt.allocPrint(w.a, "member={s}", .{w.gil_agent}));
    if (agent_out.status != 200 or has(agent_out.body, w.gil_agent)) return error.AgentNotRemoved;
    const nobody = try pagePost(w, w.ivy, "/channels/Lobby/admit", "member=human%3A999999");
    if (nobody.status != 400 or !has(nobody.body, "no account")) return error.NobodyAdmitted;
    if ((try pagePost(w, w.ivy, "/channels/Nowhere/admit", (try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1003)})))).status != 404) return error.NowhereChanged;
}

/// **A NAME IS TAKEN IN ANY SPELLING**: Lobby again, as made, in lower and
/// upper case, and general in capitals, each a 409 that says so; a name
/// the rule refuses, a 400; still two channels.
fn takenName(w: *World) !void {
    const before = count((try channelsPage(w, w.ivy)).body, "<li data-channel=");
    for ([_][]const u8{ "Lobby", "lobby", "LOBBY", "GENERAL" }) |name| {
        const r = try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name={s}", .{name}));
        if (r.status != 409 or !has(r.body, "that name is taken, by a channel or by someone")) return error.MadeTwice;
    }
    if ((try pagePost(w, w.ivy, "/channels", "name=1st")).status != 400) return error.BadNameTaken;
    if (count((try channelsPage(w, w.ivy)).body, "<li data-channel=") != before) return error.ChannelAdded;
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
        (try std.fmt.allocPrint(w.a, "action=admit channel=Lobby members={s} verdict=permitted", .{w.gil_agent})),
        (try std.fmt.allocPrint(w.a, "action=remove channel=Lobby members={s} verdict=permitted", .{w.gil_agent})),
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
    const conv = try topicOf(w, "Logins", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1016)}), agent }, una);
    // The agent's message: its kind, its owner, and its owner's login.
    const said = try std.fmt.allocPrint(w.a, "\"by\":\"{s}\",\"kind\":\"agent\",\"owner\":\"human:{s}\",\"login\":\"person1016\",", .{ agent, try hid(w.a, 1016) });
    const posted = try send(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), .{ .key = key }, "I am Person 1016");
    if (posted.status != 201 or !has(posted.body, said)) return error.NoOwnersLogin;
    // The human's own: their login.
    const theirs = try request(w.a, w.port(), "POST", try agentPath(w, conv, "/messages"), una, "no, I am");
    if (theirs.status != 201 or !has(theirs.body, (try std.fmt.allocPrint(w.a, "\"by\":\"human:{s}\",\"kind\":\"human\",\"login\":\"person1016\",", .{try hid(w.a, 1016)})))) return error.NoOwnLogin;
    // The page: each bubble's meta line, the one renderer the page and its
    // stream share.
    const page = try get(w.a, w.port(), "/chat/channel/Logins/talk", una);
    if (page.status != 200) return error.NoPage;
    const label = "P\xd0\xb5rson 1016 · agent of @person1016";
    if (!has(page.body, "<div class=chat-meta>#1 " ++ label ++ " · <time")) return error.NoLabelOnTheMessage;
    if (!has(page.body, "<div class=chat-meta>#2 Person 1016 · @person1016 · <time")) return error.NoLoginBesideTheHuman;
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
/// of two topics of channels the agent is in arrives on its one stream,
/// each naming its channel and topic; one of a channel it is not in never
/// does. Closed and resumed with the last event's place, it is sent what
/// came meanwhile in both, and nothing it had. A session and a human's key
/// are refused; signed out, a 401.
fn agentStream(w: *World) !void {
    const owner = try signUp(w.a, w.port(), 1023);
    const pal = try ownAgent(w, owner, "Pal+1023", "");
    const own = try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1023)});
    const ann = try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1001)});
    const dm = try topicOf(w, "PalPair", &.{ own, pal.id }, owner);
    const group = try topicOf(w, "PalGroup", &.{ own, pal.id, ann }, owner);
    const apart = try topicOf(w, "Apart", &.{ own, ann }, owner);
    const in_dm = "\"channel\":\"PalPair\",\"topic\":\"talk\",\"ref\":\"MSG_PalPair.talk_";
    const in_group = "\"channel\":\"PalGroup\",\"topic\":\"talk\",\"ref\":\"MSG_PalGroup.talk_";

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
    if (!has(l.got.items, in_dm ++ "1\",\"id\":1,") or !has(l.got.items, in_dm ++ "2\",\"id\":2,")) return error.DmNotNamed;
    if (!has(l.got.items, in_group ++ "1\",\"id\":1,")) return error.GroupNotNamed;
    if (has(l.got.items, "apart one")) return error.NotItsConversation;
    if (count(l.got.items, "event: message\n") != 3) return error.NotEachOnce;
    const last = try eventId(l.got.items, "\"markdown\":\"dm two\"");
    if (!std.mem.endsWith(u8, last, ".palpair/talk.2")) return error.NotAPlace;
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

    // Refused: a session, a human's own key; signed out, a 401.
    if ((try get(w.a, w.port(), "/stream", owner)).status != 403) return error.SessionStreamed;
    const human_key = try request(w.a, w.port(), "POST", "/keys", owner, "");
    if ((try send(w.a, w.port(), "GET", "/stream", .{ .key = try field(human_key.body, "secret") }, "")).status != 403) return error.HumanKeyStreamed;
    if ((try get(w.a, w.port(), "/stream", "")).status != 401) return error.NobodyStreamed;
}

/// **THE ONE STREAM IS ONE OF THE AGENT'S STREAMS**, under the host's cap of
/// eight a holder: the agent holds it and eight of a topic's, and
/// its oldest, the one stream, is ended. And it ends at its lifetime, so a
/// key revoked while it is open stops reaching it; resumed, a 401.
fn agentStreamHeld(w: *World) !void {
    const owner = try signUp(w.a, w.port(), 1024);
    const pal = try ownAgent(w, owner, "Pal+1024", "");
    const dm = try topicOf(w, "HeldPair", &.{ try std.fmt.allocPrint(w.a, "human%3A{s}", .{try hid(w.a, 1024)}), pal.id }, owner);
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

/// **A CHANNEL'S TOPIC** (Topics, Topic.roc decides): a member makes one;
/// its name taken again in another case, a bad name, a stranger and nobody
/// signed in are refused. A member posts, and the message carries its
/// reference, `MSG_<channel>.<topic>_<n>`; another member reads it and
/// streams the next; a stranger, and an agent not in the channel, never
/// reach it.
fn topicsMade(w: *World) !void {
    const p = try signUp(w.a, w.port(), 1025);
    const q = try signUp(w.a, w.port(), 1026);
    const r = try signUp(w.a, w.port(), 1027);
    const made = try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name=Garden&members=human%3A{s}%2Chuman%3A{s}", .{ try hid(w.a, 1025), try hid(w.a, 1026) }));
    if (made.status != 201) return error.ChannelNotMade;

    const topic = try pagePost(w, p, "/channels/Garden/topics", "name=ChitChat");
    if (topic.status != 201 or !std.mem.eql(u8, topic.body, "{\"channel\":\"Garden\",\"topic\":\"ChitChat\"}")) return error.TopicNotMade;
    if ((try pagePost(w, q, "/channels/garden/topics", "name=CHITCHAT")).status != 409) return error.TakenTwice;
    if ((try pagePost(w, p, "/channels/Garden/topics", "name=chit_chat")).status != 400) return error.BadNameMade;
    if ((try pagePost(w, r, "/channels/Garden/topics", "name=Mine")).status != 403) return error.StrangerMade;
    if ((try request(w.a, w.port(), "POST", "/channels/Garden/topics", "", "name=Nobody")).status != 401) return error.NobodyMade;
    if ((try pagePost(w, p, "/channels/Nowhere/topics", "name=Lost")).status != 404) return error.NowhereMade;

    const posted = try request(w.a, w.port(), "POST", "/channels/Garden/topics/ChitChat/messages", p, "hello garden");
    if (posted.status != 201 or !std.mem.startsWith(u8, posted.body, "{\"ref\":\"MSG_Garden.ChitChat_1\",\"id\":1,")) return error.NotPosted;
    const read = try get(w.a, w.port(), "/channels/garden/topics/chitchat", q);
    if (read.status != 200 or !has(read.body, "\"markdown\":\"hello garden\"") or !has(read.body, "\"ref\":\"MSG_Garden.ChitChat_1\"") or !has(read.body, "\"earlier\":false")) return error.NotRead;
    if ((try get(w.a, w.port(), "/channels/Garden/topics/ChitChat", r)).status != 404) return error.StrangerRead;
    if ((try get(w.a, w.port(), "/channels/Garden/topics/ChitChat", "")).status != 401) return error.NobodyRead;
    if ((try get(w.a, w.port(), "/channels/Garden/topics/Nope", q)).status != 404) return error.NoTopicRead;
    if ((try request(w.a, w.port(), "POST", "/channels/Garden/topics/ChitChat/messages", r, "let me in")).status != 404) return error.StrangerPosted;

    const l = try Listener.open(w.a, w.port(), "/channels/Garden/topics/ChitChat/stream", q, "1");
    defer l.close();
    if ((try request(w.a, w.port(), "POST", "/channels/Garden/topics/ChitChat/messages", p, "a second")).status != 201) return error.NotPosted;
    try l.until("\"markdown\":\"a second\"");
    if (!has(l.got.items, "\"ref\":\"MSG_Garden.ChitChat_2\"") or has(l.got.items, "hello garden")) return error.StreamedWrong;

    // An agent not in the channel, even a member's own with a key that
    // reads everywhere, never reaches its topics.
    const pal = try ownAgent(w, p, "Pal+1025", "");
    if ((try send(w.a, w.port(), "GET", "/channels/Garden/topics/ChitChat", .{ .key = pal.key }, "")).status != 404) return error.AgentRead;
}

/// **AN AGENT IN A CHANNEL**: an agent let in is a member as a human is:
/// by its key it reads and posts in every topic and makes one, and its one
/// stream (`GET /stream`) gets each topic's posts, naming the channel, the
/// topic and its reference, and resumes. A human not in the channel never
/// reaches a topic until let in; an agent not in it, its owner's or not,
/// never does.
fn agentMember(w: *World) !void {
    const p = try signUp(w.a, w.port(), 1028);
    const q = try signUp(w.a, w.port(), 1029);
    const pal = try ownAgent(w, p, "Pal+1028", "");
    const qs = try ownAgent(w, q, "Pal+1029", "");
    if ((try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name=Workshop&members=human%3A{s}%2C{s}", .{ try hid(w.a, 1028), pal.id }))).status != 201) return error.ChannelNotMade;
    const made = try pagePost(w, p, "/channels/Workshop/topics", "name=Desk");
    if (made.status != 201 or !std.mem.eql(u8, made.body, "{\"channel\":\"Workshop\",\"topic\":\"Desk\"}")) return error.TopicNotMade;

    const one = try Listener.openAs(w.a, w.port(), "/stream", .{ .key = pal.key }, "");
    errdefer one.close();
    if ((try request(w.a, w.port(), "POST", "/channels/Workshop/topics/Desk/messages", p, "a job for you")).status != 201) return error.NotPosted;
    try one.until("\"markdown\":\"a job for you\"");
    if (!has(one.got.items, "{\"channel\":\"Workshop\",\"topic\":\"Desk\",\"ref\":\"MSG_Workshop.Desk_1\",\"id\":1,")) return error.NotNamedOnTheStream;
    if (!has(one.got.items, ".workshop/desk.1\n")) return error.NotItsPlace;
    // The DM rule's kin: the topic of one human and one agent names it.
    if (!has(one.got.items, try std.fmt.allocPrint(w.a, "\"mentions\":[\"{s}\"]", .{pal.id}))) return error.AgentNotNamed;

    const by_key = try send(w.a, w.port(), "POST", "/channels/Workshop/topics/Desk/messages", .{ .key = pal.key }, "done");
    if (by_key.status != 201) return error.AgentNotPosted;
    const read = try send(w.a, w.port(), "GET", "/channels/Workshop/topics/Desk", .{ .key = pal.key }, "");
    if (read.status != 200 or !has(read.body, "\"markdown\":\"done\"")) return error.AgentNotRead;
    // The agent makes a topic too, and posts in it.
    if ((try send(w.a, w.port(), "POST", "/channels/Workshop/topics", .{ .key = pal.key }, "name=Notes")).status != 201) return error.AgentMadeNoTopic;
    if ((try send(w.a, w.port(), "POST", "/channels/Workshop/topics/Notes/messages", .{ .key = pal.key }, "my notes")).status != 201) return error.AgentNotPosted;
    try one.until("\"markdown\":\"my notes\"");
    // Q is in no channel: refused, then let in, then reads; Q's agent, never.
    if ((try get(w.a, w.port(), "/channels/Workshop/topics/Desk", q)).status != 404) return error.StrangerRead;
    if ((try send(w.a, w.port(), "GET", "/channels/Workshop/topics/Desk", .{ .key = qs.key }, "")).status != 404) return error.OtherAgentRead;
    if ((try pagePost(w, w.ivy, "/channels/Workshop/admit", try std.fmt.allocPrint(w.a, "member=human%3A{s}", .{try hid(w.a, 1029)}))).status != 200) return error.NotAdmitted;
    if ((try get(w.a, w.port(), "/channels/Workshop/topics/Desk", q)).status != 200) return error.MemberNotRead;
    if ((try send(w.a, w.port(), "GET", "/channels/Workshop/topics/Desk", .{ .key = qs.key }, "")).status != 404) return error.OtherAgentRead;
    if ((try get(w.a, w.port(), "/channels/Workshop/topics/Desk", p)).status != 200) return error.OwnerNotRead;
    // Its agent's one stream, resumed, sends the topic's posts it missed.
    const last = try eventId(one.got.items, "\"markdown\":\"a job for you\"");
    one.close();
    if ((try request(w.a, w.port(), "POST", "/channels/Workshop/topics/Desk/messages", p, "and another")).status != 201) return error.NotPosted;
    const back = try Listener.openAs(w.a, w.port(), "/stream", .{ .key = pal.key }, last);
    defer back.close();
    try back.until("\"markdown\":\"and another\"");
    if (has(back.got.items, "a job for you")) return error.SentTwice;
}

/// **A DM'S NAME**: its two humans' ids in NUMBER order, `7_11` (never
/// `11_7`, and 7 before 11 though "11" sorts first as text).
fn pairOf(a: std.mem.Allocator, x: []const u8, y: []const u8) ![]const u8 {
    const i = try std.fmt.parseInt(u64, x, 10);
    const j = try std.fmt.parseInt(u64, y, 10);
    return std.fmt.allocPrint(a, "{d}_{d}", .{ @min(i, j), @max(i, j) });
}

/// The same pair the wrong way round, `11_7`: no DM's name (a self-DM's
/// pair has no wrong way).
fn pairBackwards(a: std.mem.Allocator, x: []const u8, y: []const u8) ![]const u8 {
    const i = try std.fmt.parseInt(u64, x, 10);
    const j = try std.fmt.parseInt(u64, y, 10);
    return std.fmt.allocPrint(a, "{d}_{d}", .{ @max(i, j), @min(i, j) });
}

/// **A HUMAN DM** (Channel.dm, Topics' `/dms`): two humans' one DM,
/// whichever asks, named by their pair (`7_11`), its routes a channel's
/// under `/dms/<pair>`, the same for both; topics in it as a channel's,
/// their messages' references the short `MSG_<topic>_<n>`; a third human
/// never reaches it, nor the pair the wrong way round; with oneself, a
/// self-DM (`<n>_<n>`), its one member; with an agent or nobody refused;
/// a DM is never an admin's to make, list, admit to or reach as a channel.
fn humanDm(w: *World) !void {
    const a = try signUp(w.a, w.port(), 1030);
    const b = try signUp(w.a, w.port(), 1031);
    const c = try signUp(w.a, w.port(), 1032);
    const ha = try hid(w.a, 1030);
    const hb = try hid(w.a, 1031);
    const made = try pagePost(w, a, "/dms", try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{hb}));
    const name = try pairOf(w.a, ha, hb);
    const self = try pairOf(w.a, ha, ha);
    if (made.status != 201 or !has(made.body, try std.fmt.allocPrint(w.a, "\"dm\":\"{s}\"", .{name}))) return error.DmNotMade;
    const again = try pagePost(w, b, "/dms", try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{ha}));
    if (again.status != 200 or !has(again.body, name)) return error.NotTheSameDm;
    const self_dm = try pagePost(w, a, "/dms", try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{ha}));
    if (self_dm.status != 201 or !has(self_dm.body, try std.fmt.allocPrint(w.a, "{{\"dm\":\"{s}\",\"members\":[\"human:{s}\"]}}", .{ self, ha }))) return error.NoSelfDm;
    if ((try pagePost(w, a, "/dms", try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{ha}))).status != 200) return error.SelfDmTwice;
    // Another human never reaches it.
    if ((try pagePost(w, a, try std.fmt.allocPrint(w.a, "/dms/{s}/topics", .{self}), "name=mine")).status != 201) return error.TopicNotMade;
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/dms/{s}/topics/mine", .{self}), a)).status != 200) return error.SelfDmUnread;
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/dms/{s}/topics/mine", .{self}), b)).status != 404) return error.SelfDmLeaked;
    if ((try pagePost(w, a, "/dms", "with=human%3A999999")).status != 404) return error.DmWithNobody;
    const pal = try ownAgent(w, a, "Pal+1030", "");
    if ((try pagePost(w, a, "/dms", try std.fmt.allocPrint(w.a, "with={s}", .{pal.id}))).status != 403) return error.DmWithAnAgent;
    if ((try request(w.a, w.port(), "POST", "/dms", "", try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{hb}))).status != 401) return error.DmByNobody;

    const topics = try std.fmt.allocPrint(w.a, "/dms/{s}/topics", .{name});
    if ((try pagePost(w, a, topics, "name=ChitChat")).status != 201) return error.TopicNotMade;
    const listed = try get(w.a, w.port(), topics, b);
    if (listed.status != 200 or !has(listed.body, "\"topic\":\"ChitChat\"")) return error.TopicNotListed;
    const posted = try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "{s}/ChitChat/messages", .{topics}), a, "hi b");
    if (posted.status != 201 or !std.mem.startsWith(u8, posted.body, "{\"ref\":\"MSG_ChitChat_1\",")) return error.NotPosted;
    const read = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "{s}/ChitChat", .{topics}), b);
    if (read.status != 200 or !has(read.body, "\"markdown\":\"hi b\"")) return error.NotRead;
    // A third human never reaches it; the pair the wrong way round is no DM's.
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "{s}/ChitChat", .{topics}), c)).status != 404) return error.ThirdRead;
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/dms/{s}/topics/ChitChat", .{try pairBackwards(w.a, ha, hb)}), a)).status != 404) return error.BackwardsPairRead;
    const l = try Listener.open(w.a, w.port(), try std.fmt.allocPrint(w.a, "{s}/ChitChat/stream", .{topics}), b, "1");
    defer l.close();
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "{s}/ChitChat/messages", .{topics}), a, "again")).status != 201) return error.NotPosted;
    try l.until("\"ref\":\"MSG_ChitChat_2\"");
    const mine = try get(w.a, w.port(), "/dms", a);
    if (mine.status != 200 or !has(mine.body, name)) return error.DmNotListed;
    if (has((try get(w.a, w.port(), "/dms", c)).body, name)) return error.ThirdListed;

    // Never a channel: not by its name's routes, nor an admin's to make,
    // admit to, or list.
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/channels/{s}/topics/ChitChat", .{name}), a)).status != 404) return error.DmAsAChannel;
    if ((try pagePost(w, w.ivy, try std.fmt.allocPrint(w.a, "/channels/{s}/admit", .{name}), "member=human%3A1")).status != 404) return error.AdmittedToADm;
    if ((try pagePost(w, w.ivy, "/channels", "name=90_91&members=")).status != 400) return error.AdminMadeADm;
    if (has((try get(w.a, w.port(), "/chat/channels", w.ivy)).body, name)) return error.DmListedAsAChannel;
}

/// A human redeems an invite's `code` on a device of their own, no cookie
/// sent, with `name` (form-encoded) when not empty.
fn join(w: *World, code: []const u8, name: []const u8) !Response {
    const body = if (name.len > 0) try std.fmt.allocPrint(w.a, "code={s}&name={s}", .{ code, name }) else try std.fmt.allocPrint(w.a, "code={s}", .{code});
    return send(w.a, w.port(), "POST", "/join", .{}, body);
}

/// The session cookie a join's answer set.
fn joined(w: *World, r: Response) ![]const u8 {
    if (r.status != 200) return error.NotJoined;
    return std.fmt.allocPrint(w.a, "__Host-session={s}", .{r.cookie("session") orelse return error.NoSessionCookie});
}

/// **A HUMAN INVITE**: a member invites Zoe by name; her name is held at
/// once, and their DM's ChitChat holds the welcome; the code is in the
/// answer alone, `/join#<code>`; the page asks for no password and fills
/// her name in; she joins under another free name (a taken one a 409,
/// spending nothing), is signed in, reads the welcome and answers; the
/// code is spent. Invited again by her inviter or an admin, never by
/// another member, and never a GitHub human; revoked, expired and past
/// ten open, refused; each event audited, never a code, and a junk code
/// not at all. A key and nobody may not invite.
fn humanInvited(w: *World) !void {
    const a = try signUp(w.a, w.port(), 1033);
    const c = try signUp(w.a, w.port(), 1034);
    const k = try mint(w, "");
    if ((try send(w.a, w.port(), "POST", "/human-invites", .{ .key = k.secret }, "name=Zoe+Inv")).status != 403) return error.KeyInvited;
    if ((try request(w.a, w.port(), "POST", "/human-invites", "", "name=Zoe+Inv")).status != 401) return error.NobodyInvited;

    const made = try pagePost(w, a, "/human-invites", "name=Zoe+Inv");
    if (made.status != 201 or !has(made.body, "\"name\":\"Zoe Inv\"") or !has(made.body, "\"topic\":\"ChitChat\"")) return error.NotInvited;
    const code = try field(made.body, "code");
    if (code.len != 64 or !has(made.body, try std.fmt.allocPrint(w.a, "\"link\":\"/join#{s}\"", .{code}))) return error.NoLink;
    const zoe = (try field(made.body, "for"))["human:".len..];
    const dm = try std.fmt.allocPrint(w.a, "\"dm\":\"{s}\"", .{try pairOf(w.a, try hid(w.a, 1033), zoe)});
    if (!has(made.body, dm)) return error.NoDm;
    // Her name is held now, in any spelling, by anyone.
    if ((try pagePost(w, a, "/agents", "name=ZOE+inv")).status != 409) return error.NameNotHeld;
    if ((try pagePost(w, c, "/human-invites", "name=zoe+INV")).status != 409) return error.NameNotHeld;
    // Listed by its inviter, without its code; by no one else.
    const listed = try get(w.a, w.port(), "/human-invites", a);
    if (listed.status != 200 or !has(listed.body, "\"name\":\"Zoe Inv\"") or has(listed.body, code)) return error.NotListed;
    if (has((try get(w.a, w.port(), "/human-invites", c)).body, "Zoe Inv")) return error.ListedToAnother;
    // The welcome waits in their DM.
    const ours = try std.fmt.allocPrint(w.a, "/dms/{s}/topics/ChitChat", .{try pairOf(w.a, try hid(w.a, 1033), zoe)});
    const welcome = try get(w.a, w.port(), ours, a);
    if (welcome.status != 200 or !has(welcome.body, "\"markdown\":\"Hi! This is an automated message from Person 1033\"")) return error.NoWelcome;

    // The page: the plain words first, the fine print after; the name filled in.
    const page = try get(w.a, w.port(), "/join", "");
    if (page.status != 200 or !has(page.body, "There is no password: this device stays signed in, and you are signed out after 30 days without a visit.") or !has(page.body, "The fine print")) return error.NoJoinPage;
    const named = try send(w.a, w.port(), "POST", "/join/name", .{}, try std.fmt.allocPrint(w.a, "code={s}", .{code}));
    if (named.status != 200 or !has(named.body, "{\"name\":\"Zoe Inv\"}")) return error.NameNotFilled;
    const junk: [64]u8 = @splat('d');
    if ((try send(w.a, w.port(), "POST", "/join/name", .{}, "code=" ++ junk)).status != 401) return error.JunkNamed;

    // A taken name spends nothing; a free one is hers.
    if ((try join(w, code, "Person+1034")).status != 409) return error.TakenNameJoined;
    const zc = try joined(w, try join(w, code, "Zoe+I"));
    const me = try get(w.a, w.port(), "/me", zc);
    if (!has(me.body, try std.fmt.allocPrint(w.a, "signed in as human:{s}\n", .{zoe}))) return error.NotHer;
    if ((try pagePost(w, a, "/agents", "name=Zoe+Inv")).status != 201) return error.OldNameHeld;
    if (!has((try get(w.a, w.port(), ours, zc)).body, "automated message")) return error.WelcomeUnread;
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "{s}/messages", .{ours}), zc, "thanks!")).status != 201) return error.NoAnswer;
    if (!has((try get(w.a, w.port(), ours, a)).body, "\"markdown\":\"thanks!\"")) return error.AnswerUnread;
    if ((try join(w, code, "")).status != 401) return error.JoinedTwice;

    // Again: by her inviter (another device), or an admin; no one else.
    const again = try pagePost(w, a, "/human-invites", try std.fmt.allocPrint(w.a, "for=human%3A{s}", .{zoe}));
    if (again.status != 201 or has(again.body, "\"dm\"")) return error.NotReinvited;
    const zc2 = try joined(w, try join(w, try field(again.body, "code"), ""));
    if (!has((try get(w.a, w.port(), "/me", zc2)).body, zoe) or !has((try get(w.a, w.port(), "/me", zc)).body, zoe)) return error.NotBothDevices;
    if ((try pagePost(w, c, "/human-invites", try std.fmt.allocPrint(w.a, "for=human%3A{s}", .{zoe}))).status != 403) return error.ReinvitedByAnother;
    if ((try pagePost(w, a, "/human-invites", try std.fmt.allocPrint(w.a, "for=human%3A{s}", .{try hid(w.a, 1034)}))).status != 400) return error.ReinvitedAGitHubHuman;
    const by_admin = try pagePost(w, w.ivy, "/human-invites", try std.fmt.allocPrint(w.a, "for=human%3A{s}", .{zoe}));
    if (by_admin.status != 201) return error.AdminRefused;
    // Revoked: by its maker alone; then refused.
    const revoke_path = try std.fmt.allocPrint(w.a, "/human-invites/{s}/revoke", .{try field(by_admin.body, "id")});
    if ((try pagePost(w, c, revoke_path, "")).status != 404) return error.RevokedByAnother;
    if ((try pagePost(w, w.ivy, revoke_path, "")).status != 200) return error.NotRevoked;
    if ((try join(w, try field(by_admin.body, "code"), "")).status != 401) return error.RevokedJoined;
    // Expired at seven days, on the server's clock.
    const late = try pagePost(w, a, "/human-invites", try std.fmt.allocPrint(w.a, "for=human%3A{s}", .{zoe}));
    if (late.status != 201) return error.NotReinvited;
    w.rig.server.clock_ahead_s_for_test.store(7 * 24 * 3600, .release);
    const too_late = try join(w, try field(late.body, "code"), "");
    w.rig.server.clock_ahead_s_for_test.store(0, .release);
    if (too_late.status != 401) return error.ExpiredJoined;

    // Ten open at once, then a 403 by name.
    var open: usize = 1; // `late`'s, open again on the clock now.
    while (open < 10) : (open += 1) {
        if ((try pagePost(w, a, "/human-invites", try std.fmt.allocPrint(w.a, "name=Cap+{d}", .{open}))).status != 201) return error.UnderTheCap;
    }
    const capped = try pagePost(w, a, "/human-invites", "name=Cap+10");
    if (capped.status != 403 or !has(capped.body, "open invites")) return error.NotCapped;
    if (count((try get(w.a, w.port(), "/human-invites", a)).body, "\"id\":") != 10) return error.NotTenOpen;

    // Audited, never a code; a junk code not at all.
    const before = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    if ((try join(w, &junk, "")).status != 401) return error.JunkJoined;
    const log = try w.rig.data.readFileAlloc(io, "auth/audit", w.a, .limited(1024 * 1024));
    if (log.len != before.len) return error.JunkAudited;
    const wanted = [_][]const u8{
        try std.fmt.allocPrint(w.a, "for=human:{s} verdict=created:human:{s}\n", .{ zoe, try hid(w.a, 1033) }),
        try std.fmt.allocPrint(w.a, "for=human:{s} verdict=reinvited:human:{s}\n", .{ zoe, try hid(w.a, 1033) }),
        try std.fmt.allocPrint(w.a, "for=human:{s} verdict=redeemed:session:", .{zoe}),
        try std.fmt.allocPrint(w.a, "for=human:{s} verdict=revoked:human:", .{zoe}),
        try std.fmt.allocPrint(w.a, "for=human:{s} verdict=refused:spent\n", .{zoe}),
        try std.fmt.allocPrint(w.a, "for=human:{s} verdict=refused:revoked\n", .{zoe}),
        try std.fmt.allocPrint(w.a, "for=human:{s} verdict=refused:expired\n", .{zoe}),
    };
    for (wanted) |line| if (!has(log, line)) return error.NotAudited;
    if (has(log, code)) return error.CodeAudited;
}

const Step = struct { name: []const u8, f: *const fn (*World) anyerror!void };

// ── the browser client ──

/// Pip's name holds markup, which every page must write as text.
const pip_name_form = "Pip+%3Cb%3E%22%26%27";
const pip_name_escaped = "Pip &lt;b&gt;&quot;&amp;&#39;";

/// What the browser client's steps share: Pip and Quin, members of
/// Orchard and Meadow, and their DM; Rue, a member of nothing.
const Browsing = struct { pip: []const u8, quin: []const u8, rue: []const u8, p: []const u8, q: []const u8, pal_key: []const u8 };
var browsing: ?Browsing = null;

/// **BROWSE** (`/chat/browse`, app/Browse.roc): every other human as a DM,
/// by numeric id, then the viewer's channels by name in raw bytes, each
/// with the topics they read, in byte order; a channel they are not in is
/// not there; a place with no topic says "No sessions yet", and a
/// human with no DM has the button that makes one, which lands back on
/// Browse at it. The top bar marks Browse as here and names the viewer as
/// text. Signed out, a 303 to `/login`; a key, a 403.
fn browse(w: *World) !void {
    const pip = try signUpAs(w.a, w.port(), 1040, pip_name_form);
    const quin = try signUp(w.a, w.port(), 1041);
    const rue = try signUp(w.a, w.port(), 1042);
    const p = try hid(w.a, 1040);
    const q = try hid(w.a, 1041);
    const r = try hid(w.a, 1042);
    for ([_][]const u8{ "Orchard", "Meadow", "apricot" }) |name| {
        if ((try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name={s}&members=human%3A{s}%2Chuman%3A{s}", .{ name, p, q }))).status != 201) return error.ChannelNotMade;
    }
    for ([_][]const u8{ "apple", "Banana" }) |topic| {
        if ((try pagePost(w, pip, "/channels/Orchard/topics", try std.fmt.allocPrint(w.a, "name={s}", .{topic}))).status != 201) return error.TopicNotMade;
    }
    const pal = try ownAgent(w, pip, "Pal+1040", "");
    // Shed: Pip and his agent Pal, not Quin; its topic Desk is theirs alone.
    if ((try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name=Shed&members=human%3A{s}%2C{s}", .{ p, pal.id }))).status != 201) return error.ChannelNotMade;
    if ((try pagePost(w, pip, "/channels/Shed/topics", "name=Desk")).status != 201) return error.TopicNotMade;
    if ((try pagePost(w, pip, "/dms", try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{q}))).status != 201) return error.DmNotMade;
    if ((try pagePost(w, pip, try std.fmt.allocPrint(w.a, "/dms/{s}/topics", .{try pairOf(w.a, p, q)}), "name=ChitChat")).status != 201) return error.TopicNotMade;
    browsing = .{ .pip = pip, .quin = quin, .rue = rue, .p = p, .q = q, .pal_key = pal.key };

    // Quin and Rue have no DM yet: Rue's row is the form that makes it (and
    // a first topic, "general" offered).
    const before = try get(w.a, w.port(), "/chat/browse", quin);
    const qr = try pairOf(w.a, q, r);
    const rue_button = try std.fmt.allocPrint(w.a, "<section id=\"dm-{s}\"><h2>Person 1042</h2>\n<form class=add-topic method=post action=\"/chat/dm/{s}\"><input name=topic placeholder=\"new topic\" required value=\"general\"> <button>Add topic</button></form>", .{ r, qr });
    if (before.status != 200 or !has(before.body, rue_button)) return error.NoStartButton;
    // The pair the wrong way round makes nothing; nor one not of the pair.
    if ((try pagePost(w, quin, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{try pairBackwards(w.a, q, r)}), "")).status != 404) return error.BackwardsPairMade;
    if ((try pagePost(w, rue, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{try pairOf(w.a, p, q)}), "")).status != 404) return error.StrangerMadeDm;
    const made = try pagePost(w, quin, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{qr}), "");
    if (made.status != 303 or !std.mem.eql(u8, made.header("location") orelse "", try std.fmt.allocPrint(w.a, "/chat/browse#dm-{s}", .{r}))) return error.DmNotStarted;
    if ((try pagePost(w, rue, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{qr}), "")).status != 303) return error.DmNotFound;
    // Quin's own row: a topic of his own, the browser on its empty page,
    // titled with his name, and his post there.
    const qq = try pairOf(w.a, q, q);
    const notes = try pagePost(w, quin, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{qq}), "topic=notes");
    const notes_page = try std.fmt.allocPrint(w.a, "/chat/dm/{s}/notes", .{qq});
    if (notes.status != 303 or !std.mem.eql(u8, notes.header("location") orelse "", notes_page)) return error.NoSelfDm;
    const self_page = try get(w.a, w.port(), notes_page, quin);
    if (self_page.status != 200 or !has(self_page.body, "<span class=\"chat-top-title\">Chat w/Person 1041: notes</span>") or !has(self_page.body, "No messages yet")) return error.SelfDmPageWrong;
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "{s}/send", .{notes_page}), quin, "a note to self")).status != 201) return error.NotSent;
    if (!has((try get(w.a, w.port(), notes_page, quin)).body, "a note to self")) return error.NotSeen;
    if ((try pagePost(w, quin, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{try pairOf(w.a, q, "999999")}), "")).status != 404) return error.DmWithNobody;
    if ((try send(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{qr}), .{ .key = pal.key }, "")).status != 403) return error.KeyStartedDm;
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{qr}), "", "")).status != 401) return error.NobodyStartedDm;
    if ((try send(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{qr}), .{ .cookie = quin, .origin = "https://evil.test" }, "")).status != 403) return error.ForeignOriginTaken;

    const page = try get(w.a, w.port(), "/chat/browse", quin);
    if (page.status != 200) return error.NoBrowse;
    const b = page.body;
    // In order: Pip's DM (the lower id) with its topic, Rue's (now made, no
    // topic), then the channels in raw byte order, capitals first.
    const order = [_][]const u8{
        "<title>Chat</title>",
        "<strong>Browse</strong>",
        "<strong>Person 1041</strong>",
        try std.fmt.allocPrint(w.a, "<section id=\"dm-{s}\"><h2>" ++ pip_name_escaped ++ "</h2>", .{p}),
        try std.fmt.allocPrint(w.a, "<a href=\"/chat/dm/{s}/ChitChat\">ChitChat</a>", .{try pairOf(w.a, p, q)}),
        try std.fmt.allocPrint(w.a, "<section id=\"dm-{s}\"><h2>Person 1042</h2>\n<ul class=browse-list>\n<li class=muted>No sessions yet</li>", .{r}),
        "<h2># Meadow</h2>\n<ul class=browse-list>\n<li class=muted>No sessions yet</li>",
        "<h2># Orchard</h2>",
        "<a href=\"/chat/channel/Orchard/Banana\">Banana</a>",
        "<a href=\"/chat/channel/Orchard/apple\">apple</a>",
        "<h2># apricot</h2>",
        "<script src=\"/chrome.js\"></script>",
    };
    var at: usize = 0;
    for (order) |needle| {
        at = (std.mem.indexOfPos(u8, b, at, needle) orelse return error.BrowseOutOfOrder) + needle.len;
    }
    if (has(b, "Desk") or has(b, "Pip <b>") or has(b, "<style")) return error.BrowseShowsTooMuch;
    // Shed is Pip's, so on his Browse, after Orchard, in raw byte order.
    const own = try get(w.a, w.port(), "/chat/browse", pip);
    if (!has(own.body, "<h2># Shed</h2>") or !has(own.body, "<a href=\"/chat/channel/Shed/Desk\">Desk</a>") or !has(own.body, "<h2>Person 1041</h2>")) return error.OwnTopicMissing;
    if ((std.mem.indexOf(u8, own.body, "<h2># Shed</h2>") orelse 0) < (std.mem.indexOf(u8, own.body, "<h2># Orchard</h2>") orelse return error.OwnTopicMissing)) return error.BrowseOutOfOrder;
    // Rue is in no channel, and sees Pip as a human with no DM yet.
    const theirs = try get(w.a, w.port(), "/chat/browse", rue);
    if (has(theirs.body, "# Orchard") or !has(theirs.body, try std.fmt.allocPrint(w.a, "action=\"/chat/dm/{s}\"", .{try pairOf(w.a, p, r)}))) return error.RueSeesWrong;

    const out = try get(w.a, w.port(), "/chat/browse", "");
    if (out.status != 303 or !std.mem.eql(u8, out.header("location") orelse "", "/login?next=%2Fchat%2Fbrowse")) return error.NotToLogin;
    if ((try send(w.a, w.port(), "GET", "/chat/browse", .{ .key = pal.key }, "")).status != 403) return error.KeyBrowsed;
    if (!has((try get(w.a, w.port(), "/chat", quin)).body, "<a href=\"/chat/browse\">")) return error.NoBrowseLink;
}

/// **A TOPIC'S PAGE** (`/chat/channel/<c>/<t>`, `/chat/dm/<pair>/<t>`,
/// app/TopicPage.roc): server-rendered, each message its bubble (the
/// author's id, `#<n> <name> · <time>`, roc-markdown's HTML), the page
/// naming its viewer and its stream, the right pane there and empty, the
/// old app's title; an empty topic says so. A topic the viewer may not
/// read, or none, is a 404 for the page, its stream and its fragments
/// alike; signed out, the page is a 303 and its stream a 401; a key, a 403.
fn topicPage(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    if ((try request(w.a, w.port(), "POST", "/channels/Orchard/topics/Banana/messages", x.pip, "hello **orchard**")).status != 201) return error.NotPosted;
    const page = try get(w.a, w.port(), "/chat/channel/orchard/banana", x.quin);
    if (page.status != 200) return error.NoTopicPage;
    const want = [_][]const u8{
        // The theme, before first paint: the palette in the head, and the
        // top bar's toggle.
        "<title>Chat</title>\n<script src=\"/palette.js\"></script>\n<body class=chat-page",
        "<button id=chat-theme-toggle type=button title=\"Toggle theme\" aria-label=\"Toggle theme\"></button> · <strong>Person 1041</strong>",
        try std.fmt.allocPrint(w.a, "<body class=chat-page data-me=\"human:{s}\" data-stream=\"/chat/channel/Orchard/Banana/stream?after=1\" data-earlier=\"/chat/channel/Orchard/Banana/earlier\" data-quote=\"/chat/channel/Orchard/Banana/quote\" data-edit=\"/chat/channel/Orchard/Banana/edit\" data-react=\"/chat/channel/Orchard/Banana/react\">", .{x.q}),
        "<span class=\"chat-top-title\">#Orchard: Banana</span>",
        "<a href=\"/chat/browse\">Browse</a>",
        "<button id=earlier type=button hidden>Earlier messages</button>",
        try std.fmt.allocPrint(w.a, "<div class=chat-msg id=msg-1 data-id=1 data-ref=\"Banana_1\" data-by=\"human:{s}\"><div class=chat-meta>#1 " ++ pip_name_escaped ++ " · @person1040 · <time class=chat-time datetime=", .{x.p}),
        "<div class=chat-body><p>hello <strong>orchard</strong></p>",
        // The right pane: compose, closed to start, the old words.
        "<div class=chat-notify id=chat-notify></div>",
        "<div id=chat-right-sidebar class=chat-compose>\n<div id=chat-compose-body class=chat-compose-body hidden><form id=chat-form data-send=\"/chat/channel/Orchard/Banana/send\" data-upload=\"/chat/channel/Orchard/Banana/upload\" data-image-most=10485760><textarea id=chat-body placeholder=\"Write a message…  Markdown is supported, and longer posts are welcome.\"></textarea><div class=chat-compose-actions><button type=submit>Send</button><button type=button id=chat-upload-btn>Upload</button></div></form><input type=file id=chat-file accept=\"image/png,image/jpeg,image/gif,image/webp\" hidden><div id=chat-status class=chat-status></div><div class=chat-hint>Markdown supported · :emoji: autocompletes · attach an image · Ctrl/⌘-Enter to send</div></div>\n<div id=chat-closed-panel class=chat-closed-panel><button type=button id=chat-open-compose class=chat-open-compose>Open compose box</button></div>\n</div>",
        "<script src=\"/keys.js\"></script>\n<script src=\"/feed.js\"></script>\n<script src=\"/emoji.js\"></script>\n<script src=\"/compose.js\"></script>\n<script src=\"/upload.js\"></script>\n<script src=\"/quote.js\"></script>\n<script src=\"/reactions.js\"></script>\n<script src=\"/keyhelp.js\"></script>",
    };
    for (want) |needle| if (!has(page.body, needle)) return error.TopicPageWrong;
    if (has(page.body, "Pip <b>") or has(page.body, "No messages yet") or has(page.body, "<style")) return error.TopicPageWrong;
    // The time is there without a script: its datetime and text, in UTC.
    if (!has(page.body, "Z data-at=") or !has(page.body, " UTC</time>")) return error.NoFallbackTime;
    const empty = try get(w.a, w.port(), "/chat/channel/Orchard/apple", x.quin);
    if (empty.status != 200 or !has(empty.body, "<p id=chat-empty class=muted>No messages yet. Say hello 👋</p>") or has(empty.body, "class=chat-msg")) return error.NoEmptyState;

    // A DM's page, from each side, titled by the other's name.
    // One page for the DM, the same URL for both of its humans.
    const dm = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat", .{try pairOf(w.a, x.p, x.q)}), x.quin);
    if (dm.status != 200 or !has(dm.body, "<span class=\"chat-top-title\">Chat w/" ++ pip_name_escaped ++ ": ChitChat</span>")) return error.NoDmPage;
    if (!has((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat", .{try pairOf(w.a, x.p, x.q)}), x.pip)).body, "<span class=\"chat-top-title\">Chat w/Person 1041: ChitChat</span>")) return error.NoDmPage;
    // Pip's self-DM has no ChitChat: the 404 of a topic not there.
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat", .{try pairOf(w.a, x.p, x.p)}), x.pip)).status != 404) return error.NoTopicRead;
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat", .{try pairBackwards(w.a, x.p, x.q)}), x.pip)).status != 404) return error.BackwardsPairShown;

    // Who may not read it: a stranger, the same 404 as no topic at all.
    const closed = [_][]const u8{ "/chat/channel/Orchard/Banana", "/chat/channel/Orchard/Banana/stream", "/chat/channel/Orchard/Banana/earlier?before=2", try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat", .{try pairOf(w.a, x.p, x.q)}) };
    for (closed) |path| if ((try get(w.a, w.port(), path, x.rue)).status != 404) return error.StrangerRead;
    // The page says why, as the old app's did: a channel not there and one
    // you are not in alike; a topic not there named. The stream and the
    // fragment are the plain 404.
    const yours = try get(w.a, w.port(), "/chat/channel/Orchard/Banana", x.rue);
    const nowhere = try get(w.a, w.port(), "/chat/channel/Nowhere/Banana", x.rue);
    if (!has(yours.body, "<span class=\"chat-top-title\">Not here</span>") or !has(yours.body, "<p>#Orchard is not a channel you are a member of.</p><p><a href=\"/chat/browse\">Go back</a></p>")) return error.NotHereWrong;
    if (nowhere.status != 404 or !has(nowhere.body, "<p>#Nowhere is not a channel you are a member of.</p>")) return error.NotHereWrong;
    const desk = try get(w.a, w.port(), "/chat/channel/Shed/Desk", x.quin);
    if (desk.status != 404 or !has(desk.body, "<p>#Shed is not a channel you are a member of.</p>")) return error.OtherChannelRead;
    const nope = try get(w.a, w.port(), "/chat/channel/Orchard/Nope", x.quin);
    if (nope.status != 404 or !has(nope.body, "<p>There is no topic “Nope” in this conversation.</p>")) return error.NoTopicRead;
    if (has((try get(w.a, w.port(), "/chat/channel/Orchard/Banana/stream", x.rue)).body, "Not here")) return error.StreamSaidWhy;
    // The topics' own routes: to a stranger, a channel that is not there
    // and one they are not in answer alike; to a member, no topic is named.
    const json_yours = try get(w.a, w.port(), "/channels/Orchard/topics/Banana", x.rue);
    const json_nowhere = try get(w.a, w.port(), "/channels/Nowhere/topics/Banana", x.rue);
    if (json_yours.status != 404 or !std.mem.eql(u8, json_yours.body, json_nowhere.body)) return error.ChannelLeaked;
    const json_nope = try get(w.a, w.port(), "/channels/Orchard/topics/Nope", x.quin);
    if (json_nope.status != 404 or std.mem.eql(u8, json_nope.body, json_yours.body)) return error.MemberToldNothing;
    const out = try get(w.a, w.port(), "/chat/channel/Orchard/Banana", "");
    if (out.status != 303 or !std.mem.eql(u8, out.header("location") orelse "", "/login?next=%2Fchat%2Fchannel%2FOrchard%2FBanana")) return error.NotToLogin;
    if ((try get(w.a, w.port(), "/chat/channel/Orchard/Banana/stream", "")).status != 401) return error.NobodyStreamed;
    if ((try send(w.a, w.port(), "GET", "/chat/channel/Orchard/Banana", .{ .key = x.pal_key }, "")).status != 403) return error.KeyRead;
    if ((try request(w.a, w.port(), "POST", "/chat/channel/Orchard/Banana", x.quin, "")).status != 405) return error.PagePosted;
}

/// **A TOPIC PAGE'S STREAM CARRIES BUBBLES**: from `?after=` (the page's
/// newest), each later post as the same bubble the page draws, built once
/// for every viewer, its id the message's; resumed by `Last-Event-ID`,
/// nothing twice. The agents' JSON stream of the topic is as it was. The
/// page's script is served, and chat-client's still are.
fn topicPageStream(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    const l = try Listener.open(w.a, w.port(), "/chat/channel/Orchard/Banana/stream?after=1", x.quin, "");
    defer l.close();
    const json = try Listener.open(w.a, w.port(), "/channels/Orchard/topics/Banana/stream", x.quin, "1");
    defer json.close();
    if ((try request(w.a, w.port(), "POST", "/channels/Orchard/topics/Banana/messages", x.pip, "a *second*")).status != 201) return error.NotPosted;
    try l.until("<em>second</em>");
    const bubble = try std.fmt.allocPrint(w.a, "event: message\nid: 2\ndata: <div class=chat-msg id=msg-2 data-id=2 data-ref=\"Banana_2\" data-by=\"human:{s}\"><div class=chat-meta>#2 " ++ pip_name_escaped ++ " · @person1040 · <time class=chat-time datetime=", .{x.p});
    if (!has(l.got.items, bubble) or has(l.got.items, "orchard")) return error.StreamedWrong;
    try json.until("\"markdown\":\"a *second*\"");
    if (has(json.got.items, "chat-msg")) return error.JsonStreamChanged;

    const resumed = try Listener.open(w.a, w.port(), "/chat/channel/Orchard/Banana/stream?after=0", x.quin, "1");
    defer resumed.close();
    try resumed.until("<em>second</em>");
    if (has(resumed.got.items, "orchard")) return error.ResumedTwice;

    // A resume point that is no message's id is a 400, never read as 0.
    // (Opened as a stream, so a server that took one fails the step within
    // the listener's wait, never hangs it.)
    for ([_][]const u8{ "?after=x", "?after=01", "?after=1&after=2" }) |q| {
        if (Listener.open(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/channel/Orchard/Banana/stream{s}", .{q}), x.quin, "")) |bad| {
            bad.close();
            return error.BadAfterTaken;
        } else |_| {}
    }
    if (Listener.open(w.a, w.port(), "/chat/channel/Orchard/Banana/stream", x.quin, "x")) |bad| {
        bad.close();
        return error.BadLastEventIdTaken;
    } else |_| {}
    if (Listener.open(w.a, w.port(), "/channels/Orchard/topics/Banana/stream", x.quin, "x")) |bad| {
        bad.close();
        return error.BadLastEventIdTaken;
    } else |_| {}

    if ((try get(w.a, w.port(), "/chrome.js", x.quin)).status != 200) return error.NoChromeJs;
    const script = try get(w.a, w.port(), "/feed.js", x.quin);
    if (script.status != 200 or !std.mem.eql(u8, script.header("content-type") orelse "", "text/javascript; charset=utf-8") or !has(script.body, "new EventSource(root.dataset.stream)")) return error.NoFeedJs;
    if ((try get(w.a, w.port(), "/chat.js", x.quin)).status != 200) return error.NoChatClient;
}

/// **EARLIER MESSAGES, A FRAGMENT**: past the newest page (100), the page
/// shows its Earlier button and names its newest; the page before comes as
/// one element of bubbles, oldest first, saying whether more come before
/// it; `before=` that is no message's id is a 400.
fn topicPageEarlier(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    var n: usize = 3;
    while (n <= 102) : (n += 1) {
        if ((try request(w.a, w.port(), "POST", "/channels/Orchard/topics/Banana/messages", x.pip, try std.fmt.allocPrint(w.a, "number {d}", .{n}))).status != 201) return error.NotPosted;
    }
    const page = try get(w.a, w.port(), "/chat/channel/Orchard/Banana", x.quin);
    if (page.status != 200 or !has(page.body, "<button id=earlier type=button>Earlier messages</button>") or !has(page.body, "stream?after=102\"")) return error.NoEarlierButton;
    if (has(page.body, "id=msg-2 ") or !has(page.body, "id=msg-3 ") or !has(page.body, "id=msg-102 ")) return error.PageWrong;
    const before = try get(w.a, w.port(), "/chat/channel/Orchard/Banana/earlier?before=3", x.quin);
    if (before.status != 200 or !std.mem.startsWith(u8, before.body, "<div data-earlier=0>\n<div class=chat-msg id=msg-1 ")) return error.EarlierWrong;
    if (!has(before.body, "id=msg-2 ") or has(before.body, "id=msg-3 ")) return error.EarlierWrong;
    const more = try get(w.a, w.port(), "/chat/channel/Orchard/Banana/earlier?before=102", x.quin);
    if (!std.mem.startsWith(u8, more.body, "<div data-earlier=1>\n<div class=chat-msg id=msg-2 ")) return error.EarlierWrong;
    // A page further behind than the stream resends gets a `gap` first,
    // naming the newest page's first, as a topic's stream does.
    const behind = try Listener.open(w.a, w.port(), "/chat/channel/Orchard/Banana/stream", x.quin, "1");
    defer behind.close();
    try behind.until("id: 3\n");
    if (!has(behind.got.items, "event: gap\ndata: {\"before\":3}\n\n") or has(behind.got.items, "id: 2\n")) return error.NoGap;
    for ([_][]const u8{ "", "?before=x", "?before=03", "?before=1&before=2" }) |q| {
        if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/channel/Orchard/Banana/earlier{s}", .{q}), x.quin)).status != 400) return error.BadBeforeTaken;
    }
}

/// **THE COMPOSE BOX SENDS** (`POST .../send`, app/TopicPage.roc): the body
/// is the markdown, decided by the topic's own rules; the answer, a 201, is
/// the new message's bubble, the same the stream sends every page; it is
/// stored once, as a topic's post. A refusal is the post's, its words its
/// own: text that is not UTF-8 a 400, a stranger the same 404 as no topic,
/// a key a 403, signed out a 401, a foreign Origin a 403, a GET a 405. A
/// DM's compose box sends to the DM's topic. The scripts are served.
fn composeSends(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    const l = try Listener.open(w.a, w.port(), "/chat/channel/Orchard/Banana/stream?after=102", x.pip, "");
    defer l.close();
    const sent = try request(w.a, w.port(), "POST", "/chat/channel/Orchard/Banana/send", x.quin, "from **compose**");
    const bubble = try std.fmt.allocPrint(w.a, "<div class=chat-msg id=msg-103 data-id=103 data-ref=\"Banana_103\" data-by=\"human:{s}\"><div class=chat-meta>#103 Person 1041 · @person1041 · <time class=chat-time datetime=", .{x.q});
    if (sent.status != 201 or !std.mem.startsWith(u8, sent.body, bubble) or !has(sent.body, "<p>from <strong>compose</strong></p>")) return error.NotSent;
    if (!std.mem.startsWith(u8, sent.header("content-type") orelse "", "text/html")) return error.NotHtml;
    // Every page's stream gets the same bubble.
    try l.until("<strong>compose</strong>");
    if (!has(l.got.items, bubble)) return error.StreamedOther;
    // Stored once, as a topic's post: the JSON read has it, its markdown as sent.
    const read = try get(w.a, w.port(), "/channels/Orchard/topics/Banana?before=104", x.pip);
    if (!has(read.body, "\"markdown\":\"from **compose**\"") or has(read.body, "\"id\":104")) return error.NotStoredOnce;

    // Refusals, each the post's own.
    const bad = try request(w.a, w.port(), "POST", "/chat/channel/Orchard/Banana/send", x.quin, "\xff\xfe");
    if (bad.status != 400 or !has(bad.body, "a message is UTF-8 text")) return error.BadTextTaken;
    if ((try request(w.a, w.port(), "POST", "/chat/channel/Orchard/Banana/send", x.rue, "let me in")).status != 404) return error.StrangerSent;
    if ((try request(w.a, w.port(), "POST", "/chat/channel/Shed/Desk/send", x.quin, "not mine")).status != 404) return error.OtherChannelSent;
    if ((try send(w.a, w.port(), "POST", "/chat/channel/Orchard/Banana/send", .{ .key = x.pal_key }, "by key")).status != 403) return error.KeySent;
    if ((try request(w.a, w.port(), "POST", "/chat/channel/Orchard/Banana/send", "", "nobody")).status != 401) return error.NobodySent;
    if ((try send(w.a, w.port(), "POST", "/chat/channel/Orchard/Banana/send", .{ .cookie = x.quin, .origin = "https://evil.test" }, "forged")).status != 403) return error.ForeignOriginSent;
    if ((try get(w.a, w.port(), "/chat/channel/Orchard/Banana/send", x.quin)).status != 405) return error.SendByGet;
    const after = try get(w.a, w.port(), "/channels/Orchard/topics/Banana?before=105", x.pip);
    if (has(after.body, "\"id\":104")) return error.RefusalStored;

    // A DM's box sends to the DM's topic.
    const dm = try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat/send", .{try pairOf(w.a, x.p, x.q)}), x.quin, "back at you");
    if (dm.status != 201 or !has(dm.body, "data-ref=\"ChitChat_")) return error.DmNotSent;

    for ([_][]const u8{ "/keys.js", "/compose.js", "/palette.js", "/keyhelp.js" }) |path| {
        if ((try get(w.a, w.port(), path, x.quin)).status != 200) return error.ScriptMissing;
    }
}

/// **RECENT** (`/chat/recent`, app/RecentPage.roc): one tile per topic the
/// viewer reads in their DMs and channels, by its last message, newest
/// first, a topic with none last; who wrote it "You" for the viewer, else
/// their first name, and the old one-line excerpt; another member's agent
/// topic not there. Nothing at all: "Nothing yet.". Live, each new post's
/// tile goes to each reader's stream, drawn for them, and to no one else.
/// The top bar marks Recent as here. Signed out, a 303 and a 401; a key,
/// a 403.
fn recentFeed(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    const page = try get(w.a, w.port(), "/chat/recent", x.quin);
    if (page.status != 200) return error.NoRecent;
    const b = page.body;
    const banana = "<a class=recent-tile href=\"/chat/channel/Orchard/Banana\" data-key=\"/chat/channel/Orchard/Banana\" data-ts=";
    const pq = try pairOf(w.a, x.p, x.q);
    const dm = try std.fmt.allocPrint(w.a, "<a class=recent-tile href=\"/chat/dm/{s}/ChitChat\" data-key=\"/chat/dm/{s}/ChitChat\" data-ts=", .{ pq, pq });
    const apple = "<a class=recent-tile href=\"/chat/channel/Orchard/apple\" data-key=\"/chat/channel/Orchard/apple\" data-ts=0>";
    const want = [_][]const u8{
        "<a href=\"/chat/browse\">Browse</a> · <strong>Recent</strong>",
        "<body class=recent-page>",
        banana,
        "<div class=recent-bar data-channel=\"Orchard\"></div></div><div class=recent-body><div class=recent-top><div class=recent-context><span>#Orchard</span><span class=recent-dot>  ·  </span><span class=recent-topic>Banana</span></div><span class=recent-ago></span></div><div class=recent-preview><span class=recent-who>You: </span>from **compose**</div>",
        dm,
        "<div class=recent-avatar>P</div></div><div class=recent-body><div class=recent-top><div class=recent-title>ChitChat</div><span class=recent-ago></span></div><div class=recent-preview><span class=recent-who>You: </span>back at you</div>",
        "<script src=\"/recent_page.js\"></script>",
    };
    for (want) |needle| if (!has(b, needle)) return error.RecentWrong;
    // A topic with no message goes last, with no preview.
    const at_apple = std.mem.indexOf(u8, b, apple) orelse return error.RecentWrong;
    if (at_apple < (std.mem.indexOf(u8, b, banana) orelse 0) or at_apple < (std.mem.indexOf(u8, b, dm) orelse 0)) return error.RecentOutOfOrder;
    if (has(b, "Desk") or has(b, "Nothing yet.") or has(b, "<style")) return error.RecentShowsTooMuch;
    // Pip's own: Shed's Desk, and Quin by first name.
    const own = try get(w.a, w.port(), "/chat/recent", x.pip);
    if (!has(own.body, "data-key=\"/chat/channel/Shed/Desk\"") or !has(own.body, "<span class=recent-who>Person: </span>from **compose**")) return error.PipSeesWrong;
    // Rue is in no channel, and her DM with Quin has no topic yet.
    if (!has((try get(w.a, w.port(), "/chat/recent", x.rue)).body, "<p id=recent-empty class=muted>Nothing yet.</p>")) return error.NoEmptyState;

    // Live: Pip's stream gets Quin's post, drawn for Pip; Rue's never does.
    const pips = try Listener.open(w.a, w.port(), "/chat/recent/stream", x.pip, "");
    defer pips.close();
    const rues = try Listener.open(w.a, w.port(), "/chat/recent/stream", x.rue, "");
    defer rues.close();
    if ((try request(w.a, w.port(), "POST", "/chat/channel/Orchard/Banana/send", x.quin, "a  live\n\nrecent <b>")).status != 201) return error.NotSent;
    try pips.until("&lt;b&gt;");
    if (!has(pips.got.items, "event: message\ndata: " ++ banana) or !has(pips.got.items, "<span class=recent-who>Person: </span>a live recent &lt;b&gt;</div>")) return error.LiveWrong;
    // Rue's stream is read until its wait runs out: a tile there fails.
    if (rues.until("recent-tile")) |_| return error.StrangerGotTile else |e| if (e != error.NeverCame) return e;

    // A channel's topic, both sides: Pip's post to Shed's Desk reaches his
    // own Recent, and never Quin's, who is not in Shed.
    const quins = try Listener.open(w.a, w.port(), "/chat/recent/stream", x.quin, "");
    defer quins.close();
    if ((try request(w.a, w.port(), "POST", "/chat/channel/Shed/Desk/send", x.pip, "desk note")).status != 201) return error.NotSent;
    try pips.until("desk note");
    if (!has(pips.got.items, "data-key=\"/chat/channel/Shed/Desk\"") or !has(pips.got.items, "<span class=recent-who>You: </span>desk note")) return error.OwnTopicMissing;
    if (quins.until("Desk")) |_| return error.OtherChannelLeaked else |e| if (e != error.NeverCame) return e;

    const out = try get(w.a, w.port(), "/chat/recent", "");
    if (out.status != 303 or !std.mem.eql(u8, out.header("location") orelse "", "/login?next=%2Fchat%2Frecent")) return error.NotToLogin;
    if ((try get(w.a, w.port(), "/chat/recent/stream", "")).status != 401) return error.NobodyStreamed;
    if ((try send(w.a, w.port(), "GET", "/chat/recent", .{ .key = x.pal_key }, "")).status != 403) return error.KeyRead;
    if ((try get(w.a, w.port(), "/recent_page.js", x.quin)).status != 200) return error.NoScript;
}

/// **QUOTE-REPLY AND EDIT** (`.../quote?n=`, `.../edit?n=`, app/Edits.roc):
/// every bubble draws both links; a quote-reply is the message under its
/// reference, "you said" or "I said", in a fence one tilde longer than any
/// inside; an edit is one's own message under "Edit of" its reference, the
/// cursor after the blank line, another's a 403. Posted, an edit by the
/// author redraws the original on every page, live (`edit`), in a resumed
/// backlog, and on its earlier page: "Edited in" the edit and the original
/// in a spoiler; one by anybody else is an ordinary message. A bad `n=`
/// a 400, no message a 404; a stranger the topic's 404, signed out a 401,
/// a key a 403, a POST a 405.
fn quoteEdit(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    const base = "/chat/channel/Orchard/Banana";
    const page = try get(w.a, w.port(), base, x.quin);
    if (!has(page.body, "</time> <button type=button class=msg-quote title=\"Quote this message in a reply (q)\">quote-reply</button> <button type=button class=msg-edit title=\"Load this message back into compose with an &quot;Edit of MSG_…&quot; backlink (e)\">edit</button></div>")) return error.NoLinks;

    // Pip's first message, quoted by Quin and by Pip.
    const theirs = try get(w.a, w.port(), base ++ "/quote?n=1", x.quin);
    if (theirs.status != 200 or !std.mem.eql(u8, theirs.body, "{\"text\":\"In MSG_Orchard.Banana_1 you said:\\n~~~ quote\\nhello **orchard**\\n~~~\\n\\n\"}")) return error.QuoteWrong;
    if (!std.mem.startsWith(u8, theirs.header("content-type") orelse "", "application/json")) return error.NotJson;
    const own = try get(w.a, w.port(), base ++ "/quote?n=1", x.pip);
    if (!has(own.body, "In MSG_Orchard.Banana_1 I said:")) return error.QuoteWrong;
    // A message holding a fence gets a longer one.
    if ((try request(w.a, w.port(), "POST", base ++ "/send", x.quin, "see\n~~~~ quote\ninner\n~~~~")).status != 201) return error.NotPosted;
    const fenced = try get(w.a, w.port(), base ++ "/quote?n=105", x.pip);
    if (!has(fenced.body, "In MSG_Orchard.Banana_105 you said:\\n~~~~~ quote\\nsee\\n~~~~ quote\\ninner\\n~~~~\\n~~~~~\\n\\n")) return error.FenceWrong;
    // A DM's reference is the short one.
    const dm_quote = try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat/quote?n=1", .{try pairOf(w.a, x.p, x.q)}), x.quin);
    if (dm_quote.status != 200 or !has(dm_quote.body, "\"In MSG_ChitChat_1 ")) return error.DmQuoteWrong;

    // An edit: one's own alone.
    const draft = try get(w.a, w.port(), base ++ "/edit?n=1", x.pip);
    if (draft.status != 200 or !std.mem.eql(u8, draft.body, "{\"text\":\"Edit of MSG_Orchard.Banana_1\\n\\nhello **orchard**\",\"caret\":30}")) return error.DraftWrong;
    const not_yours = try get(w.a, w.port(), base ++ "/edit?n=1", x.quin);
    if (not_yours.status != 403 or !has(not_yours.body, "only its author edits a message")) return error.EditedAnothers;

    // Posted: the original redrawn live on every page, after the edit's own.
    const l = try Listener.open(w.a, w.port(), base ++ "/stream?after=105", x.quin, "");
    defer l.close();
    if ((try request(w.a, w.port(), "POST", base ++ "/send", x.pip, "Edit of MSG_Orchard.Banana_1\n\nhello **fixed**")).status != 201) return error.NotPosted;
    try l.until("chat-edited-orig");
    const redrawn = try std.fmt.allocPrint(w.a, "event: edit\ndata: <div class=chat-msg id=msg-1 data-id=1 data-ref=\"Banana_1\" data-by=\"human:{s}\">", .{x.p});
    const note = "<div class=chat-body><div class=chat-edited-note>Edited in <a class=msg-ref href=\"#msg-106\">MSG_Orchard.Banana_106</a></div><details class=chat-edited-spoiler><summary>original</summary><div class=chat-edited-orig>hello **orchard**</div></details></div>";
    const at_edit = std.mem.indexOf(u8, l.got.items, redrawn) orelse return error.NoLiveEdit;
    const at_post = std.mem.indexOf(u8, l.got.items, "id: 106\n") orelse return error.NoLiveEdit;
    if (at_post > at_edit or !has(l.got.items, note)) return error.LiveEditWrong;
    // Another's "edit" is an ordinary message: no redraw (read up to a
    // post after it, so a redraw would have come first).
    if ((try request(w.a, w.port(), "POST", base ++ "/send", x.quin, "Edit of MSG_Orchard.Banana_2\n\nmine now")).status != 201) return error.NotPosted;
    if ((try request(w.a, w.port(), "POST", base ++ "/send", x.pip, "after the fake")).status != 201) return error.NotPosted;
    try l.until("after the fake");
    if (has(l.got.items, "id=msg-2 ")) return error.AnothersEditApplied;

    // The newest page draws its own: an edit of 108 (Pip's "after the
    // fake"), posted as 109, supersedes it on the page itself.
    if ((try request(w.a, w.port(), "POST", base ++ "/send", x.pip, "Edit of MSG_Orchard.Banana_108\n\nafter the fake, fixed")).status != 201) return error.NotPosted;
    try l.until("after the fake, fixed");
    const newest = try get(w.a, w.port(), base, x.quin);
    if (!has(newest.body, "Edited in <a class=msg-ref href=\"#msg-109\">MSG_Orchard.Banana_109</a></div><details class=chat-edited-spoiler><summary>original</summary><div class=chat-edited-orig>after the fake</div>")) return error.NewestPageEditWrong;

    // Resumed: the backlog sends the edit's redraw after the edit.
    const resumed = try Listener.open(w.a, w.port(), base ++ "/stream", x.quin, "105");
    defer resumed.close();
    try resumed.until("after the fake");
    if (!has(resumed.got.items, note) or has(resumed.got.items, "id=msg-2 ")) return error.BacklogEditWrong;
    // The earlier page draws the original superseded, the other one not.
    const earlier = try get(w.a, w.port(), base ++ "/earlier?before=3", x.quin);
    if (!has(earlier.body, note) or has(earlier.body, "Edited in <a class=msg-ref href=\"#msg-107\">")) return error.EarlierEditWrong;

    // Refusals.
    for ([_][]const u8{ "", "?n=x", "?n=01", "?n=1&n=2" }) |q| {
        if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, base ++ "/quote{s}", .{q}), x.quin)).status != 400) return error.BadNTaken;
        if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, base ++ "/edit{s}", .{q}), x.pip)).status != 400) return error.BadNTaken;
    }
    for ([_][]const u8{ "/quote?n=0", "/quote?n=9999", "/edit?n=9999" }) |path| {
        if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, base ++ "{s}", .{path}), x.pip)).status != 404) return error.NoMessageFound;
    }
    if ((try get(w.a, w.port(), base ++ "/quote?n=1", x.rue)).status != 404) return error.StrangerQuoted;
    if ((try get(w.a, w.port(), "/chat/channel/Shed/Desk/quote?n=1", x.quin)).status != 404) return error.OtherChannelQuoted;
    if ((try get(w.a, w.port(), base ++ "/quote?n=1", "")).status != 401) return error.NobodyQuoted;
    if ((try send(w.a, w.port(), "GET", base ++ "/edit?n=1", .{ .key = x.pal_key }, "")).status != 403) return error.KeyEdited;
    if ((try request(w.a, w.port(), "POST", base ++ "/quote?n=1", x.quin, "")).status != 405) return error.QuotePosted;
    if ((try get(w.a, w.port(), "/quote.js", x.quin)).status != 200) return error.NoScript;
}

/// **NO SAVES** (Steve, 2026-11-02: the old save was never meant to be
/// public, and roc-chat's was broken): no save route, no reading list
/// page, no Saved link, no save button on a bubble, no save script.
fn noSaves(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    const base = "/chat/channel/Orchard/Banana";
    if ((try request(w.a, w.port(), "POST", base ++ "/save", x.quin, "n=1")).status != 404) return error.SaveRouteLives;
    if ((try get(w.a, w.port(), "/chat/saved", x.quin)).status != 404) return error.SavedPageLives;
    const page = (try get(w.a, w.port(), base, x.quin)).body;
    if (has(page, "/chat/saved") or has(page, "msg-save") or has(page, "data-save") or has(page, "save.js")) return error.SaveOnPage;
    for ([_][]const u8{ "/save.js", "/saved_page.js" }) |path| {
        if ((try get(w.a, w.port(), path, x.quin)).status != 404) return error.SaveScriptServed;
    }
}

/// Pip's conversation with Quin, for the steps on a conversation's page.
var conversing: ?[]const u8 = null;

/// **REACTIONS** (`POST .../react`, app/Reactions.roc): a reaction turns
/// one emoji on or off on one message, a `204`; every page's stream gets
/// the message's chips drawn again from the whole fold (`event:
/// reaction`), each chip naming its people (ids for the page to mark the
/// viewer's own, and names), the last event of each person and emoji
/// winning, an emoji with no one left gone; the page and its earlier pages
/// draw each bubble's chips. A line cut short at the file's end does not
/// spoil the next reaction. An emoji not one glyph's shape, or a bad n, a
/// 400 in the old words, no such message among them; `on` left out is on;
/// a stranger 404, signed out 401, a key 403, a GET 405.
fn reactionsLive(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    const base = "/chat/channel/Orchard/Banana";
    const l = try Listener.open(w.a, w.port(), base ++ "/stream?after=1", x.pip, "");
    defer l.close();
    if ((try request(w.a, w.port(), "POST", base ++ "/react", x.quin, "msg=1&emoji=%F0%9F%91%8D&on=1")).status != 204) return error.NotReacted;
    const one = try std.fmt.allocPrint(w.a, "event: reaction\ndata: <div class=chat-reactions data-n=1><button type=button class=chat-react-chip data-emoji=\"👍\" data-by=\"human:{s}\" data-names=\"Person 1041\">👍 1</button></div>\n\n", .{x.q});
    try l.until("👍 1</button>");
    if (!has(l.got.items, one)) return error.LiveChipsWrong;
    // Kept as the old app kept it: one JSON line, its six fields in the old order.
    const file = "chat/channels/orchard/topics/banana/reactions.jsonl";
    var buf: [8192]u8 = undefined;
    const first = try w.rig.data.readFile(io, file, &buf);
    const line_head = try std.fmt.allocPrint(w.a, "{{\"msg\":1,\"uid\":\"human:{s}\",\"from\":\"Person 1041\",\"emoji\":\"👍\",\"on\":true,\"at\":\"20", .{x.q});
    if (!std.mem.startsWith(u8, first, line_head) or !std.mem.endsWith(u8, first, "Z\"}\n") or std.mem.count(u8, first, "\n") != 1) return error.ReactionLineWrong;
    // Pip on it too, then a second emoji; Quin off the first.
    if ((try request(w.a, w.port(), "POST", base ++ "/react", x.pip, "msg=1&emoji=%F0%9F%91%8D&on=1")).status != 204) return error.NotReacted;
    try l.until("👍 2</button>");
    if (!has(l.got.items, try std.fmt.allocPrint(w.a, "data-by=\"human:{s} human:{s}\" data-names=\"Person 1041, " ++ pip_name_escaped ++ "\">👍 2</button>", .{ x.q, x.p }))) return error.LiveChipsWrong;
    if ((try request(w.a, w.port(), "POST", base ++ "/react", x.pip, "msg=1&emoji=%F0%9F%8E%89&on=1")).status != 204) return error.NotReacted;
    try l.until("🎉 1</button>");
    if ((try request(w.a, w.port(), "POST", base ++ "/react", x.quin, "msg=1&emoji=%F0%9F%91%8D&on=0")).status != 204) return error.NotReacted;
    const after = try std.fmt.allocPrint(w.a, "data-n=1><button type=button class=chat-react-chip data-emoji=\"👍\" data-by=\"human:{s}\" data-names=\"" ++ pip_name_escaped ++ "\">👍 1</button><button type=button class=chat-react-chip data-emoji=\"🎉\" data-by=\"human:{s}\"", .{ x.p, x.p });
    try l.until(after);
    // The earlier page draws message 1's chips; a bubble with none an empty strip.
    const earlier = (try get(w.a, w.port(), base ++ "/earlier?before=3", x.quin)).body;
    if (!has(earlier, after) or !has(earlier, "<div class=chat-reactions data-n=2></div>")) return error.PageChipsWrong;
    // Pip's 🎉 off: the emoji gone from the strip.
    if ((try request(w.a, w.port(), "POST", base ++ "/react", x.pip, "msg=1&emoji=%F0%9F%8E%89&on=0")).status != 204) return error.NotReacted;
    try l.until(try std.fmt.allocPrint(w.a, "data-names=\"" ++ pip_name_escaped ++ "\">👍 1</button></div>\n\n", .{}));
    // A line cut short at the file's end does not spoil the next one.
    const kept = try w.rig.data.readFile(io, file, &buf);
    try put(w.rig.data, file, try std.fmt.allocPrint(w.a, "{s}{{\"msg\":2,\"uid\":\"hu", .{kept}));
    if ((try request(w.a, w.port(), "POST", base ++ "/react", x.quin, "msg=2&emoji=%F0%9F%94%A5&on=1")).status != 204) return error.TornSpoiled;
    const healed = (try get(w.a, w.port(), base ++ "/earlier?before=3", x.quin)).body;
    const only_pips = try std.fmt.allocPrint(w.a, "data-n=1><button type=button class=chat-react-chip data-emoji=\"👍\" data-by=\"human:{s}\" data-names=\"" ++ pip_name_escaped ++ "\">👍 1</button></div>", .{x.p});
    if (!has(healed, "data-n=2><button type=button class=chat-react-chip data-emoji=\"🔥\"") or !has(healed, only_pips)) return error.TornSpoiled;

    // Refusals.
    for ([_][]const u8{ "msg=1&emoji=x", "msg=1&emoji=%F0%9F%91%8D%F0%9F%91%8D%F0%9F%91%8D%F0%9F%91%8D%F0%9F%91%8D", "msg=1&emoji=%F0%9F%91%8D+", "msg=1", "msg=x&emoji=%F0%9F%91%8D", "emoji=%F0%9F%91%8D" }) |form| {
        const bad = try request(w.a, w.port(), "POST", base ++ "/react", x.quin, form);
        if (bad.status != 400 or !std.mem.startsWith(u8, bad.body, "react: ")) return error.BadReactionTaken;
    }
    // No such message: the old 400, in its words.
    const none = try request(w.a, w.port(), "POST", base ++ "/react", x.quin, "msg=9999&emoji=%F0%9F%91%8D");
    if (none.status != 400 or !std.mem.eql(u8, none.body, "react: no such message\n")) return error.NoMessageReacted;
    // `on` left out is on, as the old form read it.
    if ((try request(w.a, w.port(), "POST", base ++ "/react", x.quin, "msg=2&emoji=%F0%9F%91%80")).status != 204) return error.NotReacted;
    try l.until("👀 1</button>");
    if ((try request(w.a, w.port(), "POST", base ++ "/react", x.rue, "msg=1&emoji=%F0%9F%91%8D")).status != 404) return error.StrangerReacted;
    if ((try request(w.a, w.port(), "POST", base ++ "/react", "", "msg=1&emoji=%F0%9F%91%8D")).status != 401) return error.NobodyReacted;
    if ((try send(w.a, w.port(), "POST", base ++ "/react", .{ .key = x.pal_key }, "msg=1&emoji=%F0%9F%91%8D")).status != 403) return error.KeyReacted;
    if ((try get(w.a, w.port(), base ++ "/react", x.quin)).status != 405) return error.ReactByGet;
    if ((try get(w.a, w.port(), "/reactions.js", x.quin)).status != 200) return error.NoScript;
}

/// A PNG's opening bytes and a little after: what the server sniffs.
const png_bytes = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";

/// The compose box's form with one file, as a browser sends it: its body,
/// and the Content-Type naming its boundary.
fn uploadForm(a: std.mem.Allocator, part: []const u8, filename: []const u8, data: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "--XyZ\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\nContent-Type: image/png\r\n\r\n{s}\r\n--XyZ--\r\n", .{ part, filename, data });
}
const upload_type = "multipart/form-data; boundary=XyZ";

/// The URL an upload's answer names, from its JSON.
fn uploadUrl(body: []const u8) ![]const u8 {
    const key = "{\"url\":\"";
    if (!std.mem.startsWith(u8, body, key)) return error.NoUrl;
    const end = std.mem.indexOfScalarPos(u8, body, key.len, '"') orelse return error.NoUrl;
    return body[key.len..end];
}

/// **UPLOADS** (app/Uploads.roc, UploadPage.roc, the old chat_upload.zig):
/// the compose box's form, its one part `file`, an image by its bytes, kept
/// in the topic's folder by a fresh name of 32 hex digits and the
/// extension its bytes give, its uploader's bytes counted in decimal; the
/// answer its URL, under its topic's page (`.../uploads/<name>`), and the
/// browser's name. Served to the topic's readers alone, by that one URL
/// (a DM's the same for both its humans, kept under `chat/dms/<pair>`),
/// from its own topic's folder alone (another topic's path for its name
/// finds nothing; the old `/chat/uploads/...` is gone), its type by its extension,
/// `nosniff`, kept for good; posted, the renderer draws it. Refusals in
/// the old words: no file a 400, not an image a 415, past 10 MiB a 413,
/// past the allowance a 403 (nothing kept, nothing counted); a stranger
/// 404s to the upload and to the image, signed out a 401, a key a 403 to
/// both (an image is its page's, a browser's), a GET of the upload a 405.
fn uploads(w: *World) !void {
    const x = browsing orelse return error.NoBrowsing;
    const base = "/chat/channel/Orchard/Banana";
    const typed: Credential = .{ .cookie = x.quin, .content_type = upload_type };
    const up = try send(w.a, w.port(), "POST", base ++ "/upload", typed, try uploadForm(w.a, "file", "cat.png", png_bytes));
    if (up.status != 200 or !std.mem.startsWith(u8, up.header("content-type") orelse "", "application/json")) return error.NotUploaded;
    const url = try uploadUrl(up.body);
    const prefix = base ++ "/uploads/";
    if (!std.mem.startsWith(u8, url, prefix) or url.len != prefix.len + 32 + 4 or !std.mem.endsWith(u8, url, ".png")) return error.UploadUrlWrong;
    for (url[prefix.len .. prefix.len + 32]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return error.UploadUrlWrong;
    if (!std.mem.endsWith(u8, up.body, ",\"name\":\"cat.png\",\"kind\":\"image\",\"width\":0,\"height\":0}")) return error.UploadAnswerWrong;
    // Kept in the topic's folder as uploaded; the bytes counted, in decimal.
    var buf: [256]u8 = undefined;
    const kept = try w.rig.data.readFile(io, try std.fmt.allocPrint(w.a, "chat/channels/orchard/topics/banana/uploads/{s}", .{url[prefix.len..]}), &buf);
    if (!std.mem.eql(u8, kept, png_bytes)) return error.UploadNotKept;
    const counted_path = try std.fmt.allocPrint(w.a, "chat/upload-bytes/{s}", .{x.q});
    if (!std.mem.eql(u8, try w.rig.data.readFile(io, counted_path, &buf), try std.fmt.allocPrint(w.a, "{d}", .{png_bytes.len}))) return error.UploadNotCounted;

    // Served to a reader: its bytes, its type, nosniff, kept for good.
    const seen = try get(w.a, w.port(), url, x.pip);
    if (seen.status != 200 or !std.mem.eql(u8, seen.body, png_bytes) or !std.mem.eql(u8, seen.header("content-type") orelse "", "image/png")) return error.UploadNotServed;
    if (!std.mem.eql(u8, seen.header("x-content-type-options") orelse "", "nosniff") or !std.mem.eql(u8, seen.header("cache-control") orelse "", "private, max-age=31536000, immutable")) return error.UploadHeadersWrong;
    // A stranger, a name no upload has: the one 404; signed out a 401; a
    // key a 403, as for every page (an image is the page's, a browser's).
    if ((try get(w.a, w.port(), url, x.rue)).status != 404) return error.StrangerSawUpload;
    if ((try send(w.a, w.port(), "GET", url, .{ .key = x.pal_key }, "")).status != 403) return error.KeySawUpload;
    if ((try get(w.a, w.port(), prefix ++ "00000000000000000000000000000000.png", x.pip)).status != 404) return error.NoUploadServed;
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/channel/Orchard/apple/uploads/{s}", .{url[prefix.len..]}), x.pip)).status != 404) return error.UploadInAnotherTopic;
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/uploads/orchard/banana/{s}", .{url[prefix.len..]}), x.pip)).status != 404) return error.OldUploadUrlServed;
    if ((try get(w.a, w.port(), url, "")).status != 401) return error.NobodySawUpload;
    // Posted, the renderer draws it.
    const posted = try send(w.a, w.port(), "POST", base ++ "/send", .{ .cookie = x.quin }, try std.fmt.allocPrint(w.a, "<img src=\"{s}\" alt=\"cat.png\">", .{url}));
    if (posted.status != 201 or !has(posted.body, try std.fmt.allocPrint(w.a, "<img src=\"{s}\" alt=\"cat.png\">", .{url}))) return error.UploadNotDrawn;

    // A DM's: one URL for both its humans; a third human never reaches it.
    const pq = try pairOf(w.a, x.p, x.q);
    const dm_up = try send(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat/upload", .{pq}), .{ .cookie = x.pip, .content_type = upload_type }, try uploadForm(w.a, "file", "dm.png", png_bytes));
    if (dm_up.status != 200) return error.DmNotUploaded;
    const dm_url = try uploadUrl(dm_up.body);
    const dm_prefix = try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat/uploads/", .{pq});
    if (!std.mem.startsWith(u8, dm_url, dm_prefix)) return error.DmUrlWrong;
    const dm_kept = try w.rig.data.readFile(io, try std.fmt.allocPrint(w.a, "chat/dms/{s}/topics/chitchat/uploads/{s}", .{ pq, dm_url[dm_prefix.len..] }), &buf);
    if (!std.mem.eql(u8, dm_kept, png_bytes)) return error.DmUploadNotKept;
    if ((try get(w.a, w.port(), try std.fmt.allocPrint(w.a, "/chat/dm/{s}/ChitChat/uploads/{s}", .{ try pairBackwards(w.a, x.p, x.q), dm_url[dm_prefix.len..] }), x.pip)).status != 404) return error.BackwardsPairUpload;
    if ((try get(w.a, w.port(), dm_url, x.quin)).status != 200 or (try get(w.a, w.port(), dm_url, x.pip)).status != 200) return error.DmUploadNotServed;
    if ((try get(w.a, w.port(), dm_url, x.rue)).status != 404) return error.StrangerSawDmUpload;

    // Refusals, in the old words; nothing counted for any of them.
    const counted = try std.fmt.allocPrint(w.a, "{s}", .{try w.rig.data.readFile(io, counted_path, &buf)});
    const text = try send(w.a, w.port(), "POST", base ++ "/upload", typed, try uploadForm(w.a, "file", "a.txt", "hello, not an image"));
    if (text.status != 415 or !std.mem.eql(u8, text.body, "unsupported file type (images: png, jpeg, gif, webp)\n")) return error.TextUploaded;
    const other = try send(w.a, w.port(), "POST", base ++ "/upload", typed, try uploadForm(w.a, "other", "cat.png", png_bytes));
    if (other.status != 400 or !std.mem.eql(u8, other.body, "no file\n")) return error.FieldlessUploaded;
    if ((try send(w.a, w.port(), "POST", base ++ "/upload", .{ .cookie = x.quin }, try uploadForm(w.a, "file", "cat.png", png_bytes))).status != 400) return error.BoundlessUploaded;
    const huge = try w.a.alloc(u8, 10 * 1024 * 1024 + 1);
    @memcpy(huge[0..png_bytes.len], png_bytes);
    @memset(huge[png_bytes.len..], 0);
    const big = try send(w.a, w.port(), "POST", base ++ "/upload", typed, try uploadForm(w.a, "file", "big.png", huge));
    if (big.status != 413 or !std.mem.eql(u8, big.body, "image too large — the limit is 10 MB.\n")) return error.HugeUploaded;
    if (!std.mem.eql(u8, try w.rig.data.readFile(io, counted_path, &buf), counted)) return error.RefusalCounted;
    // Past the allowance: refused, nothing kept or counted; just under it, kept.
    try put(w.rig.data, counted_path, try std.fmt.allocPrint(w.a, "{d}", .{1024 * 1024 * 1024 - png_bytes.len + 1}));
    const over = try send(w.a, w.port(), "POST", base ++ "/upload", typed, try uploadForm(w.a, "file", "cat.png", png_bytes));
    if (over.status != 403 or !std.mem.eql(u8, over.body, "Upload limit reached — you've used your 1 GB upload allowance.\n")) return error.OverAllowance;
    try put(w.rig.data, counted_path, try std.fmt.allocPrint(w.a, "{d}", .{1024 * 1024 * 1024 - png_bytes.len}));
    if ((try send(w.a, w.port(), "POST", base ++ "/upload", typed, try uploadForm(w.a, "file", "cat.png", png_bytes))).status != 200) return error.AllowanceEdgeRefused;
    if (!std.mem.eql(u8, try w.rig.data.readFile(io, counted_path, &buf), "1073741824")) return error.AllowanceEdgeNotCounted;
    // Who may: a stranger 404, signed out 401, a key 403, a GET 405.
    if ((try send(w.a, w.port(), "POST", base ++ "/upload", .{ .cookie = x.rue, .content_type = upload_type }, try uploadForm(w.a, "file", "cat.png", png_bytes))).status != 404) return error.StrangerUploaded;
    if ((try send(w.a, w.port(), "POST", base ++ "/upload", .{ .content_type = upload_type }, try uploadForm(w.a, "file", "cat.png", png_bytes))).status != 401) return error.NobodyUploaded;
    if ((try send(w.a, w.port(), "POST", base ++ "/upload", .{ .key = x.pal_key, .content_type = upload_type }, try uploadForm(w.a, "file", "cat.png", png_bytes))).status != 403) return error.KeyUploaded;
    if ((try get(w.a, w.port(), base ++ "/upload", x.quin)).status != 405) return error.UploadByGet;
    if ((try get(w.a, w.port(), "/upload.js", x.quin)).status != 200) return error.NoScript;
}

/// How many entries the data root's folder `path` holds; none when it is not there.
fn filesIn(w: *World, path: []const u8) !usize {
    var dir = w.rig.data.openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    return n;
}

/// Whether the data root has a file at `path`.
fn onDisk(w: *World, path: []const u8) bool {
    var buf: [65536]u8 = undefined;
    _ = w.rig.data.readFile(io, path, &buf) catch return false;
    return true;
}

/// **A HUMAN ERASED** (app/Erase.roc, UsersPage.roc, Store.erase!): an
/// admin's users page lists every human, each with a Remove button (its
/// are-you-sure the page's script's) or why not: oneself, an admin, one in
/// a channel or whose agent is. Removed: their DMs whole (both sides, their
/// images too), their agents and their keys' use, their sessions and
/// upload count;
/// their name free for someone new; anyone else's things untouched. A
/// second time, a 404. Who may: an admin by session; another human 403,
/// a key 403, signed out 401 (the page a 303), a foreign Origin 403, a GET
/// of the removal 405.
fn eraseHuman(w: *World) !void {
    const xena = try signUpAs(w.a, w.port(), 1080, "Xena+Throw");
    const yuri = try signUp(w.a, w.port(), 1081);
    const zack = try signUp(w.a, w.port(), 1082);
    const x = try hid(w.a, 1080);
    const y = try hid(w.a, 1081);
    const z = try hid(w.a, 1082);
    // Zack is in a channel; Yuri's agent is in one: neither may go.
    if ((try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name=Keep&members=human%3A{s}", .{z}))).status != 201) return error.ChannelNotMade;
    const yuri_agent = try ownAgent(w, yuri, "Yuri+Bot", "");
    if ((try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name=KeepToo&members={s}", .{yuri_agent.id}))).status != 201) return error.ChannelNotMade;
    // Xena: a DM with Yuri, both posting, an image; her self-DM; an agent with a key.
    const xy = try pairOf(w.a, x, y);
    if ((try pagePost(w, xena, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{xy}), "topic=hi")).status != 303) return error.DmNotMade;
    const dm_page = try std.fmt.allocPrint(w.a, "/chat/dm/{s}/hi", .{xy});
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "{s}/send", .{dm_page}), xena, "hello Yuri")).status != 201) return error.NotSent;
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "{s}/send", .{dm_page}), yuri, "hello Xena")).status != 201) return error.NotSent;
    if ((try send(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "{s}/upload", .{dm_page}), .{ .cookie = xena, .content_type = upload_type }, try uploadForm(w.a, "file", "x.png", png_bytes))).status != 200) return error.NotUploaded;
    const xx = try pairOf(w.a, x, x);
    if ((try pagePost(w, xena, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{xx}), "topic=notes")).status != 303) return error.DmNotMade;
    const xena_agent = try ownAgent(w, xena, "Xena+Bot", "");
    // Zack's key comes after Xena's: erasing hers must not hand out its id again.
    const zack_agent = try ownAgent(w, zack, "Zack+Bot", "");
    // Yuri's own self-DM, to stay.
    const yy = try pairOf(w.a, y, y);
    if ((try pagePost(w, yuri, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{yy}), "topic=mine")).status != 303) return error.DmNotMade;

    // The page: Xena's Remove button, naming her; why not for the rest.
    const page = try get(w.a, w.port(), "/chat/users", w.ivy);
    if (page.status != 200) return error.NoUsersPage;
    if (!has(page.body, try std.fmt.allocPrint(w.a, "<form class=erase method=post action=\"/chat/users/{s}/remove\" data-name=\"Xena Throw\"><button>Remove</button></form>", .{x}))) return error.NoRemoveButton;
    if (!has(page.body, try std.fmt.allocPrint(w.a, "<li data-human={s}>Person 1082 (<code>human:{s}</code>) <span class=muted>in a channel: Keep</span>", .{ z, z }))) return error.ChannelMemberRemovable;
    if (!has(page.body, try std.fmt.allocPrint(w.a, "<li data-human={s}>Person 1081 (<code>human:{s}</code>) <span class=muted>in a channel: KeepToo</span>", .{ y, y }))) return error.AgentOwnerRemovable;
    if (!has(page.body, "<span class=muted>you cannot remove yourself</span>") or !has(page.body, "<script src=\"/users_page.js\"></script>")) return error.UsersPageWrong;
    if (!has((try get(w.a, w.port(), "/chat", w.ivy)).body, "<a href=\"/chat/users\">Users (an admin's)</a>")) return error.NoUsersLink;
    if (has((try get(w.a, w.port(), "/chat", yuri)).body, "/chat/users")) return error.UsersLinkForAll;

    // Who may not: another human, a key, nobody, a foreign Origin, a GET.
    const remove_x = try std.fmt.allocPrint(w.a, "/chat/users/{s}/remove", .{x});
    if ((try get(w.a, w.port(), "/chat/users", yuri)).status != 403 or (try get(w.a, w.port(), "/chat/users", zack)).status != 403) return error.MemberSawUsers;
    if ((try pagePost(w, yuri, remove_x, "")).status != 403) return error.MemberRemoved;
    if ((try send(w.a, w.port(), "POST", remove_x, .{ .key = xena_agent.key }, "")).status != 403) return error.KeyRemoved;
    if ((try request(w.a, w.port(), "POST", remove_x, "", "")).status != 401) return error.NobodyRemoved;
    if ((try get(w.a, w.port(), "/chat/users", "")).status != 303) return error.NobodySawUsers;
    if ((try send(w.a, w.port(), "POST", remove_x, .{ .cookie = w.ivy, .origin = "https://evil.test" }, "")).status != 403) return error.ForeignOriginRemoved;
    if ((try get(w.a, w.port(), remove_x, w.ivy)).status != 405) return error.RemovedByGet;
    // Who may not be: one in a channel, one whose agent is, nobody's id.
    const zack_no = try pagePost(w, w.ivy, try std.fmt.allocPrint(w.a, "/chat/users/{s}/remove", .{z}), "");
    if (zack_no.status != 409 or !std.mem.eql(u8, zack_no.body, "in a channel: Keep\n")) return error.ChannelMemberRemoved;
    if ((try pagePost(w, w.ivy, try std.fmt.allocPrint(w.a, "/chat/users/{s}/remove", .{y}), "")).status != 409) return error.AgentOwnerRemoved;
    if ((try pagePost(w, w.ivy, "/chat/users/999999/remove", "")).status != 404) return error.NobodyErased;
    if (!onDisk(w, try std.fmt.allocPrint(w.a, "chat/dms/{s}/channel", .{xy}))) return error.ErasedEarly;

    // Erased: back to the page, and every trace of her gone, her agent's key
    // and its invite too, and nobody else's.
    const keys_before = try filesIn(w, "auth/keys");
    const invites_before = try filesIn(w, "auth/invites");
    const gone = try pagePost(w, w.ivy, remove_x, "");
    if (gone.status != 303 or !std.mem.eql(u8, gone.header("location") orelse "", "/chat/users")) return error.NotErased;
    if ((try get(w.a, w.port(), "/me", xena)).status != 401) return error.SessionLived;
    if ((try send(w.a, w.port(), "GET", "/dms", .{ .key = xena_agent.key }, "")).status != 401) return error.AgentKeyLived;
    if (try filesIn(w, "auth/keys") != keys_before - 1 or try filesIn(w, "auth/invites") != invites_before - 1) return error.KeysOrInvitesLived;
    // A key minted now takes an id past every one still held.
    const later = try ownAgent(w, yuri, "Yuri+Two", "");
    if (try std.fmt.parseInt(u64, later.key_id, 10) <= try std.fmt.parseInt(u64, zack_agent.key_id, 10)) return error.KeyIdGivenTwice;
    if (onDisk(w, try std.fmt.allocPrint(w.a, "chat/dms/{s}/channel", .{xy})) or onDisk(w, try std.fmt.allocPrint(w.a, "chat/dms/{s}/topics/hi/transcript", .{xy})) or onDisk(w, try std.fmt.allocPrint(w.a, "chat/dms/{s}/channel", .{xx}))) return error.DmLived;
    var buf: [256]u8 = undefined;
    if (w.rig.data.readFile(io, try std.fmt.allocPrint(w.a, "chat/dms/{s}", .{xy}), &buf)) |_| return error.DmFolderLived else |_| {}
    if (onDisk(w, try std.fmt.allocPrint(w.a, "chat/upload-bytes/{s}", .{x}))) return error.OwnFilesLived;
    if ((try get(w.a, w.port(), dm_page, yuri)).status != 404) return error.DmPageLived;
    if (has((try get(w.a, w.port(), "/chat/users", w.ivy)).body, "Xena Throw")) return error.StillListed;
    // Nobody else's things: Yuri, his agent, his self-DM, Zack's channel.
    if ((try get(w.a, w.port(), "/me", yuri)).status != 200) return error.OtherSessionGone;
    if ((try send(w.a, w.port(), "GET", "/dms", .{ .key = yuri_agent.key }, "")).status != 200) return error.OtherKeyGone;
    if (!onDisk(w, try std.fmt.allocPrint(w.a, "chat/dms/{s}/channel", .{yy})) or !onDisk(w, "chat/channels/keep/channel")) return error.OtherPlaceGone;
    // Her name is free for someone new; a second removal finds no one.
    if ((try pagePost(w, w.ivy, remove_x, "")).status != 404) return error.ErasedTwice;
    _ = try signUpAs(w.a, w.port(), 1083, "Xena+Throw");
}

const steps = [_]Step{
    .{ .name = "A and B sign in (and C, the third user)", .f = signIn },
    .{ .name = "A and B's topic: Ivy makes their channel, Talk, and A its topic, general", .f = start },
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
    .{ .name = "the agent, by key alone, makes a topic in its channel with Steve and posts; Steve's stream gets it once", .f = agentStarts },
    .{ .name = "Steve posts, and the agent reads it with its key", .f = agentReads },
    .{ .name = "each message names the channel's members its markdown mentions, as words, by their names now, and not in what it quotes", .f = mentions },
    .{ .name = "the agent's key cannot mint a key, nor make an agent", .f = keyCannotMint },
    .{ .name = "Steve revokes the key, and its next use is a 401", .f = revoke },
    .{ .name = "an expired key is a 401", .f = expired },
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
    .{ .name = "a message's HTML on the page is exactly step 6's for it", .f = pageHtml },
    .{ .name = "a human's twenty-first agent is refused", .f = agentsCapped },
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
    .{ .name = "a human past the keys cap is refused, by name", .f = keysCapped },
    .{ .name = "a human past the invites cap is refused, by name", .f = invitesCapped },
    .{ .name = "a message's media loads only from the chat's uploads", .f = mediaFromUploads },
    .{ .name = "the agents page lists the viewer's agents, and no one else's", .f = agentsPageOwn },
    .{ .name = "an agent made as the agents page's form does is listed there", .f = agentMadeFromPage },
    .{ .name = "an invite's code is in its answer alone; the page lists the invite, never a code", .f = inviteFromPage },
    .{ .name = "a key and an invite revoked from the page are gone from it", .f = revokeFromPage },
    .{ .name = "another human sees none of it on their page, and revokes none of it", .f = othersSeeNoneOnPage },
    .{ .name = "a key asking for the agents page is a 403", .f = agentsPageRefusesKey },
    .{ .name = "an invite redeemed with format=secret answers the secret alone, and it works; an unknown format spends nothing", .f = redeemSecretAlone },
    .{ .name = "an agent's post says its kind and its owner, though it took a look-alike of its owner's name; a human's says no owner", .f = authorKind },
    .{ .name = "an admin makes channels, linked from /chat for her alone; the channels page lists them by key, with their members", .f = adminMakesChannel },
    .{ .name = "a human who is no admin is refused the channels page and each channel write; signed out, a 303 and a 401", .f = memberRefusedChannels },
    .{ .name = "a key, even an admin's own, is refused the channels page and each channel write", .f = keyRefusedChannels },
    .{ .name = "admit and remove change a channel's members, an agent as a human; one already in, one not in, no account and no channel refused by name", .f = admitRemove },
    .{ .name = "a channel's name is taken in any spelling", .f = takenName },
    .{ .name = "every channel change, and every refusal of a named asker, is audited, with no secret", .f = channelsAudited },
    .{ .name = "an agent named as a look-alike of its owner comes with its owner's login, and the page labels it so, in both renderers", .f = loginBeside },
    .{ .name = "a human signing up as a name another holds, in any case and spacing, is refused; a near miss is signed up", .f = humanNameTaken },
    .{ .name = "an agent named as a human, or as another agent, in any case, is a 409; a near miss is made", .f = agentNameTaken },
    .{ .name = "one stream per agent: each post in its channels' topics, naming the channel and topic, never another channel's; resumed with Last-Event-ID, what came meanwhile and nothing twice; a session and a human's key refused", .f = agentStream },
    .{ .name = "the one stream is one of the agent's streams under the cap, and ends at its lifetime once its key is revoked", .f = agentStreamHeld },
    .{ .name = "a member makes a channel's topic, posts with its reference, another member reads and streams it; a stranger, nobody, and an agent not in the channel are refused", .f = topicsMade },
    .{ .name = "an agent in a channel: by key it reads, posts in and makes topics, its one stream gets every topic's posts naming channel, topic and reference, and resumes; a human not in it refused until let in; an agent not in it never", .f = agentMember },
    .{ .name = "a human DM: the pair's one, whichever asks; its topics' references short; a third human never reaches it; with oneself, a self-DM of one, another never reaching it; an agent, nobody refused; never a channel", .f = humanDm },
    .{ .name = "a human invite: her name held at once, the welcome in their DM, the code in its answer alone; she joins on the plain page under another free name, reads and answers; the code once; again by her inviter or an admin alone; revoked, expired and past ten open refused; audited without the code", .f = humanInvited },
    .{ .name = "an agent's owner renames it: a free name, its old name freed; another's in another spelling, a 409; its own in a new spelling, taken; another human or a key, a 403; each audited", .f = agentRenamed },
    .{ .name = "Browse: every human as a DM by numeric id, oneself too (a self-DM, a topic of one's own made from it), then channels in raw byte order, each with the topics they read in byte order, a channel they are not in not among them; a human with no DM has a button that makes one; empty places said; the top bar marks Browse; signed out a 303, a key a 403", .f = browse },
    .{ .name = "a topic's page: server-rendered bubbles with author, number, name as text and markdown, its viewer and stream named, the right pane empty, the old titles; a stranger, another channel's topic and none a 404, the page saying why without naming a channel the viewer is not in; the JSON routes alike; signed out a 303 and a 401, a key a 403", .f = topicPage },
    .{ .name = "a topic page's stream sends each later post as the page's own bubble, after ?after= and resumed by Last-Event-ID, nothing twice; a bad resume point a 400; the agents' JSON stream unchanged; the scripts served beside chat-client's", .f = topicPageStream },
    .{ .name = "past a page of messages, the Earlier button shows, and the page before comes as a fragment of bubbles saying whether more come before; a page far behind gets a gap; a before= that is no id a 400", .f = topicPageEarlier },
    .{ .name = "the compose box sends: a 201 with the new message's bubble, the same the stream sends, stored once; refusals the post's own (not UTF-8 a 400, a stranger and another channel's topic 404, a key 403, signed out 401, a foreign Origin 403, a GET 405); a DM's box to its topic", .f = composeSends },
    .{ .name = "Recent: one tile per topic the viewer reads, by its last message, newest first, an empty topic last, You or a first name and the old excerpt, a channel they are not in not there; Nothing yet for none; live, each post's tile to each reader drawn for them and to no one else, a channel's to its members and not another's; signed out a 303 and a 401, a key a 403", .f = recentFeed },
    .{ .name = "quote-reply and edit: both links on every bubble; a quote under its reference, you or I said, its fence longer than any inside, a DM's short; an edit one's own alone; posted, the original redrawn live, in a resumed backlog and on its earlier page, another's edit ordinary; bad n a 400, no message a 404, a stranger 404, signed out 401, a key 403, a POST 405", .f = quoteEdit },
    .{ .name = "no saves: no save route, no reading list page, no Saved link, no save button, no save script", .f = noSaves },
    .{ .name = "Steve's path: Browse, the other human's Add topic form, a topic named, the browser on its empty page, a message sent, seen by both; a channel member adds a topic the same way; a stranger, a key, nobody and a name that is no topic name refused", .f = stevesPath },
    .{ .name = "one namespace for channels and users: no channel under a user's name, no human or agent under a channel's, in any case; near misses made", .f = channelNamesTaken },
    .{ .name = "no conversation without a topic: the conversation routes and pages are 404s to a session and a key, Browse has no Conversations, and a key narrowed with only: is no grant; a topic still reads", .f = noConversationKind },
    .{ .name = "one session a browser: an invite opened while signed in is a 409 naming who, unspent, and a fresh browser redeems it; a returning GitHub user signs straight in as themselves, ending the session the browser held and no other; Log out on home and the hello page", .f = oneSessionABrowser },
    .{ .name = "the agents' limit in a topic: an agent's sixteenth post answering agents within the hour is a 429, its own alone counted; an hour-old one no longer counts, and a human's post resets them", .f = topicHops },
    .{ .name = "reactions: one emoji on or off on one message, a 204; every page's stream gets the message's chips drawn again from the fold, each naming its people, the last event of each person and emoji winning, an emptied emoji gone; earlier pages draw them; a torn last line spoils nothing; a bad emoji or msg, or no such message, the old 400; on left out is on; a stranger 404, signed out 401, a key 403, a GET 405", .f = reactionsLive },
    .{ .name = "uploads: an image from the compose box's form, kept in its topic's folder by a fresh name, counted; served to the topic's readers by one URL, a DM's the same for both, nosniff, kept for good, and drawn when posted; not an image, no file, past 10 MiB and past the allowance refused in the old words, nothing counted; a stranger, nobody, a key and a GET refused", .f = uploads },
    .{ .name = "a human erased: the admin's users page, a Remove button or why not (oneself, a channel's member, one whose agent is); removed, their DMs whole, their agents' keys, their sessions and files gone, nobody else's, their name free again; a second time a 404; another human, a key, nobody, a foreign Origin and a GET refused", .f = eraseHuman },
};

/// **STEVE'S PATH**, his acceptance test for the chat: (1) go to Browse,
/// (2) choose Alice, (3) choose a topic name, (4) land on an empty chat with
/// Alice for that topic, (5) type, (6) Send, (7) see the message.
fn stevesPath(w: *World) !void {
    const steve = try signUp(w.a, w.port(), 1062);
    const alice = try signUp(w.a, w.port(), 1063);
    const s = try hid(w.a, 1062);
    const a = try hid(w.a, 1063);
    const sa = try pairOf(w.a, s, a);
    // (1) Browse, and (2) Alice's row: the Add topic form, "general" offered.
    const b = try get(w.a, w.port(), "/chat/browse", steve);
    const form = try std.fmt.allocPrint(w.a, "<form class=add-topic method=post action=\"/chat/dm/{s}\"><input name=topic placeholder=\"new topic\" required value=\"general\">", .{sa});
    if (b.status != 200 or !has(b.body, form)) return error.NoTopicForm;
    // (3) a topic named; (4) the browser lands on its page, empty.
    const made = try pagePost(w, steve, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{sa}), "topic=plans");
    const mine = try std.fmt.allocPrint(w.a, "/chat/dm/{s}/plans", .{sa});
    if (made.status != 303 or !std.mem.eql(u8, made.header("location") orelse "", mine)) return error.NotLandedOnTopic;
    const empty = try get(w.a, w.port(), mine, steve);
    if (empty.status != 200 or !has(empty.body, "No messages yet") or !has(empty.body, "id=chat-form")) return error.TopicNotEmpty;
    // (5, 6) typed and sent; (7) seen on the page, and by Alice on hers.
    if ((try request(w.a, w.port(), "POST", try std.fmt.allocPrint(w.a, "{s}/send", .{mine}), steve, "hello Alice")).status != 201) return error.NotSent;
    if (!has((try get(w.a, w.port(), mine, steve)).body, "hello Alice")) return error.NotSeen;
    if (!has((try get(w.a, w.port(), mine, alice)).body, "hello Alice")) return error.AliceDoesNotSee;
    // The topic is on both Browse pages now, by the one URL, and named twice is a 409.
    if (!has((try get(w.a, w.port(), "/chat/browse", alice)).body, try std.fmt.allocPrint(w.a, "<a href=\"/chat/dm/{s}/plans\">plans</a>", .{sa}))) return error.NotOnBrowse;
    if ((try pagePost(w, steve, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{sa}), "topic=plans")).status != 409) return error.NamedTwice;
    if ((try pagePost(w, steve, try std.fmt.allocPrint(w.a, "/chat/dm/{s}", .{sa}), "topic=no+spaces")).status != 400) return error.BadNameTaken;
    // A channel member adds a topic the same way; a stranger can't.
    const x = browsing orelse return error.NoBrowsing;
    const pears = try pagePost(w, x.quin, "/chat/channel/Orchard", "topic=Pears");
    if (pears.status != 303 or !std.mem.eql(u8, pears.header("location") orelse "", "/chat/channel/Orchard/Pears")) return error.ChannelTopicNotMade;
    if ((try get(w.a, w.port(), "/chat/channel/Orchard/Pears", x.quin)).status != 200) return error.ChannelTopicNoPage;
    if ((try pagePost(w, x.rue, "/chat/channel/Orchard", "topic=Plums")).status == 303) return error.StrangerMadeTopic;
    if ((try pagePost(w, x.quin, "/chat/channel/Orchard", "")).status != 400) return error.UnnamedTopic;
    if ((try send(w.a, w.port(), "POST", "/chat/channel/Orchard", .{ .key = x.pal_key }, "topic=ByKey")).status != 403) return error.KeyMadeTopic;
    if ((try request(w.a, w.port(), "POST", "/chat/channel/Orchard", "", "topic=Nobody")).status != 401) return error.NobodyMadeTopic;
}

/// **ONE NAMESPACE FOR CHANNELS AND USERS** (Accounts.name_holder): an
/// admin's channel under a human's name, in another case, is a 409, and a
/// near miss is made; a human signing up as a channel's name, in another
/// case, gets the form again saying it is taken, and an agent so named is
/// a 409; their near misses are made.
fn channelNamesTaken(w: *World) !void {
    const human = try signUpAs(w.a, w.port(), 1058, "Wrenfield");
    const as_human = try pagePost(w, w.ivy, "/channels", "name=WRENFIELD");
    if (as_human.status != 409 or !has(as_human.body, "that name is taken, by a channel or by someone")) return error.ChannelTookAHumansName;
    if ((try pagePost(w, w.ivy, "/channels", "name=Wrenfield2")).status != 201) return error.NearMissRefused;
    if ((try pagePost(w, w.ivy, "/channels", "name=Harbor")).status != 201) return error.ChannelNotMade;
    const again = try nameFormAnswer(w.a, w.port(), 1059, "harbor");
    if (again.status != 400 or !has(again.body, "That name is taken")) return error.HumanTookAChannelsName;
    if (again.cookie("session") != null) return error.SignedInAnyway;
    const agent = try request(w.a, w.port(), "POST", "/agents", human, "name=HARBOR");
    if (agent.status != 409 or !has(agent.body, "that name is taken")) return error.AgentTookAChannelsName;
    if ((try request(w.a, w.port(), "POST", "/agents", human, "name=Harbor+Pal")).status != 201) return error.NearMissRefused;
    _ = try signUpAs(w.a, w.port(), 1059, "Harbor+2");
}

/// **NO CONVERSATION WITHOUT A TOPIC** (Steve, 2026-11-01): the
/// conversation kind is gone. Its routes are no routes, a session's and a
/// key's alike: no start, read, post or stream under `/conversations`, and
/// no page at `/chat/<id>`; Browse has no Conversations; and a key narrowed
/// to listed resources (`only:`) is no grant. A topic is still read.
fn noConversationKind(w: *World) !void {
    for ([_][]const u8{ "/conversations", "/conversations/1", "/conversations/1/stream", "/chat/1", "/chat/1/stream" }) |path| {
        if ((try get(w.a, w.port(), path, w.ann)).status != 404) return error.ConversationRouteAnswered;
    }
    if ((try request(w.a, w.port(), "POST", "/conversations", w.ann, try std.fmt.allocPrint(w.a, "with=human%3A{s}", .{try hid(w.a, 1002)}))).status != 404) return error.ConversationStarted;
    if ((try request(w.a, w.port(), "POST", "/conversations/1/messages", w.ann, "hello")).status != 404) return error.ConversationPosted;
    // Step 28 retired Steve's first agent: one of this step's own.
    const agent = try field((try request(w.a, w.port(), "POST", "/agents", w.steve, "name=Kindless")).body, "id");
    const k = try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}", .{agent}));
    if ((try send(w.a, w.port(), "GET", "/conversations", .{ .key = k.secret }, "")).status != 404) return error.ConversationListedByKey;
    if (has((try get(w.a, w.port(), "/chat/browse", w.ann)).body, "Conversations")) return error.ConversationsOnBrowse;
    const narrow = try request(w.a, w.port(), "POST", "/invites", w.steve, try std.fmt.allocPrint(w.a, "as={s}&read=only%3A1", .{agent}));
    if (narrow.status != 400 or !has(narrow.body, "is `everywhere` or `off`")) return error.NarrowKeyGranted;
    // A topic still reads, both ways.
    if ((try get(w.a, w.port(), w.topic, w.ann)).status != 200) return error.TopicUnread;
}

/// **A BROWSER HOLDS ONE SESSION, AND SIGNING IN NEVER LEAVES ANOTHER
/// ALIVE** (Steve, 2026-11-01, after an invite's redemption signed him out
/// as Bob): an invite's link opened in a browser signed in already is a
/// 409 that names who is signed in, at the name lookup and at the
/// redemption, and the invite is unspent; a fresh browser redeems it. A
/// returning GitHub user signs in straight to a session, as themselves,
/// with no name form; signing in from a browser signed in as another ends
/// that other's session there (its cookie a 401 after), and leaves the
/// returning user's other browsers signed in. Home and the hello page
/// offer Log out, as the frame's top bar does.
fn oneSessionABrowser(w: *World) !void {
    const sam = try signUpAs(w.a, w.port(), 1057, "Sam+Vale");
    const s = try hid(w.a, 1057);
    const made = try request(w.a, w.port(), "POST", "/human-invites", sam, "name=Jasper");
    if (made.status != 201) return error.NotInvited;
    const code = try field(made.body, "code");
    const form = try std.fmt.allocPrint(w.a, "code={s}", .{code});
    // Sam's own browser, signed in: refused, saying so, and nothing spent.
    const named = try request(w.a, w.port(), "POST", "/join/name", sam, form);
    if (named.status != 409 or !has(named.body, "You're signed in as Sam Vale. Log out first, or open this invite in a private window.")) return error.NameLookupWhileSignedIn;
    const redeemed_signed_in = try request(w.a, w.port(), "POST", "/join", sam, form);
    if (redeemed_signed_in.status != 409 or !has(redeemed_signed_in.body, "You're signed in as Sam Vale.")) return error.JoinedWhileSignedIn;
    const still = try get(w.a, w.port(), "/me", sam);
    if (!has(still.body, try std.fmt.allocPrint(w.a, "signed in as human:{s}\n", .{s}))) return error.SessionOverwritten;
    // A fresh browser redeems it: the invite was never spent.
    const fresh = try request(w.a, w.port(), "POST", "/join", "", form);
    if (fresh.status != 200) return error.InviteSpentByRefusal;
    const jasper = try std.fmt.allocPrint(w.a, "__Host-session={s}", .{fresh.cookie("session") orelse return error.NoSessionCookie});
    if (!has((try get(w.a, w.port(), "/me", jasper)).body, "signed in as human:")) return error.JasperNotSignedIn;

    // Sam signs in again with GitHub, from Jasper's browser: Sam, at once,
    // and Jasper's session there ends; Sam's own browser stays signed in.
    const back = try signInAgain(w.a, w.port(), 1057, jasper);
    if (back.status != 303) return error.ReturningUserNotSignedIn;
    const again = try std.fmt.allocPrint(w.a, "__Host-session={s}", .{back.cookie("session") orelse return error.NoSessionCookie});
    if (!has((try get(w.a, w.port(), "/me", again)).body, try std.fmt.allocPrint(w.a, "signed in as human:{s}\n", .{s}))) return error.NotTheSameHuman;
    if ((try get(w.a, w.port(), "/me", jasper)).status != 401) return error.HeldSessionLives;
    if (!has((try get(w.a, w.port(), "/me", sam)).body, try std.fmt.allocPrint(w.a, "signed in as human:{s}\n", .{s}))) return error.OtherBrowserSignedOut;
    // From a browser holding nothing: Sam again, no name form, no new account.
    const plain = try signInAgain(w.a, w.port(), 1057, "");
    if (plain.status != 303 or has(plain.body, "Your name")) return error.ReturningUserAskedForName;

    // Log out, offered on home and the hello page.
    const log_out = "<form class=logout method=post action=\"/logout\"><button>Log out</button></form>";
    if (!has((try get(w.a, w.port(), "/chat", sam)).body, log_out)) return error.NoLogOutOnHome;
    if (!has((try get(w.a, w.port(), "/", sam)).body, log_out)) return error.NoLogOutOnHello;
    if (has((try get(w.a, w.port(), "/", "")).body, log_out)) return error.LogOutWhenSignedOut;
}

/// **THE AGENTS' LIMIT, IN A TOPIC** (Messages.check_hops!, fifteen
/// an hour, each agent its own): in a channel of Steve and his agents Tick
/// and Tock, Tick answers Tock fifteen times and Tock answers three, Tock's
/// never counting toward Tick's; Tick's sixteenth post, even a status, is
/// a 429 naming the cap, and nothing is stored. An hour on, Tick's fifteen
/// have left the window and it posts again; back at the hour's start they
/// count once more, and a human's post resets them.
fn topicHops(w: *World) !void {
    const tick = try field((try request(w.a, w.port(), "POST", "/agents", w.steve, "name=Tick")).body, "id");
    const tock = try field((try request(w.a, w.port(), "POST", "/agents", w.steve, "name=Tock")).body, "id");
    const tick_key = (try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}", .{tick}))).secret;
    const tock_key = (try agentKey(w, try std.fmt.allocPrint(w.a, "as={s}", .{tock}))).secret;
    if ((try pagePost(w, w.ivy, "/channels", try std.fmt.allocPrint(w.a, "name=Clock&members=human%3A{s}%2C{s}%2C{s}", .{ try hid(w.a, 1004), tick, tock }))).status != 201) return error.ChannelNotMade;
    if ((try request(w.a, w.port(), "POST", "/channels/Clock/topics", w.steve, "name=hops")).status != 201) return error.TopicNotMade;
    const path = "/channels/Clock/topics/hops/messages";
    for (0..15) |i| {
        const text = try std.fmt.allocPrint(w.a, "@Tock hop {d}", .{i + 1});
        if ((try send(w.a, w.port(), "POST", path, .{ .key = tick_key }, text)).status != 201) return error.HopRefused;
        if (i % 5 == 0 and (try send(w.a, w.port(), "POST", path, .{ .key = tock_key }, "@Tick back")).status != 201) return error.OthersHopsCounted;
    }
    const sixteenth = try send(w.a, w.port(), "POST", path, .{ .key = tick_key }, "status: still here");
    if (sixteenth.status != 429) return error.RunawayAccepted;
    if (!has(sixteenth.body, "at most 15 times in 60 minutes") or !has(sixteenth.body, "a human's post resets it")) return error.CapNotNamed;
    const read = try send(w.a, w.port(), "GET", "/channels/Clock/topics/hops", .{ .key = tick_key }, "");
    if (has(read.body, "still here") or !has(read.body, "@Tock hop 15")) return error.RunawayStored;
    // An hour and a second on, on the server's clock: the fifteen are out
    // of the window.
    w.rig.server.clock_ahead_s_for_test.store(3601, .release);
    const later = try send(w.a, w.port(), "POST", path, .{ .key = tick_key }, "@Tock an hour on");
    w.rig.server.clock_ahead_s_for_test.store(0, .release);
    if (later.status != 201) return error.OldHopsCounted;
    if ((try send(w.a, w.port(), "POST", path, .{ .key = tick_key }, "@Tock too soon")).status != 429) return error.RunawayAccepted;
    if ((try request(w.a, w.port(), "POST", path, w.steve, "carry on")).status != 201) return error.HumanRefused;
    if ((try send(w.a, w.port(), "POST", path, .{ .key = tick_key }, "@Tock five")).status != 201) return error.NotLetGoOn;
}

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
