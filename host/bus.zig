//! **THE BUS**: a keyed fan-out of published frames to the streams held
//! open on each key. `Host.publish!` puts a frame on a key; each stream
//! subscribed to the key gets its own copy in its mailbox, and the stream's
//! task writes it out verbatim (the Roc rendered it once). (From zig-webbox
//! src/bus.zig at ac6bb97: `Subscriber`, `Hub` and the mailbox simulator,
//! cut to owned bytes: no `Kept`, no render, no one-loop host.)
//!
//! **LIVE ONLY, AND NEVER A SILENT GAP**: a mailbox holds 16 frames; a frame
//! that finds it full is dropped and the subscriber marked `missed`, and the
//! stream's task ends the stream rather than carry on past the hole. The
//! browser reconnects and the Roc resumes it from its Last-Event-ID.
//!
//! **LOCK ORDER: THE HUB, THEN A SUBSCRIBER.** `publish` takes the hub's
//! mutex, then each subscriber's; `open` and `close` take the hub's alone;
//! `take` the subscriber's alone. No cycle. Each subscriber's `seq` is a
//! futex: a push bumps and wakes it, and `next` waits on it with the
//! keepalive as its timeout, so a quiet stream still wakes to ping.

const std = @import("std");
const Io = std.Io;

/// One held stream's mailbox: a ring of owned frames, drained by the
/// stream's task. Opened (`Hub.open`) in the turn that read its backlog,
/// closed (`Hub.close`) when the stream ends.
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
    /// A frame was dropped (the ring full, or no memory for its copy): the
    /// stream ends rather than show a gap.
    missed: bool = false,

    /// The frames a mailbox holds; the next is `missed`.
    pub const cap = 16;

    pub const Next = union(enum) {
        /// An owned frame: the caller frees it with `gpa`.
        msg: []u8,
        /// Nothing within the keepalive: a ping is due.
        idle,
        /// The stream's task was canceled (the server stopping).
        canceled,
    };

    /// A copy of `msg` queued, or `missed` set; never a wait.
    fn push(s: *Subscriber, msg: []const u8) void {
        {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            if (s.count < cap) {
                if (s.gpa.dupe(u8, msg)) |copy| {
                    s.ring[(s.head + s.count) % cap] = copy;
                    s.count += 1;
                } else |_| s.missed = true;
            } else s.missed = true;
        }
        _ = s.seq.fetchAdd(1, .release);
        s.io.futexWake(u32, &s.seq.raw, 1);
    }

    /// The oldest frame, or null when there is none; never a wait.
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

    /// Whether a frame was dropped.
    pub fn hasMissed(s: *Subscriber) bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.missed;
    }

    /// The oldest frame, waiting for one at most `keepalive_ms`. A spurious
    /// wake is an early `.idle`: one more ping, harmless.
    pub fn next(s: *Subscriber, keepalive_ms: u32) Next {
        if (s.take()) |m| return .{ .msg = m };
        const expected = s.seq.load(.acquire);
        s.io.futexWaitTimeout(u32, &s.seq.raw, expected, .{
            .duration = .{ .raw = .fromMilliseconds(keepalive_ms), .clock = .awake },
        }) catch return .canceled;
        if (s.take()) |m| return .{ .msg = m };
        return .idle;
    }

    fn drainAndFree(s: *Subscriber) void {
        while (s.take()) |m| s.gpa.free(m);
    }
};

/// **EVERY HELD STREAM, BY ITS KEY**: one per server.
pub const Hub = struct {
    io: Io,
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: []u8, sub: *Subscriber };

    pub fn init(io: Io, gpa: std.mem.Allocator) Hub {
        return .{ .io = io, .gpa = gpa };
    }

    /// Every subscriber closed already (each stream's task closes its own).
    pub fn deinit(h: *Hub) void {
        std.debug.assert(h.entries.items.len == 0);
        h.entries.deinit(h.gpa);
    }

    /// A new subscriber on `key` (copied): the caller closes it.
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

    /// `sub` out of the registry, then freed: once it is out, no publish
    /// can reach it.
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
        sub.drainAndFree();
        h.gpa.destroy(sub);
    }

    /// `msg` to every subscriber on `key`, each its own copy. The caller's
    /// bytes are not kept.
    pub fn publish(h: *Hub, key: []const u8, msg: []const u8) void {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        for (h.entries.items) |e| if (std.mem.eql(u8, e.key, key)) e.sub.push(msg);
    }

    /// How many subscribers there are, for tests.
    pub fn count(h: *Hub) usize {
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        return h.entries.items.len;
    }
};

// ── tests ───────────────────────────────────────────────────────────────────
//
// On std.testing.allocator, so a frame, key or subscriber left unfreed fails
// the test. `next` waits out its keepalive on an empty mailbox, so these call
// it only with a frame waiting, or with a short keepalive.

const testing = std.testing;

fn expectMsg(sub: *Subscriber, want: []const u8) !void {
    switch (sub.next(1)) {
        .msg => |m| {
            defer testing.allocator.free(m);
            try testing.expectEqualStrings(want, m);
        },
        else => return error.TestExpectedMsg,
    }
}

