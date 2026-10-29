//! **THE STORE**: the files under the data root, as the Roc's hosted file
//! functions (platform/Host.roc's `read!`, `write!`, `append!` and their
//! kin) ask for them. Each answers a tag, never a bare error, and the
//! request's failure is the caller's to record (host/call.zig's `Ctx`).
//!
//! **A PATH IS THE HOST'S PATH RULE** (host/auth/path_rule.zig): relative,
//! with no empty, `.` or `..` part, **and no part a temporary's name**
//! (`temp`). A path that breaks it is the Roc's bug: `failed`, never
//! `missing`, and nothing is touched.
//!
//! **A LINK IS NEVER FOLLOWED, AT ANY PART OF A PATH**: a link under the
//! data root can point outside it. Each folder on the way is opened from
//! the one before with O_NOFOLLOW (`walk`), and the file itself too, so the
//! kernel refuses a link in the same call that opens what is used: there is
//! no check of the path beforehand for a link swapped in to race. A link,
//! as the file or as a folder on its path, is `failed` for every function.
//!
//! **MISSING AND FAILED ARE NEVER ONE ANSWER**: nothing there (the path, or
//! a folder on it, not found) is `missing`; anything else that stops a read
//! (a folder the server may not enter, a link, a disk error) is `failed`.
//! What is read is often rewritten, so an unreadable file taken for an
//! absent one would be written over.
//!
//! **EVERY WRITE IS DURABLE BEFORE IT ANSWERS** (decision D5): the file is
//! synced, and so is each folder whose entries it changed (the file's own,
//! and the parent of every folder made for it). A sync that fails is the
//! write's failure.
//!
//! **`write` IS ATOMIC**: the bytes go to a sibling temporary, synced, then
//! renamed over the file, and the folder synced. A stop before the rename
//! leaves the old file whole, and the temporary: `list` never shows one,
//! the next write of that file takes it, and `sweepTemps` clears any left
//! at start. (zig-webbox store.zig's `replace`, rebuilt on a data-root
//! `Dir` and with the syncs it left to its host.)
//!
//! No lock: the turn (host/server.zig) runs one handler at a time, so two
//! writes of one file never meet.

const std = @import("std");
const Io = std.Io;
const path_rule = @import("auth/path_rule.zig");
const route = @import("seam/chat_route.zig");

/// The most bytes `read` answers; a larger file is a failed read.
pub const read_most = 16 * 1024 * 1024;

/// A fault planted in the store's next writes.
pub const Fault = enum {
    none,
    /// **A STOP BETWEEN THE TEMPORARY AND THE RENAME**: the temporary
    /// written and synced, then the write ends as a killed process's would,
    /// with nothing renamed and nothing cleaned up.
    stop_before_rename,
    /// Every sync fails, as a disk's would (`error.InputOutput`).
    sync_fails,
    /// **EVERY SYNC SKIPPED**: host/files_bench.zig's, to time what the
    /// syncs cost. A store that skips them is not durable; no test or
    /// server sets it.
    sync_skipped,
};

/// The answers cross the seam as they are (host/seam/chat_route.zig).
pub const Read = route.Read;
pub const Entry = route.Entry;
pub const Listing = route.Listing;
pub const Stat = route.Stat;

/// **THE STORE'S TEMPORARIES, ONE RULE**: the name `write` gives the
/// sibling it renames over a file, and the test `list` and `sweepTemps` use
/// to know one. `~`, eight lowercase hex digits of a hash of the file's
/// name, `.tmp`: one per name, so writes of two files in one folder never
/// share it. No path the Roc names may have a part that is one.
pub const temp = struct {
    pub const len = 13;

    pub fn name(buf: *[len]u8, of: []const u8) []const u8 {
        const h: u32 = @truncate(std.hash.Wyhash.hash(0, of));
        return std.fmt.bufPrint(buf, "~{x:0>8}.tmp", .{h}) catch unreachable;
    }

    pub fn is(entry: []const u8) bool {
        if (entry.len != len or entry[0] != '~' or !std.mem.endsWith(u8, entry, ".tmp")) return false;
        for (entry[1..9]) |c| switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        };
        return true;
    }
};

