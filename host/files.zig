//! **THE STORE**: the files under the data root, as the Roc's hosted file
//! functions (platform/Host.roc's `read!`, `write!`, `append!` and their
//! kin) ask for them. Each answers a tag, never a bare error, and the
//! request's failure is the caller's to record (host/call.zig's `Ctx`).
//!
//! **A PATH IS secrets.zig's PATH RULE**: relative, with no empty, `.` or
//! `..` part (`secrets.pathOk`, the one home of it). A path that breaks it
//! is the Roc's bug: `failed`, never `missing`, and nothing is touched.
//!
//! **MISSING AND FAILED ARE NEVER ONE ANSWER**: nothing there (the path, or
//! a folder on it, not found) is `missing`; anything else that stops a read
//! (a folder the server may not enter, a disk error) is `failed`. What is
//! read is often rewritten, so an unreadable file taken for an absent one
//! would be written over.
//!
//! **EVERY WRITE IS DURABLE BEFORE IT ANSWERS** (decision D5): the file is
//! synced, and so is each folder whose entries it changed (the file's own,
//! and the parent of every folder made for it). A sync that fails is the
//! write's failure.
//!
//! **`write` IS ATOMIC**: the bytes go to a sibling temporary, synced, then
//! renamed over the file, and the folder synced. A stop before the rename
//! leaves the old file whole (and the temporary, which the next write of
//! that file writes over). (zig-webbox store.zig's `replace`, rebuilt on a
//! data-root `Dir` and with the syncs it left to its host.)
//!
//! No lock: the turn (host/server.zig) runs one handler at a time, so two
//! writes of one file never meet.

const std = @import("std");
const Io = std.Io;
const secrets = @import("auth/secrets.zig");

/// The most bytes `read` answers; a larger file is a failed read.
pub const read_most = 16 * 1024 * 1024;

/// A test's fault, planted in the store's next writes.
pub const Fault = enum {
    none,
    /// **A STOP BETWEEN THE TEMPORARY AND THE RENAME**: the temporary
    /// written and synced, then the write ends as a killed process's would,
    /// with nothing renamed and nothing cleaned up.
    stop_before_rename,
    /// Every sync fails, as a disk's would (`error.InputOutput`).
    sync_fails,
};

pub const Read = union(enum) { failed, found: []const u8, missing };
pub const Kind = enum { dir, file, other };
pub const Entry = struct { name: []const u8, kind: Kind };
pub const Listing = union(enum) { failed, found: []const Entry, missing };
pub const Stat = union(enum) {
    failed,
    found: struct { size: u64, mtime: i64 },
    missing,
};

