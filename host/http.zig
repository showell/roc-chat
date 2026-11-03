//! This is the HTTP server. It reads each request's head, asks the Roc app
//! whether to read its body and how much (`roc_admission`), reads it, hands
//! the whole request to the app (`roc_handle_http_request`), and writes back
//! whatever response the app gives. It does no routing: app/Route.roc
//! decides what each path means.
//!
//! Each connection gets a task of its own and one request, and every answer
//! says `connection: close`. A single mutex, the turn, is held while the
//! app judges a head or handles a request, so the app makes one call at a
//! time. The turn is never held while the network is read or written, so a
//! slow client delays nobody else.
//!
//! Reads must finish within `Limits.read_ms` and writes within
//! `Limits.write_ms`. A watchdog shuts the socket of a client that is too
//! slow. An oversized head gets a 431, an oversized body a 413, and a late
//! request a 408.
//!
//! The app judges each request's head before any body is read
//! (`roc_admission`): it refuses a request outright, or says how large a
//! body to read and how much longer than the request's read time it may
//! take. The bodies being read or held, across every connection, are held
//! to `Limits.body_bytes_in_flight_most`; a request whose body would pass
//! it gets a 503, its body unread.
//!
//! When the app marks an answer as a `Stream`, the connection stays open
//! and sends the frames the app publishes to the stream's key
//! (host/bus.zig). host/sse.zig limits how many streams are open at once,
//! and a stream open for `Limits.stream_most_ms` is ended, so its client
//! reconnects and is asked again who it is.
//!
//! The server listens on 127.0.0.1 only; a public name reaches it through
//! a proxy on the same machine. The app decides who each request is (a
//! signed session, or an agent's key) and refuses requests that other web
//! sites make through a browser (app/RequestOrigin.roc). The server's
//! secret, which signs sessions, is the host's alone
//! (host/sign_in_primitives.zig).

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const seam = @import("seam.zig");
const files = @import("file_primitives.zig");
const bus = @import("bus.zig");
const sse = @import("sse.zig");
const sign_in = @import("sign_in_primitives.zig");

const log = std.log.scoped(.http);

/// The port when none is given.
pub const default_port: u16 = 9611;

pub const Limits = struct {
    /// The request, head and body, read whole from the accept.
    read_ms: u32 = 10_000,
    /// The response, written whole.
    write_ms: u32 = 10_000,
    /// The most body bytes read or held at once, across every connection:
    /// a few uploads at their largest (the app's `upload_body_allowance`).
    /// A request is charged its stated length, or its allowance when its
    /// body is chunked, from before its body is read until it is answered.
    body_bytes_in_flight_most: usize = 64 * 1024 * 1024,
    /// After a refusal, the most time spent draining what the client still
    /// sends (`linger`), inside the write deadline.
    linger_ms: u32 = 1_000,
    /// A stream quiet this long sends the keepalive.
    stream_ping_ms: u32 = 25_000,
    /// The most streams held at once, at most `sse.Slots.most_ever`.
    streams_most: u32 = sse.Slots.most_ever,
    /// The most streams one holder holds at once.
    streams_per_holder: u32 = 8,
    /// The longest a stream is held: then it ends, and its client, which
    /// reconnects, is asked again who it is.
    stream_most_ms: u32 = 60 * 60 * 1000,
};

/// How a server is set up: its port (0 for any free one), its limits, its
/// data root, and its public origin, `https://` and the name a proxy
/// serves it under, or empty for none.
pub const Setup = struct {
    port: u16,
    limits: Limits = .{},
    root: *const files.DataRoot,
    public_origin: []const u8 = "",
};

/// The most a request's head may be: past it, a 431.
pub const head_most = 16 * 1024;

