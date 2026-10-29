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
//! Then agents and API keys (the host design's step 7), Steve (a fourth
//! user) and his agent, which holds only a key:
//!
//!  12. Steve makes an agent
//!  13. Steve mints a key for it (and C cannot mint one acting as it)
//!  14. the agent, with only the key, starts a conversation with Steve and
//!      posts; Steve's stream gets the post once
//!  15. Steve posts, and the agent reads it with its key
//!  16. the agent's key cannot mint a key, nor make an agent
//!  17. Steve revokes the key, and its next use is a 401
//!  18. an expired key is a 401
//!  19. a key read-scoped to one conversation cannot post there, nor read
//!      another
//!  20. a session cookie and a Bearer key together are a 400
//!  21. every key refused in use, and every grant refused, is in the audit,
//!      and no secret is
//!
//! Then the pages (QUEUE 315), a browser's view of the same:
//!
//!  22. the list page shows a conversation the viewer is in, and not one
//!      they aren't
//!  23. a participant's name is written escaped (B's holds markup)
//!  24. the conversation page is a 200 to a participant, a 404 to a third user
//!  25. signed out, a page redirects to /login
//!  26. a message's HTML on the page is exactly step 6's for it
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
const Credential = struct { cookie: []const u8 = "", key: []const u8 = "" };

/// One request on a connection of its own, with `credential`.
fn send(a: std.mem.Allocator, port: u16, method: []const u8, target: []const u8, credential: Credential, body: []const u8) !Response {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const cookie_line = if (credential.cookie.len > 0) try std.fmt.allocPrint(a, "cookie: {s}\r\n", .{credential.cookie}) else "";
    const key_line = if (credential.key.len > 0) try std.fmt.allocPrint(a, "authorization: Bearer {s}\r\n", .{credential.key}) else "";
    const text = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nhost: chat.test\r\nconnection: close\r\n{s}{s}content-length: {d}\r\n\r\n{s}", .{ method, target, cookie_line, key_line, body.len, body });
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
    const login = try get(a, port, "/login", "");
    if (login.status != 303) return error.LoginNotARedirect;
    const location = login.header("location") orelse return error.NoLocation;
    const at = std.mem.indexOf(u8, location, "&state=") orelse return error.NoState;
    const state_cookie = try std.fmt.allocPrint(a, "__Host-state={s}", .{login.cookie("state") orelse return error.NoStateCookie});
    const target = try std.fmt.allocPrint(a, "/login/github?code=user-id-{d}&state={s}", .{ n, location[at + "&state=".len ..] });
    const named = try get(a, port, target, state_cookie);
    if (named.status != 200) return error.NoNameForm;
    const both = try std.fmt.allocPrint(a, "{s}; __Host-pending={s}", .{ state_cookie, named.cookie("pending") orelse return error.NoPendingCookie });
    const made = try request(a, port, "POST", "/login/name", both, try std.fmt.allocPrint(a, "name={s}", .{name}));
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
    /// Steve, his agent (`agent:N`), its key's public id and secret, and
    /// the conversation the agent started with him.
    steve: []const u8 = "",
    agent: []const u8 = "",
    key_id: []const u8 = "",
    key: []const u8 = "",
    agents_conv: []const u8 = "",

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

// ── the pages (QUEUE 315) ──

/// B's name holds markup, and the page must write it as text.
const bea_name_form = "Bea+%3Ci%3Ex%3C%2Fi%3E+%26+%22co%22";
const bea_name_raw = "Bea <i>x</i> & \"co\"";
const bea_name_escaped = "Bea &lt;i&gt;x&lt;/i&gt; &amp; &quot;co&quot;";

fn listPage(w: *World) !void {
    // A conversation A is not in: C's, with B.
    const other = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.cal, "with=human%3A1002"));
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
}

fn signedOutPage(w: *World) !void {
    for ([_][]const u8{ "/chat", try std.fmt.allocPrint(w.a, "/chat/{s}", .{w.conv}) }) |target| {
        const r = try get(w.a, w.port(), target, "");
        if (r.status != 303) return error.NotARedirect;
        if (!std.mem.eql(u8, r.header("location") orelse "", "/login")) return error.NotToLogin;
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
    if (!std.mem.eql(u8, try field(r.body, "owner"), "human:1004")) return error.NotSteves;
}

fn mintForAgent(w: *World) !void {
    const form = try std.fmt.allocPrint(w.a, "as={s}", .{w.agent});
    // C, another human, is no owner of Steve's agent.
    if ((try request(w.a, w.port(), "POST", "/keys", w.cal, form)).status != 403) return error.MintedForAnothersAgent;
    const k = try mint(w, form);
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
    const started = try send(w.a, w.port(), "POST", "/conversations", .{ .key = w.key }, "with=human%3A1004");
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
    if (!has(r.body, "\"by\":\"human:1004\",\"markdown\":\"hi CC, it's Steve\"")) return error.NotSeen;
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
    const k = try mint(w, try std.fmt.allocPrint(w.a, "as={s}&lifetime=1", .{w.agent}));
    // Past its one second, on the host's clock of whole seconds.
    sleepMs(2100);
    if ((try send(w.a, w.port(), "GET", try agentPath(w, w.agents_conv, ""), .{ .key = k.secret }, "")).status != 401) return error.ExpiredKeyWorks;
}

fn scoped(w: *World) !void {
    // A second conversation, Steve's with his agent: the one the key reads.
    const x = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.steve, try std.fmt.allocPrint(w.a, "with={s}", .{w.agent})));
    const k = try mint(w, try std.fmt.allocPrint(w.a, "as={s}&read=only%3A{s}&post=off", .{ w.agent, x }));
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
    .{ .name = "Steve makes an agent", .f = makeAgent },
    .{ .name = "Steve mints a key for it (and C cannot)", .f = mintForAgent },
    .{ .name = "the agent, by key alone, starts a conversation with Steve and posts; Steve's stream gets it once", .f = agentStarts },
    .{ .name = "Steve posts, and the agent reads it with its key", .f = agentReads },
    .{ .name = "the agent's key cannot mint a key, nor make an agent", .f = keyCannotMint },
    .{ .name = "Steve revokes the key, and its next use is a 401", .f = revoke },
    .{ .name = "an expired key is a 401", .f = expired },
    .{ .name = "a key read-scoped to one conversation cannot post there, nor read another", .f = scoped },
    .{ .name = "a session cookie and a Bearer key together are a 400", .f = bothCredentials },
    .{ .name = "every key refused in use, and every grant refused, is audited, with no secret", .f = audited },
    .{ .name = "the list page shows a conversation the viewer is in, and not one they aren't", .f = listPage },
    .{ .name = "a participant's name is written escaped", .f = namesEscaped },
    .{ .name = "the conversation page is a 200 to a participant, a 404 to a third user", .f = conversationPage },
    .{ .name = "signed out, a page redirects to /login", .f = signedOutPage },
    .{ .name = "a message's HTML on the page is exactly step 6's for it", .f = pageHtml },
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
        std.debug.print("HOLD port={d} conv={s} ann={s} bea={s}\n", .{ w.port(), w.conv, w.ann, w.bea });
        while (true) sleepMs(1000);
    }
    if (passed == steps.len) {
        std.debug.print("e2e: {d} of {d} passed\n", .{ passed, steps.len });
        return true;
    }
    std.debug.print("e2e: FAILED ({d} of {d} passed)\n", .{ passed, steps.len });
    return false;
}
