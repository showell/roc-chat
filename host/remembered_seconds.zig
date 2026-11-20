//! Seconds the app keeps in the server's memory between requests, each
//! under a key of its own: the one state the host holds for the app apart
//! from files and streams. A second is remembered until the server stops,
//! and never written to disk, so a restart forgets them all. The host knows
//! nothing of what a key or a second means; the app uses them for when each
//! human was last active (app/Presence.roc), for the tallies of failed
//! device codes (app/DeviceCodeLimit.roc), and for each user's message rate
//! (app/MessageRate.roc, two keys a user).
//!
//! Only the app's calls reach it, and the app makes one call at a time (the
//! turn, host/http.zig), so it takes no lock of its own.

const std = @import("std");

/// The most bytes a key may be.
pub const key_most = 64;

/// The most keys kept, a bound the app stays far under. The app keeps at
/// most eight keys a user, and there are at most 2,000 accounts
/// (app/SignUpLimits.roc, `accounts_most`): one for when a human was last
/// active (app/Presence.roc), five for their searches (app/SearchLimit.roc)
/// and two for their message rate (app/MessageRate.roc), 16,000 in all;
/// 8,198 for the device codes' tallies (app/DeviceCodeLimit.roc: two keys
/// for each of 4,096 buckets of clients, `local`, `repeated` and everyone);
/// and 20 for the day's GitHub sign-ups (app/SignUpLimits.roc). That is
/// 24,218 at most, under a third of this.
pub const keys_most = 65_536 + 9_216;

pub const RememberedSeconds = struct {
    gpa: std.mem.Allocator,
    seconds: std.StringHashMapUnmanaged(i64) = .empty,

    pub fn init(gpa: std.mem.Allocator) RememberedSeconds {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *RememberedSeconds) void {
        var keys = r.seconds.keyIterator();
        while (keys.next()) |key| r.gpa.free(key.*);
        r.seconds.deinit(r.gpa);
    }

    /// The second `key` held, or null for none.
    pub fn recall(r: *const RememberedSeconds, key: []const u8) ?i64 {
        return r.seconds.get(key);
    }

    /// `second` kept under `key`, and the second it held before, or null
    /// for none. A key that is empty or longer than `key_most`, a new key
    /// past `keys_most`, or no memory for one, is the app's bug or a
    /// server that can't go on: the server stops.
    pub fn remember(r: *RememberedSeconds, key: []const u8, second: i64) ?i64 {
        if (key.len == 0 or key.len > key_most) std.debug.panic("replace_second_kept_under_key: a key of {d} bytes (1 to {d})", .{ key.len, key_most });
        if (r.seconds.getPtr(key)) |held| {
            const before = held.*;
            held.* = second;
            return before;
        }
        if (r.seconds.count() >= keys_most) std.debug.panic("replace_second_kept_under_key: {d} keys already, the most", .{keys_most});
        const copy = r.gpa.dupe(u8, key) catch std.debug.panic("replace_second_kept_under_key: no memory for a key", .{});
        r.seconds.put(r.gpa, copy, second) catch std.debug.panic("replace_second_kept_under_key: no memory for a key", .{});
        return null;
    }
};

// ── tests: on std.testing.allocator, so anything left unfreed fails

const testing = std.testing;

test "a key holds no second until one is remembered, then the latest, and remembering answers the one before" {
    var r = RememberedSeconds.init(testing.allocator);
    defer r.deinit();
    try testing.expectEqual(null, r.recall("1"));
    try testing.expectEqual(null, r.remember("1", 100));
    try testing.expectEqual(100, r.recall("1"));
    try testing.expectEqual(100, r.remember("1", 160));
    try testing.expectEqual(160, r.recall("1"));
    try testing.expectEqual(null, r.recall("2"));
    try testing.expectEqual(null, r.remember("2", 5));
    try testing.expectEqual(160, r.recall("1"));
    try testing.expectEqual(5, r.recall("2"));
}

test "a key is copied, so the caller's bytes may change after" {
    var r = RememberedSeconds.init(testing.allocator);
    defer r.deinit();
    var key = "7".*;
    _ = r.remember(&key, 1);
    key = "8".*;
    try testing.expectEqual(1, r.recall("7"));
    try testing.expectEqual(null, r.recall("8"));
}

test "a key of the most bytes is kept" {
    var r = RememberedSeconds.init(testing.allocator);
    defer r.deinit();
    const longest: [key_most]u8 = @splat('k');
    try testing.expectEqual(null, r.remember(&longest, 3));
    try testing.expectEqual(3, r.recall(&longest));
}