pub const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    limits: Limits,
    listener: net.Server,
    /// The data root the file primitives answer from, the caller's, open
    /// for the server's life.
    root: *const files.DataRoot,
    /// Held while a request's Roc call runs, and only then.
    turn: Io.Mutex = .init,
    /// Every held stream, by its key.
    hub: bus.Hub,
    slots: sse.Slots = .{},
    /// The secret sessions are signed with, read from the data root.
    secret: sign_in.ServerSecret,
    /// `https://` and the name a proxy serves this server under, or empty.
    public_origin: []const u8,
    /// The body bytes charged to requests not yet answered.
    body_bytes_in_flight: std.atomic.Value(usize) = .init(0),

    /// Starts the app on `setup.root` (`start_app`), reads the secret
    /// there (made first when there is none), then listens on 127.0.0.1 at
    /// `setup.port`. Tests pass 0 to get any free port.
    pub fn listen(io: Io, gpa: std.mem.Allocator, setup: Setup) !Server {
        try start_app(io, gpa, setup.root);
        const secret = try sign_in.ServerSecret.load_or_create(io, setup.root.dir);
        const addr: net.IpAddress = try .parse("127.0.0.1", setup.port);
        return .{
            .io = io,
            .gpa = gpa,
            .limits = setup.limits,
            .listener = try addr.listen(io, .{ .reuse_address = true }),
            .root = setup.root,
            .hub = .init(io, gpa),
            .secret = secret,
            .public_origin = setup.public_origin,
        };
    }

    /// What this server's Roc calls answer from.
    fn answering(s: *Server) Answering {
        return .{
            .root = s.root,
            .io = s.io,
            .hub = &s.hub,
            .slots = &s.slots,
            .secret = &s.secret,
            .public_origin = s.public_origin,
        };
    }

    /// The port it listens on.
    pub fn port(s: *const Server) u16 {
        return s.listener.socket.address.getPort();
    }

    /// Serves each connection on a task of its own until `stop`. When it
    /// returns, every connection's task has ended.
    pub fn run(s: *Server) !void {
        defer s.hub.deinit();
        defer s.listener.deinit(s.io);
        var connections: Io.Group = .init;
        defer connections.cancel(s.io);
        while (true) {
            const connection = s.listener.accept(s.io) catch |e| switch (e) {
                // `stop`, or the task's own cancel.
                error.SocketNotListening, error.Canceled => return,
                else => {
                    log.warn("accept failed: {t}", .{e});
                    continue;
                },
            };
            connections.concurrent(s.io, serve, .{ s, connection }) catch |e| {
                // Served here instead, its read would have no deadline and
                // would hold the accept loop.
                log.warn("no task for a connection ({t}): answered 503", .{e});
                busy(s.io, connection);
            };
        }
    }

    /// `run` returns: no more connections are accepted.
    pub fn stop(s: *Server) void {
        const listening: net.Stream = .{ .socket = s.listener.socket };
        listening.shutdown(s.io, .both) catch {};
    }

    /// One connection: its head read under the read deadline and judged by
    /// the Roc in the turn, then the body it admits read, the request
    /// answered by the Roc in the turn, and the answer written under the
    /// write deadline or held open as a stream, then closed.
    fn serve(s: *Server, connection: net.Stream) void {
        defer connection.close(s.io);
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var read_buf: [head_most]u8 = undefined;
        var write_buf: [16 * 1024]u8 = undefined;
        var sr = connection.reader(s.io, &read_buf);
        var sw = connection.writer(s.io, &write_buf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);

        var fired = std.atomic.Value(bool).init(false);
        const began = Io.Clock.now(.awake, s.io);
        const head = blk: {
            var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.read_ms, net.ShutdownHow.recv, &fired }) catch |e| {
                log.warn("no task for the read's watchdog ({t}): closed", .{e});
                return;
            };
            defer watchdog.cancel(s.io);
            break :blk read_head(arena, &http, s.port(), &fired);
        };
        const received = switch (head) {
            .parsed => |r| r,
            .refused => |r| return s.refuse(connection, &http, r),
            .gone => return,
        };
        const allowance = switch (s.admit_in_turn(arena, received.parsed)) {
            .admit => |a| a,
            .refuse => |refusal| return s.refuse(connection, &http, .{ .req = received.req, .answer = refusal }),
        };
        var charged: usize = 0;
        defer _ = s.body_bytes_in_flight.fetchSub(charged, .monotonic);
        // The body has what is left of the read's time, and the app's grace.
        const request: Read = if (!received.req.head.method.requestHasBody()) head else blk: {
            const wanted = body_bytes_wanted(received.req.head, allowance.body_most);
            if (!s.charge_body_bytes(wanted)) {
                log.warn("{d} body bytes for {f} would pass the {d} in flight: answered 503", .{ wanted, files.loggable(received.parsed.path), s.limits.body_bytes_in_flight_most });
                break :blk .{ .refused = .{ .req = received.req, .answer = in_flight_full } };
            }
            charged = wanted;
            const spent: u64 = @intCast(@max(0, began.untilNow(s.io, .awake).toMilliseconds()));
            const ms: u32 = @intCast(@min(std.math.maxInt(u32), (@as(u64, s.limits.read_ms) -| spent) + allowance.body_grace_ms));
            var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, ms, net.ShutdownHow.recv, &fired }) catch |e| {
                log.warn("no task for the body's watchdog ({t}): closed", .{e});
                return;
            };
            defer watchdog.cancel(s.io);
            break :blk read_body(arena, received, allowance.body_most, &fired);
        };
        switch (request) {
            .gone => return,
            .parsed => |p| {
                var req = p.req;
                switch (s.answer_in_turn(arena, p.parsed)) {
                    .whole => |response| {
                        var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.write_ms, net.ShutdownHow.both, &fired }) catch |e| {
                            log.warn("no task for the write's watchdog ({t}): closed", .{e});
                            return;
                        };
                        defer watchdog.cancel(s.io);
                        req.respond(response.body, .{ .status = response.status, .keep_alive = false, .extra_headers = response.headers }) catch |e|
                            log.warn("the answer to {f} was not written ({t})", .{ files.loggable(p.parsed.path), e });
                    },
                    .stream => |stream| s.serve_stream(&arena_state, connection, &req, stream),
                }
            },
            .refused => |r| s.refuse(connection, &http, r),
        }
    }

    /// The refusal `r` written under the write deadline, its body unread,
    /// then what the client still sends drained (`linger`).
    fn refuse(s: *Server, connection: net.Stream, http: *std.http.Server, r: Refusal) void {
        var fired = std.atomic.Value(bool).init(false);
        var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.write_ms, net.ShutdownHow.both, &fired }) catch |e| {
            log.warn("no task for the write's watchdog ({t}): closed", .{e});
            return;
        };
        defer watchdog.cancel(s.io);
        if (r.req) |req| {
            var refused = req;
            // No `100 Continue`: the body is never wanted.
            refused.head.expect = null;
            refused.respond(r.answer.body, .{ .status = r.answer.status, .keep_alive = false, .extra_headers = r.answer.headers }) catch return;
        } else raw(http, r.answer.status);
        linger(s.io, connection, s.limits.linger_ms);
    }

    /// `n` more body bytes charged to the bytes in flight, unless they would
    /// pass the most: whether they were.
    fn charge_body_bytes(s: *Server, n: usize) bool {
        const before = s.body_bytes_in_flight.fetchAdd(n, .monotonic);
        if (before + n <= s.limits.body_bytes_in_flight_most) return true;
        _ = s.body_bytes_in_flight.fetchSub(n, .monotonic);
        return false;
    }

    /// The Roc's judgement of `parsed`'s head, in the turn.
    fn admit_in_turn(s: *Server, arena: std.mem.Allocator, parsed: Parsed) Admitted {
        s.turn.lockUncancelable(s.io);
        defer s.turn.unlock(s.io);
        return admit(arena, s.answering(), parsed);
    }

    /// The Roc's answer to `parsed`, in the turn. A stream subscribes to
    /// its key in the same turn, so a frame the app publishes after this
    /// call reaches it, and none before it does.
    fn answer_in_turn(s: *Server, arena: std.mem.Allocator, parsed: Parsed) Opened {
        s.turn.lockUncancelable(s.io);
        defer s.turn.unlock(s.io);
        return switch (answer(arena, s.answering(), parsed)) {
            .whole => |w| .{ .whole = w },
            .stream => |st| .{ .stream = .{
                .answer = st,
                .sub = s.hub.open(st.key) catch |e| {
                    log.warn("no subscriber for the stream {f} ({t}): answered 500", .{ files.loggable(parsed.path), e });
                    return .{ .whole = failed };
                },
            } },
        };
    }

    /// A held stream, on its connection's task, as its last answer: the
    /// head and the app's first bytes, then each frame published to its
    /// key, and the keepalive when it is quiet. Each write is under the
    /// write deadline, so a reader that stops reading is shut. It ends when
    /// a write fails, when its mailbox missed a frame (the browser
    /// reconnects and the app resumes it), when a newer stream of its
    /// holder takes its slot or the app ends its holder's streams, which
    /// wakes it at once, or when it has been held `stream_most_ms`.
    ///
    /// Once the first bytes are written, the call's arena is freed: the
    /// stream needs nothing of it after them (the hub keeps its own key, and
    /// its slot its own holder), so a stream held for hours holds none of
    /// the transcript its call read, decoded and rendered.
    fn serve_stream(s: *Server, arena_state: *std.heap.ArenaAllocator, connection: net.Stream, req: *std.http.Server.Request, opened: OpenStream) void {
        const sub = opened.sub;
        defer s.hub.close(sub);
        const held = s.slots.hold(s.io, .{ .all = s.limits.streams_most, .per_holder = s.limits.streams_per_holder }, .{
            .holder = opened.answer.holder,
            .stream = connection,
            .sub = sub,
        });
        defer s.slots.let_go(s.io, held);
        const headers = std.mem.concat(arena_state.allocator(), std.http.Header, &.{ &sse.headers, opened.answer.headers }) catch return;
        var head_buf: [4096]u8 = undefined;
        var body = blk: {
            var fired = std.atomic.Value(bool).init(false);
            var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.write_ms, net.ShutdownHow.both, &fired }) catch return;
            defer watchdog.cancel(s.io);
            break :blk req.respondStreaming(&head_buf, .{ .respond_options = .{
                .status = .ok,
                .keep_alive = false,
                .transfer_encoding = .none,
                .extra_headers = headers,
            } }) catch return;
        };
        // The head goes with the first bytes, even none, so the browser
        // knows it is connected.
        if (!s.push(connection, &body, opened.answer.body)) return;
        _ = arena_state.reset(.free_all);
        const opened_at = Io.Clock.now(.awake, s.io);
        while (!sub.has_missed()) {
            const held_ms: u64 = @intCast(@max(0, opened_at.untilNow(s.io, .awake).toMilliseconds()));
            if (held_ms >= s.limits.stream_most_ms) return;
            const wait: u32 = @intCast(@min(s.limits.stream_ping_ms, s.limits.stream_most_ms - held_ms));
            const frame = switch (sub.next(wait)) {
                .frame => |m| m,
                .idle => null,
                .ended, .canceled => return,
            };
            defer if (frame) |f| sub.gpa.free(f);
            if (!s.push(connection, &body, frame orelse sse.ping)) return;
        }
    }

    /// `bytes` written onto the socket under the write deadline: whether
    /// they were.
    fn push(s: *Server, connection: net.Stream, body: *std.http.BodyWriter, bytes: []const u8) bool {
        var fired = std.atomic.Value(bool).init(false);
        var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.write_ms, net.ShutdownHow.both, &fired }) catch return false;
        defer watchdog.cancel(s.io);
        // The body's buffer into the connection's, then the connection's
        // onto the socket.
        body.writer.writeAll(bytes) catch return false;
        body.writer.flush() catch return false;
        body.flush() catch return false;
        return true;
    }
};

