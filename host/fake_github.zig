//! A fake GitHub for tests: plain HTTP on 127.0.0.1, on a free port. The end
//! to end and the client's tests point the host at it through its settings,
//! so no test reaches the real one.
//!
//! `GET /login/oauth/authorize` stands for the human agreeing: it answers a
//! 302 to the `redirect_uri` with the `state` it was given and `code=` the
//! query's `as`, or `error=access_denied` with no `as`, as GitHub does when
//! its human says no.
//!
//! `POST /login/oauth/access_token` answers by the code:
//!
//! | code          | answer                                                  |
//! |---------------|---------------------------------------------------------|
//! | `user-id-N`   | the token `tok-id-N`                                    |
//! | `malformed`   | a body cut off mid-JSON                                 |
//! | `huge`        | a body past the client's cap                            |
//! | `slow`        | no answer for `slow_ms`                                 |
//! | anything else | `{"error": "bad_verification_code"}`, a 200, as GitHub's |
//!
//! `GET /user` answers `tok-id-N` with `{"login": "personN", "id": N}`, and
//! any other token with a 401. As GitHub does, it refuses a request with no
//! User-Agent (a 403) and answers `incorrect_client_credentials` to a wrong
//! client id or secret.

const std = @import("std");
const Io = std.Io;

pub const client_id = "fake-client-id";
/// Bytes a form must encode, so the client's encoding is tested.
pub const client_secret = "fake-secret&=+%~";
/// How long a slow answer waits. A stop cancels the wait.
const slow_ms = 30_000;
const huge_bytes = 1 << 20;

pub const Fake = struct {
    io: Io,
    gpa: std.mem.Allocator,
    server: Io.net.Server,
    port: u16,
    accepting: Io.Future(void) = undefined,
    conns: Io.Group = .init,
    /// The token exchanges it has answered, which a test reads to see that a
    /// refusal reached no one.
    exchanges: std.atomic.Value(u32) = .init(0),
    url_buf: [32]u8 = undefined,

    pub fn start(io: Io, gpa: std.mem.Allocator) !*Fake {
        const f = try gpa.create(Fake);
        errdefer gpa.destroy(f);
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", 0);
        f.* = .{ .io = io, .gpa = gpa, .server = try addr.listen(io, .{}), .port = 0 };
        errdefer f.server.deinit(io);
        f.port = f.server.socket.address.getPort();
        f.accepting = try io.concurrent(accept_loop, .{f});
        return f;
    }

    pub fn stop(f: *Fake) void {
        f.accepting.cancel(f.io);
        f.conns.cancel(f.io);
        f.server.deinit(f.io);
        f.gpa.destroy(f);
    }

    /// `http://127.0.0.1:<port>`, the base URL of both its halves.
    pub fn base(f: *Fake) []const u8 {
        return std.fmt.bufPrint(&f.url_buf, "http://127.0.0.1:{d}", .{f.port}) catch unreachable;
    }
};

fn accept_loop(f: *Fake) void {
    while (true) {
        const stream = f.server.accept(f.io) catch return;
        f.conns.concurrent(f.io, serve_connection, .{ f, stream }) catch stream.close(f.io);
    }
}

fn serve_connection(f: *Fake, stream: Io.net.Stream) void {
    defer stream.close(f.io);
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var sr = stream.reader(f.io, &read_buf);
    var sw = stream.writer(f.io, &write_buf);
    var server = std.http.Server.init(&sr.interface, &sw.interface);
    var req = server.receiveHead() catch return;
    handle(f, &req) catch {};
}

const json = [_]std.http.Header{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};

fn handle(f: *Fake, req: *std.http.Server.Request) !void {
    var arena_state: std.heap.ArenaAllocator = .init(f.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The head's strings point into the read buffer, which the body's read
    // reuses.
    const target = try arena.dupe(u8, req.head.target);
    const method = req.head.method;
    var user_agent = false;
    var accept: []const u8 = "";
    var authorization: []const u8 = "";
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "user-agent") and h.value.len > 0) user_agent = true;
        if (std.ascii.eqlIgnoreCase(h.name, "accept")) accept = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorization = try arena.dupe(u8, h.value);
    }
    const authorize = "/login/oauth/authorize?";
    if (method == .GET and std.mem.startsWith(u8, target, authorize)) return authorized(req, arena, target[authorize.len..]);
    if (!user_agent) return req.respond("Please send a User-Agent.\n", .{ .status = .forbidden, .keep_alive = false });
    if (method == .POST and std.mem.eql(u8, target, "/login/oauth/access_token")) {
        var b: [256]u8 = undefined;
        const form = try req.readerExpectNone(&b).allocRemaining(arena, .limited(8192));
        _ = f.exchanges.fetchAdd(1, .acq_rel);
        return token(f, req, arena, form, std.mem.indexOf(u8, accept, "application/json") != null);
    }
    if (method == .GET and std.mem.eql(u8, target, "/user")) return user(req, arena, authorization);
    return req.respond("{\"message\":\"Not Found\"}", .{ .status = .not_found, .keep_alive = false, .extra_headers = &json });
}