pub const Files = struct {
    io: Io,
    /// The data root, open for the server's life.
    root: Io.Dir,
    fault_for_test: Fault = .none,

    /// The file's bytes, in `arena`.
    pub fn read(f: *const Files, arena: std.mem.Allocator, path: []const u8) Read {
        const file = f.openFile(path, .read_only) catch |e| return if (absent(e)) .missing else .failed;
        defer file.close(f.io);
        const st = file.stat(f.io) catch return .failed;
        if (st.kind != .file or st.size > read_most) return .failed;
        return readOpen(f, arena, file, 0, st.size);
    }

    /// At most `max` of the file's bytes from `offset` (none past its end),
    /// in `arena`.
    pub fn readAt(f: *const Files, arena: std.mem.Allocator, path: []const u8, offset: u64, max: u64) Read {
        const file = f.openFile(path, .read_only) catch |e| return if (absent(e)) .missing else .failed;
        defer file.close(f.io);
        const st = file.stat(f.io) catch return .failed;
        if (st.kind != .file) return .failed;
        return readOpen(f, arena, file, offset, @min(max, st.size -| offset, read_most));
    }

    /// The file's size and its last change, in whole seconds since the
    /// epoch. A folder or a link is `failed`: it is not a file.
    pub fn stat(f: *const Files, path: []const u8) Stat {
        if (!pathOk(path)) return .failed;
        var dir = f.walk(path, .open) catch |e| return if (absent(e)) .missing else .failed;
        defer f.closeWalked(dir);
        const st = dir.statFile(f.io, std.fs.path.basename(path), .{ .follow_symlinks = false }) catch |e| return if (absent(e)) .missing else .failed;
        if (st.kind != .file) return .failed;
        return .{ .found = .{ .size = st.size, .mtime = st.mtime.toSeconds() } };
    }

    /// The folder's entries, in the order the disk gives them, in `arena`;
    /// never the store's own temporaries. A path that is a file or a link
    /// is `failed`.
    pub fn list(f: *const Files, arena: std.mem.Allocator, path: []const u8) Listing {
        if (!pathOk(path)) return .failed;
        var parent = f.walk(path, .open) catch |e| return if (e == error.FileNotFound) .missing else .failed;
        defer f.closeWalked(parent);
        const last = std.fs.path.basename(path);
        var dir = parent.openDir(f.io, last, .{ .iterate = true, .follow_symlinks = false }) catch |e| return switch (linkOr(f, parent, last, e)) {
            error.FileNotFound => .missing,
            else => .failed,
        };
        defer dir.close(f.io);
        var out: std.ArrayList(Entry) = .empty;
        var it = dir.iterate();
        while (it.next(f.io) catch return .failed) |entry| {
            if (temp.is(entry.name)) continue;
            const name = arena.dupe(u8, entry.name) catch return .failed;
            out.append(arena, .{ .name = name, .kind = switch (entry.kind) {
                .directory => .dir,
                .file => .file,
                else => .other,
            } }) catch return .failed;
        }
        return .{ .found = out.items };
    }

    /// **THE FILE MADE TO HOLD EXACTLY `bytes`, ATOMICALLY AND DURABLY**:
    /// a sibling temporary, synced, renamed over it, the folder synced. The
    /// folders above it are made as needed.
    pub fn write(f: *const Files, path: []const u8, bytes: []const u8) !void {
        if (!pathOk(path)) return error.BadPath;
        var dir = try f.walk(path, .make);
        defer f.closeWalked(dir);
        const name = std.fs.path.basename(path);
        // **A LINK AS THE FILE IS REFUSED, AND THIS CHECK CANNOT BE RACED
        // INTO AN ESCAPE**: the rename below never follows a link, so a link
        // swapped in after it is replaced, never written through.
        try refuseLink(f, dir, name);
        var tmp_buf: [temp.len]u8 = undefined;
        const tmp = temp.name(&tmp_buf, name);
        // A stopped write's temporary (or a link at its name) goes first,
        // so the exclusive create never meets one: O_EXCL never follows.
        dir.deleteFile(f.io, tmp) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        {
            const file = try dir.createFile(f.io, tmp, .{ .exclusive = true });
            defer file.close(f.io);
            try file.writeStreamingAll(f.io, bytes);
            try f.sync(file);
        }
        if (f.fault_for_test == .stop_before_rename) return error.StoppedForTest;
        dir.rename(tmp, dir, name, f.io) catch |e| {
            dir.deleteFile(f.io, tmp) catch {};
            return e;
        };
        try f.syncDir(dir);
    }

    /// **`bytes` AT THE END OF THE FILE, SYNCED**: one positional write at
    /// its end, the file and its folders made as needed; its size after.
    pub fn append(f: *const Files, path: []const u8, bytes: []const u8) !u64 {
        if (!pathOk(path)) return error.BadPath;
        var dir = try f.walk(path, .make);
        defer f.closeWalked(dir);
        const name = std.fs.path.basename(path);
        var made = false;
        // O_NOFOLLOW opens it, and O_EXCL makes it: neither follows a link.
        const file = dir.openFile(f.io, name, .{ .mode = .read_write, .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound => blk: {
                made = true;
                break :blk try dir.createFile(f.io, name, .{ .exclusive = true, .truncate = false });
            },
            else => return e,
        };
        defer file.close(f.io);
        const st = try file.stat(f.io);
        if (st.kind != .file) return error.NotAFile;
        try file.writePositionalAll(f.io, bytes, st.size);
        try f.sync(file);
        if (made) try f.syncDir(dir);
        return st.size + bytes.len;
    }

    /// The file gone; one not there is gone already. A link is refused,
    /// not removed (unlinking never follows, so the check cannot be raced
    /// into an escape).
    pub fn remove(f: *const Files, path: []const u8) !void {
        if (!pathOk(path)) return error.BadPath;
        var dir = f.walk(path, .open) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer f.closeWalked(dir);
        const name = std.fs.path.basename(path);
        try refuseLink(f, dir, name);
        dir.deleteFile(f.io, name) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        try f.syncDir(dir);
    }

    /// **EVERY TEMPORARY A STOPPED WRITE LEFT, REMOVED; HOW MANY**: the
    /// data root walked, never through a link, before the server takes a
    /// request (host/main.zig), so no write is in flight. Only a regular
    /// file with a temporary's name goes. The folders are not synced: a
    /// temporary that comes back after a crash is swept at the next start.
    pub fn sweepTemps(f: *const Files) !usize {
        return sweepDir(f, f.root, 0);
    }

    /// The folders a path is deeper than are past this, and a sweep that
    /// reaches it fails rather than recurse without end.
    const sweep_depth_most = 64;

    fn sweepDir(f: *const Files, dir: Io.Dir, depth: usize) !usize {
        if (depth > sweep_depth_most) return error.TooDeep;
        var readable = try dir.openDir(f.io, ".", .{ .iterate = true });
        defer readable.close(f.io);
        var swept: usize = 0;
        var it = readable.iterate();
        while (try it.next(f.io)) |entry| {
            switch (entry.kind) {
                .file => if (temp.is(entry.name)) {
                    try readable.deleteFile(f.io, entry.name);
                    swept += 1;
                },
                .directory => {
                    var sub = try readable.openDir(f.io, entry.name, .{ .follow_symlinks = false });
                    defer sub.close(f.io);
                    swept += try sweepDir(f, sub, depth + 1);
                },
                else => {},
            }
        }
        return swept;
    }

    /// The file at `path`, opened with no link followed at any part.
    fn openFile(f: *const Files, path: []const u8, mode: Io.Dir.OpenFileOptions.Mode) !Io.File {
        if (!pathOk(path)) return error.BadPath;
        var dir = try f.walk(path, .open);
        defer f.closeWalked(dir);
        return dir.openFile(f.io, std.fs.path.basename(path), .{ .mode = mode, .follow_symlinks = false });
    }

    const Walk = enum { open, make };

    /// **THE FOLDER `path` IS IN, OPENED A PART AT A TIME, EACH FROM THE
    /// ONE BEFORE, NONE THROUGH A LINK** (O_NOFOLLOW): the kernel refuses a
    /// link in the call that opens the folder, so nothing checked can be
    /// swapped before it is used. A link on the way is `error.IsLink`.
    /// `.make` makes each missing folder and syncs its parent, so a new
    /// folder's entry is as durable as the file written in it. The root
    /// itself when `path` has one part (`closeWalked` knows not to close it).
    fn walk(f: *const Files, path: []const u8, how: Walk) !Io.Dir {
        var dir = f.root;
        errdefer f.closeWalked(dir);
        var parts = std.mem.splitScalar(u8, path, '/');
        var part = parts.first();
        while (parts.next()) |after| : (part = after) {
            if (how == .make) {
                var made = true;
                dir.createDir(f.io, part, .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => made = false,
                    else => return e,
                };
                if (made) try f.syncDir(dir);
            }
            const next = dir.openDir(f.io, part, .{ .follow_symlinks = false }) catch |e| return linkOr(f, dir, part, e);
            f.closeWalked(dir);
            dir = next;
        }
        return dir;
    }

    fn closeWalked(f: *const Files, dir: Io.Dir) void {
        if (dir.handle != f.root.handle) dir.close(f.io);
    }

    fn sync(f: *const Files, file: Io.File) !void {
        switch (f.fault_for_test) {
            .sync_fails => return error.InputOutput,
            .sync_skipped => return,
            else => try file.sync(f.io),
        }
    }

    /// A folder synced: its entries (a rename, a new file) made durable.
    /// **OPENED AGAIN TO BE SYNCED**: a folder opened only to be walked
    /// (std's default, O_PATH) has a descriptor fsync refuses.
    fn syncDir(f: *const Files, dir: Io.Dir) !void {
        var readable = try dir.openDir(f.io, ".", .{ .iterate = true });
        defer readable.close(f.io);
        try f.sync(.{ .handle = readable.handle, .flags = .{ .nonblocking = false } });
    }
};

/// The host's path rule, and no part a temporary's name.
fn pathOk(path: []const u8) bool {
    if (!path_rule.ok(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| if (temp.is(p)) return false;
    return true;
}

/// `len` bytes of an open file from `offset`, in `arena`.
fn readOpen(f: *const Files, arena: std.mem.Allocator, file: Io.File, offset: u64, len: u64) Read {
    const buf = arena.alloc(u8, @intCast(len)) catch return .failed;
    const got = file.readPositionalAll(f.io, buf, offset) catch return .failed;
    return .{ .found = buf[0..got] };
}

/// **WHY AN O_NOFOLLOW OPEN FAILED**: a folder opened so answers `NotDir`
/// for a link and for a file alike, and a file `SymLinkLoop` for a link.
/// The entry is looked at (not followed) only to name the error; the open
/// already refused it, so there is nothing here to race.
fn linkOr(f: *const Files, dir: Io.Dir, name: []const u8, e: anyerror) anyerror {
    if (e != error.NotDir and e != error.SymLinkLoop) return e;
    const st = dir.statFile(f.io, name, .{ .follow_symlinks = false }) catch return e;
    return if (st.kind == .sym_link) error.IsLink else e;
}

/// `error.IsLink` if `name` in `dir` is a link; nothing there is fine.
fn refuseLink(f: *const Files, dir: Io.Dir, name: []const u8) !void {
    const st = dir.statFile(f.io, name, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    if (st.kind == .sym_link) return error.IsLink;
}

/// **NOTHING THERE**: the path, or a folder on it, not found, or a part of
/// it a file. Every other error (a link among them) is a failure.
fn absent(e: anyerror) bool {
    return e == error.FileNotFound or e == error.NotDir;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testFiles(tmp: *testing.TmpDir) Files {
    return .{ .io = testing.io, .root = tmp.dir };
}

test "write: atomic; a stop between the temporary and the rename leaves the old file whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = testFiles(&tmp);
    try f.write("a/b/note.txt", "the old record\n");
    f.fault_for_test = .stop_before_rename;
    try testing.expectError(error.StoppedForTest, f.write("a/b/note.txt", "the new record, longer than the old\n"));
    f.fault_for_test = .none;
    try testing.expectEqualStrings("the old record\n", (try readFound(&f, "a/b/note.txt")));
    // The stopped write's temporary is there, and the next write takes it.
    try f.write("a/b/note.txt", "the next\n");
    try testing.expectEqualStrings("the next\n", (try readFound(&f, "a/b/note.txt")));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(1, f.list(arena_state.allocator(), "a/b").found.len);
}

test "a stopped write's temporary: never listed, never a path, swept at start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f = testFiles(&tmp);
    try f.write("top", "t");
    try f.write("d/e/kept", "k");
    f.fault_for_test = .stop_before_rename;
    try testing.expectError(error.StoppedForTest, f.write("top", "lost"));
    try testing.expectError(error.StoppedForTest, f.write("d/e/kept", "lost"));
    try testing.expectError(error.StoppedForTest, f.write("d/e/new", "lost"));
    f.fault_for_test = .none;

    // On disk: each temporary beside its file. Listed: only the files.
    var buf: [temp.len]u8 = undefined;
    _ = try tmp.dir.statFile(testing.io, temp.name(&buf, "top"), .{});
    try testing.expectEqual(1, f.list(a, "d/e").found.len);
    try testing.expectEqualStrings("kept", f.list(a, "d/e").found[0].name);

    // A temporary's name is no path's part: the Roc can never reach one.
    const tmp_name = temp.name(&buf, "kept");
    const as_path = try std.fmt.allocPrint(a, "d/e/{s}", .{tmp_name});
    try testing.expectEqual(Read.failed, f.read(a, as_path));
    try testing.expectError(error.BadPath, f.write(as_path, "x"));
    try testing.expectError(error.BadPath, f.remove(as_path));

    // A file the Roc wrote with a name like one's, but not one, is listed.
    try testing.expect(!temp.is("~0123456G.tmp") and !temp.is("~01234567.txt") and temp.is("~0123abcd.tmp"));
    try f.write("d/e/~0123456G.tmp", "a near miss");

    try testing.expectEqual(3, try f.sweepTemps());
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, temp.name(&buf, "top"), .{}));
    try testing.expectEqual(0, try f.sweepTemps());
    try testing.expectEqualStrings("t", (try readFound(&f, "top")));
    try testing.expectEqualStrings("k", (try readFound(&f, "d/e/kept")));
    try testing.expectEqualStrings("a near miss", (try readFound(&f, "d/e/~0123456G.tmp")));
}

test "a sweep never follows a link, nor removes one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    const f = testFiles(&tmp);
    // A temporary outside the root, a link inside to its folder, and a
    // link with a temporary's name.
    var buf: [temp.len]u8 = undefined;
    const name = temp.name(&buf, "x");
    try outside.dir.writeFile(testing.io, .{ .sub_path = name, .data = "outside" });
    const out_path = try outside.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(out_path);
    try tmp.dir.symLink(testing.io, out_path, "escape", .{});
    try tmp.dir.symLink(testing.io, name, "~0123abcd.tmp", .{});
    try testing.expectEqual(0, try f.sweepTemps());
    _ = try outside.dir.statFile(testing.io, name, .{});
    _ = try tmp.dir.statFile(testing.io, "~0123abcd.tmp", .{ .follow_symlinks = false });
}