/// The app's start, once, before the server listens (`roc_start`): it
/// makes the first data in an empty data folder, and refuses a folder that
/// holds part of a chat, so the server never serves from one.
pub fn start_app(io: Io, gpa: std.mem.Allocator, root: *const files.DataRoot) error{AppStartFailed}!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    seam.begin(.{ .arena = arena_state.allocator(), .root = root, .io = io });
    const started = seam.roc_start();
    seam.end();
    if (started != .ready) {
        log.warn("the app cannot start on its data folder: it holds part of a chat, or cannot be read", .{});
        return error.AppStartFailed;
    }
}

/// What the turn gives a connection: a whole answer to write, or a stream
/// and its subscriber.
const Opened = union(enum) { whole: Written, stream: OpenStream };

const OpenStream = struct { answer: Streamed, sub: *bus.Subscriber };

/// A connection there is no task to serve: a 503 written straight to it,
/// a few bytes the socket's own buffer takes, and closed.
fn busy(io: Io, connection: net.Stream) void {
    defer connection.close(io);
    var w = connection.writer(io, &.{});
    w.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
}

/// The parts of a request the Roc is handed, copied out of the read
/// buffer, which the body's read reuses.
pub const Parsed = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    headers: []const std.http.Header,
    body: []const u8,
    /// The port the server listens on, so the app knows its own origin.
    port: u16,
};

