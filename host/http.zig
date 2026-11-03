//! This is the HTTP server. It reads each request whole, hands it to the
//! Roc app (`roc_handle_http_request`), and writes back whatever response
//! the app gives. It does no routing: app/Route.roc decides what each path
//! means.
//!
//! Each connection gets a task of its own and one request, and every answer
//! says `connection: close`. A single mutex, the turn, is held while the
//! app handles a request, so the app handles one request at a time. The
//! turn is taken only after the request has been read, and let go before
//! the answer is written, so a slow client delays nobody else.
//!
//! Reads must finish within `Limits.read_ms` and writes within
//! `Limits.write_ms`. A watchdog shuts the socket of a client that is too
//! slow. An oversized head gets a 431, an oversized body a 413, and a late
//! request a 408.
//!
//! When the app marks an answer as a `Stream`, the connection stays open
//! and sends the frames the app publishes to the stream's key
//! (host/bus.zig). host/sse.zig limits how many streams are open at once.
//!
//! The server listens on 127.0.0.1 only. Until sign-in exists, the app
//! treats every request as Steve's, so only this machine may reach it.
//! app/RequestOrigin.roc refuses requests that other web sites make
//! through a browser on this machine.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const seam = @import("seam.zig");
const files = @import("file_primitives.zig");
const bus = @import("bus.zig");
const sse = @import("sse.zig");

const log = std.log.scoped(.http);

/// The port when none is given.
pub const default_port: u16 = 9611;

