//! A fake GitHub for tests: plain HTTP on 127.0.0.1, an ephemeral port, the
//! two endpoints the host calls (and `/zen`). One task per connection, one
//! request per connection (the client sends `connection: close`).
//!
//! What a code or a token makes it do:
//!
//! | code            | `POST /login/oauth/access_token`                   |
//! |-----------------|----------------------------------------------------|
//! | `good`          | `{"access_token": "tok-good", ...}`                |
//! | `bad`           | `{"error": "bad_verification_code", ...}` (a 200, as GitHub) |
//! | `slow`          | no answer for `slow_ms` (a test's deadline is far shorter) |
//! | `malformed`     | a body cut off mid-JSON                            |
//! | `huge`          | a 1 MiB body with its Content-Length               |
//! | `huge-chunked`  | a 1 MiB body, chunked, no length                   |
//! | `crlf-token`    | a token with CR LF in it                           |
//! | `user-X`        | the token `tok-X`, for `/user` below               |
//!
//! | token           | `GET /user`                                        |
//! |-----------------|----------------------------------------------------|
//! | `tok-good`      | `{"login": "octocat", "id": 583231, ...}`          |
//! | `tok-slow`      | no answer for `slow_ms`                            |
//! | `tok-malformed` | a body cut off mid-JSON                            |
//! | `tok-huge`      | a 1 MiB body                                       |
//! | `tok-id-N`      | `{"login": "personN", "id": N, ...}`: as many people as a test wants (the code `user-id-N`) |
//! | anything else   | 401 `{"message": "Bad credentials"}`               |
//!
//! As GitHub does, it refuses a request with no User-Agent (403), answers
//! the token form-encoded unless asked for JSON, and answers
//! `incorrect_client_credentials` to a wrong client id or secret.
const std = @import("std");
const Io = std.Io;

pub const client_id = "fake-client-id";
/// Bytes a form must encode, so the client's encoding is tested.
pub const client_secret = "fake secret&=+%~";
pub const user_id: u64 = 583231;
pub const user_login = "octocat";
/// How long a slow answer waits. A stop cancels the wait.
pub const slow_ms = 30_000;
pub const huge_bytes = 1 << 20;

pub const Fake = struct {
    io: Io,
    gpa: std.mem.Allocator,
    server: Io.net.Server,
    port: u16,
    accepting: Io.Future(void) = undefined,
    conns: Io.Group = .init,
    requests: std.atomic.Value(u32) = .init(0),
    without_user_agent: std.atomic.Value(u32) = .init(0),
    url_buf: [32]u8 = undefined,

    pub fn start(io: Io, gpa: std.mem.Allocator) !*Fake {
        const f = try gpa.create(Fake);
        errdefer gpa.destroy(f);
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", 0);
        f.* = .{ .io = io, .gpa = gpa, .server = try addr.listen(io, .{}), .port = 0 };
        errdefer f.server.deinit(io);
        f.port = f.server.socket.address.getPort();
        f.accepting = try io.concurrent(acceptLoop, .{f});
        return f;
    }

    pub fn stop(f: *Fake) void {
        f.accepting.cancel(f.io);
        f.conns.cancel(f.io);
        f.server.deinit(f.io);
        f.gpa.destroy(f);
    }

    /// `http://127.0.0.1:<port>`, the base URL for both of the client's.
    pub fn base(f: *Fake) []const u8 {
        return std.fmt.bufPrint(&f.url_buf, "http://127.0.0.1:{d}", .{f.port}) catch unreachable;
    }
};

fn acceptLoop(f: *Fake) void {
    while (true) {
        const stream = f.server.accept(f.io) catch return;
        f.conns.concurrent(f.io, serveConn, .{ f, stream }) catch stream.close(f.io);
    }
}