/// A response as the host writes it: a status std knows, and headers each
/// free of CR, LF and NUL.
const Written = struct {
    status: std.http.Status,
    headers: []const std.http.Header,
    body: []const u8,
};

/// A request read: std's, to answer it by, and its parts copied out.
const Received = struct { req: std.http.Server.Request, parsed: Parsed };

const Read = union(enum) {
    parsed: Received,
    refused: Refusal,
    /// Nothing to answer: the client went.
    gone,
};

/// A request refused before the Roc answers it, its body unread or not
/// read whole: `req` when its head was read, else only `answer.status` is
/// written.
const Refusal = struct { req: ?std.http.Server.Request, answer: Written };

/// The answer when the bytes in flight are full.
const in_flight_full: Written = .{ .status = .service_unavailable, .headers = &.{}, .body = "the server is busy; try again\n" };

/// The body bytes a request may bring into memory, charged before it is
/// read: none when it has no body, or states a length past `most` (it is
/// refused unread), else its stated length, or `most` when it is chunked.
fn body_bytes_wanted(head: std.http.Server.Request.Head, most: usize) usize {
    if (head.content_length) |n| return if (n > most) 0 else @intCast(n);
    if (head.transfer_encoding == .none) return 0;
    return most;
}

/// The head of the request on `http`, copied into `arena`, its body not yet
/// read; or the refusal to send.
fn read_head(arena: std.mem.Allocator, http: *std.http.Server, port: u16, fired: *std.atomic.Value(bool)) Read {
    var req = http.receiveHead() catch |e| return switch (e) {
        error.HttpHeadersOversize => status_only(.request_header_fields_too_large),
        error.HttpHeadersInvalid => status_only(.bad_request),
        error.HttpRequestTruncated, error.HttpConnectionClosing, error.ReadFailed => if (fired.load(.acquire))
            status_only(.request_timeout)
        else
            .gone,
    };
    const parsed = copy_head(arena, &req, port) catch return .{ .refused = .{ .req = req, .answer = failed } };
    return .{ .parsed = .{ .req = req, .parsed = parsed } };
}

