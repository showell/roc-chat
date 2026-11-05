//! The host's one outbound conversation: GitHub's OAuth code exchange and
//! `GET /user`, over std.http.Client with TLS through the system's CA bundle,
//! and the settings it runs on.
//!
//! The Roc never sees the client secret or the access token. The settings
//! keep the secret for the server's life. The token lives in a `Token` for
//! the one call that uses it and is wiped when that call returns, and every
//! buffer that held either is wiped too, what std.http.Client keeps in its
//! own buffers included: a `Session` allocates everything through `Wiping`.
//!
//! Every call has a deadline. std.http.Client has none, so each request runs
//! as a task raced against a watch task (`Io.Select`): the watch sleeps to
//! the connect deadline, and if the request has not connected by then it
//! wins; else it sleeps on to the whole deadline. The loser is canceled, so
//! a stalled GitHub ends as `Timeout`, never as a stuck sign-in. A race and
//! not a socket option, because the client makes its socket itself and the
//! connect deadline must also bound the DNS lookup and the TLS handshake. A
//! `Session` holds one whole deadline for all its calls, so a sign-in, an
//! exchange and then a `/user`, is bounded as one.
//!
//! A base URL is `https://`, or `http://` to a loopback literal, which is
//! the fake GitHub in tests (`base_allowed`). `localhost` is not one, as a
//! hosts file or a resolver can send it anywhere. A redirect is never
//! followed: it is a `BadResponse`.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const Wiping = @import("wiping_allocator.zig").Wiping;

/// The settings' files in the data root. Each name starts with `.`, so the
/// path rule (host/file_primitives.zig) keeps it from every file primitive.
pub const client_id_name = ".github-client-id";
pub const client_secret_name = ".github-client-secret";
/// Optional: where GitHub's sign-in pages are, and where its API is. A test
/// names its fake's here; a server with none talks to GitHub.
pub const oauth_base_name = ".github-oauth-base";
pub const api_base_name = ".github-api-base";

const github_oauth_base = "https://github.com";
const github_api_base = "https://api.github.com";

/// The most bytes a settings file may hold.
const setting_most = 200;

/// One setting's bytes, held by value, so the settings move with the server.
const Setting = struct {
    bytes: [setting_most]u8 = undefined,
    len: u8 = 0,

    fn of(text: []const u8) Setting {
        var s: Setting = .{ .len = @intCast(text.len) };
        @memcpy(s.bytes[0..text.len], text);
        return s;
    }

    pub fn slice(s: *const Setting) []const u8 {
        return s.bytes[0..s.len];
    }
};

/// What the host holds to sign in with GitHub, read once at the start.
pub const Settings = struct {
    client_id: Setting,
    client_secret: Setting,
    oauth_base: Setting,
    api_base: Setting,
    /// GitHub refuses a request with none.
    user_agent: []const u8 = "gopher-roc",
    /// By when a request must have connected: the DNS lookup, the TCP
    /// connect, the CA bundle load and the TLS handshake.
    connect_timeout_ms: u32 = 5_000,
    /// By when a `Session`'s calls must all be done, from its start.
    whole_timeout_ms: u32 = 15_000,
    /// The most bytes of one answer's body. `/user` is about 1.5 KiB.
    max_response_bytes: u32 = 64 * 1024,

    /// The settings in `dir`, the data root; null when it holds no GitHub
    /// file at all, so a server needs nothing to run without GitHub. Any
    /// file with the client id or the secret missing is
    /// `error.GitHubSettingsPartial`, a file its group or anyone else may
    /// read or write `error.GitHubSettingOpenToOthers`, one empty or too long
    /// `error.GitHubSettingUnusable`, and a base URL `base_allowed` refuses
    /// `error.GitHubBaseRefused`: each stops the server rather than leaving
    /// it half set up.
    pub fn load(io: Io, dir: Io.Dir) !?Settings {
        const client_id = try read_setting(io, dir, client_id_name);
        const client_secret = try read_setting(io, dir, client_secret_name);
        const oauth_base = try read_setting(io, dir, oauth_base_name);
        const api_base = try read_setting(io, dir, api_base_name);
        if (client_id == null and client_secret == null and oauth_base == null and api_base == null) return null;
        if (client_id == null or client_secret == null) return error.GitHubSettingsPartial;
        const settings: Settings = .{
            .client_id = client_id.?,
            .client_secret = client_secret.?,
            .oauth_base = oauth_base orelse .of(github_oauth_base),
            .api_base = api_base orelse .of(github_api_base),
        };
        if (!base_allowed(settings.oauth_base.slice()) or !base_allowed(settings.api_base.slice())) return error.GitHubBaseRefused;
        return settings;
    }
};

