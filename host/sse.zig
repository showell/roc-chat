//! **SERVER-SENT EVENTS**: a stream's head, its keepalive, and the cap on
//! streams held at once. The server writes a stream (server.zig
//! `serveStream`): the head and the Roc's backlog, then each frame published
//! to its key, verbatim, each under the write deadline. (From zig-webbox
//! src/sse.zig and src/linux_streams.zig at ac6bb97.)
//!
//! **THE BODY ENDS WHEN THE CONNECTION DOES**, never chunked: each frame
//! goes out as it is, and the stream is the connection's last answer.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const route = @import("seam/chat_route.zig");

/// A stream's headers: its type, never cached, and never buffered by a
/// proxy (so frames arrive live).
pub const headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/event-stream" },
    .{ .name = "cache-control", .value = "no-cache" },
    .{ .name = "x-accel-buffering", .value = "no" },
};

/// The keepalive: a comment line, which a browser ignores. A stream quiet
/// for the keepalive sends it, and a gone reader is noticed when it fails.
pub const ping = ": ping\n\n";

/// **THE STREAMS HELD AT ONCE, AND BY WHOM** (the security review's H2): a
/// stream takes a slot, named for its holder (the principal the app says
/// asked). **A HOLDER AT ITS OWN CAP ENDS ITS OWN OLDEST**, never another's,
/// so one user opening streams ends only their own. When every slot is
/// held, the oldest stream of the holder holding the most is ended. An
/// ended stream's socket is shut, so its write fails and its task lets the
/// slot go. A slot is given back when its stream ends, unless a newer
/// stream has it already.
pub const Slots = struct {
    mutex: Io.Mutex = .init,
    held: [most_ever]?Slot = @splat(null),
    tickets: u64 = 0,

    /// The most `most` may be; a server holds fewer when its limits say so.
    pub const most_ever = 64;

    const Slot = struct {
        stream: net.Stream,
        ticket: u64,
        holder: [route.holder_most]u8,
        holder_len: usize,

        fn heldBy(x: *const Slot, holder: []const u8) bool {
            return std.mem.eql(u8, x.holder[0..x.holder_len], holder);
        }
    };

    pub const Held = struct { slot: usize, ticket: u64 };

    /// The limits a hold keeps: the slots, of `most_ever`, and a holder's.
    pub const Most = struct { all: u32, per_holder: u32 };

    /// A slot for `stream`, held by `holder` (at most route.holder_most
    /// bytes), of the first `most.all`: that holder's oldest ended for it
    /// when it holds `most.per_holder`; else a free one; else the oldest of
    /// the holder holding the most.
    pub fn hold(s: *Slots, io: Io, most: Most, holder: []const u8, stream: net.Stream) Held {
        std.debug.assert(holder.len <= route.holder_most);
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const n = @min(most.all, most_ever);
        s.tickets += 1;
        var free: ?usize = null;
        var own: usize = 0;
        var own_oldest: ?usize = null;
        for (s.held[0..n], 0..) |*h, i| {
            if (h.*) |*x| {
                if (x.heldBy(holder)) {
                    own += 1;
                    if (own_oldest == null or x.ticket < s.held[own_oldest.?].?.ticket) own_oldest = i;
                }
            } else if (free == null) free = i;
        }
        const i = if (own >= @max(most.per_holder, 1))
            s.end(io, own_oldest.?)
        else
            free orelse s.end(io, s.busiestOldest(n));
        var slot: Slot = .{ .stream = stream, .ticket = s.tickets, .holder = undefined, .holder_len = holder.len };
        @memcpy(slot.holder[0..holder.len], holder);
        s.held[i] = slot;
        return .{ .slot = i, .ticket = s.tickets };
    }

    /// Slot `i`'s stream ended (its socket shut): `i`.
    fn end(s: *Slots, io: Io, i: usize) usize {
        s.held[i].?.stream.shutdown(io, .both) catch {};
        return i;
    }

    /// Of the first `n` slots, all held: the oldest stream of the holder
    /// holding the most (the oldest of all among holders tied).
    fn busiestOldest(s: *const Slots, n: usize) usize {
        var best: usize = 0;
        var best_count: usize = 0;
        for (s.held[0..n], 0..) |h, i| {
            const x = h.?;
            var c: usize = 0;
            var oldest = i;
            for (s.held[0..n], 0..) |o, j| {
                if (o.?.heldBy(x.holder[0..x.holder_len])) {
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
    pub fn letGo(s: *Slots, io: Io, h: Held) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        if (s.held[h.slot]) |x| if (x.ticket == h.ticket) {
            s.held[h.slot] = null;
        };
    }

    /// How many streams are held, for tests.
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
