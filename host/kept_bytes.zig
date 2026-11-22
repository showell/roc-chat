//! Bytes the app keeps in the server's memory between requests, each under
//! a key of its own, as the seconds of host/remembered_seconds.zig are: kept
//! until they are replaced or the server stops, and never written to disk,
//! so a restart forgets them. The host knows nothing of what they mean; the
//! app keeps the directory files it read there (app/DirectoryCache.roc).
//!
//! Only the app's calls reach it, one at a time (the turn, host/http.zig),
//! so it takes no lock of its own.

const std = @import("std");

/// The most bytes a key may be.
pub const key_most = 64;

/// The most keys kept, a bound the app stays far under: it keeps one, the
/// directory's.
pub const keys_most = 16;

/// The most bytes kept under every key together: the directory of 2,000
/// accounts (app/SignUpLimits.roc) and its channels' members is well under
/// a MiB.
pub const bytes_most = 64 * 1024 * 1024;

pub const KeptBytes = struct {
    gpa: std.mem.Allocator,
    kept: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The bytes kept under every key.
    total: usize = 0,

    pub fn init(gpa: std.mem.Allocator) KeptBytes {
        return .{ .gpa = gpa };
    }

    pub fn deinit(k: *KeptBytes) void {
        var it = k.kept.iterator();
        while (it.next()) |entry| {
            k.gpa.free(entry.key_ptr.*);
            k.gpa.free(entry.value_ptr.*);
        }
        k.kept.deinit(k.gpa);
    }

    /// The bytes `key` holds, or null for none.
    pub fn recall(k: *const KeptBytes, key: []const u8) ?[]const u8 {
        return k.kept.get(key);
    }

    /// `bytes`, copied, kept under `key` in place of what it held. A key
    /// that is empty or longer than `key_most`, a new key past
    /// `keys_most`, more than `bytes_most` in all, or no memory, is the
    /// app's bug or a server that can't go on: the server stops.
    pub fn keep(k: *KeptBytes, key: []const u8, bytes: []const u8) void {
        if (key.len == 0 or key.len > key_most) std.debug.panic("replace_bytes_kept_under_key: a key of {d} bytes (1 to {d})", .{ key.len, key_most });
        const held = k.kept.getPtr(key);
        const before = if (held) |h| h.len else 0;
        if (k.total - before + bytes.len > bytes_most) std.debug.panic("replace_bytes_kept_under_key: {d} bytes would pass the {d} kept in all", .{ k.total - before + bytes.len, bytes_most });
        const copy = k.gpa.dupe(u8, bytes) catch std.debug.panic("replace_bytes_kept_under_key: no memory for {d} bytes", .{bytes.len});
        if (held) |h| {
            k.gpa.free(h.*);
            h.* = copy;
        } else {
            if (k.kept.count() >= keys_most) std.debug.panic("replace_bytes_kept_under_key: {d} keys already, the most", .{keys_most});
            const key_copy = k.gpa.dupe(u8, key) catch std.debug.panic("replace_bytes_kept_under_key: no memory for a key", .{});
            k.kept.put(k.gpa, key_copy, copy) catch std.debug.panic("replace_bytes_kept_under_key: no memory for a key", .{});
        }
        k.total = k.total - before + bytes.len;
    }
};

// ── tests: on std.testing.allocator, so anything left unfreed fails

const testing = std.testing;

test "a key holds nothing until bytes are kept, then the latest, each key its own" {
    var k = KeptBytes.init(testing.allocator);
    defer k.deinit();
    try testing.expectEqual(null, k.recall("directory"));
    k.keep("directory", "one");
    try testing.expectEqualStrings("one", k.recall("directory").?);
    k.keep("directory", "two, longer");
    try testing.expectEqualStrings("two, longer", k.recall("directory").?);
    k.keep("other", "");
    try testing.expectEqualStrings("", k.recall("other").?);
    try testing.expectEqualStrings("two, longer", k.recall("directory").?);
    try testing.expectEqual(11, k.total);
}

test "the key and the bytes are copied, so the caller's may change after" {
    var k = KeptBytes.init(testing.allocator);
    defer k.deinit();
    var key = "a".*;
    var bytes = "xy".*;
    k.keep(&key, &bytes);
    key = "b".*;
    bytes = "zz".*;
    try testing.expectEqualStrings("xy", k.recall("a").?);
    try testing.expectEqual(null, k.recall("b"));
}

test "a key of the most bytes is kept" {
    var k = KeptBytes.init(testing.allocator);
    defer k.deinit();
    const longest: [key_most]u8 = @splat('k');
    k.keep(&longest, "v");
    try testing.expectEqualStrings("v", k.recall(&longest).?);
}