/// The body of the request `received`, at most `body_most` bytes, copied
/// into `arena`; or the refusal to send.
fn read_body(arena: std.mem.Allocator, received: Received, body_most: usize, fired: *std.atomic.Value(bool)) Read {
    var req = received.req;
    var with_body = received.parsed;
    // No length and not chunked: no body (std asserts one or the other).
    if (req.head.transfer_encoding == .none and req.head.content_length == null) req.head.content_length = 0;
    if (req.head.content_length) |n| if (n > body_most) return too_large(req);
    var body_buf: [256]u8 = undefined;
    const body = req.readerExpectContinue(&body_buf) catch return .gone;
    with_body.body = body.allocRemaining(arena, .limited(body_most + 1)) catch |e| return switch (e) {
        error.StreamTooLong => too_large(req),
        error.OutOfMemory => .{ .refused = .{ .req = req, .answer = failed } },
        error.ReadFailed => if (fired.load(.acquire)) timed_out(req) else .gone,
    };
    // std's reader treats a closed socket as the body's end, with no
    // error, and the watchdog closes the socket. So check for a short body.
    if (fired.load(.acquire)) return timed_out(req);
    if (req.head.content_length) |n| if (with_body.body.len != n) return .gone;
    return .{ .parsed = .{ .req = req, .parsed = with_body } };
}

