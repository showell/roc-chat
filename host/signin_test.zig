//! **SIGN-IN, END TO END**: the real server in this process, the chat's Roc
//! linked, its secrets on disk under a data root of the test's own, and the
//! fake GitHub (host/github/fake_github.zig) on another port as both of
//! GitHub's bases. Clients speak HTTP by hand, one request a connection,
//! carrying the cookies the server set, as a browser would.
//!
//! **THE TURN IS FREE DURING THE EXCHANGE** is the point of the design,
//! so it is tested directly: with the fake GitHub stalling the
//! exchange, another client is answered while it waits.

const std = @import("std");
const Io = std.Io;
const server = @import("server.zig");
const signin = @import("signin.zig");
const secrets = @import("auth/secrets.zig");
const crypto = @import("auth/crypto.zig");
const fake_github = @import("github/fake_github.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

const RunResult = @typeInfo(@TypeOf(server.Server.run)).@"fn".return_type.?;

const paths: secrets.Paths = .{ .client_id = "client_id", .client_secret = "client_secret", .signing_key = "signing_key" };
const origin = "http://chat.test";
/// GitHub's whole deadline for a sign-in: long enough for loopback, short
/// enough to wait out.
const github_whole_ms = 1500;

/// A server with sign-in, the fake GitHub, and a data root with secrets.
const Rig = struct {
    fake: *fake_github.Fake,
    data: std.testing.TmpDir,
    auth: signin.Auth,
    server: server.Server,
    run: Io.Future(RunResult),

    fn start() !*Rig {
        const r = try gpa.create(Rig);
        errdefer gpa.destroy(r);
        r.fake = try fake_github.Fake.start(io, gpa);
        errdefer r.fake.stop();
        r.data = std.testing.tmpDir(.{});
        errdefer r.data.cleanup();
        try r.data.dir.createDir(io, secrets.folder, .fromMode(0o700));
        var dir = try r.data.dir.openDir(io, secrets.folder, .{});
        defer dir.close(io);
        try put(dir, paths.client_id, fake_github.client_id);
        try put(dir, paths.client_secret, fake_github.client_secret);
        var diag: secrets.Diagnostic = .{};
        const held = try secrets.load(io, gpa, r.data.dir, paths, &diag);
        r.auth = .{
            .secrets = held,
            .github = .{ .oauth_base = r.fake.base(), .api_base = r.fake.base(), .connect_timeout_ms = 1000, .whole_timeout_ms = github_whole_ms },
            .origin = origin,
        };
        errdefer r.auth.secrets.deinit(gpa);
        r.server = try .init(io, gpa, try .parse("127.0.0.1", 0), .{}, r.data.dir);
        r.server.auth = &r.auth;
        r.run = try io.concurrent(server.Server.run, .{&r.server});
        return r;
    }

    fn stop(r: *Rig) void {
        r.server.stop();
        r.run.await(io) catch |e| std.debug.print("the server's run: {t}\n", .{e});
        r.fake.stop();
        r.auth.secrets.deinit(gpa);
        r.data.cleanup();
        gpa.destroy(r);
    }

    fn port(r: *const Rig) u16 {
        return r.server.port();
    }

    /// Requests the fake GitHub has had.
    fn githubAsked(r: *const Rig) u32 {
        return r.fake.requests.load(.acquire);
    }

    /// Whether `token` is a state the site key signed (SignInWeb's form:
    /// `<body>.<hex MAC>`, the MAC over the purpose line and the body).
    fn stateVerifies(r: *const Rig, token: []const u8) bool {
        const dot = std.mem.lastIndexOfScalar(u8, token, '.') orelse return false;
        var mac: [crypto.mac_len]u8 = undefined;
        const got = std.fmt.hexToBytes(&mac, token[dot + 1 ..]) catch return false;
        var buf: [256]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "roc-chat oauth state\n{s}", .{token[0..dot]}) catch return false;
        return crypto.verify(&r.auth.secrets.signing_key.bytes, message, got);
    }
};

