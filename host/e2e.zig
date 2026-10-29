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
//! An agent's key comes only from an invite (steps 13, 18 and 19 get theirs
//! so too). Then the invites themselves:
//!
//!  22. Steve invites his agent; the code sent with a cookie is refused, and
//!      the agent, with the code alone, redeems it and posts with the key
//!  23. redeeming the same code again is a 401
//!  24. an invite past its ten minutes is a 401 (the server's clock moved
//!      ahead, `clock_ahead_s_for_test`, never a wait)
//!  25. another human's session cannot invite for Steve's agent
//!  26. a key cannot make an invite
//!  27. a mint acting as an agent is refused; Steve's own key is minted
//!  28. after the agent is retired, its invite redeems to nothing
//!  29. agent ids: make one, retire it (the highest), make another, and its
//!      id is fresh
//!  30. every invite made, redeemed and refused is audited, with no code;
//!      a refusal naming no stored invite is not
//!
//! **A RETIREMENT HERE IS THE TEST'S** (`retire`): no route retires yet, so
//! the step removes the agent's line from the accounts, which is what
//! Admin's plan does to the accounts (RemoveAccount); its keys and votes
//! are no part of what these steps ask.
//!
//! Then the pages (QUEUE 315), a browser's view of the same:
//!
//!  31. the list page shows a conversation the viewer is in, and not one
//!      they aren't
//!  32. a participant's name is written escaped (B's holds markup)
//!  33. the conversation page is a 200 to a participant, a 404 to a third
//!      user; a page is a 403 to a key
//!  34. signed out, a page redirects to /login
//!  35. a message's HTML on the page is exactly step 6's for it
//!
//! Then the security review's fixes (2026-10-29), each its own user:
//!
//!  36. a human's twenty-first agent is refused (Limits.agents_per_human)
//!  37. C cannot name Steve's agent in a new conversation, nor an id no
//!      one holds, and both refusals read the same; Steve can name it
//!  38. a POST with A's cookie from another origin is a 403, and one with
//!      no Origin and no `Sec-Fetch-Site: same-origin` too; nothing is
//!      posted
//!  39. a logout from another origin is refused; from the chat's own, it
//!      ends the session, and the old cookie is a 401
//!  40. a stream ends at its lifetime (`stream_lifetime_ms_for_test`), so a
//!      key revoked while its stream is open stops reaching it
//!  41. junk invite codes, a callback with a forged state and a name with
//!      no pending sign-up, five of each, leave the audit's size unchanged
//!  42. A opening nine streams of one conversation ends A's own first
//!      (eight a holder), and B's stream there stays live
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

    /// Reads until the server ends the stream: whether it ended (false
    /// when a read waited past `wait_ms` first).
    fn ends(l: *Listener) bool {
        while (true) l.more() catch |e| return e == error.EndOfStream;
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

/// **AGENTS ARE CAPPED PER HUMAN** (H1): a new human, Dee, makes twenty,
/// and the twenty-first is a 403. The cap is app/Limits.roc's.
const agents_per_human = 20;

fn agentsCapped(w: *World) !void {
    const dee = try signUp(w.a, w.port(), 1006);
    for (0..agents_per_human) |_| {
        if ((try request(w.a, w.port(), "POST", "/agents", dee, "name=Many")).status != 201) return error.NotMade;
    }
    const r = try request(w.a, w.port(), "POST", "/agents", dee, "name=Many");
    if (r.status != 403) return error.Uncapped;
    if (!has(r.body, "as many agents")) return error.NotSaid;
}

/// **ONLY ITS OWNER NAMES AN AGENT** (M2), and an unknown id is refused
/// in the same words (L1).
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

/// **A WRITE FROM ANOTHER ORIGIN IS REFUSED** (M4), whatever cookie it
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

/// **LOGOUT ENDS THE SESSION** (M5), behind M4's check.
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

/// **A STREAM ENDS AT ITS LIFETIME** (M3): Steve's own key holds a
/// stream; the key is revoked while it is open, and the stream ends at its
/// lifetime (half a second here, `stream_lifetime_ms_for_test`), never
/// carrying on for the revoked key; resumed, the key is a 401.
const lifetime_ms_for_test = 500;

fn streamLifetime(w: *World) !void {
    const conv = try startedId(try request(w.a, w.port(), "POST", "/conversations", w.steve, "with=human%3A1001"));
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

/// **A HOLDER'S STREAMS ARE CAPPED, AND ONLY ITS OWN END** (H2): B holds a
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
    if (!std.mem.eql(u8, try field(r.body, "owner"), "human:1004")) return error.NotSteves;
}

fn mintForAgent(w: *World) !void {
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

fn redeemTwice(w: *World) !void {
    if ((try redeem(w, w.code)).status != 401) return error.RedeemedTwice;
    // An unknown code too, and none at all.
    const unknown: [64]u8 = @splat('d');
    if ((try redeem(w, &unknown)).status != 401) return error.UnknownRedeemed;
    if ((try send(w.a, w.port(), "POST", "/invites/redeem", .{}, "")).status != 401) return error.NothingRedeemed;
}

fn inviteExpired(w: *World) !void {
    const inv = try invite(w, try std.fmt.allocPrint(w.a, "as={s}", .{w.agent}));
    // Ten minutes and a second later, on the server's clock.
    w.rig.server.clock_ahead_s_for_test.store(601, .release);
    defer w.rig.server.clock_ahead_s_for_test.store(0, .release);
    if ((try redeem(w, inv.code)).status != 401) return error.ExpiredRedeemed;
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
    // audited (M1).
    if (has(log, "invite=unknown")) return error.AnonymousAudited;
}

/// **AN ANONYMOUS REFUSAL WRITES NO AUDIT** (M1): junk invite codes, a
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
    .{ .name = "Steve gets it a key, by an invite (and C cannot invite for it)", .f = mintForAgent },
    .{ .name = "the agent, by key alone, starts a conversation with Steve and posts; Steve's stream gets it once", .f = agentStarts },
    .{ .name = "Steve posts, and the agent reads it with its key", .f = agentReads },
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
