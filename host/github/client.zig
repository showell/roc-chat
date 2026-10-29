//! The host's one outbound conversation: GitHub's OAuth code exchange and
//! `GET /user`, over std.http.Client with TLS through the system CA bundle.
//!
//! The Roc never sees the client secret or the access token. The token lives
//! in a `Token` for the one `identify` call and is wiped when it returns,
//! whatever it returned; every buffer that held it, or the client secret, is
//! wiped too (the form, the Authorization header, the answer's body). What
//! std.http.Client keeps in its own connection buffers is freed, not wiped:
//! a heap read past free would see it, as it would see any request.
//!
//! **EVERY CALL HAS A DEADLINE.** std.http.Client has no timeouts, so each
//! request runs as a task raced against a watch task (`Io.Select`): the watch
//! sleeps to the connect deadline, and if the request has not connected by
//! then it wins; else it sleeps on to the whole deadline. The loser is
//! canceled, and std's threaded Io interrupts a task blocked in a syscall
//! (`connect`, `read`) with a signal, so a stalled GitHub ends as `Timeout`,
//! never as a stuck sign-in. Why a race and not a socket option: the client
//! makes its socket itself (no SO_RCVTIMEO to set), and the connect deadline
//! must also bound the DNS lookup, the CA bundle load and the TLS handshake,
//! which no one socket option does. A `Session` holds one whole deadline for
//! all its calls, so a sign-in (exchange, then identify) is bounded as one.
//!
//! **PLAIN HTTP ONLY TO A LOOPBACK LITERAL** (`baseAllowed`): a base URL is
//! `https://`, or `http://127.0.0.1[:port]` or `http://[::1][:port]`, which is
//! the fake GitHub in tests. Not `localhost`, which a hosts file or a resolver
//! can send anywhere. Redirects are never followed: one is a `BadResponse`.
const std = @import("std");
const Io = std.Io;
const http = std.http;

pub const Config = struct {
    /// Where `/login/oauth/access_token` is.
    oauth_base: []const u8 = "https://github.com",
    /// Where `/user` is.
    api_base: []const u8 = "https://api.github.com",
    /// GitHub refuses a request with none.
    user_agent: []const u8 = "roc-chat",
    /// By when a request must have connected: the DNS lookup, the TCP
    /// connect, the CA bundle load and the TLS handshake.
    connect_timeout_ms: u32 = 5_000,
    /// By when a `Session`'s calls must all be done, from its start.
    whole_timeout_ms: u32 = 15_000,
    /// The most bytes of one answer's body. `/user` is about 1.5 KiB.
    max_response_bytes: u32 = 64 * 1024,

    pub fn check(c: Config) error{BaseUrlRefused}!void {
        if (!baseAllowed(c.oauth_base) or !baseAllowed(c.api_base)) return error.BaseUrlRefused;
        if (c.user_agent.len == 0 or !visible(c.user_agent, true)) return error.BaseUrlRefused;
    }
};

/// How a call failed. Each is a fact for the Roc's `exchanged` answer.
pub const Failure = error{
    /// A deadline passed: the connect's, or the whole session's.
    Timeout,
    /// No conversation with GitHub: the address did not resolve, the
    /// connect or the TLS handshake failed, the request could not be sent,
    /// or the host had no resource to make the call with.
    Refused,
    /// GitHub answered, but not with what this call expects: a malformed or
    /// oversized body, an unexpected status, a redirect, a compressed body.
    BadResponse,
    /// GitHub answered no: a bad or expired code, bad client credentials, a
    /// revoked token.
    Denied,
};

/// A call's error: a `Failure`, or the caller's own task canceled, which
/// std.Io requires be passed on.
pub const Error = Failure || Io.Cancelable;

pub const Credentials = struct {
    client_id: []const u8,
    client_secret: []const u8,
};

/// The longest code the host sends. GitHub's are 20 bytes; the Roc's own
/// rule (`GitHubSignIn.max_code_bytes`) is 64.
pub const max_code_bytes = 256;
pub const max_token_bytes = 255;
/// The most bytes of a login the host carries. GitHub's own rule (39) is
/// the Roc's to apply (`GitHubLogin`).
pub const max_login_bytes = 64;
const max_base_bytes = 200;

pub const Token = struct {
    buf: [max_token_bytes]u8 = @splat(0),
    len: u8 = 0,

    fn slice(t: *const Token) []const u8 {
        return t.buf[0..t.len];
    }

    pub fn wipe(t: *Token) void {
        std.crypto.secureZero(u8, &t.buf);
        t.len = 0;
    }

    pub fn format(_: Token, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("<token>");
    }
};