fn put(dir: Io.Dir, path: []const u8, bytes: []const u8) !void {
    const f = try dir.createFile(io, path, .{ .permissions = .fromMode(0o600) });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
    try f.setPermissions(io, .fromMode(0o600));
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

    fn header(r: Response, comptime name: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, r.head, "\r\n" ++ name ++ ": ") orelse return null;
        const from = at + name.len + 4;
        const to = std.mem.indexOfPos(u8, r.head, from, "\r\n") orelse return null;
        return r.head[from..to];
    }

    /// The whole `set-cookie` line for cookie `__Host-<name>`, or null.
    fn setCookie(r: Response, comptime name: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, r.head, "\r\nset-cookie: __Host-" ++ name ++ "=") orelse return null;
        const from = at + "\r\nset-cookie: ".len;
        const to = std.mem.indexOfPos(u8, r.head, from, "\r\n") orelse return null;
        return r.head[from..to];
    }

    /// The value cookie `__Host-<name>` is set to, or null.
    fn cookie(r: Response, comptime name: []const u8) ?[]const u8 {
        const line = r.setCookie(name) orelse return null;
        const from = ("__Host-" ++ name ++ "=").len;
        return line[from .. std.mem.indexOfScalar(u8, line, ';') orelse line.len];
    }
};

/// One request on a connection of its own, its `cookie` header when not
/// empty, and the response.
fn request(arena: std.mem.Allocator, port: u16, method: []const u8, target: []const u8, cookie: []const u8, body: []const u8) !Response {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const cookie_line = if (cookie.len > 0) try std.fmt.allocPrint(arena, "cookie: {s}\r\n", .{cookie}) else "";
    const body_lines = if (body.len > 0) try std.fmt.allocPrint(arena, "content-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n", .{body.len}) else "";
    // As a browser on the chat's own pages says of a write (app/Origin.roc).
    const text = try std.fmt.allocPrint(arena, "{s} {s} HTTP/1.1\r\nhost: chat.test\r\nconnection: close\r\nsec-fetch-site: same-origin\r\n{s}{s}\r\n{s}", .{ method, target, cookie_line, body_lines, body });
    var w = stream.writer(io, &.{});
    try w.interface.writeAll(text);
    var buf: [4096]u8 = undefined;
    var r = stream.reader(io, &buf);
    return .of(try r.interface.allocRemaining(arena, .limited(1024 * 1024)));
}

fn get(arena: std.mem.Allocator, port: u16, target: []const u8, cookie: []const u8) !Response {
    return request(arena, port, "GET", target, cookie, "");
}

/// 64 hex digits: a MAC's or a session secret's length, no one's.
const forged_hex: [64]u8 = @splat('c');

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// A browser's /login: the state GitHub is handed, and the state cookie.
const LoggedIn = struct { state: []const u8, cookie: []const u8 };

fn login(arena: std.mem.Allocator, rig: *Rig) !LoggedIn {
    const r = try get(arena, rig.port(), "/login", "");
    try std.testing.expectEqual(303, r.status);
    const location = r.header("location") orelse return error.NoLocation;
    const at = std.mem.indexOf(u8, location, "&state=") orelse return error.NoState;
    return .{
        .state = location[at + "&state=".len ..],
        .cookie = try std.fmt.allocPrint(arena, "__Host-state={s}", .{r.cookie("state") orelse return error.NoStateCookie}),
    };
}

/// GitHub sending the browser back with `code` and `state`.
fn callback(arena: std.mem.Allocator, rig: *Rig, code: []const u8, state: []const u8, cookie: []const u8) !Response {
    const target = try std.fmt.allocPrint(arena, "/login/github?code={s}&state={s}", .{ code, state });
    return get(arena, rig.port(), target, cookie);
}

fn expectRefused(r: Response, comptime why: []const u8) !void {
    try std.testing.expectEqual(403, r.status);
    try std.testing.expectEqualStrings("sign-in refused: " ++ why ++ "\n", r.body);
    try std.testing.expect(r.setCookie("session") == null);
}

test "/login: a 303 to GitHub's authorize page with the client id, the callback and a state the site key signed; the state's nonce in this browser's cookie" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rig = try Rig.start();
    defer rig.stop();
    const r = try get(a, rig.port(), "/login", "");
    try std.testing.expectEqual(303, r.status);
    const location = r.header("location").?;
    const want = try std.fmt.allocPrint(a, "{s}/login/oauth/authorize?client_id={s}&redirect_uri=http%3A%2F%2Fchat.test%2Flogin%2Fgithub&state=", .{ rig.fake.base(), fake_github.client_id });
    try std.testing.expect(std.mem.startsWith(u8, location, want));
    const state = location[want.len..];
    try std.testing.expect(rig.stateVerifies(state));
    // One bit of the state changed, and it no longer verifies.
    const flipped = try a.dupe(u8, state);
    flipped[0] = if (flipped[0] == '0') '1' else '0';
    try std.testing.expect(!rig.stateVerifies(flipped));
    // The cookie holds the state's nonce (the state's first part), and the
    // policy: __Host-, Secure, HttpOnly, SameSite=Lax, OAuthState's ten minutes.
    const nonce = state[0..std.mem.indexOfScalar(u8, state, '.').?];
    const line = r.setCookie("state").?;
    try std.testing.expectEqualStrings(nonce, r.cookie("state").?);
    try std.testing.expectEqual(64, nonce.len);
    try std.testing.expect(std.mem.endsWith(u8, line, "; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=600"));
    try std.testing.expectEqual(0, rig.githubAsked());
}

