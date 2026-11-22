//! **THE FOLDERS WATCHED FOR CHANGES**: folders under the data root the
//! kernel tells the server of (inotify), and how many changes it has told
//! of since the server started, a count that only grows. A change is any
//! file or folder made, written, renamed, removed or given new rights
//! directly in a watched folder, by the server or by anyone else, and the
//! watched folder itself moved or removed; a read is none. The host knows
//! nothing of what a folder holds: the app keeps what it read of a folder
//! in memory and reads it again once the count has moved
//! (app/DirectoryCache.roc).
//!
//! **A WATCH IS SET BEFORE THE APP READS**: the app watches, takes the
//! count, then reads, so a change after the count is told of whether it
//! came before or after the read, and nothing is missed. A change the
//! kernel drops (its queue full) is told as one change, so even then the
//! count moves.
//!
//! **CONFINED AS EVERY PRIMITIVE IS**: a folder is opened through the data
//! root with no link followed (`DataRoot.open_folder`), and the watch is set
//! on what was opened, through `/proc/self/fd`, so no path is looked up
//! twice.
//!
//! Only the app's calls reach it, one at a time (the turn, host/http.zig),
//! so it takes no lock of its own.

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const files = @import("file_primitives.zig");

const log = std.log.scoped(.folder_watch);

/// Host.roc's `watch_folder_for_changes!` answer, alphabetical.
pub const WatchAnswer = enum(u8) { failed, missing, path_refused, watched };

/// Which folders a watch covers: the folder alone, or it and each folder
/// directly in it. Host.roc's tag, alphabetical.
pub const Reach = enum(u8) { alone, with_its_folders };

/// What a watched folder tells of: anything made, written, renamed,
/// removed or given new rights in it, and the folder itself moved or
/// removed.
const changes_mask: u32 = linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
    linux.IN.CREATE | linux.IN.DELETE | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

/// What a folder above a watched one tells of: a name made, renamed or
/// removed in it, and the folder itself moved or removed. A watch follows
/// its folder, not its path, so a watched folder moved away (or one above
/// it), and another put at its path, is told of here, and the app reads
/// and watches again.
const above_mask: u32 = linux.IN.CREATE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.DELETE |
    linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

pub const FolderWatch = struct {
    /// The kernel's queue of changes, made at the first watch.
    queue: ?linux.fd_t = null,
    /// Every change told of since the start.
    changes: u64 = 0,

    pub fn deinit(w: *FolderWatch) void {
        if (w.queue) |fd| _ = linux.close(fd);
        w.queue = null;
    }

    /// The folder `path` watched, and with `.with_its_folders` each folder
    /// directly in it, as they are now; a folder already watched stays so.
    /// Each folder above it, the data root included, is watched for a name
    /// made, renamed or removed (`above_mask`), so a folder moved away and
    /// another put at its path is told of. `missing` when it is not there,
    /// those above it that are watched, so its making is told of;
    /// `path_refused` as every primitive refuses a path; and `failed`,
    /// logged, when the kernel refuses a watch (too many, or no memory):
    /// then some of them may not be watched.
    pub fn watch(w: *FolderWatch, root: *const files.DataRoot, path: []const u8, reach: Reach) WatchAnswer {
        const what = "watch_folder_for_changes";
        root.count(.watches);
        if (!files.path_rule(path)) return .path_refused;
        if (root.watches_refused_for_test) |refused| if (refused.load(.acquire)) {
            log.warn(what ++ " {f}: refused, as a test asked", .{files.loggable(path)});
            return .failed;
        };
        const queue = w.queue orelse made: {
            const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) {
                log.warn(what ++ " {f}: inotify_init1: {t}", .{ files.loggable(path), linux.errno(rc) });
                return .failed;
            }
            const fd: linux.fd_t = @intCast(rc);
            w.queue = fd;
            break :made fd;
        };
        add(queue, root.dir, "", "", above_mask) catch return .failed;
        var above = std.mem.splitScalar(u8, path, '/');
        var start: usize = 0;
        while (above.next()) |part| {
            const end = start + part.len;
            if (end == path.len) break;
            const prefix = path[0..end];
            start = end + 1;
            var upper = switch (root.open_folder(what, prefix)) {
                .found => |d| d,
                .missing => return .missing,
                .path_refused => return .path_refused,
                .failed => return .failed,
            };
            defer upper.close(root.io);
            add(queue, upper, prefix, "", above_mask) catch return .failed;
        }
        var folder = switch (root.open_folder(what, path)) {
            .found => |d| d,
            .missing => return .missing,
            .path_refused => return .path_refused,
            .failed => return .failed,
        };
        defer folder.close(root.io);
        add(queue, folder, path, "", changes_mask) catch return .failed;
        if (reach == .alone) return .watched;
        var it = folder.iterate();
        while (it.next(root.io) catch |e| {
            log.warn(what ++ " {f}: {t}", .{ files.loggable(path), e });
            return .failed;
        }) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entry.kind != .directory and entry.kind != .unknown) continue;
            var inner = folder.openDir(root.io, entry.name, .{ .follow_symlinks = false }) catch |e| switch (e) {
                error.NotDir, error.SymLinkLoop, error.FileNotFound => continue,
                else => {
                    log.warn(what ++ " {f}/{f}: {t}", .{ files.loggable(path), files.loggable(entry.name), e });
                    return .failed;
                },
            };
            defer inner.close(root.io);
            add(queue, inner, path, entry.name, changes_mask) catch return .failed;
        }
        return .watched;
    }

    /// Every change told of since the start, the kernel's queue read to
    /// its end first.
    pub fn count_changes(w: *FolderWatch) u64 {
        const queue = w.queue orelse return w.changes;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const rc = linux.read(queue, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return w.changes,
                .INTR => continue,
                else => |e| std.debug.panic("count_changes_in_watched_folders: reading the kernel's queue: {t}", .{e}),
            }
            var at: usize = 0;
            while (at < rc) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&buf[at]));
                w.changes += 1;
                at += @sizeOf(linux.inotify_event) + event.len;
            }
        }
    }
};