pub const Files = struct {
    io: Io,
    /// The data root, open for the server's life.
    root: Io.Dir,
    fault_for_test: Fault = .none,

    /// The file's bytes, in `arena`.
    pub fn read(f: *const Files, arena: std.mem.Allocator, path: []const u8) Read {
        if (!secrets.pathOk(path)) return .failed;
        const bytes = f.root.readFileAlloc(f.io, path, arena, .limited(read_most)) catch |e| return if (absent(e)) .missing else .failed;
        return .{ .found = bytes };
    }

    /// At most `max` of the file's bytes from `offset` (none past its end),
    /// in `arena`.
    pub fn readAt(f: *const Files, arena: std.mem.Allocator, path: []const u8, offset: u64, max: u64) Read {
        if (!secrets.pathOk(path)) return .failed;
        const file = f.root.openFile(f.io, path, .{}) catch |e| return if (absent(e)) .missing else .failed;
        defer file.close(f.io);
        const st = file.stat(f.io) catch return .failed;
        if (st.kind != .file) return .failed;
        const n: usize = @intCast(@min(max, st.size -| offset, read_most));
        const buf = arena.alloc(u8, n) catch return .failed;
        const got = file.readPositionalAll(f.io, buf, offset) catch return .failed;
        return .{ .found = buf[0..got] };
    }

    /// The file's size and its last change, in whole seconds since the
    /// epoch. A folder is `failed`: it is not a file.
    pub fn stat(f: *const Files, path: []const u8) Stat {
        if (!secrets.pathOk(path)) return .failed;
        const st = f.root.statFile(f.io, path, .{}) catch |e| return if (absent(e)) .missing else .failed;
        if (st.kind != .file) return .failed;
        return .{ .found = .{ .size = st.size, .mtime = st.mtime.toSeconds() } };
    }

    /// The folder's entries, in the order the disk gives them, in `arena`.
    /// A path that is a file is `failed`.
    pub fn list(f: *const Files, arena: std.mem.Allocator, path: []const u8) Listing {
        if (!secrets.pathOk(path)) return .failed;
        var dir = f.root.openDir(f.io, path, .{ .iterate = true }) catch |e| return switch (e) {
            error.FileNotFound => .missing,
            else => .failed,
        };
        defer dir.close(f.io);
        var out: std.ArrayList(Entry) = .empty;
        var it = dir.iterate();
        while (it.next(f.io) catch return .failed) |entry| {
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
        if (!secrets.pathOk(path)) return error.BadPath;
        var dir = try f.folderOf(path);
        defer if (dir.handle != f.root.handle) dir.close(f.io);
        const name = std.fs.path.basename(path);
        var tmp_buf: [16]u8 = undefined;
        const tmp = siblingName(&tmp_buf, name);
        {
            const file = try dir.createFile(f.io, tmp, .{});
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
        if (!secrets.pathOk(path)) return error.BadPath;
        var dir = try f.folderOf(path);
        defer if (dir.handle != f.root.handle) dir.close(f.io);
        const name = std.fs.path.basename(path);
        var made = false;
        const file = dir.openFile(f.io, name, .{ .mode = .read_write }) catch |e| switch (e) {
            error.FileNotFound => blk: {
                made = true;
                break :blk try dir.createFile(f.io, name, .{ .truncate = false });
            },
            else => return e,
        };
        defer file.close(f.io);
        const st = try file.stat(f.io);
        try file.writePositionalAll(f.io, bytes, st.size);
        try f.sync(file);
        if (made) try f.syncDir(dir);
        return st.size + bytes.len;
    }

    /// The file gone; one not there is gone already.
    pub fn remove(f: *const Files, path: []const u8) !void {
        if (!secrets.pathOk(path)) return error.BadPath;
        f.root.deleteFile(f.io, path) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        const parent = std.fs.path.dirname(path) orelse return f.syncDir(f.root);
        var dir = try f.root.openDir(f.io, parent, .{});
        defer dir.close(f.io);
        try f.syncDir(dir);
    }

    /// **THE FOLDER `path` IS IN, OPEN, EACH FOLDER ON THE WAY MADE AND ITS
    /// PARENT SYNCED**, so a new folder's entry is as durable as the file
    /// written in it. The root itself when `path` has one part (not to be
    /// closed).
    fn folderOf(f: *const Files, path: []const u8) !Io.Dir {
        const parent = std.fs.path.dirname(path) orelse return f.root;
        var dir = f.root;
        var parts = std.mem.splitScalar(u8, parent, '/');
        while (parts.next()) |part| {
            var made = true;
            dir.createDir(f.io, part, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => made = false,
                else => {
                    if (dir.handle != f.root.handle) dir.close(f.io);
                    return e;
                },
            };
            if (made) f.syncDir(dir) catch |e| {
                if (dir.handle != f.root.handle) dir.close(f.io);
                return e;
            };
            const next = dir.openDir(f.io, part, .{});
            if (dir.handle != f.root.handle) dir.close(f.io);
            dir = try next;
        }
        return dir;
    }

    fn sync(f: *const Files, file: Io.File) !void {
        if (f.fault_for_test == .sync_fails) return error.InputOutput;
        try file.sync(f.io);
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

/// **NOTHING THERE**: the path, or a folder on it, not found, or a part of
/// it a file. Every other error is a failure.
fn absent(e: anyerror) bool {
    return e == error.FileNotFound or e == error.NotDir;
}

/// The temporary `write` makes beside `name`: `~`, eight hex digits of a
/// hash of the name, `.tmp`. One per name, so writes of two files in one
/// folder never share it.
fn siblingName(buf: *[16]u8, name: []const u8) []const u8 {
    const h: u32 = @truncate(std.hash.Wyhash.hash(0, name));
    return std.fmt.bufPrint(buf, "~{x:0>8}.tmp", .{h}) catch unreachable;
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