test "a new human: the callback with a good code asks for a name, the name makes the account and sets the session cookie, /me knows them; signing in again goes straight to a session" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rig = try Rig.start();
    defer rig.stop();

    const first = try login(a, rig);
    const named = try callback(a, rig, "good", first.state, first.cookie);
    try std.testing.expectEqual(200, named.status);
    try std.testing.expect(has(named.body, "<form method=post action=/login/name>"));
    try std.testing.expect(named.setCookie("session") == null);
    const pending = named.cookie("pending").?;
    // The exchange and the identify: two requests to GitHub.
    try std.testing.expectEqual(2, rig.githubAsked());

    // A name the rule refuses: the form again, a 400, nothing spent.
    const both = try std.fmt.allocPrint(a, "{s}; __Host-pending={s}", .{ first.cookie, pending });
    const blank = try request(a, rig.port(), "POST", "/login/name", both, "name=+++");
    try std.testing.expectEqual(400, blank.status);
    try std.testing.expect(blank.setCookie("session") == null);

    const made = try request(a, rig.port(), "POST", "/login/name", both, "name=The+Octocat");
    try std.testing.expectEqual(303, made.status);
    try std.testing.expectEqualStrings("/", made.header("location").?);
    const line = made.setCookie("session").?;
    try std.testing.expect(std.mem.endsWith(u8, line, "; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=604800"));
    const session = made.cookie("session").?;
    try std.testing.expectEqual(64, session.len);

    const me = try get(a, rig.port(), "/me", try std.fmt.allocPrint(a, "__Host-session={s}", .{session}));
    try std.testing.expectEqual(200, me.status);
    try std.testing.expectEqualStrings("signed in as human:583231\n", me.body);

    // The account is stored through AccountCodec, the settings' counter advanced.
    var buf: [1024]u8 = undefined;
    const accounts = try rig.data.dir.readFile(io, "auth/accounts", &buf);
    try std.testing.expectEqualStrings("account v1 kind=human github=583231 login=octocat generation=1 role=member name=The Octocat\n", accounts);

    // The pending sign-up named again: refused, PendingReused said first.
    try expectRefused(try request(a, rig.port(), "POST", "/login/name", both, "name=Another"), "pending-reused");

    // A known human signs in: straight to a session, no name asked.
    const again = try login(a, rig);
    const back = try callback(a, rig, "good", again.state, again.cookie);
    try std.testing.expectEqual(303, back.status);
    try std.testing.expect(back.setCookie("session") != null);
    try std.testing.expect(!std.mem.eql(u8, session, back.cookie("session").?));
}

