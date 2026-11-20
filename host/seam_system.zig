//! **THE CLOCK, RANDOMNESS, THE DIGESTS AND THE SERVER'S LOG**, part of
//! the seam (host/seam.zig): the facts about the machine a Roc call asks
//! for, none of them a file's.

const std = @import("std");
const files = @import("file_primitives.zig");
const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;
const call = seam_call.call;
const io_of = seam_call.io_of;

const log = std.log.scoped(.seam);

pub export fn current_utc_seconds_since_epoch() callconv(.c) i64 {
    return files.current_utc_seconds_since_epoch(io_of("current_utc_seconds_since_epoch"));
}

/// **MORE THAN `random_most`, OR NO RANDOMNESS, STOPS THE SERVER**: the
/// first is the app's bug, and the second leaves nothing safe to hand back.
pub export fn fill_with_random_bytes(count: u64) callconv(.c) RocBytes {
    const what = "fill_with_random_bytes";
    if (count > files.random_most) std.debug.panic(what ++ ": {d} bytes asked, at most {d}", .{ count, files.random_most });
    var buf: [files.random_most]u8 = undefined;
    const n: usize = @intCast(count);
    files.fill_with_random_bytes(io_of(what), buf[0..n]) catch |e| std.debug.panic(what ++ ": {t}", .{e});
    return .from(buf[0..n]);
}

/// SHA-256, from Zig's standard library: the digest of a secret the app
/// keeps in its place.
pub export fn sha256_of_bytes(bytes: RocBytes) callconv(.c) RocBytes {
    _ = call("sha256_of_bytes");
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes.slice(), &digest, .{});
    return .from(&digest);
}

/// CRC-32, from Zig's standard library: a download's gzip trailer.
pub export fn crc32_of_bytes(bytes: RocBytes) callconv(.c) u32 {
    _ = call("crc32_of_bytes");
    return std.hash.Crc32.hash(bytes.slice());
}

/// A line the app logs: a refusal a server's owner wants to hear of, such
/// as sign-ups paused.
pub export fn write_line_to_server_log(line: RocBytes) callconv(.c) void {
    _ = call("write_line_to_server_log");
    log.warn("app: {f}", .{files.loggable(line.slice())});
}