/// The file `name` in `dir`, its spaces and line ends off both ends; null
/// when there is none. The mode is read from the file that is read, so a
/// file swapped between the two is never the one judged.
fn read_setting(io: Io, dir: Io.Dir, name: []const u8) !?Setting {
    const file = dir.openFile(io, name, .{ .allow_directory = false }) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer file.close(io);
    const st = try file.stat(io);
    if (st.permissions.toMode() & 0o077 != 0) return error.GitHubSettingOpenToOthers;
    var buf: [setting_most + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    var reader = file.reader(io, &.{});
    const n = reader.interface.readSliceShort(&buf) catch |e| switch (e) {
        error.ReadFailed => return reader.err.?,
    };
    if (n > setting_most) return error.GitHubSettingUnusable;
    const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (text.len == 0 or !visible(text)) return error.GitHubSettingUnusable;
    return .of(text);
}

/// How a call failed.
pub const Failure = error{
    /// A deadline passed: the connect's, or the whole session's.
    Timeout,
    /// No conversation with GitHub: the address did not resolve, the connect
    /// or the TLS handshake failed, the request could not be sent, or the
    /// host had no resource to make the call with.
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

/// The longest code the host sends: the app's rule (app/GitHubCode.roc) is
/// tighter, and this is the host's own bound.
const max_code_bytes = 256;
const max_token_bytes = 255;
/// The most bytes of a login the host carries. GitHub's own rule is the
/// app's to apply (app/GitHubLogin.roc).
const max_login_bytes = 64;

const Token = struct {
    buf: [max_token_bytes]u8 = @splat(0),
    len: u8 = 0,

    fn slice(t: *const Token) []const u8 {
        return t.buf[0..t.len];
    }

    fn wipe(t: *Token) void {
        std.crypto.secureZero(u8, &t.buf);
        t.len = 0;
    }

    pub fn format(_: Token, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("<token>");
    }
};

/// Who GitHub says a token belongs to.
pub const Identity = struct {
    id: u64,
    login_buf: [max_login_bytes]u8,
    login_len: u8,

    pub fn login(i: *const Identity) []const u8 {
        return i.login_buf[0..i.login_len];
    }
};

/// Whether `base` is a base URL the client may talk to (the top of this
/// file).
pub fn base_allowed(base: []const u8) bool {
    if (base.len == 0 or base.len > setting_most or !visible(base)) return false;
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
pub fn identify_code(gpa: std.mem.Allocator, io: Io, settings: *const Settings, code: []const u8) Error!Identity {
    var s = try Session.init(gpa, io, settings);
    defer s.deinit();
    var token = try s.exchange_code(code);
    defer token.wipe();
    return s.identify(&token);
}

/// One std.http.Client and one whole deadline, for a sign-in's calls. A
/// session is used by one task at a time and is not moved once a call runs.
const Session = struct {
    /// Every allocation of the session's, through `wiping`.
    gpa: std.mem.Allocator,
    /// On the heap, so a `Session` can be moved before its first call.
    wiping: *Wiping,
    io: Io,
    settings: *const Settings,
    client: http.Client,
    whole_by: Io.Clock.Timestamp,

    fn init(child: std.mem.Allocator, io: Io, settings: *const Settings) Failure!Session {
        const wiping = child.create(Wiping) catch return error.Refused;
        wiping.* = .{ .child = child };
        const gpa = wiping.allocator();
        return .{
            .gpa = gpa,
            .wiping = wiping,
            .io = io,
            .settings = settings,
            .client = .{ .allocator = gpa, .io = io },
            .whole_by = .fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(settings.whole_timeout_ms) }),
        };
    }

    fn deinit(s: *Session) void {
        s.client.deinit();
        const child = s.wiping.child;
        child.destroy(s.wiping);
    }

    /// `POST {oauth_base}/login/oauth/access_token`, form-encoded, for JSON.
    fn exchange_code(s: *Session, code: []const u8) Error!Token {
        if (code.len == 0 or code.len > max_code_bytes) return error.Denied;
        const fields = [_][2][]const u8{
            .{ "client_id", s.settings.client_id.slice() },
            .{ "client_secret", s.settings.client_secret.slice() },
            .{ "code", code },
        };
        var form_len: usize = 0;
        for (fields, 0..) |f, i| form_len += @intFromBool(i > 0) + f[0].len + 1 + encoded_len(f[1]);
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
            form_encode(&fw, f[1]) catch unreachable;
        }

        var url_buf: [setting_most + 64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/login/oauth/access_token", .{trim_slash(s.settings.oauth_base.slice())}) catch unreachable;
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
        // It goes into a header: one visible-ASCII word.
        if (t.len == 0 or t.len > max_token_bytes or !visible(t)) return error.BadResponse;
        var token: Token = .{};
        @memcpy(token.buf[0..t.len], t);
        token.len = @intCast(t.len);
        return token;
    }

    /// `GET {api_base}/user` with the token: GitHub's id and login. The
    /// token is wiped when this returns, whatever it returned.
    fn identify(s: *Session, token: *Token) Error!Identity {
        defer token.wipe();
        var auth_buf: [7 + max_token_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &auth_buf);
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token.slice()}) catch unreachable;

        var url_buf: [setting_most + 64]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/user", .{trim_slash(s.settings.api_base.slice())}) catch unreachable;
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

    /// The request raced against its deadlines. Both tasks are awaited
    /// before this returns (`cancelDiscard` cancels the loser and waits for
    /// it), so `call`, on the caller's stack, outlives them.
    fn run(s: *Session, call: *Call) Error!Answer {
        call.body_buf = s.gpa.alloc(u8, s.settings.max_response_bytes) catch return error.Refused;
        const connect_in: Io.Clock.Timestamp = .fromNow(s.io, .{ .clock = .awake, .raw = .fromMilliseconds(s.settings.connect_timeout_ms) });
        const connect_by = if (connect_in.compare(.lt, s.whole_by)) connect_in else s.whole_by;

        var buffer: [2]Raced = undefined;
        var race: Io.Select(Raced) = .init(s.io, &buffer);
        // With no unit of concurrency there is no deadline, so no call.
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

/// One request: what it sends, and what came of it. It lives on the caller's
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
    c.outcome = round_trip(s, c);
}

fn round_trip(s: *Session, c: *Call) Error!Answer {
    const uri = std.Uri.parse(c.url) catch return error.Refused;
    var req = s.client.request(c.method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .user_agent = .{ .override = s.settings.user_agent },
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

/// A fixed buffer for std.json's copies of a body's strings, the token among
/// them, wiped when done.
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

fn trim_slash(base: []const u8) []const u8 {
    return std.mem.trimEnd(u8, base, "/");
}

/// Printable ASCII with no space.
fn visible(s: []const u8) bool {
    for (s) |ch| if (ch < 0x21 or ch > 0x7e) return false;
    return true;
}

fn unreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

fn encoded_len(v: []const u8) usize {
    var n: usize = 0;
    for (v) |ch| n += if (unreserved(ch)) 1 else 3;
    return n;
}

/// application/x-www-form-urlencoded: unreserved bytes as they are, every
/// other byte as `%XX`.
fn form_encode(w: *Io.Writer, v: []const u8) Io.Writer.Error!void {
    for (v) |ch| {
        if (unreserved(ch)) try w.writeByte(ch) else try w.print("%{X:0>2}", .{ch});
    }
}

// ── tests

const testing = std.testing;
const fake_github = @import("fake_github.zig");

test {
    _ = @import("wiping_allocator.zig");
}

test "a base URL: https anywhere, http only to a loopback literal" {
    for ([_][]const u8{
        "https://github.com",
        "https://api.github.com/",
        "http://127.0.0.1:4567",
        "http://127.0.0.1",
        "http://[::1]:4567",
    }) |ok| try testing.expect(base_allowed(ok));
    for ([_][]const u8{
        "http://github.com",
        "http://localhost:4567",
        "http://127.0.0.2:4567",
        "http://127.0.0.1.evil.example:4567",
        "http://user@127.0.0.1:4567",
        "https://user:pw@github.com",
        "ftp://github.com",
        "github.com",
        "",
        "https://github.com\r\nX-Evil: 1",
        "https://github.com?x=1",
    }) |bad| try testing.expect(!base_allowed(bad));
}

test "form encoding" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try form_encode(&w, "a b&c=d+e%f~g.h_i-j");
    try testing.expectEqualStrings("a%20b%26c%3Dd%2Be%25f~g.h_i-j", w.buffered());
    try testing.expectEqual(w.buffered().len, encoded_len("a b&c=d+e%f~g.h_i-j"));
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

/// `text` written to the file `name` in `dir`, its owner's alone.
fn write_setting(dir: Io.Dir, name: []const u8, text: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = text, .flags = .{ .permissions = .fromMode(0o600) } });
}

test "the settings: none is null, and GitHub's own bases are the default" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(null, try Settings.load(testing.io, tmp.dir));
    try write_setting(tmp.dir, client_id_name, "the-id\n");
    try write_setting(tmp.dir, client_secret_name, " the-secret ");
    const settings = (try Settings.load(testing.io, tmp.dir)).?;
    try testing.expectEqualStrings("the-id", settings.client_id.slice());
    try testing.expectEqualStrings("the-secret", settings.client_secret.slice());
    try testing.expectEqualStrings(github_oauth_base, settings.oauth_base.slice());
    try testing.expectEqualStrings(github_api_base, settings.api_base.slice());
}

