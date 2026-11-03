//! Server-sent events: a stream's headers, its keepalive, and the cap on
//! the streams held at once. host/http.zig writes a stream: the head and
//! the app's first bytes, then each frame published to its key, as it is.
//! The body ends when the connection does, never chunked. Cribbed from
//! roc-chat's host/sse.zig.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

/// The host's stream headers, written before the app's: the type, never
/// cached, and never buffered by a proxy, so frames arrive live.
pub const headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "x-accel-buffering", .value = "no" },
};

/// The keepalive, a comment line, which a browser ignores. A stream quiet
/// this long sends it, and a reader that has gone is noticed when the
/// write fails.
pub const ping = ": ping\n\n";

/// The most bytes a holder's name may be.
pub const holder_most = 64;

/// The streams held at once, and by whom. A stream takes a slot named for
/// its holder, the bytes the app gives. A holder at its own cap ends its
/// own oldest stream, never another's, so one user opening streams ends
/// only their own. When every slot is held, the oldest stream of the
/// holder holding the most is ended. An ended stream's socket is shut, so
/// its next write fails and its task lets the slot go.
pub const Slots = struct {
    mutex: Io.Mutex = .init,
    held: [most_ever]?Slot = @splat(null),
    tickets: u64 = 0,

    /// The most slots a server may have; its limits may say fewer.
    pub const most_ever = 64;

    const Slot = struct {
        stream: net.Stream,
        ticket: u64,
        holder: [holder_most]u8,
        holder_len: usize,

        fn held_by(x: *const Slot, holder: []const u8) bool {
            return std.mem.eql(u8, x.holder[0..x.holder_len], holder);
        }
    };

    pub const Held = struct { slot: usize, ticket: u64 };

    /// The slots in use, of `most_ever`, and the most one holder may hold.
    pub const Most = struct { all: u32, per_holder: u32 };

    /// A slot for `stream`, held by `holder`: that holder's oldest ended
    /// for it when it holds `most.per_holder`; else a free one; else the
    /// oldest of the holder holding the most.
    pub fn hold(s: *Slots, io: Io, most: Most, holder: []const u8, stream: net.Stream) Held {
        std.debug.assert(holder.len <= holder_most);
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const n = @min(most.all, most_ever);
        s.tickets += 1;
        var free: ?usize = null;
        var own: usize = 0;
        var own_oldest: ?usize = null;
        for (s.held[0..n], 0..) |*h, i| {
            if (h.*) |*x| {
                if (x.held_by(holder)) {
                    own += 1;
                    if (own_oldest == null or x.ticket < s.held[own_oldest.?].?.ticket) own_oldest = i;
                }
            } else if (free == null) free = i;
        }
        const i = if (own >= @max(most.per_holder, 1))
            s.end(io, own_oldest.?)
        else
            free orelse s.end(io, s.busiest_oldest(n));
        var slot: Slot = .{ .stream = stream, .ticket = s.tickets, .holder = undefined, .holder_len = holder.len };
        @memcpy(slot.holder[0..holder.len], holder);
        s.held[i] = slot;
        return .{ .slot = i, .ticket = s.tickets };
    }

    /// Slot `i`'s stream ended, its socket shut: `i`.
    fn end(s: *Slots, io: Io, i: usize) usize {
        s.held[i].?.stream.shutdown(io, .both) catch {};
        return i;
    }

    /// Of the first `n` slots, all held: the oldest stream of the holder
    /// holding the most, the oldest of all among holders tied.
    fn busiest_oldest(s: *const Slots, n: usize) usize {
        var best: usize = 0;
        var best_count: usize = 0;
        for (s.held[0..n], 0..) |h, i| {
            const x = h.?;
            var c: usize = 0;
            var oldest = i;
            for (s.held[0..n], 0..) |o, j| {
                if (o.?.held_by(x.holder[0..x.holder_len])) {
                    c += 1;
                    if (o.?.ticket < s.held[oldest].?.ticket) oldest = j;
                }
            }
            if (c > best_count or (c == best_count and s.held[oldest].?.ticket < s.held[best].?.ticket)) {
                best = oldest;
                best_count = c;
            }
        }
        return best;
    }

    /// `h`'s slot given back, unless a newer stream has taken it.
    pub fn let_go(s: *Slots, io: Io, h: Held) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.held[h.slot]) |x| if (x.ticket == h.ticket) {
            s.held[h.slot] = null;
        };
    }

    pub fn count(s: *Slots, io: Io) usize {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        var n: usize = 0;
        for (s.held) |h| if (h != null) {
            n += 1;
        };
        return n;
    }
};
