//! The bus: frames published on a key, fanned out to the streams held open
//! on that key. The app publishes a frame (`Host.publish_bytes_to_streams_on_key!`),
//! each stream subscribed to the key gets its own copy in its mailbox, and
//! the stream's task writes it out as it is. The bus knows keys and bytes,
//! never what they mean.
//!
//! A stream never skips a frame silently. A mailbox holds 16 frames; a
//! frame that finds it full is dropped and the subscriber marked missed,
//! and the stream's task ends the stream. The browser reconnects, and the
//! app resumes it from the last frame it saw.
//!
//! The locks are taken in one order, the hub's and then a subscriber's, so
//! they never deadlock.

const std = @import("std");
const Io = std.Io;

/// One held stream's mailbox: a ring of owned frames, drained by the
/// stream's task. It is opened in the turn whose call answered the stream,
/// and closed when the stream ends.
pub const Subscriber = struct {
    io: Io,
    /// The server's allocator: a frame outlives the call that published it.
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    /// Bumped on every push. `next` waits on a snapshot of it, so a push
    /// between the snapshot and the wait ends the wait at once.
    seq: std.atomic.Value(u32) = .init(0),
    ring: [cap]?[]u8 = @splat(null),
    head: usize = 0,
    count: usize = 0,
    missed: bool = false,
    /// Set by `end`: the stream is over, and its task should stop waiting.
    ended: bool = false,

    pub const cap = 16;

    pub const Next = union(enum) {
        /// An owned frame, which the caller frees with `gpa`.
        frame: []u8,
        /// Nothing came within the wait: a keepalive is due.
        idle,
        /// The stream was ended from outside (`end`).
        ended,
        /// The stream's task was canceled, as the server stops.
        canceled,
    };

    /// A copy of `frame` queued, or the subscriber marked missed. It never
    /// waits.
    fn push(s: *Subscriber, frame: []const u8) void {
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            if (s.count < cap) {
                if (s.gpa.dupe(u8, frame)) |copy| {
                    s.ring[(s.head + s.count) % cap] = copy;
                    s.count += 1;
                } else |_| s.missed = true;
            } else s.missed = true;
        }
        _ = s.seq.fetchAdd(1, .release);
        s.io.futexWake(u32, &s.seq.raw, 1);
    }

    /// The oldest frame, or null when there is none. It never waits.
    pub fn take(s: *Subscriber) ?[]u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.count == 0) return null;
        const m = s.ring[s.head].?;
        s.ring[s.head] = null;
        s.head = (s.head + 1) % cap;
        s.count -= 1;
        return m;
    }

    pub fn has_missed(s: *Subscriber) bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.missed;
    }

    fn has_ended(s: *Subscriber) bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.ended;
    }

    /// The stream is over: a `next` waiting now returns `.ended` at once,
    /// and so does every later one. It never waits.
    pub fn end(s: *Subscriber) void {
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            s.ended = true;
        }
        _ = s.seq.fetchAdd(1, .release);
        s.io.futexWake(u32, &s.seq.raw, 1);
    }

    /// The oldest frame, waiting at most `wait_ms` for one, or `.ended`. A
    /// spurious wake is an early `.idle`, which costs one more keepalive.
    pub fn next(s: *Subscriber, wait_ms: u32) Next {
        // The snapshot comes first: a push or an `end` after it changes
        // `seq`, so the wait below returns at once rather than missing it.
        const expected = s.seq.load(.acquire);
        if (s.has_ended()) return .ended;
        if (s.take()) |m| return .{ .frame = m };
        s.io.futexWaitTimeout(u32, &s.seq.raw, expected, .{
            .duration = .{ .raw = .fromMilliseconds(wait_ms), .clock = .awake },
        }) catch return .canceled;
        if (s.has_ended()) return .ended;
        if (s.take()) |m| return .{ .frame = m };
        return .idle;
    }

    fn drain_and_free(s: *Subscriber) void {
        while (s.take()) |m| s.gpa.free(m);
    }
};