test "the settings: any file without the id or the secret, a file open to others, an empty one, a long one and a refused base each stop the start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try write_setting(tmp.dir, client_id_name, "the-id");
    try testing.expectError(error.GitHubSettingsPartial, Settings.load(testing.io, tmp.dir));
    try write_setting(tmp.dir, client_secret_name, "the-secret");
    try tmp.dir.setFilePermissions(testing.io, client_secret_name, .fromMode(0o640), .{});
    try testing.expectError(error.GitHubSettingOpenToOthers, Settings.load(testing.io, tmp.dir));
    try tmp.dir.setFilePermissions(testing.io, client_secret_name, .fromMode(0o600), .{});
    try write_setting(tmp.dir, client_secret_name, " \n");
    try testing.expectError(error.GitHubSettingUnusable, Settings.load(testing.io, tmp.dir));
    try write_setting(tmp.dir, client_secret_name, &@as([setting_most + 1]u8, @splat('x')));
    try testing.expectError(error.GitHubSettingUnusable, Settings.load(testing.io, tmp.dir));
    try write_setting(tmp.dir, client_secret_name, "the-secret");
    try write_setting(tmp.dir, api_base_name, "http://github.com");
    try testing.expectError(error.GitHubBaseRefused, Settings.load(testing.io, tmp.dir));
    try write_setting(tmp.dir, api_base_name, "http://127.0.0.1:4567");
    _ = (try Settings.load(testing.io, tmp.dir)).?;
}