/// The value of `name` in a form or a query, decoded, or null.
fn field(arena: std.mem.Allocator, form: []const u8, name: []const u8) !?[]const u8 {
    var pairs = std.mem.splitScalar(u8, form, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return try form_decode(arena, pair[eq + 1 ..]);
    }
    return null;
}

fn authorized(req: *std.http.Server.Request, arena: std.mem.Allocator, query: []const u8) !void {
    const back = (try field(arena, query, "redirect_uri")) orelse return error.NoRedirect;
    const state = (try field(arena, query, "state")) orelse return error.NoState;
    const location = if (try field(arena, query, "as")) |code|
        try std.fmt.allocPrint(arena, "{s}?code={s}&state={s}", .{ back, code, state })
    else
        try std.fmt.allocPrint(arena, "{s}?error=access_denied&state={s}", .{ back, state });
    return req.respond("", .{ .status = .found, .keep_alive = false, .extra_headers = &.{.{ .name = "location", .value = location }} });
}

fn token(f: *Fake, req: *std.http.Server.Request, arena: std.mem.Allocator, form: []const u8, wants_json: bool) !void {
    const id = (try field(arena, form, "client_id")) orelse "";
    const secret = (try field(arena, form, "client_secret")) orelse "";
    const code = (try field(arena, form, "code")) orelse "";
    if (!wants_json) return req.respond("access_token=tok-id-1&scope=&token_type=bearer", .{ .keep_alive = false });
    if (!std.mem.eql(u8, id, client_id) or !std.mem.eql(u8, secret, client_secret)) {
        return req.respond("{\"error\":\"incorrect_client_credentials\"}", .{ .keep_alive = false, .extra_headers = &json });
    }
    if (std.mem.startsWith(u8, code, "user-id-")) {
        const body = try std.fmt.allocPrint(arena, "{{\"access_token\":\"tok-id-{s}\",\"token_type\":\"bearer\",\"scope\":\"\"}}", .{code["user-id-".len..]});
        return req.respond(body, .{ .keep_alive = false, .extra_headers = &json });
    }
    if (std.mem.eql(u8, code, "slow")) {
        f.io.sleep(.fromMilliseconds(slow_ms), .awake) catch return;
    }
    if (std.mem.eql(u8, code, "malformed")) {
        return req.respond("{\"access_token\":\"tok-id-1\",\"scope\":", .{ .keep_alive = false, .extra_headers = &json });
    }
    if (std.mem.eql(u8, code, "huge")) {
        const body = try arena.alloc(u8, huge_bytes);
        @memset(body, ' ');
        return req.respond(body, .{ .keep_alive = false, .extra_headers = &json });
    }
    return req.respond("{\"error\":\"bad_verification_code\"}", .{ .keep_alive = false, .extra_headers = &json });
}

fn user(req: *std.http.Server.Request, arena: std.mem.Allocator, authorization: []const u8) !void {
    const prefix = "Bearer tok-id-";
    if (std.mem.startsWith(u8, authorization, prefix)) {
        const id = std.fmt.parseInt(u64, authorization[prefix.len..], 10) catch 0;
        if (id > 0) {
            const body = try std.fmt.allocPrint(arena, "{{\"login\":\"person{d}\",\"id\":{d},\"type\":\"User\",\"site_admin\":false}}", .{ id, id });
            return req.respond(body, .{ .keep_alive = false, .extra_headers = &json });
        }
    }
    return req.respond("{\"message\":\"Bad credentials\"}", .{ .status = .unauthorized, .keep_alive = false, .extra_headers = &json });
}

fn form_decode(arena: std.mem.Allocator, v: []const u8) ![]u8 {
    const out = try arena.alloc(u8, v.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        if (v[i] == '+') {
            out[n] = ' ';
        } else if (v[i] == '%' and i + 2 < v.len) {
            out[n] = try std.fmt.parseInt(u8, v[i + 1 .. i + 3], 16);
            i += 2;
        } else out[n] = v[i];
        n += 1;
    }
    return out[0..n];
}
