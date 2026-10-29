//! **THE SERVER**: std.http's per-connection protocol object, run on a task
//! of its own for each connection (`Io.Group.concurrent` on the threaded
//! Io), and **one mutex, the turn**, held only while a request's handler,
//! its Roc call, runs. (The model of zig-webbox's linux_host.zig, rebuilt
//! from std alone, as probe (a) showed it works.)
//!
//! **THE TURN NEVER WAITS ON THE NETWORK**: a request's head and body are
//! read whole before its turn, under deadlines, and its answer is written
//! after, under a deadline of its own. So a slow client holds its own task
//! and nothing else.
//!
//! **ONE WATCHDOG FOR EVERY DEADLINE**: each connection arms its deadline
//! (the head, the idle wait for the next head, the body, the answer's
//! write), and one task looks at them all a few times a second, shutting
//! the socket of one past its deadline, which ends the read or write
//! blocked on it. A read past its deadline is a 408 (or, between requests,
//! a quiet close); a write past it ends the connection.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const abi = @import("seam/chat_abi.zig");
const call = @import("call.zig");
const files = @import("files.zig");

const log = std.log.scoped(.roc_chat);

/// The limits a server keeps; a test sets its own, shorter.
pub const Limits = struct {
    /// A connection's first head, whole, from its accept.
    head_ms: u32 = 10_000,
    /// A kept-open connection's next head, whole, from its last answer:
    /// past it, closed with no answer.
    idle_ms: u32 = 10_000,
    /// A body, whole, from its head.
    body_ms: u32 = 10_000,
    /// An answer, written whole.
    write_ms: u32 = 10_000,
    /// The most a body may be; past it a 413, never read, never in the turn.
    body_most: usize = 64 * 1024,
    /// The most requests a connection serves; its last answer says close.
    requests_most: u32 = 1000,
    /// The most connections open at once that are kept open; past it, an
    /// answer says close.
    kept_open_most: u32 = 64,

    /// The watchdog's look: a quarter of the shortest deadline, 5 to 100 ms.
    fn tickMs(l: Limits) u32 {
        const shortest = @min(@min(l.head_ms, l.idle_ms), @min(l.body_ms, l.write_ms));
        return std.math.clamp(shortest / 4, 5, 100);
    }
};

/// The most a request's head may be: past it, a 431.
pub const head_most = 16 * 1024;

/// What a test reads of the turn.
pub const Stats = struct {
    /// Roc calls made.
    turns: std.atomic.Value(u32) = .init(0),
    /// Handlers in the turn now, and the most there have been at once.
    in_turn: std.atomic.Value(u32) = .init(0),
    most_in_turn: std.atomic.Value(u32) = .init(0),
    /// Roc crashes said (`Server.sayCrash`).
    crashes: std.atomic.Value(u32) = .init(0),
};