pub const Identity = struct {
    id: u64,
    login_buf: [max_login_bytes]u8,
    login_len: u8,

    pub fn login(i: *const Identity) []const u8 {
        return i.login_buf[0..i.login_len];
    }
};

/// The plain-HTTP rule (see the top of this file).
pub fn baseAllowed(base: []const u8) bool {
    if (base.len == 0 or base.len > max_base_bytes or !visible(base, false)) return false;
    const uri = std.Uri.parse(base) catch return false;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return false;
    const host = switch (uri.host orelse return false) {
        .raw, .percent_encoded => |h| h,
    };
    if (host.len == 0) return false;
    if (std.mem.eql(u8, uri.scheme, "https")) return true;
    if (!std.mem.eql(u8, uri.scheme, "http")) return false;
    return std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]") or std.mem.eql(u8, host, "::1");
}

/// Exchanges `code` for a token, then asks who it belongs to, under one
/// deadline; the token is wiped before this returns.
pub fn signIn(gpa: std.mem.Allocator, io: Io, cfg: Config, creds: Credentials, code: []const u8) (Error || error{BaseUrlRefused})!Identity {
    var s = try Session.init(gpa, io, cfg);
    defer s.deinit();
    var token = try s.exchangeCode(creds, code);
    defer token.wipe();
    return s.identify(&token);
}

