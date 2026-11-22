//! **THE BYTES KEPT UNDER A KEY**, part of the seam (host/seam.zig),
//! answered by host/kept_bytes.zig, in the server's memory alone.

const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;
const kept_bytes = @import("kept_bytes.zig");

/// Host.roc's `read_bytes_kept_under_key!` status, alphabetical.
pub const KeptStatus = enum(u8) { found, missing };
/// Its answer: the list, then the tag. `bytes` is empty when `Missing`.
pub const KeptRec = extern struct { bytes: RocBytes, status: KeptStatus };

fn kept_of(comptime what: []const u8) *kept_bytes.KeptBytes {
    return seam_call.call(what).kept orelse @panic(what ++ ": this call keeps no bytes (only the server's keeps any)");
}

pub export fn replace_bytes_kept_under_key(key: RocBytes, bytes: RocBytes) callconv(.c) kept_bytes.KeepAnswer {
    return kept_of("replace_bytes_kept_under_key").keep(key.slice(), bytes.slice());
}

pub export fn read_bytes_kept_under_key(key: RocBytes) callconv(.c) KeptRec {
    return if (kept_of("read_bytes_kept_under_key").recall(key.slice())) |bytes|
        .{ .bytes = .from(bytes), .status = .found }
    else
        .{ .bytes = .from(""), .status = .missing };
}