pub const Server = struct {
    io: Io,
    gpa: std.mem.Allocator,
    limits: Limits,
    listener: net.Server,
    /// **THE TURN**: held only while a request's Roc call runs.
    turn: Io.Mutex = .init,
    watch: Watch = .{},
    stats: Stats = .{},
    /// A test's: the turn held this long besides the Roc call, so that
    /// handlers that could overlap would.
    hold_turn_ms_for_test: u32 = 0,
    /// The data root's files, asked only in the turn.
    files: files.Files,
    /// The last crash's line, as logged (written in the turn; a test reads
    /// it holding the turn).
    crash_said: [2048]u8 = undefined,
    crash_said_len: usize = 0,

    /// Serves `data`, the data root (the caller's, open for the server's life).
    pub fn init(io: Io, gpa: std.mem.Allocator, addr: net.IpAddress, limits: Limits, data: Io.Dir) !Server {
        return .{
            .io = io,
            .gpa = gpa,
            .limits = limits,
            .listener = try addr.listen(io, .{ .reuse_address = true }),
            .files = .{ .io = io, .root = data },
        };
    }

    pub fn port(s: *const Server) u16 {
        return s.listener.socket.address.getPort();
    }

    /// Serves until `stop`: each connection on a task of its own, the
    /// watchdog on another. When it returns, every connection is done.
    pub fn run(s: *Server) !void {
        defer s.listener.deinit(s.io);
        defer s.watch.conns.deinit(s.gpa);
        var watchdog = try s.io.concurrent(Watch.run, .{ &s.watch, s.io, s.limits.tickMs() });
        defer watchdog.cancel(s.io);
        var conns: Io.Group = .init;
        defer conns.cancel(s.io);
        while (true) {
            const stream = s.listener.accept(s.io) catch |e| switch (e) {
                // `stop`, or the task's own cancel.
                error.SocketNotListening, error.Canceled => return,
                else => {
                    log.warn("accept failed: {t}", .{e});
                    continue;
                },
            };
            conns.concurrent(s.io, serveConn, .{ s, stream }) catch |e| {
                // **NO TASK, NO SERVING**: served inline, its head would be
                // read with no deadline, holding the accept loop.
                log.warn("no task for a connection ({t}); answered 503", .{e});
                busy(s.io, stream);
            };
        }
    }

    /// `run` returns: no more connections are accepted.
    pub fn stop(s: *Server) void {
        const listening: net.Stream = .{ .socket = s.listener.socket };
        listening.shutdown(s.io, .both) catch {};
    }

    fn serveConn(s: *Server, stream: net.Stream) void {
        defer stream.close(s.io);
        var conn: Conn = .{ .stream = stream };
        s.watch.add(s.io, s.gpa, &conn) catch {
            busy(s.io, stream);
            return;
        };
        defer s.watch.remove(s.io, &conn);
        var read_buf: [head_most]u8 = undefined;
        var write_buf: [16 * 1024]u8 = undefined;
        var sr = stream.reader(s.io, &read_buf);
        var sw = stream.writer(s.io, &write_buf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);
        var served: u32 = 0;
        while (s.serveOne(&conn, &http, served)) served += 1;
        if (conn.unread) s.linger(&conn);
    }

    /// **A REFUSED BODY IS DRAINED BEFORE THE CLOSE**: closed with the
    /// client's bytes unread, the socket resets, and a client still sending
    /// may lose the answer it was sent. So the server's side is shut, and
    /// what the client still sends is read and dropped, for a moment.
    fn linger(s: *Server, conn: *Conn) void {
        conn.stream.shutdown(s.io, .send) catch return;
        s.watch.arm(s.io, conn, 1000, .recv);
        defer s.watch.disarm(s.io, conn);
        var buf: [4096]u8 = undefined;
        var r = conn.stream.reader(s.io, &buf);
        _ = r.interface.discardRemaining() catch {};
    }

    /// One request on the connection, answered: whether the connection
    /// serves another.
    fn serveOne(s: *Server, conn: *Conn, http: *std.http.Server, served: u32) bool {
        const io = s.io;
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        s.watch.arm(io, conn, if (served == 0) s.limits.head_ms else s.limits.idle_ms, .recv);
        var req = http.receiveHead() catch |e| {
            s.watch.disarm(io, conn);
            switch (e) {
                error.HttpHeadersOversize => raw(http, "431 Request Header Fields Too Large"),
                error.HttpHeadersInvalid => raw(http, "400 Bad Request"),
                // **A HEAD PAST ITS DEADLINE IS A 408**, a connection's
                // first, or one begun and not finished; a kept-open
                // connection with no next head is closed quietly.
                error.HttpRequestTruncated, error.HttpConnectionClosing, error.ReadFailed => if (conn.fired.load(.acquire) and (served == 0 or e == error.HttpRequestTruncated)) raw(http, "408 Request Timeout"),
            }
            return false;
        };
        s.watch.disarm(io, conn);

        // **THE PATH AND HEADERS COPIED BEFORE THE BODY IS READ**: reading
        // it reuses the buffer the head's strings point into.
        var copied = call.copy(arena, &req) catch return refuse(&req, call.failed);

        // **THE BODY READ WHOLE, BEFORE THE TURN, TO THE CAP.**
        if (req.head.method.requestHasBody()) {
            // A refusal from here leaves the body unread.
            conn.unread = true;
            if (req.head.expect) |e| if (!std.mem.eql(u8, e, "100-continue")) {
                return refuse(&req, .{ .status = .expectation_failed, .body = "only 100-continue is met\n" });
            };
            // No length and not chunked: no body (std asserts one or the other).
            if (req.head.transfer_encoding == .none and req.head.content_length == null) req.head.content_length = 0;
            if (req.head.content_length) |n| if (n > s.limits.body_most) return refuse(&req, call.too_large);
            s.watch.arm(io, conn, s.limits.body_ms, .recv);
            defer s.watch.disarm(io, conn);
            var body_buf: [256]u8 = undefined;
            const body = req.readerExpectContinue(&body_buf) catch return false;
            copied.body = body.allocRemaining(arena, .limited(s.limits.body_most + 1)) catch |e| switch (e) {
                error.StreamTooLong => return refuse(&req, call.too_large),
                error.OutOfMemory => return refuse(&req, call.failed),
                error.ReadFailed => return if (conn.fired.load(.acquire)) refuse(&req, call.too_slow) else false,
            };
            // **A BODY CUT SHORT IS NO BODY**: std's reader ends a
            // length-framed body at the socket's end, short, with no error
            // (the watchdog's shut socket is such an end).
            if (conn.fired.load(.acquire)) return refuse(&req, call.too_slow);
            if (req.head.content_length) |n| if (copied.body.len != n) return false;
            conn.unread = false;
        }

        // **WHETHER THIS ANSWER KEEPS THE CONNECTION**, decided before it
        // is written, so its head says it.
        const keep = req.head.keep_alive and served + 1 < s.limits.requests_most and s.watch.count(io) <= s.limits.kept_open_most;

        const reply = s.answer(arena, &copied);

        s.watch.arm(io, conn, s.limits.write_ms, .both);
        defer s.watch.disarm(io, conn);
        req.respond(reply.body, .{ .status = reply.status, .keep_alive = keep, .extra_headers = reply.headers }) catch return false;
        return keep and http.reader.state == .ready;
    }

    /// **ONE ROC CALL, IN THE TURN**, and its reply made after it. A later
    /// decision that asks for work off the turn (GitHub's token exchange)
    /// does it here, between two calls, each in a turn of its own.
    fn answer(s: *Server, arena: std.mem.Allocator, copied: *const call.Copied) call.Reply {
        var ctx: call.Ctx = .{ .req = copied, .arena = arena, .files = &s.files };
        const decided = blk: {
            s.turn.lockUncancelable(s.io);
            defer s.turn.unlock(s.io);
            const n = s.stats.in_turn.fetchAdd(1, .acq_rel) + 1;
            _ = s.stats.most_in_turn.fetchMax(n, .acq_rel);
            defer _ = s.stats.in_turn.fetchSub(1, .acq_rel);
            _ = s.stats.turns.fetchAdd(1, .acq_rel);
            if (s.hold_turn_ms_for_test > 0) io_sleep(s.io, s.hold_turn_ms_for_test);
            const d = abi.decide(arena, copied.path, copied.method, .of(&ctx));
            if (d) |_| {} else |e| if (e == error.RocCrashed) s.sayCrash(copied);
            break :blk d;
        };
        return call.replyOf(arena, decided, &ctx) catch call.failed;
    }

    /// **A ROC CRASH IS LOGGED ONCE**, in the turn.
    fn sayCrash(s: *Server, c: *const call.Copied) void {
        var w: Io.Writer = .fixed(&s.crash_said);
        w.print("the Roc call for {s} failed: RocCrashed{s}", .{ c.path, abi.last_crash[0..abi.last_crash_len] }) catch {};
        s.crash_said_len = w.end;
        _ = s.stats.crashes.fetchAdd(1, .acq_rel);
        log.warn("{s}", .{s.crash_said[0..s.crash_said_len]});
    }
};