/// One std.http.Client and one whole deadline, for a sign-in's calls. A
/// session is used by one task at a time and is not moved once a call runs.
pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cfg: Config,
    client: http.Client,
    whole_by: Io.Clock.Timestamp,

    pub fn init(gpa: std.mem.Allocator, io: Io, cfg: Config) error{BaseUrlRefused}!Session {
        try cfg.check();
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .client = .{ .allocator = gpa, .io = io },
            .whole_by = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(cfg.whole_timeout_ms) }),
        };
    }

    pub fn deinit(s: *Session) void {
        s.client.deinit();
    }

    /// `POST {oauth_base}/login/oauth/access_token`, form-encoded, for JSON.
    pub fn exchangeCode(s: *Session, creds: Credentials, code: []const u8) Error!Token {
        if (code.len == 0 or code.len > max_code_bytes) return error.Denied;
        const fields = [_][2][]const u8{
            .{ "client_id", creds.client_id },
            .{ "client_secret", creds.client_secret },
            .{ "code", code },
        };
        var form_len: usize = 0;
        for (fields, 0..) |f, i| form_len += @intFromBool(i > 0) + f[0].len + 1 + encodedLen(f[1]);
        const form = s.gpa.alloc(u8, form_len) catch return error.Refused;
        defer {
            std.crypto.secureZero(u8, form);
            s.gpa.free(form);
        }
        var fw: Io.Writer = .fixed(form);
        for (fields, 0..) |f, i| {
            if (i > 0) fw.writeByte('&') catch unreachable;
            fw.writeAll(f[0]) catch unreachable;
            fw.writeByte('=') catch unreachable;
            formEncode(&fw, f[1]) catch unreachable;
        }

        var url_buf: [max_base_bytes + 64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/login/oauth/access_token", .{trimSlash(s.cfg.oauth_base)}) catch unreachable;
        var call: Call = .{
            .method = .POST,
            .url = url,
            .accept = "application/json",
            .content_type = "application/x-www-form-urlencoded",
            .payload = form,
        };
        defer call.wipe(s.gpa);
        const answer = try s.run(&call);

        switch (answer.status) {
            .ok => {},
            .bad_request, .unauthorized, .forbidden, .not_found, .unprocessable_entity => return error.Denied,
            else => return error.BadResponse,
        }
        const Granted = struct { access_token: ?[]const u8 = null, @"error": ?[]const u8 = null };
        var scratch = try Scratch.init(s.gpa, answer.body.len);
        defer scratch.deinit(s.gpa);
        const parsed = std.json.parseFromSliceLeaky(Granted, scratch.fba.allocator(), answer.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.BadResponse;
        if (parsed.@"error" != null) return if (parsed.access_token == null) error.Denied else error.BadResponse;
        const t = parsed.access_token orelse return error.BadResponse;
        // It goes into a header: one visible-ASCII word, no CR, LF or space.
        if (t.len == 0 or t.len > max_token_bytes or !visible(t, false)) return error.BadResponse;
        var token: Token = .{};
        @memcpy(token.buf[0..t.len], t);
        token.len = @intCast(t.len);
        return token;
    }

    /// `GET {api_base}/user` with the token: GitHub's id and login. The
    /// token is wiped when this returns, whatever it returned.
    pub fn identify(s: *Session, token: *Token) Error!Identity {
        defer token.wipe();
        if (token.len == 0) return error.Denied;
        var auth_buf: [7 + max_token_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &auth_buf);
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token.slice()}) catch unreachable;

        var url_buf: [max_base_bytes + 64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/user", .{trimSlash(s.cfg.api_base)}) catch unreachable;
        var call: Call = .{
            .method = .GET,
            .url = url,
            .accept = "application/vnd.github+json",
            .authorization = auth,
        };
        defer call.wipe(s.gpa);
        const answer = try s.run(&call);

        switch (answer.status) {
            .ok => {},
            .unauthorized, .forbidden => return error.Denied,
            else => return error.BadResponse,
        }
        const User = struct { id: ?u64 = null, login: ?[]const u8 = null };
        var scratch = try Scratch.init(s.gpa, answer.body.len);
        defer scratch.deinit(s.gpa);
        const user = std.json.parseFromSliceLeaky(User, scratch.fba.allocator(), answer.body, .{
            .ignore_unknown_fields = true,
        }) catch return error.BadResponse;
        const id = user.id orelse return error.BadResponse;
        const login = user.login orelse return error.BadResponse;
        if (login.len > max_login_bytes) return error.BadResponse;
        var identity: Identity = .{ .id = id, .login_buf = @splat(0), .login_len = @intCast(login.len) };
        @memcpy(identity.login_buf[0..login.len], login);
        return identity;
    }

    /// `GET {api_base}/zen`, for the opt-in smoke test: the body, copied to
    /// `out`.
    pub fn zen(s: *Session, out: []u8) Error![]u8 {
        var url_buf: [max_base_bytes + 64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/zen", .{trimSlash(s.cfg.api_base)}) catch unreachable;
        var call: Call = .{ .method = .GET, .url = url, .accept = "application/vnd.github+json" };
        defer call.wipe(s.gpa);
        const answer = try s.run(&call);
        if (answer.status != .ok or answer.body.len > out.len) return error.BadResponse;
        @memcpy(out[0..answer.body.len], answer.body);
        return out[0..answer.body.len];
    }

    /// The request raced against its deadlines. **EVERY TASK IS AWAITED
    /// BEFORE THIS RETURNS**: `cancelDiscard` cancels the loser and waits
    /// for it, so `call` (on the caller's stack) outlives both tasks.
    fn run(s: *Session, call: *Call) Error!Answer {
        if (!baseAllowed(call.url)) return error.Refused;
        call.body_buf = s.gpa.alloc(u8, s.cfg.max_response_bytes) catch return error.Refused;
        const connect_in: Io.Clock.Timestamp = .fromNow(s.io, .{ .clock = .awake, .raw = .fromMilliseconds(s.cfg.connect_timeout_ms) });
        const connect_by = if (connect_in.compare(.lt, s.whole_by)) connect_in else s.whole_by;

        var buffer: [2]Raced = undefined;
        var race: Io.Select(Raced) = .init(s.io, &buffer);
        // No unit of concurrency, no deadline: the call is not made.
        race.concurrent(.work, work, .{ s, call }) catch return error.Refused;
        race.concurrent(.watch, watch, .{ s.io, &call.connected, connect_by, s.whole_by }) catch {
            race.cancelDiscard();
            return error.Refused;
        };
        const first = race.await() catch |e| {
            race.cancelDiscard();
            return e;
        };
        race.cancelDiscard();
        return switch (first) {
            .work => call.outcome,
            .watch => |w| switch (w) {
                .connect_late, .whole_late => error.Timeout,
                .canceled => error.Canceled,
            },
        };
    }
};

const Answer = struct { status: http.Status, body: []const u8 };

const Watched = enum { canceled, connect_late, whole_late };
const Raced = union(enum) { work: void, watch: Watched };

/// One request: what it sends, and what came of it. Lives on the caller's
/// stack for the length of `run`.
const Call = struct {
    method: http.Method,
    url: []const u8,
    accept: []const u8,
    content_type: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    body_buf: []u8 = &.{},
    connected: std.atomic.Value(bool) = .init(false),
    outcome: Error!Answer = error.Refused,

    fn wipe(c: *Call, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, c.body_buf);
        gpa.free(c.body_buf);
        c.body_buf = &.{};
    }
};

fn watch(io: Io, connected: *const std.atomic.Value(bool), connect_by: Io.Clock.Timestamp, whole_by: Io.Clock.Timestamp) Watched {
    connect_by.wait(io) catch return .canceled;
    if (!connected.load(.acquire)) return .connect_late;
    whole_by.wait(io) catch return .canceled;
    return .whole_late;
}

fn work(s: *Session, c: *Call) void {
    c.outcome = roundTrip(s, c);
}