/// Every held stream, by its key: one per server.
pub const Hub = struct {
    io: Io,
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: []u8, sub: *Subscriber };

    pub fn init(io: Io, gpa: std.mem.Allocator) Hub {
        return .{ .io = io, .gpa = gpa };
    }

    /// Each stream's task closes its own subscriber before this.
    pub fn deinit(h: *Hub) void {
        std.debug.assert(h.entries.items.len == 0);
        h.entries.deinit(h.gpa);
    }

    /// A new subscriber on `key`, which is copied. The caller closes it.
    pub fn open(h: *Hub, key: []const u8) !*Subscriber {
        const sub = try h.gpa.create(Subscriber);
        errdefer h.gpa.destroy(sub);
        sub.* = .{ .io = h.io, .gpa = h.gpa };
        const key_copy = try h.gpa.dupe(u8, key);
        errdefer h.gpa.free(key_copy);
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        try h.entries.append(h.gpa, .{ .key = key_copy, .sub = sub });
        return sub;
    }

    /// `sub` taken out of the hub, so no publish reaches it, then freed.
    pub fn close(h: *Hub, sub: *Subscriber) void {
        {
            h.mutex.lockUncancelable(h.io);
            defer h.mutex.unlock(h.io);
            for (h.entries.items, 0..) |e, i| if (e.sub == sub) {
                h.gpa.free(e.key);
                _ = h.entries.swapRemove(i);
                break;
            };
        }
        sub.drain_and_free();
        h.gpa.destroy(sub);
    }

    /// `frame` to every subscriber on `key`, each its own copy; the
    /// caller's bytes are not kept.
    pub fn publish(h: *Hub, key: []const u8, frame: []const u8) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        for (h.entries.items) |e| if (std.mem.eql(u8, e.key, key)) e.sub.push(frame);
    }

    pub fn count(h: *Hub) usize {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        return h.entries.items.len;
    }
};

// ── tests: on std.testing.allocator, so anything left unfreed fails

const testing = std.testing;

fn expect_frame(sub: *Subscriber, want: []const u8) !void {
    switch (sub.next(1)) {
        .frame => |m| {
            defer testing.allocator.free(m);
            try testing.expectEqualStrings(want, m);
        },
        else => return error.TestExpectedFrame,
    }
}

test "a frame reaches every subscriber on its key, each its own copy, and no other key" {
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.deinit();
    const a1 = try hub.open("room");
    const a2 = try hub.open("room");
    const other = try hub.open("elsewhere");
    var frame = "hi".*;
    hub.publish("room", &frame);
    frame = "xx".*;
    try expect_frame(a1, "hi");
    try expect_frame(a2, "hi");
    try testing.expectEqual(0, other.count);
    hub.close(a1);
    hub.publish("room", "still here");
    try expect_frame(a2, "still here");
    try testing.expect(other.take() == null);
    hub.close(a2);
    hub.close(other);
    try testing.expectEqual(0, hub.count());
}

test "a full mailbox keeps its oldest 16 in order and marks the 17th missed" {
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.deinit();
    const sub = try hub.open("k");
    defer hub.close(sub);
    var buf: [8]u8 = undefined;
    for (0..Subscriber.cap) |n| hub.publish("k", try std.fmt.bufPrint(&buf, "{d}", .{n}));
    try testing.expect(!sub.has_missed());
    hub.publish("k", "one too many");
    try testing.expect(sub.has_missed());
    for (0..Subscriber.cap) |n| try expect_frame(sub, try std.fmt.bufPrint(&buf, "{d}", .{n}));
}

test "an empty mailbox answers idle when its wait is over, not before" {
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.deinit();
    const sub = try hub.open("k");
    defer hub.close(sub);
    const t0 = Io.Clock.now(.awake, testing.io);
    try testing.expect(sub.next(30) == .idle);
    try testing.expect(t0.untilNow(testing.io, .awake).toMilliseconds() >= 30);
}

fn wait_for_next(sub: *Subscriber) Subscriber.Next {
    return sub.next(25_000);
}

test "ending a subscriber wakes its waiting task at once, and every later wait answers ended" {
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.deinit();
    const sub = try hub.open("k");
    defer hub.close(sub);
    const t0 = Io.Clock.now(.awake, testing.io);
    var waiting = try testing.io.concurrent(wait_for_next, .{sub});
    // Time for the task to reach its wait.
    try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(50) }, testing.io);
    sub.end();
    try testing.expect(waiting.await(testing.io) == .ended);
    try testing.expect(t0.untilNow(testing.io, .awake).toMilliseconds() < 1_000);
    hub.publish("k", "after the end");
    try testing.expect(sub.next(25_000) == .ended);
}