fn too_large(req: std.http.Server.Request) Read {
    return .{ .refused = .{ .req = req, .answer = .{ .status = .payload_too_large, .headers = &.{}, .body = "the body is too large\n" } } };
}

fn timed_out(req: std.http.Server.Request) Read {
    return .{ .refused = .{ .req = req, .answer = .{ .status = .request_timeout, .headers = &.{}, .body = "the request was too slow\n" } } };
}

/// A refusal with no head to answer: its status alone.
fn status_only(status: std.http.Status) Read {
    return .{ .refused = .{ .req = null, .answer = .{ .status = status, .headers = &.{}, .body = "" } } };
}

fn copy_head(arena: std.mem.Allocator, req: *const std.http.Server.Request, port: u16) !Parsed {
    const target = req.head.target;
    const at = std.mem.indexOfScalar(u8, target, '?');
    var headers: std.ArrayList(std.http.Header) = .empty;
    var it = req.iterateHeaders();
    while (it.next()) |h| try headers.append(arena, .{
        .name = try arena.dupe(u8, h.name),
        .value = try arena.dupe(u8, h.value),
    });
    return .{
        .method = @tagName(req.head.method),
        .path = try arena.dupe(u8, target[0 .. at orelse target.len]),
        .query = try arena.dupe(u8, if (at) |q| target[q + 1 ..] else ""),
        .headers = headers.items,
        .body = "",
        .port = port,
    };
}

/// The Roc's answer: a whole one, or a stream to hold open.
pub const Answered = union(enum) { whole: Written, stream: Streamed };

/// A stream as the app answered it: its headers, written after the host's
/// (`sse.headers`), its first bytes, its key on the bus and its holder.
pub const Streamed = struct {
    headers: []const std.http.Header,
    body: []const u8,
    key: []const u8,
    holder: []const u8,
};

/// What a call's hosted functions answer from, and the public origin the
/// app is told of.
pub const Answering = struct {
    root: *const files.DataRoot,
    io: Io,
    hub: *bus.Hub,
    slots: *sse.Slots,
    secret: *const sign_in.ServerSecret,
    public_origin: []const u8,
};

const failed: Written = .{ .status = .internal_server_error, .headers = &.{}, .body = "failed\n" };

/// Asks the app to answer `parsed`, and copies the answer into `arena`.
/// An answer the app got wrong becomes a 500: a status std doesn't know, a
/// header containing a CR, LF or NUL, or a malformed stream.
pub fn answer(arena: std.mem.Allocator, answering: Answering, parsed: Parsed) Answered {
    seam.begin(call_of(arena, answering));
    const r = seam.roc_handle_http_request(.{
        .body = .from(parsed.body),
        .headers = .from(parsed.headers),
        .method = .from(parsed.method),
        .path = .from(parsed.path),
        .public_origin = .from(answering.public_origin),
        .query = .from(parsed.query),
        .port = parsed.port,
    });
    seam.end();
    return checked(arena, parsed, r);
}

fn call_of(arena: std.mem.Allocator, answering: Answering) seam.Call {
    return .{
        .arena = arena,
        .root = answering.root,
        .io = answering.io,
        .hub = answering.hub,
        .slots = answering.slots,
        .secret = answering.secret,
    };
}

/// What the Roc judges of a request's head: refused, with its answer, or
/// admitted, with the most its body may be and how much longer than what
/// is left of the request's read time it may take.
pub const Admitted = union(enum) { admit: Allowance, refuse: Written };

pub const Allowance = struct { body_most: usize, body_grace_ms: u32 };

