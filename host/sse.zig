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

/// **THE STREAMS HELD AT ONCE**: a stream takes a slot, and when none is
/// free the oldest is ended (its socket shut, so its write fails and its
/// task lets the slot go). A slot is given back when its stream ends,
/// unless a newer stream has it already.
pub const Slots = struct {
    mutex: Io.Mutex = .init,
    held: [most_ever]?Slot = @splat(null),
    tickets: u64 = 0,

    /// The most `most` may be; a server holds fewer when its limits say so.
    pub const most_ever = 64;

    const Slot = struct { stream: net.Stream, ticket: u64 };

    pub const Held = struct { slot: usize, ticket: u64 };

    /// A slot for `stream`, of the first `most`: the oldest ended for it
    /// when all are held.
    pub fn hold(s: *Slots, io: Io, most: u32, stream: net.Stream) Held {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        const n = @min(most, most_ever);
        s.tickets += 1;
        var free: ?usize = null;
        var oldest: usize = 0;
        for (s.held[0..n], 0..) |h, i| {
            if (h) |x| {
                if (s.held[oldest] == null or x.ticket < s.held[oldest].?.ticket) oldest = i;
            } else if (free == null) free = i;
        }
        const i = free orelse at: {
            s.held[oldest].?.stream.shutdown(io, .both) catch {};
            break :at oldest;
        };
        s.held[i] = .{ .stream = stream, .ticket = s.tickets };
        return .{ .slot = i, .ticket = s.tickets };
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
