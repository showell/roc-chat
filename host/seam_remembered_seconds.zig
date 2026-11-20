//! **THE SECONDS KEPT UNDER A KEY**, part of the seam (host/seam.zig),
//! answered by host/remembered_seconds.zig, in the server's memory alone.

const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;
const remembered = @import("remembered_seconds.zig");

/// Host.roc's `replace_second_kept_under_key!` and
/// `read_second_kept_under_key!` status, alphabetical.
pub const RememberedStatus = enum(u8) { found, missing };
/// Their answer: the I64, then the tag. `second` is 0 when `Missing`.
pub const RememberedRec = extern struct { second: i64, status: RememberedStatus };

fn seconds_of(comptime what: []const u8) *remembered.RememberedSeconds {
    return seam_call.call(what).seconds orelse @panic(what ++ ": this call has no remembered seconds (only the server's keeps any)");
}

fn remembered_rec(second: ?i64) RememberedRec {
    return if (second) |s| .{ .second = s, .status = .found } else .{ .second = 0, .status = .missing };
}

pub export fn replace_second_kept_under_key(key: RocBytes, second: i64) callconv(.c) RememberedRec {
    return remembered_rec(seconds_of("replace_second_kept_under_key").remember(key.slice(), second));
}

pub export fn read_second_kept_under_key(key: RocBytes) callconv(.c) RememberedRec {
    return remembered_rec(seconds_of("read_second_kept_under_key").recall(key.slice()));
}