/// The watch set on `folder`, `path`'s folder `name` (or `path` itself,
/// with `name` empty; the data root, with both empty), as its descriptor
/// names it, for `mask`: added to any mask the folder is watched for
/// already, so a folder both watched and above another keeps both.
fn add(queue: linux.fd_t, folder: Io.Dir, path: []const u8, name: []const u8, mask: u32) !void {
    var buf: [64]u8 = undefined;
    const by_descriptor = std.fmt.bufPrintSentinel(&buf, "/proc/self/fd/{d}", .{folder.handle}, 0) catch unreachable;
    const rc = linux.inotify_add_watch(queue, by_descriptor, mask | linux.IN.ONLYDIR | linux.IN.MASK_ADD);
    if (linux.errno(rc) != .SUCCESS) {
        log.warn("watch_folder_for_changes {f}{s}{f}: inotify_add_watch: {t}", .{ files.loggable(path), if (name.len > 0) "/" else "", files.loggable(name), linux.errno(rc) });
        return error.WatchRefused;
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a watched folder's changes are counted, a read's are not, and an unwatched folder's are not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "auth/1/keys");
    try tmp.dir.createDirPath(testing.io, "users/1");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auth/1/name", .data = "Steve" });
    var calls: files.FileCalls = .{};
    const root: files.DataRoot = .{ .io = testing.io, .dir = tmp.dir, .calls_for_test = &calls };
    var w: FolderWatch = .{};
    defer w.deinit();

    try testing.expectEqual(0, w.count_changes());
    try testing.expectEqual(WatchAnswer.watched, w.watch(&root, "auth", .with_its_folders));
    try testing.expectEqual(1, calls.watches.load(.monotonic));
    const before = w.count_changes();
    try testing.expectEqual(0, before);

    // A read and a listing change nothing.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    _ = root.read_utf8_bytes_from_file(arena.allocator(), "auth/1/name");
    _ = root.list_names_in_directory(arena.allocator(), "auth");
    try testing.expectEqual(before, w.count_changes());

    // A file in a folder watched with its folders, written in place.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auth/1/name", .data = "Stevie" });
    const written = w.count_changes();
    try testing.expect(written > before);

    // Deeper than the reach, and in a folder not watched: nothing.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "auth/1/keys/x", .data = "k" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users/1/x", .data = "u" });
    try testing.expectEqual(written, w.count_changes());

    // A new folder in the watched one, then the count holds still.
    try tmp.dir.createDirPath(testing.io, "auth/2");
    const made = w.count_changes();
    try testing.expect(made > written);
    try testing.expectEqual(made, w.count_changes());

    // The server's own replace is a change too.
    try testing.expectEqual(files.ReplaceAnswer.replaced, root.replace_file_with_utf8_bytes_atomically("auth/1/name", "Steve"));
    try testing.expect(w.count_changes() > made);
}

test "a folder alone: its own files count, its folders' don't" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "chat/channel/general");
    const root: files.DataRoot = .{ .io = testing.io, .dir = tmp.dir };
    var w: FolderWatch = .{};
    defer w.deinit();
    try testing.expectEqual(WatchAnswer.watched, w.watch(&root, "chat/channel", .alone));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "chat/channel/general/x", .data = "t" });
    try testing.expectEqual(0, w.count_changes());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "chat/channel/general.channel", .data = "1\n" });
    try testing.expect(w.count_changes() > 0);
}

test "a folder above a watched one: its folder moved away and another put in its place is a change; one not yet there is watched through its parent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "chat/channel");
    const root: files.DataRoot = .{ .io = testing.io, .dir = tmp.dir };
    var w: FolderWatch = .{};
    defer w.deinit();
    try testing.expectEqual(WatchAnswer.watched, w.watch(&root, "chat/channel", .alone));
    try tmp.dir.rename("chat", tmp.dir, "chat-moved", testing.io);
    const moved = w.count_changes();
    try testing.expect(moved > 0);
    try testing.expectEqual(WatchAnswer.missing, w.watch(&root, "chat/channel", .alone));
    try tmp.dir.createDirPath(testing.io, "chat/channel");
    try testing.expect(w.count_changes() > moved);
}

test "a watch a test refuses fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "auth");
    const refused: std.atomic.Value(bool) = .init(true);
    const root: files.DataRoot = .{ .io = testing.io, .dir = tmp.dir, .watches_refused_for_test = &refused };
    var w: FolderWatch = .{};
    defer w.deinit();
    try testing.expectEqual(WatchAnswer.failed, w.watch(&root, "auth", .with_its_folders));
}

test "missing, refused, and a link never watched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "real");
    try tmp.dir.symLink(testing.io, "real", "via", .{});
    const root: files.DataRoot = .{ .io = testing.io, .dir = tmp.dir };
    var w: FolderWatch = .{};
    defer w.deinit();
    try testing.expectEqual(WatchAnswer.missing, w.watch(&root, "nowhere", .alone));
    try testing.expectEqual(WatchAnswer.path_refused, w.watch(&root, "../x", .alone));
    try testing.expectEqual(WatchAnswer.path_refused, w.watch(&root, "via", .alone));
}
