//! **THE FILE PRIMITIVES**, part of the seam (host/seam.zig): Host.roc's
//! reads, writes and listings under the data root, and the data disk's
//! free bytes, each answered by host/file_primitives.zig; and the folders
//! watched for changes, by host/folder_watch.zig.

const std = @import("std");
const files = @import("file_primitives.zig");
const folder_watch = @import("folder_watch.zig");
const seam_call = @import("seam_call.zig");
const RocBytes = seam_call.RocBytes;
const RocBytesList = seam_call.RocBytesList;
const call = seam_call.call;
const root_of = seam_call.root_of;

// ── the answers ─────────────────────────────────────────────────────────────

/// Host.roc's `read_utf8_bytes_from_file!` status, alphabetical.
pub const ReadStatus = enum(u8) { failed, found, missing, not_utf8, path_refused };
/// Host.roc's `read_utf8_bytes_from_file!` answer: the list, then the tag.
pub const ReadRec = extern struct { bytes: RocBytes, status: ReadStatus };
/// Host.roc's `list_names_in_directory!` answer.
pub const ListRec = extern struct { names: RocBytesList, status: ReadStatus };
/// Host.roc's `read_binary_bytes_from_file!` status, alphabetical.
pub const BinaryReadStatus = enum(u8) { failed, found, missing, path_refused };
/// Host.roc's `read_binary_bytes_from_file!` answer: the list, then the tag.
pub const BinaryReadRec = extern struct { bytes: RocBytes, status: BinaryReadStatus };

comptime {
    for (.{ ReadStatus, BinaryReadStatus, files.AppendAnswer, files.CreateAnswer, files.BinaryCreateAnswer, files.ReplaceAnswer, files.MakeDirectoryAnswer, folder_watch.WatchAnswer, folder_watch.Reach }) |E| {
        std.debug.assert(@sizeOf(E) == 1);
    }
}

// ── the hosted functions ────────────────────────────────────────────────────

pub export fn read_utf8_bytes_from_file(path: RocBytes) callconv(.c) ReadRec {
    const what = "read_utf8_bytes_from_file";
    return switch (root_of(what).read_utf8_bytes_from_file(call(what).arena, path.slice())) {
        .found => |b| .{ .bytes = .from(b), .status = .found },
        .missing => .{ .bytes = .from(""), .status = .missing },
        .not_utf8 => .{ .bytes = .from(""), .status = .not_utf8 },
        .path_refused => .{ .bytes = .from(""), .status = .path_refused },
        .failed => .{ .bytes = .from(""), .status = .failed },
    };
}

pub export fn read_binary_bytes_from_file(path: RocBytes) callconv(.c) BinaryReadRec {
    const what = "read_binary_bytes_from_file";
    return switch (root_of(what).read_binary_bytes_from_file(call(what).arena, path.slice())) {
        .found => |b| .{ .bytes = .from(b), .status = .found },
        .missing => .{ .bytes = .from(""), .status = .missing },
        .path_refused => .{ .bytes = .from(""), .status = .path_refused },
        .failed => .{ .bytes = .from(""), .status = .failed },
    };
}

pub export fn create_file_with_binary_bytes_unless_it_exists(path: RocBytes, bytes: RocBytes) callconv(.c) files.BinaryCreateAnswer {
    return root_of("create_file_with_binary_bytes_unless_it_exists").create_file_with_binary_bytes_unless_it_exists(path.slice(), bytes.slice());
}

pub export fn append_utf8_bytes_to_file(path: RocBytes, bytes: RocBytes) callconv(.c) files.AppendAnswer {
    return root_of("append_utf8_bytes_to_file").append_utf8_bytes_to_file(path.slice(), bytes.slice());
}

pub export fn create_file_with_utf8_bytes_unless_it_exists(path: RocBytes, bytes: RocBytes) callconv(.c) files.CreateAnswer {
    return root_of("create_file_with_utf8_bytes_unless_it_exists").create_file_with_utf8_bytes_unless_it_exists(path.slice(), bytes.slice());
}

pub export fn replace_file_with_utf8_bytes_atomically(path: RocBytes, bytes: RocBytes) callconv(.c) files.ReplaceAnswer {
    return root_of("replace_file_with_utf8_bytes_atomically").replace_file_with_utf8_bytes_atomically(path.slice(), bytes.slice());
}

pub export fn make_directory_and_its_parents(path: RocBytes) callconv(.c) files.MakeDirectoryAnswer {
    return root_of("make_directory_and_its_parents").make_directory_and_its_parents(path.slice());
}

pub export fn list_names_in_directory(path: RocBytes) callconv(.c) ListRec {
    const what = "list_names_in_directory";
    return switch (root_of(what).list_names_in_directory(call(what).arena, path.slice())) {
        .found => |names| .{ .names = .from(names), .status = .found },
        .missing => .{ .names = .from(&.{}), .status = .missing },
        .not_utf8 => .{ .names = .from(&.{}), .status = .not_utf8 },
        .path_refused => .{ .names = .from(&.{}), .status = .path_refused },
        .failed => .{ .names = .from(&.{}), .status = .failed },
    };
}

pub export fn free_bytes_on_data_disk() callconv(.c) u64 {
    return root_of("free_bytes_on_data_disk").free_bytes_on_data_disk();
}

fn watch_of(comptime what: []const u8) *folder_watch.FolderWatch {
    return call(what).watch orelse @panic(what ++ ": this call watches no folders (only the server's does)");
}

pub export fn watch_folder_for_changes(path: RocBytes, reach: folder_watch.Reach) callconv(.c) folder_watch.WatchAnswer {
    const what = "watch_folder_for_changes";
    return watch_of(what).watch(root_of(what), path.slice(), reach);
}

pub export fn count_changes_in_watched_folders() callconv(.c) u64 {
    return watch_of("count_changes_in_watched_folders").count_changes();
}