test "a link is refused by every function, as the file, as a folder on the way, to a folder outside" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = testFiles(&tmp);

    const secret = "OUTSIDE-the-root";
    try outside.dir.writeFile(testing.io, .{ .sub_path = "x", .data = secret });
    const out_path = try outside.dir.realPathFileAlloc(testing.io, ".", a);
    const out_file = try std.fmt.allocPrint(a, "{s}/x", .{out_path});

    try f.write("in/real", "inside");
    var in = try tmp.dir.openDir(testing.io, "in", .{});
    defer in.close(testing.io);
    // A link as the file: to a file outside, and to one inside.
    try in.symLink(testing.io, out_file, "to_out", .{});
    try in.symLink(testing.io, "real", "to_real", .{});
    // A link as a folder on the way: to a folder inside, and to one outside.
    try tmp.dir.symLink(testing.io, "in", "via", .{});
    try tmp.dir.symLink(testing.io, out_path, "away", .{});
    // A dangling link: a write through it would make a file outside.
    try in.symLink(testing.io, try std.fmt.allocPrint(a, "{s}/made", .{out_path}), "dangling", .{});

    for ([_][]const u8{ "in/to_out", "in/to_real", "via/real", "away/x", "in/dangling", "away/new/deeper" }) |p| {
        try testing.expectEqual(Read.failed, f.read(a, p));
        try testing.expectEqual(Read.failed, f.readAt(a, p, 0, 10));
        try testing.expectEqual(Stat.failed, f.stat(p));
        try testing.expect(std.meta.isError(f.write(p, "written through")));
        try testing.expect(std.meta.isError(f.append(p, "appended through")));
        try testing.expect(std.meta.isError(f.remove(p)));
    }
    for ([_][]const u8{ "via", "away", "in/to_real", "away/sub" }) |p| {
        try testing.expectEqual(Listing.failed, f.list(a, p));
    }

    // Nothing outside was read, written, made or removed; the links stand.
    try testing.expectEqualStrings(secret, try outside.dir.readFileAlloc(testing.io, "x", a, .limited(100)));
    try testing.expectError(error.FileNotFound, outside.dir.statFile(testing.io, "made", .{}));
    try testing.expectError(error.FileNotFound, outside.dir.statFile(testing.io, "new", .{}));
    try testing.expectEqualStrings("inside", (try readFound(&f, "in/real")));
    for ([_][]const u8{ "in/to_out", "in/to_real", "via", "away", "in/dangling" }) |p| {
        try testing.expectEqual(Io.File.Kind.sym_link, (try tmp.dir.statFile(testing.io, p, .{ .follow_symlinks = false })).kind);
    }
}