fn roundTrip(s: *Session, c: *Call) Error!Answer {
    const uri = std.Uri.parse(c.url) catch return error.Refused;
    var req = s.client.request(c.method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = s.cfg.user_agent },
            .accept_encoding = .{ .override = "identity" },
            .authorization = if (c.authorization) |a| .{ .override = a } else .omit,
            .content_type = if (c.content_type) |t| .{ .override = t } else .omit,
        },
        .extra_headers = &.{.{ .name = "accept", .value = c.accept }},
    }) catch |e| return switch (e) {
        error.Canceled => error.Canceled,
        else => error.Refused,
    };
    defer req.deinit();
    c.connected.store(true, .release);

    if (c.payload) |p| {
        req.transfer_encoding = .{ .content_length = p.len };
        var body = req.sendBodyUnflushed(&.{}) catch return error.Refused;
        body.writer.writeAll(p) catch return error.Refused;
        body.end() catch return error.Refused;
        req.connection.?.flush() catch return error.Refused;
    } else req.sendBodiless() catch return error.Refused;

    var response = req.receiveHead(&.{}) catch |e| return switch (e) {
        error.Canceled => error.Canceled,
        else => error.BadResponse,
    };
    if (response.head.content_encoding != .identity) return error.BadResponse;
    if (response.head.content_length) |n| if (n > c.body_buf.len) return error.BadResponse;
    var w: Io.Writer = .fixed(c.body_buf);
    var transfer: [64]u8 = undefined;
    _ = response.reader(&transfer).streamRemaining(&w) catch return error.BadResponse;
    return .{ .status = response.head.status, .body = w.buffered() };
}

/// A fixed buffer for std.json's copies of a body's strings (the token
/// among them), wiped when done.
const Scratch = struct {
    mem: []u8,
    fba: std.heap.FixedBufferAllocator,

    fn init(gpa: std.mem.Allocator, body_len: usize) Failure!Scratch {
        const mem = gpa.alloc(u8, 2 * body_len + 1024) catch return error.Refused;
        return .{ .mem = mem, .fba = .init(mem) };
    }

    fn deinit(sc: *Scratch, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, sc.mem);
        gpa.free(sc.mem);
    }
};

fn trimSlash(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

/// Printable ASCII, with or without the space.
fn visible(s: []const u8, space_ok: bool) bool {
    for (s) |ch| if (ch < 0x21 or ch > 0x7e) {
        if (!(space_ok and ch == ' ')) return false;
    };
    return true;
}

fn unreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

fn encodedLen(v: []const u8) usize {
    var n: usize = 0;
    for (v) |ch| n += if (unreserved(ch)) 1 else 3;
    return n;
}

/// application/x-www-form-urlencoded: unreserved bytes as they are, every
/// other byte as `%XX`.
fn formEncode(w: *Io.Writer, v: []const u8) Io.Writer.Error!void {
    for (v) |ch| {
        if (unreserved(ch)) try w.writeByte(ch) else try w.print("%{X:0>2}", .{ch});
    }
}

// ── tests (the client against the fake GitHub is host/github/github_test.zig) ─────

const testing = std.testing;

test "the plain-HTTP rule: https anywhere, http only to a loopback literal" {
    for ([_][]const u8{
        "https://github.com",
        "https://api.github.com",
        "https://api.github.com/",
        "http://127.0.0.1:4567",
        "http://127.0.0.1",
        "http://[::1]:4567",
    }) |ok| try testing.expect(baseAllowed(ok));
    for ([_][]const u8{
        "http://github.com",
        "http://api.github.com",
        "http://localhost:4567",
        "http://127.0.0.2:4567",
        "http://127.0.0.1.evil.example:4567",
        "http://10.0.0.1",
        "http://user@127.0.0.1:4567",
        "https://user:pw@github.com",
        "ftp://github.com",
        "github.com",
        "",
        "https://github.com\r\nX-Evil: 1",
        "https://github.com?x=1",
    }) |bad| try testing.expect(!baseAllowed(bad));
    try testing.expectError(error.BaseUrlRefused, (Config{ .api_base = "http://api.github.com" }).check());
    try (Config{}).check();
}

test "form encoding" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try formEncode(&w, "a b&c=d+e%f~g.h_i-j");
    try testing.expectEqualStrings("a%20b%26c%3Dd%2Be%25f~g.h_i-j", w.buffered());
    try testing.expectEqual(w.buffered().len, encodedLen("a b&c=d+e%f~g.h_i-j"));
}

test "a token formats as <token>" {
    var t: Token = .{};
    @memcpy(t.buf[0..9], "gho_SECRE");
    t.len = 9;
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try w.print("{f}", .{t});
    try testing.expectEqualStrings("<token>", w.buffered());
    t.wipe();
    try testing.expect(std.mem.allEqual(u8, &t.buf, 0));
}