fn serveConn(f: *Fake, stream: Io.net.Stream) void {
    defer stream.close(f.io);
    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var sr = stream.reader(f.io, &rbuf);
    var sw = stream.writer(f.io, &wbuf);
    var server = std.http.Server.init(&sr.interface, &sw.interface);
    var req = server.receiveHead() catch return;
    handle(f, &req) catch {};
}

const json = [_]std.http.Header{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};

fn handle(f: *Fake, req: *std.http.Server.Request) !void {
    _ = f.requests.fetchAdd(1, .acq_rel);
    var arena_state: std.heap.ArenaAllocator = .init(f.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // **THE HEAD'S STRINGS POINT INTO THE READ BUFFER**: copied before the
    // body is read over them.
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
    if (!user_agent) {
        _ = f.without_user_agent.fetchAdd(1, .acq_rel);
        return req.respond("Request forbidden by administrative rules. Please make sure your request has a User-Agent header.\n", .{ .status = .forbidden, .keep_alive = false });
    }

    if (method == .POST and std.mem.eql(u8, target, "/login/oauth/access_token")) {
        var b: [256]u8 = undefined;
        const form = try req.readerExpectNone(&b).allocRemaining(arena, .limited(8192));
        return token(f, req, arena, form, std.mem.indexOf(u8, accept, "application/json") != null);
    }
    if (method == .GET and std.mem.eql(u8, target, "/user")) return user(f, req, authorization);
    if (method == .GET and std.mem.eql(u8, target, "/zen"))
        return req.respond("Keep it logically awesome.", .{ .keep_alive = false });
    return req.respond("{\"message\":\"Not Found\"}", .{ .status = .not_found, .keep_alive = false, .extra_headers = &json });
}

fn token(f: *Fake, req: *std.http.Server.Request, arena: std.mem.Allocator, form: []const u8, wants_json: bool) !void {
    var id: []const u8 = "";
    var secret: []const u8 = "";
    var code: []const u8 = "";
    var pairs = std.mem.splitScalar(u8, form, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const value = try formDecode(arena, pair[eq + 1 ..]);
        const name = pair[0..eq];
        if (std.mem.eql(u8, name, "client_id")) id = value;
        if (std.mem.eql(u8, name, "client_secret")) secret = value;
        if (std.mem.eql(u8, name, "code")) code = value;
    }
    if (!wants_json) {
        return req.respond("access_token=tok-good&scope=&token_type=bearer", .{ .keep_alive = false });
    }
    if (!std.mem.eql(u8, id, client_id) or !std.mem.eql(u8, secret, client_secret)) {
        return req.respond("{\"error\":\"incorrect_client_credentials\",\"error_description\":\"The client_id and/or client_secret passed are incorrect.\"}", .{ .keep_alive = false, .extra_headers = &json });
    }
    if (std.mem.eql(u8, code, "good")) return granted(req, arena, "tok-good");
    if (std.mem.startsWith(u8, code, "user-")) {
        return granted(req, arena, try std.fmt.allocPrint(arena, "tok-{s}", .{code["user-".len..]}));
    }
    if (std.mem.eql(u8, code, "slow")) {
        f.io.sleep(.fromMilliseconds(slow_ms), .awake) catch return;
        return granted(req, arena, "tok-good");
    }
    if (std.mem.eql(u8, code, "malformed")) {
        return req.respond("{\"access_token\":\"tok-good\",\"scope\":", .{ .keep_alive = false, .extra_headers = &json });
    }
    if (std.mem.eql(u8, code, "huge")) return huge(req, arena, false);
    if (std.mem.eql(u8, code, "huge-chunked")) return huge(req, arena, true);
    if (std.mem.eql(u8, code, "crlf-token")) {
        return req.respond("{\"access_token\":\"tok\\r\\nX-Evil: 1\",\"token_type\":\"bearer\",\"scope\":\"\"}", .{ .keep_alive = false, .extra_headers = &json });
    }
    return req.respond("{\"error\":\"bad_verification_code\",\"error_description\":\"The code passed is incorrect or expired.\",\"error_uri\":\"https://docs.github.com/apps/managing-oauth-apps/troubleshooting-oauth-app-access-token-request-errors/#bad-verification-code\"}", .{ .keep_alive = false, .extra_headers = &json });
}

fn granted(req: *std.http.Server.Request, arena: std.mem.Allocator, tok: []const u8) !void {
    const body = try std.fmt.allocPrint(arena, "{{\"access_token\":\"{s}\",\"token_type\":\"bearer\",\"scope\":\"\"}}", .{tok});
    return req.respond(body, .{ .keep_alive = false, .extra_headers = &json });
}

fn user(f: *Fake, req: *std.http.Server.Request, authorization: []const u8) !void {
    const prefix = "Bearer ";
    const tok = if (std.mem.startsWith(u8, authorization, prefix)) authorization[prefix.len..] else "";
    if (std.mem.eql(u8, tok, "tok-good")) {
        return req.respond(std.fmt.comptimePrint(
            "{{\"login\":\"{s}\",\"id\":{d},\"node_id\":\"MDQ6VXNlcjE=\",\"type\":\"User\",\"site_admin\":false,\"name\":\"The Octocat\",\"public_repos\":8}}",
            .{ user_login, user_id },
        ), .{ .keep_alive = false, .extra_headers = &json });
    }
    if (std.mem.startsWith(u8, tok, "tok-id-")) {
        const id = std.fmt.parseInt(u64, tok["tok-id-".len..], 10) catch 0;
        if (id > 0) {
            var buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&buf, "{{\"login\":\"person{d}\",\"id\":{d},\"type\":\"User\",\"site_admin\":false}}", .{ id, id }) catch unreachable;
            return req.respond(body, .{ .keep_alive = false, .extra_headers = &json });
        }
    }
    if (std.mem.eql(u8, tok, "tok-slow")) {
        f.io.sleep(.fromMilliseconds(slow_ms), .awake) catch return;
        return req.respond("{}", .{ .keep_alive = false, .extra_headers = &json });
    }
    if (std.mem.eql(u8, tok, "tok-malformed")) {
        return req.respond("{\"login\":\"octocat\",\"id\":", .{ .keep_alive = false, .extra_headers = &json });
    }
    if (std.mem.eql(u8, tok, "tok-huge")) {
        var arena_state: std.heap.ArenaAllocator = .init(f.gpa);
        defer arena_state.deinit();
        return huge(req, arena_state.allocator(), false);
    }
    return req.respond("{\"message\":\"Bad credentials\",\"documentation_url\":\"https://docs.github.com/rest\",\"status\":\"401\"}", .{ .status = .unauthorized, .keep_alive = false, .extra_headers = &json });
}

/// A well-formed JSON body of `huge_bytes`, so only its size is wrong.
fn huge(req: *std.http.Server.Request, arena: std.mem.Allocator, chunked: bool) !void {
    const head = "{\"access_token\":\"tok-good\",\"login\":\"octocat\",\"id\":1,\"pad\":\"";
    const tail = "\"}";
    const body = try arena.alloc(u8, huge_bytes);
    @memcpy(body[0..head.len], head);
    @memset(body[head.len .. body.len - tail.len], 'x');
    @memcpy(body[body.len - tail.len ..], tail);
    if (!chunked) return req.respond(body, .{ .keep_alive = false, .extra_headers = &json });
    var hbuf: [1024]u8 = undefined;
    var bw = try req.respondStreaming(&hbuf, .{ .respond_options = .{
        .keep_alive = false,
        .transfer_encoding = .chunked,
        .extra_headers = &json,
    } });
    var at: usize = 0;
    while (at < body.len) : (at += 4096) {
        try bw.writer.writeAll(body[at..@min(at + 4096, body.len)]);
        try bw.flush();
    }
    try bw.end();
}

fn formDecode(arena: std.mem.Allocator, v: []const u8) ![]u8 {
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