/// Asks the app to judge `parsed`'s head, its body not yet read, and copies
/// a refusal into `arena`. A refusal the app got wrong (a stream, or one
/// `checked` refuses) becomes a 500.
pub fn admit(arena: std.mem.Allocator, answering: Answering, parsed: Parsed) Admitted {
    seam.begin(call_of(arena, answering));
    const r = seam.roc_admission(.{
        .headers = .from(parsed.headers),
        .method = .from(parsed.method),
        .path = .from(parsed.path),
        .public_origin = .from(answering.public_origin),
        .port = parsed.port,
    });
    seam.end();
    return switch (r.verdict) {
        .admit => .{ .admit = .{
            .body_most = std.math.cast(usize, r.body_most) orelse std.math.maxInt(usize),
            .body_grace_ms = r.body_grace_ms,
        } },
        .refuse => switch (checked(arena, parsed, r.refusal)) {
            .whole => |w| .{ .refuse = w },
            .stream => {
                log.warn("the app refused {f} with a stream", .{files.loggable(parsed.path)});
                return .{ .refuse = failed };
            },
        },
    };
}

/// The app's answer `r` to `parsed`, its headers copied into `arena`, or a
/// 500 for an answer the app got wrong.
fn checked(arena: std.mem.Allocator, parsed: Parsed, r: seam.Response) Answered {
    const status = std.enums.fromInt(std.http.Status, r.status) orelse {
        log.warn("the app answered {f} with the status {d}, which is none", .{ files.loggable(parsed.path), r.status });
        return .{ .whole = failed };
    };
    const recs = r.headers.slice();
    const headers = arena.alloc(std.http.Header, recs.len) catch return .{ .whole = failed };
    for (recs, headers) |rec, *h| {
        h.* = .{ .name = rec.name.slice(), .value = rec.value.slice() };
        if (!header_safe(h.name) or !header_safe(h.value) or h.name.len == 0) {
            log.warn("the app answered {f} with a header holding CR, LF or NUL", .{files.loggable(parsed.path)});
            return .{ .whole = failed };
        }
    }
    const key = r.stream_key.slice();
    const holder = r.stream_holder.slice();
    switch (r.kind) {
        .whole => {
            if (key.len != 0 or holder.len != 0) {
                log.warn("the app answered {f} whole, naming a stream's key or holder", .{files.loggable(parsed.path)});
                return .{ .whole = failed };
            }
            return .{ .whole = .{ .status = status, .headers = headers, .body = r.body.slice() } };
        },
        .stream => {
            if (status != .ok or key.len == 0 or holder.len == 0 or holder.len > sse.holder_most) {
                log.warn("the app answered {f} with a stream of status {d}, a key of {d} bytes and a holder of {d} (200, some and 1 to {d})", .{ files.loggable(parsed.path), r.status, key.len, holder.len, sse.holder_most });
                return .{ .whole = failed };
            }
            return .{ .stream = .{ .headers = headers, .body = r.body.slice(), .key = key, .holder = holder } };
        },
    }
}

pub fn header_safe(bytes: []const u8) bool {
    return std.mem.indexOfAny(u8, bytes, "\r\n\x00") == null;
}

/// The watchdog. After `ms` it sets `fired` and shuts the socket: `.recv`
/// for a read, so a 408 can still be written, and `.both` for a write. The
/// caller cancels it when the work finishes in time.
fn shut_after(io: Io, connection: net.Stream, ms: u32, how: net.ShutdownHow, fired: *std.atomic.Value(bool)) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch return;
    fired.store(true, .release);
    connection.shutdown(io, how) catch {};
}

/// After a refusal, reads and drops whatever the client is still sending,
/// for at most `ms`. Closing a socket with unread bytes resets it, and the
/// client could lose the refusal.
fn linger(io: Io, connection: net.Stream, ms: u32) void {
    connection.shutdown(io, .send) catch return;
    var fired = std.atomic.Value(bool).init(false);
    var watchdog = io.concurrent(shut_after, .{ io, connection, ms, net.ShutdownHow.recv, &fired }) catch |e| {
        log.warn("no task for the linger's watchdog ({t}): closed", .{e});
        return;
    };
    defer watchdog.cancel(io);
    var buf: [4096]u8 = undefined;
    var r = connection.reader(io, &buf);
    _ = r.interface.discardRemaining() catch {};
}

/// A status written with no request to answer (a head that never came
/// whole, or was too big), then the close.
fn raw(http: *std.http.Server, status: std.http.Status) void {
    http.out.print("HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{ @backingInt(status), status.phrase() orelse "" }) catch return;
    http.out.flush() catch {};
}