fn io_sleep(io: Io, ms: u32) void {
    Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(ms) }, io) catch {};
}

/// A refusal before the turn: answered, and the connection closed (its body
/// may be unread). Never a 100 Continue first.
fn refuse(req: *std.http.Server.Request, reply: call.Reply) bool {
    req.head.expect = null;
    req.respond(reply.body, .{ .status = reply.status, .keep_alive = false, .extra_headers = reply.headers }) catch {};
    return false;
}

/// A status written with no request to answer (a head that never came
/// whole), and the connection closed.
fn raw(http: *std.http.Server, comptime status: []const u8) void {
    http.out.writeAll("HTTP/1.1 " ++ status ++ "\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch return;
    http.out.flush() catch {};
}

/// A connection there is no task to serve: a 503 written straight to it (a
/// few bytes, which the socket's own buffer takes), and closed.
fn busy(io: Io, stream: net.Stream) void {
    defer stream.close(io);
    var w = stream.writer(io, &.{});
    w.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\nconnection: close\r\ncontent-length: 0\r\n\r\n") catch {};
}

/// A connection as the watchdog sees it: its socket, its deadline (none
/// when null) and how to end it there, and whether it has.
const Conn = struct {
    stream: net.Stream,
    deadline: ?Io.Timestamp = null,
    how: net.ShutdownHow = .recv,
    fired: std.atomic.Value(bool) = .init(false),
    /// A request's body was refused and left unread (`Server.linger`).
    unread: bool = false,
};

/// **THE WATCHDOG**: every open connection, and the one task that ends a
/// read or write past its deadline by shutting its socket (`.recv` for a
/// read, so a 408 can still be written; `.both` for a write).
const Watch = struct {
    mutex: Io.Mutex = .init,
    conns: std.ArrayList(*Conn) = .empty,

    fn add(w: *Watch, io: Io, gpa: std.mem.Allocator, c: *Conn) !void {
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        try w.conns.append(gpa, c);
    }

    fn remove(w: *Watch, io: Io, c: *Conn) void {
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        for (w.conns.items, 0..) |x, i| if (x == c) {
            _ = w.conns.swapRemove(i);
            break;
        };
    }

    fn count(w: *Watch, io: Io) usize {
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        return w.conns.items.len;
    }

    fn arm(w: *Watch, io: Io, c: *Conn, ms: u32, how: net.ShutdownHow) void {
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        c.deadline = Io.Clock.now(.awake, io).addDuration(.fromMilliseconds(ms));
        c.how = how;
        c.fired.store(false, .release);
    }

    fn disarm(w: *Watch, io: Io, c: *Conn) void {
        w.mutex.lockUncancelable(io);
        defer w.mutex.unlock(io);
        c.deadline = null;
    }

    fn run(w: *Watch, io: Io, tick_ms: u32) void {
        while (true) {
            Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(tick_ms) }, io) catch return;
            const now = Io.Clock.now(.awake, io);
            w.mutex.lockUncancelable(io);
            defer w.mutex.unlock(io);
            for (w.conns.items) |c| {
                const at = c.deadline orelse continue;
                if (now.compare(.lt, at)) continue;
                c.deadline = null;
                c.fired.store(true, .release);
                c.stream.shutdown(io, c.how) catch {};
            }
        }
    }
};