/// Settings that talk to `fake`, with `secret` for the client's.
fn fake_settings(fake: *fake_github.Fake, secret: []const u8) Settings {
    return .{
        .client_id = .of(fake_github.client_id),
        .client_secret = .of(secret),
        .oauth_base = .of(fake.base()),
        .api_base = .of(fake.base()),
        .connect_timeout_ms = 2_000,
        .whole_timeout_ms = 300,
    };
}

test "the exchange against the fake: a good code is who GitHub says; every other answer its failure, the secret sent form-encoded" {
    const fake = try fake_github.Fake.start(testing.io, testing.allocator);
    defer fake.stop();
    const settings = fake_settings(fake, fake_github.client_secret);
    const who = try identify_code(testing.allocator, testing.io, &settings, "user-id-7");
    try testing.expectEqual(7, who.id);
    try testing.expectEqualStrings("person7", who.login());
    try testing.expectError(error.Denied, identify_code(testing.allocator, testing.io, &settings, "bad"));
    try testing.expectError(error.Denied, identify_code(testing.allocator, testing.io, &settings, ""));
    try testing.expectError(error.BadResponse, identify_code(testing.allocator, testing.io, &settings, "malformed"));
    try testing.expectError(error.BadResponse, identify_code(testing.allocator, testing.io, &settings, "huge"));
    try testing.expectError(error.Timeout, identify_code(testing.allocator, testing.io, &settings, "slow"));
    const wrong = fake_settings(fake, "another-secret");
    try testing.expectError(error.Denied, identify_code(testing.allocator, testing.io, &wrong, "user-id-7"));
}

test "no GitHub there: refused, never a hang" {
    const fake = try fake_github.Fake.start(testing.io, testing.allocator);
    var settings = fake_settings(fake, fake_github.client_secret);
    fake.stop();
    settings.whole_timeout_ms = 2_000;
    try testing.expectError(error.Refused, identify_code(testing.allocator, testing.io, &settings, "user-id-7"));
}