test "refused with the core's answer: a replayed state, a forged state, another browser's state, a bad code, a forged pending sign-up and a forged session cookie" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rig = try Rig.start();
    defer rig.stop();

    // A replayed state: once it has been spent, never again.
    const one = try login(a, rig);
    try std.testing.expectEqual(200, (try callback(a, rig, "good", one.state, one.cookie)).status);
    const asked = rig.githubAsked();
    try expectRefused(try callback(a, rig, "good", one.state, one.cookie), "state-reused");
    try std.testing.expectEqual(asked, rig.githubAsked());

    // A forged state: its MAC's first digit changed. GitHub is never asked.
    const two = try login(a, rig);
    const forged = try a.dupe(u8, two.state);
    const last = forged.len - 1;
    forged[last] = if (forged[last] == '0') '1' else '0';
    try expectRefused(try callback(a, rig, "good", forged, two.cookie), "state-forged");
    // A state that is not a token at all.
    try expectRefused(try callback(a, rig, "good", "nonsense", two.cookie), "state-forged");
    // Another browser's: a good state, with no cookie or this one's.
    const three = try login(a, rig);
    try expectRefused(try callback(a, rig, "good", three.state, ""), "state-mismatched");
    try expectRefused(try callback(a, rig, "good", three.state, two.cookie), "state-mismatched");
    try std.testing.expectEqual(asked, rig.githubAsked());

    // A bad code: GitHub says no, and the core says GitHub gave no identity.
    try expectRefused(try callback(a, rig, "bad", three.state, three.cookie), "github-unreachable");
    // GitHub sent no code (the person said no).
    const four = try login(a, rig);
    const target = try std.fmt.allocPrint(a, "/login/github?error=access_denied&state={s}", .{four.state});
    try expectRefused(try get(a, rig.port(), target, four.cookie), "github-denied");

    // A forged pending sign-up: none at all, and one whose MAC is wrong.
    const five = try login(a, rig);
    try expectRefused(try request(a, rig.port(), "POST", "/login/name", five.cookie, "name=Mallory"), "pending-forged");
    const fake_pending = try std.fmt.allocPrint(a, "{s}; __Host-pending=00.583231.6f63746f636174.1761600000.{s}", .{ five.cookie, &forged_hex });
    try expectRefused(try request(a, rig.port(), "POST", "/login/name", fake_pending, "name=Mallory"), "pending-forged");

    // A forged session cookie, a malformed one, and none: not signed in.
    try std.testing.expectEqual(401, (try get(a, rig.port(), "/me", "__Host-session=" ++ forged_hex)).status);
    try std.testing.expectEqual(401, (try get(a, rig.port(), "/me", "__Host-session=zz")).status);
    try std.testing.expectEqual(401, (try get(a, rig.port(), "/me", "")).status);

    // The refusal past GitHub's exchange audited, as AuditCodec spells it;
    // the anonymous ones, which anyone repeats for free, never (M1).
    var buf: [8192]u8 = undefined;
    const audit = try rig.data.dir.readFile(io, "auth/audit", &buf);
    try std.testing.expect(has(audit, "github-unreachable"));
    for ([_][]const u8{ "state-reused", "state-forged", "state-mismatched", "github-denied", "pending-forged" }) |why|
        try std.testing.expect(!has(audit, why));
}

/// The callback, on a task of its own: its response and when it came.
const Pending = struct {
    rig: *Rig,
    arena: std.mem.Allocator,
    state: []const u8,
    cookie: []const u8,
    response: ?Response = null,
    done_at: ?Io.Timestamp = null,

    fn go(p: *Pending) void {
        p.response = callback(p.arena, p.rig, "slow", p.state, p.cookie) catch null;
        p.done_at = Io.Clock.now(.awake, io);
    }
};

test "the turn is free during the exchange: with GitHub stalled, another client is answered at once, and the stalled sign-in ends as GitHub's failure at the deadline" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rig = try Rig.start();
    defer rig.stop();
    // The exchange's timeout is said as a warning: the point here, quiet.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const one = try login(a, rig);
    var slow: Pending = .{ .rig = rig, .arena = a, .state = one.state, .cookie = one.cookie };
    const t0 = Io.Clock.now(.awake, io);
    var task = try io.concurrent(Pending.go, .{&slow});
    // The exchange has begun when the fake GitHub has its request.
    while (rig.githubAsked() == 0) try io.sleep(.fromMilliseconds(5), .awake);
    // Another client, in the turn and out of it while GitHub waits.
    var other_arena = std.heap.ArenaAllocator.init(gpa);
    defer other_arena.deinit();
    const hello = try get(other_arena.allocator(), rig.port(), "/", "");
    const hello_at = Io.Clock.now(.awake, io);
    try std.testing.expectEqual(200, hello.status);
    const other = try login(other_arena.allocator(), rig);
    try std.testing.expect(rig.stateVerifies(other.state));
    try std.testing.expect(slow.done_at == null);
    task.await(io);
    const waited = t0.durationTo(slow.done_at.?).toMilliseconds();
    try std.testing.expect(t0.durationTo(hello_at).toMilliseconds() < github_whole_ms / 2);
    try std.testing.expect(waited >= github_whole_ms - 100 and waited < fake_github.slow_ms);
    try expectRefused(slow.response.?, "github-unreachable");
    // The turn held one handler at a time throughout.
    try std.testing.expectEqual(1, rig.server.stats.most_in_turn.load(.acquire));
}

test "a GitHub that never answers is the core's failure page at the deadline, not a hang; the state is spent" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const rig = try Rig.start();
    defer rig.stop();
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const one = try login(a, rig);
    const t0 = Io.Clock.now(.awake, io);
    const r = try callback(a, rig, "slow", one.state, one.cookie);
    const took = t0.durationTo(Io.Clock.now(.awake, io)).toMilliseconds();
    try expectRefused(r, "github-unreachable");
    try std.testing.expect(took >= github_whole_ms - 100 and took < 3 * github_whole_ms);
    try expectRefused(try callback(a, rig, "good", one.state, one.cookie), "state-reused");
}