test "append: the size after, each time" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = testFiles(&tmp);
    try testing.expectEqual(6, try f.append("log/t.md", "first\n"));
    try testing.expectEqual(13, try f.append("log/t.md", "second\n"));
    try testing.expectEqual(13, try f.append("log/t.md", ""));
    try testing.expectEqualStrings("first\nsecond\n", (try readFound(&f, "log/t.md")));
}

test "an empty, absolute or `..` path is refused by every function, and nothing is touched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = testFiles(&tmp);
    try tmp.dir.createDir(testing.io, "inside", .default_dir);
    try f.write("inside/x", "x");
    for ([_][]const u8{ "", "/etc/passwd", "..", "../x", "inside/../../x", "inside/../x", "a//b", "./x" }) |p| {
        try testing.expectEqual(Read.failed, f.read(testing.allocator, p));
        try testing.expectEqual(Read.failed, f.readAt(testing.allocator, p, 0, 10));
        try testing.expectEqual(Stat.failed, f.stat(p));
        try testing.expectEqual(Listing.failed, f.list(testing.allocator, p));
        try testing.expectError(error.BadPath, f.write(p, "no"));
        try testing.expectError(error.BadPath, f.append(p, "no"));
        try testing.expectError(error.BadPath, f.remove(p));
    }
    try testing.expectEqualStrings("x", (try readFound(&f, "inside/x")));
}