test "bus: publish reaches every subscriber on its key, each its own copy, and no other key" {
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.deinit();
    const a1 = try hub.open("room");
    const a2 = try hub.open("room");
    const other = try hub.open("elsewhere");
    var frame = "hi".*;
    hub.publish("room", &frame);
    // The publisher's bytes are not kept.
    frame = "xx".*;
    try expectMsg(a1, "hi");
    try expectMsg(a2, "hi");
    try testing.expectEqual(0, other.count);
    hub.close(a1);
    hub.publish("room", "still here");
    try expectMsg(a2, "still here");
    hub.close(a2);
    hub.close(other);
    try testing.expectEqual(0, hub.count());
}

test "bus: a full mailbox keeps its oldest 16 in order and marks the 17th missed" {
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.deinit();
    const sub = try hub.open("k");
    defer hub.close(sub);
    var buf: [8]u8 = undefined;
    for (0..Subscriber.cap) |n| hub.publish("k", try std.fmt.bufPrint(&buf, "{d}", .{n}));
    try testing.expect(!sub.hasMissed());
    hub.publish("k", "one too many");
    try testing.expect(sub.hasMissed());
    for (0..Subscriber.cap) |n| try expectMsg(sub, try std.fmt.bufPrint(&buf, "{d}", .{n}));
}

test "bus: an empty mailbox answers idle at its keepalive, not before" {
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.deinit();
    const sub = try hub.open("k");
    defer hub.close(sub);
    const t0 = Io.Clock.now(.awake, testing.io);
    try testing.expect(sub.next(30) == .idle);
    try testing.expect(t0.untilNow(testing.io, .awake).toMilliseconds() >= 30);
}

// ── the mailbox contract, over seeded runs ──────────────────────────────────
//
// **THE CONTRACT**: a reader sees exactly the frames published on its key
// since it opened, in the order they were published, nothing from another
// key and nothing skipped; a reader whose mailbox was full when a frame
// arrived ends (the stream's task ends on `missed`) and never sees a gap.
// The model is a list of what each reader is owed; the hub is driven by
// seeded opens, closes, publishes and reads, on one thread. (webbox's
// simulator, its `nextFrame` replaced by the stream task's own rule:
// `missed` first, then `take`.)

/// How often each case was met over every seed: a simulator that never
/// overflowed a mailbox would prove nothing about it.
var sim_seen: struct { frames: usize = 0, missed: usize = 0, empty: usize = 0, closed: usize = 0 } = .{};

const SimReader = struct {
    sub: *Subscriber,
    key: usize,
    /// Frames published on its key since it opened and not yet read.
    owed: std.ArrayList([]const u8) = .empty,
    /// The model's verdict: a frame arrived while its mailbox was full.
    overflowed: bool = false,
    /// A slow reader reads one turn in eight, so its mailbox fills.
    slow: bool = false,
};

fn simRun(seed: u64) !void {
    const keys = [_][]const u8{ "conv/1_2", "conv/1_3", "user/7" };
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var hub = Hub.init(testing.io, testing.allocator);
    defer hub.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var readers: std.ArrayList(SimReader) = .empty;
    defer {
        for (readers.items) |*rd| {
            rd.owed.deinit(testing.allocator);
            hub.close(rd.sub);
        }
        readers.deinit(testing.allocator);
    }
    var seq: usize = 0;
    for (0..r.intRangeAtMost(usize, 50, 400)) |_| {
        switch (r.uintLessThan(u8, 10)) {
            0, 1 => if (readers.items.len < 6) {
                const k = r.uintLessThan(usize, keys.len);
                try readers.append(testing.allocator, .{ .sub = try hub.open(keys[k]), .key = k, .slow = r.uintLessThan(u8, 3) == 0 });
            },
            2 => if (readers.items.len > 0) {
                var rd = readers.swapRemove(r.uintLessThan(usize, readers.items.len));
                rd.owed.deinit(testing.allocator);
                hub.close(rd.sub);
                sim_seen.closed += 1;
            },
            3, 4, 5, 6 => {
                const k = r.uintLessThan(usize, keys.len);
                seq += 1;
                const ev = try std.fmt.allocPrint(arena.allocator(), "{s}#{d}", .{ keys[k], seq });
                for (readers.items) |*rd| {
                    if (rd.key != k or rd.overflowed) continue;
                    if (rd.owed.items.len == Subscriber.cap) rd.overflowed = true else try rd.owed.append(testing.allocator, ev);
                }
                hub.publish(keys[k], ev);
            },
            else => for (readers.items) |*rd| {
                if (rd.slow and r.uintLessThan(u8, 8) != 0) continue;
                for (0..r.uintAtMost(usize, 4)) |_| {
                    try testing.expectEqual(rd.overflowed, rd.sub.hasMissed());
                    if (rd.overflowed) {
                        sim_seen.missed += 1;
                        break;
                    }
                    const frame = rd.sub.take() orelse {
                        try testing.expect(rd.owed.items.len == 0);
                        sim_seen.empty += 1;
                        break;
                    };
                    defer testing.allocator.free(frame);
                    try testing.expect(rd.owed.items.len > 0);
                    try testing.expectEqualStrings(rd.owed.items[0], frame);
                    _ = rd.owed.orderedRemove(0);
                    sim_seen.frames += 1;
                }
            },
        }
    }
}

test "bus: the mailbox contract over seeded runs (webbox's simulator)" {
    sim_seen = .{};
    // 300 seeds, as webbox's: about 1.2 s in Debug, all of it work, none
    // of it waiting. At 120 seeds the overflow case is met only 16 times.
    for (1..301) |seed| try simRun(seed);
    try testing.expect(sim_seen.frames > 1000 and sim_seen.missed > 10 and sim_seen.empty > 100 and sim_seen.closed > 100);
}