pub const Limits = struct {
    /// The request, head and body, read whole from the accept.
    read_ms: u32 = 10_000,
    /// The response, written whole.
    write_ms: u32 = 10_000,
    /// The most a body may be: a message's form, with room to spare.
    body_most: usize = 64 * 1024,
    /// After a refusal, the most time spent draining what the client still
    /// sends (`linger`), inside the write deadline.
    linger_ms: u32 = 1_000,
    /// A stream quiet this long sends the keepalive.
    stream_ping_ms: u32 = 25_000,
    /// The most streams held at once, at most `sse.Slots.most_ever`.
    streams_most: u32 = sse.Slots.most_ever,
    /// The most streams one holder holds at once.
    streams_per_holder: u32 = 8,
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

    /// Listens on 127.0.0.1 at `at_port`. Tests pass 0 to get any free port.
    pub fn listen(io: Io, gpa: std.mem.Allocator, at_port: u16, limits: Limits, root: *const files.DataRoot) !Server {
        const addr: net.IpAddress = try .parse("127.0.0.1", at_port);
        return .{
            .io = io,
            .gpa = gpa,
            .limits = limits,
            .listener = try addr.listen(io, .{ .reuse_address = true }),
            .root = root,
            .hub = .init(io, gpa),
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

    /// One connection: its request read under the read deadline, answered
    /// by the Roc in the turn, the answer written under the write deadline
    /// or held open as a stream, then closed.
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
        const request = blk: {
            var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.read_ms, net.ShutdownHow.recv, &fired }) catch |e| {
                log.warn("no task for the read's watchdog ({t}): closed", .{e});
                return;
            };
            defer watchdog.cancel(s.io);
            break :blk read_request(arena, &http, .{ .limits = s.limits, .port = s.port() }, &fired);
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
                    .stream => |stream| s.serve_stream(arena, connection, &req, stream),
                }
            },
            .refused => |r| {
                var watchdog = s.io.concurrent(shut_after, .{ s.io, connection, s.limits.write_ms, net.ShutdownHow.both, &fired }) catch |e| {
                    log.warn("no task for the write's watchdog ({t}): closed", .{e});
                    return;
                };
                defer watchdog.cancel(s.io);
                if (r.req) |req| {
                    var refused = req;
                    refused.head.expect = null;
                    refused.respond(r.body, .{ .status = r.status, .keep_alive = false }) catch return;
                } else raw(&http, r.status);
                linger(s.io, connection, s.limits.linger_ms);
            },
        }
    }

    /// The Roc's answer to `parsed`, in the turn. A stream subscribes to
    /// its key in the same turn, so a frame the app publishes after this
    /// call reaches it, and none before it does.
    fn answer_in_turn(s: *Server, arena: std.mem.Allocator, parsed: Parsed) Opened {
        s.turn.lockUncancelable(s.io);
        defer s.turn.unlock(s.io);
        return switch (answer(arena, .{ .root = s.root, .io = s.io, .hub = &s.hub }, parsed)) {
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
    /// reconnects and the app resumes it), or when a newer stream of its
    /// holder takes its slot.
    fn serve_stream(s: *Server, arena: std.mem.Allocator, connection: net.Stream, req: *std.http.Server.Request, opened: OpenStream) void {
        const sub = opened.sub;
        defer s.hub.close(sub);
        const held = s.slots.hold(s.io, .{ .all = s.limits.streams_most, .per_holder = s.limits.streams_per_holder }, opened.answer.holder, connection);
        defer s.slots.let_go(s.io, held);
        const headers = std.mem.concat(arena, std.http.Header, &.{ &sse.headers, opened.answer.headers }) catch return;
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
        while (!sub.has_missed()) {
            const frame = switch (sub.next(s.limits.stream_ping_ms)) {
                .frame => |m| m,
                .idle => null,
                .canceled => return,
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

/// What a read needs of its server: the limits, and the port it listens on.
const Reading = struct { limits: Limits, port: u16 };

/// A response as the host writes it: a status std knows, and headers each
/// free of CR, LF and NUL.
const Written = struct {
    status: std.http.Status,
    headers: []const std.http.Header,
    body: []const u8,
};

const Read = union(enum) {
    parsed: struct { req: std.http.Server.Request, parsed: Parsed },
    /// Refused before the Roc is asked: `req` when the head was read.
    refused: struct { req: ?std.http.Server.Request, status: std.http.Status, body: []const u8 },
    /// Nothing to answer: the client went.
    gone,
};

/// The request on `http`, head and body, copied into `arena`; or the
/// refusal to send.
fn read_request(arena: std.mem.Allocator, http: *std.http.Server, reading: Reading, fired: *std.atomic.Value(bool)) Read {
    const limits = reading.limits;
    var req = http.receiveHead() catch |e| return switch (e) {
        error.HttpHeadersOversize => .{ .refused = .{ .req = null, .status = .request_header_fields_too_large, .body = "" } },
        error.HttpHeadersInvalid => .{ .refused = .{ .req = null, .status = .bad_request, .body = "" } },
        error.HttpRequestTruncated, error.HttpConnectionClosing, error.ReadFailed => if (fired.load(.acquire))
            .{ .refused = .{ .req = null, .status = .request_timeout, .body = "" } }
        else
            .gone,
    };
    const parsed = copy_head(arena, &req, reading.port) catch return .{ .refused = .{ .req = req, .status = .internal_server_error, .body = "failed\n" } };
    var with_body = parsed;
    if (req.head.method.requestHasBody()) {
        // No length and not chunked: no body (std asserts one or the other).
        if (req.head.transfer_encoding == .none and req.head.content_length == null) req.head.content_length = 0;
        if (req.head.content_length) |n| if (n > limits.body_most) return too_large(req);
        var body_buf: [256]u8 = undefined;
        const body = req.readerExpectContinue(&body_buf) catch return .gone;
        with_body.body = body.allocRemaining(arena, .limited(limits.body_most + 1)) catch |e| return switch (e) {
            error.StreamTooLong => too_large(req),
            error.OutOfMemory => .{ .refused = .{ .req = req, .status = .internal_server_error, .body = "failed\n" } },
            error.ReadFailed => if (fired.load(.acquire)) timed_out(req) else .gone,
        };
        // std's reader treats a closed socket as the body's end, with no
        // error, and the watchdog closes the socket. So check for a short body.
        if (fired.load(.acquire)) return timed_out(req);
        if (req.head.content_length) |n| if (with_body.body.len != n) return .gone;
    }
    return .{ .parsed = .{ .req = req, .parsed = with_body } };
}

fn too_large(req: std.http.Server.Request) Read {
    return .{ .refused = .{ .req = req, .status = .payload_too_large, .body = "the body is too large\n" } };
}

fn timed_out(req: std.http.Server.Request) Read {
    return .{ .refused = .{ .req = req, .status = .request_timeout, .body = "the request was too slow\n" } };
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

/// What a call's hosted functions answer from.
pub const Answering = struct { root: *const files.DataRoot, io: Io, hub: *bus.Hub };

const failed: Written = .{ .status = .internal_server_error, .headers = &.{}, .body = "failed\n" };

/// Asks the app to answer `parsed`, and copies the answer into `arena`.
/// An answer the app got wrong becomes a 500: a status std doesn't know, a
/// header containing a CR, LF or NUL, or a malformed stream.
pub fn answer(arena: std.mem.Allocator, answering: Answering, parsed: Parsed) Answered {
    seam.begin(.{ .arena = arena, .root = answering.root, .io = answering.io, .hub = answering.hub });
    const r = seam.roc_handle_http_request(.{
        .body = .from(parsed.body),
        .headers = .from(parsed.headers),
        .method = .from(parsed.method),
        .path = .from(parsed.path),
        .query = .from(parsed.query),
        .port = parsed.port,
    });
    seam.end();
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
    http.out.print("HTTP/1.1 {d} {s}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n", .{ @intFromEnum(status), status.phrase() orelse "" }) catch return;
    http.out.flush() catch {};
}