test "missing and failed differ: a folder of mode 000 is a failure, not a missing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = testFiles(&tmp);
    try f.write("locked/x", "kept");
    try testing.expectEqual(Read.missing, f.read(testing.allocator, "nope/x"));
    try testing.expectEqual(Read.missing, f.read(testing.allocator, "locked/nope"));
    try testing.expectEqual(Read.missing, f.read(testing.allocator, "locked/x/under_a_file"));
    try testing.expectEqual(Stat.missing, f.stat("locked/nope"));
    try testing.expectEqual(Listing.missing, f.list(testing.allocator, "nope"));

    var locked = try tmp.dir.openDir(testing.io, "locked", .{ .iterate = true });
    defer locked.close(testing.io);
    try locked.setPermissions(testing.io, .fromMode(0o000));
    defer locked.setPermissions(testing.io, .fromMode(0o700)) catch {};
    // Root reads through a 000 folder, and the test would prove nothing.
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    try testing.expectEqual(Read.failed, f.read(testing.allocator, "locked/x"));
    try testing.expectEqual(Read.failed, f.read(testing.allocator, "locked/nope"));
    try testing.expectEqual(Read.failed, f.readAt(testing.allocator, "locked/x", 0, 4));
    try testing.expectEqual(Stat.failed, f.stat("locked/x"));
    try testing.expectEqual(Listing.failed, f.list(testing.allocator, "locked"));
    try testing.expect(std.meta.isError(f.write("locked/x", "lost")));
    try testing.expect(std.meta.isError(f.append("locked/x", "lost")));
}

test "a failed sync fails the write, the append and the remove" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = testFiles(&tmp);
    try f.write("x", "old");
    f.fault_for_test = .sync_fails;
    try testing.expectError(error.InputOutput, f.write("x", "new"));
    // The write failed before its rename: the old bytes are still the file's.
    try testing.expectEqualStrings("old", (try readFound(&f, "x")));
    try testing.expectError(error.InputOutput, f.append("y", "new"));
    try testing.expectError(error.InputOutput, f.remove("x"));
}

test "readAt, stat, list and remove" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = testFiles(&tmp);
    try f.write("d/t", "0123456789");
    try testing.expectEqualStrings("345", (f.readAt(a, "d/t", 3, 3)).found);
    try testing.expectEqualStrings("89", (f.readAt(a, "d/t", 8, 100)).found);
    try testing.expectEqualStrings("", (f.readAt(a, "d/t", 50, 100)).found);
    try testing.expectEqual(10, f.stat("d/t").found.size);
    try testing.expect(f.stat("d/t").found.mtime > 1_700_000_000);
    try testing.expectEqual(Stat.failed, f.stat("d"));
    try f.write("d/sub/u", "u");
    const l = f.list(a, "d").found;
    try testing.expectEqual(2, l.len);
    try testing.expectEqual(Listing.failed, f.list(a, "d/t"));
    try f.remove("d/t");
    try f.remove("d/t");
    try f.remove("gone/d/t");
    try testing.expectEqual(Read.missing, f.read(a, "d/t"));
}

fn readFound(f: *const Files, path: []const u8) ![]const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    var fba = std.heap.FixedBufferAllocator.init(&S.buf);
    return switch (f.read(fba.allocator(), path)) {
        .found => |b| b,
        else => |r| {
            std.debug.print("read {s}: {t}\n", .{ path, r });
            return error.NotFound;
        },
    };
}
