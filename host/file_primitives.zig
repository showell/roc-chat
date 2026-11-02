//! **THE FILE PRIMITIVES**: general reads and writes of UTF-8 text under one
//! data root, knowing nothing of what the text means. The Roc's `FileSystem`
//! module is their only caller, and it alone knows which file holds what.
//! docs/platform.md describes each one; this file is where they are kept.
//!
//! **A TRUST BOUNDARY: EVERY PATH IS CONFINED TO THE DATA ROOT**
//! (`path_rule`): relative, its parts split by `/`, none empty, none
//! starting with `.` (so no `.`, no `..`, and no name a replace's temporary
//! uses), no NUL, and UTF-8. A path that breaks the rule is `path_refused`
//! and nothing is touched.
//!
//! **A LINK IS NEVER FOLLOWED, AT ANY PART OF A PATH**: a link under the
//! root can point outside it. Each folder on the way is opened from the one
//! before with O_NOFOLLOW (`walk`), and so is the file, so the kernel refuses
//! a link in the same call that opens what is used: nothing is checked first
//! and used later, so nothing can be swapped in between. A link anywhere on
//! the path is `path_refused`.
//!
//! **TEXT ONLY, BOTH WAYS**: bytes that are not UTF-8 are `not_utf8`, on
//! every write (nothing is written) and on every read (nothing is handed
//! back). Never a crash.
//!
//! **MISSING AND FAILED ARE NEVER ONE ANSWER**: a file read as missing may
//! be written afresh, so a file that exists but cannot be read must never
//! look missing.
//!
//! **EVERY WRITE IS DURABLE BEFORE IT ANSWERS**: the file is fsynced, and so
//! is each folder whose entries changed. A failed fsync fails the write.
//!
//! **NO LOCKS**: the server answers one request at a time (host/http.zig),
//! so two writes of one file never meet.
//!
//! **EACH ANSWER'S TAGS ARE IN ROC'S ORDER, ALPHABETICAL**: a tag union with
//! no payloads crosses to the Roc as one byte numbered so, and these enums
//! cross as they are (host/seam_test.zig holds them to `roc glue`'s).

const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;

const log = std.log.scoped(.file_primitives);

/// **WHEN THIS FILE IS THE TESTS' ROOT, THEIR PLANTED FAILURES' WARNINGS
/// ARE NOT LOGGED**: the tests check every answer themselves. (A setting
/// only the root's counts, so the server's own log is untouched.)
pub const std_options: std.Options = .{ .log_level = .err };

/// **THE READ CAP, A SAFETY NET**: the most bytes
/// `read_utf8_bytes_from_file` answers; a larger file is a failed read, so
/// one huge file can't exhaust the request's memory. 17 MiB, strictly above
/// the app's own limit on a transcript (16 MiB, `Transcript.most_bytes` in
/// app/Transcript.roc, the rule's one home), so a file the app grew to its
/// limit is always read: this cap is reached only by a file the app did
/// not write.
pub const read_most = 17 * 1024 * 1024;

/// **BYTES FROM OUTSIDE, AS A LOG LINE SHOWS THEM, THE ONE HOME OF THAT
/// RULE**: printable ASCII as it is, every other byte (a CR, an LF, an
/// escape, a byte of UTF-8) as `\xNN`, so a path or a client's request can
/// never start a forged line in the log or drive the terminal reading it.
/// Every log line that holds such bytes (here, and host/http.zig) prints
/// them through this, with `{f}`.
pub fn loggable(bytes: []const u8) std.ascii.HexEscape {
    return std.ascii.hexEscape(bytes, .lower);
}

/// The longest path the rule allows, in bytes.
pub const path_most = 1024;

pub const ReadAnswer = union(enum) {
    failed,
    found: []const u8,
    missing,
    not_utf8,
    path_refused,
};

pub const AppendAnswer = enum(u8) { appended, failed, missing_directory, not_utf8, path_refused };

pub const CreateAnswer = enum(u8) { already_exists, created, failed, missing_directory, not_utf8, path_refused };

pub const ReplaceAnswer = enum(u8) { failed, missing_directory, not_utf8, path_refused, replaced };

pub const MakeDirectoryAnswer = enum(u8) { failed, made, path_refused };

pub const ListAnswer = union(enum) {
    failed,
    found: []const []const u8,
    missing,
    not_utf8,
    path_refused,
};

/// A fault a test plants in the next replace.
pub const Fault = enum {
    none,
    /// **A STOP BETWEEN THE TEMPORARY AND THE RENAME**: the temporary
    /// written and fsynced, then the replace ends as a killed process's
    /// would, nothing renamed and nothing cleaned up.
    stop_before_rename,
    /// Every fsync fails, as a failing disk's would.
    fsync_fails,
};

/// **THE PATH RULE, ITS ONE HOME**: whether `path` stays inside the data
/// root by its spelling. Links are refused as the path is walked.
pub fn path_rule(path: []const u8) bool {
    if (path.len == 0 or path.len > path_most) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.') return false;
        if (std.mem.indexOfScalar(u8, part, 0) != null) return false;
    }
    return true;
}

/// The name a replace writes before its rename, beside the file: `.` and
/// the file's name, so the path rule keeps every caller from naming it, and
/// a listing never shows it.
fn temporary_name(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".{s}.replacing", .{name}) catch unreachable;
}

pub const DataRoot = struct {
    io: Io,
    /// The data root, open for the server's life.
    dir: Io.Dir,
    fault_for_test: Fault = .none,

    /// **THE FILE'S TEXT**: `found`, its bytes in `arena`; `missing` when
    /// it, or a folder on its path, is not there.
    pub fn read_utf8_bytes_from_file(root: *const DataRoot, arena: std.mem.Allocator, path: []const u8) ReadAnswer {
        if (!path_rule(path)) return .path_refused;
        const dir = root.walk(path, .open) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            error.FileNotFound, error.NotDir => .missing,
            else => root.failed("read_utf8_bytes_from_file", path, e, @as(ReadAnswer, .failed)),
        };
        defer root.close_walked(dir);
        const name = std.fs.path.basename(path);
        const file = dir.openFile(root.io, name, .{ .follow_symlinks = false, .allow_directory = false }) catch |e| return switch (link_or(root, dir, name, e)) {
            error.IsLink => .path_refused,
            error.FileNotFound => .missing,
            else => |other| root.failed("read_utf8_bytes_from_file", path, other, @as(ReadAnswer, .failed)),
        };
        defer file.close(root.io);
        const st = file.stat(root.io) catch |e| return root.failed("read_utf8_bytes_from_file", path, e, @as(ReadAnswer, .failed));
        if (st.kind != .file) return root.failed("read_utf8_bytes_from_file", path, error.NotAFile, @as(ReadAnswer, .failed));
        if (st.size > read_most) return root.failed("read_utf8_bytes_from_file", path, error.FileTooBig, @as(ReadAnswer, .failed));
        const buf = arena.alloc(u8, @intCast(st.size)) catch |e| return root.failed("read_utf8_bytes_from_file", path, e, @as(ReadAnswer, .failed));
        const got = file.readPositionalAll(root.io, buf, 0) catch |e| return root.failed("read_utf8_bytes_from_file", path, e, @as(ReadAnswer, .failed));
        if (!std.unicode.utf8ValidateSlice(buf[0..got])) return .not_utf8;
        return .{ .found = buf[0..got] };
    }

    /// **`bytes` AT THE FILE'S END, FSYNCED**: opened with O_APPEND, so
    /// every write lands at the end; made when it is missing, and then its
    /// folder fsynced too. Its folder must exist (`missing_directory`). A
    /// failed fsync is `failed` though the bytes were written: it says they
    /// may not last, not that they are absent.
    pub fn append_utf8_bytes_to_file(root: *const DataRoot, path: []const u8, bytes: []const u8) AppendAnswer {
        const what = "append_utf8_bytes_to_file";
        if (!path_rule(path)) return .path_refused;
        if (!std.unicode.utf8ValidateSlice(bytes)) return .not_utf8;
        const dir = root.walk(path, .open) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            error.FileNotFound, error.NotDir => .missing_directory,
            else => root.failed(what, path, e, AppendAnswer.failed),
        };
        defer root.close_walked(dir);
        const name = std.fs.path.basename(path);
        var name_z_buf: [path_most + 1]u8 = undefined;
        @memcpy(name_z_buf[0..name.len], name);
        name_z_buf[name.len] = 0;
        const name_z: [:0]const u8 = name_z_buf[0..name.len :0];
        const base: linux.O = .{ .ACCMODE = .WRONLY, .APPEND = true, .NOFOLLOW = true, .CLOEXEC = true };
        var made = false;
        const fd = open_at(dir.handle, name_z, base) catch |e| switch (e) {
            error.FileNotFound => made_now: {
                made = true;
                var create = base;
                create.CREAT = true;
                create.EXCL = true;
                break :made_now open_at(dir.handle, name_z, create) catch |c| return root.failed(what, path, c, AppendAnswer.failed);
            },
            error.IsLink => return .path_refused,
            else => return root.failed(what, path, e, AppendAnswer.failed),
        };
        defer _ = linux.close(fd);
        write_all(fd, bytes) catch |e| return root.failed(what, path, e, AppendAnswer.failed);
        root.fsync_fd(fd) catch |e| return root.failed(what, path, e, AppendAnswer.failed);
        if (made) root.fsync_dir(dir) catch |e| return root.failed(what, path, e, AppendAnswer.failed);
        return .appended;
    }

    /// **A ONE-TIME RECORD**: the file made holding exactly `bytes`, unless
    /// something is already at its name (`already_exists`; nothing is
    /// changed). O_EXCL, so two creates never both succeed. Its folder must
    /// exist.
    pub fn create_file_with_utf8_bytes_unless_it_exists(root: *const DataRoot, path: []const u8, bytes: []const u8) CreateAnswer {
        const what = "create_file_with_utf8_bytes_unless_it_exists";
        if (!path_rule(path)) return .path_refused;
        if (!std.unicode.utf8ValidateSlice(bytes)) return .not_utf8;
        const dir = root.walk(path, .open) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            error.FileNotFound, error.NotDir => .missing_directory,
            else => root.failed(what, path, e, CreateAnswer.failed),
        };
        defer root.close_walked(dir);
        const name = std.fs.path.basename(path);
        refuse_link(root, dir, name) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            else => root.failed(what, path, e, CreateAnswer.failed),
        };
        const file = dir.createFile(root.io, name, .{ .exclusive = true }) catch |e| return switch (e) {
            error.PathAlreadyExists => .already_exists,
            else => root.failed(what, path, e, CreateAnswer.failed),
        };
        {
            defer file.close(root.io);
            file.writeStreamingAll(root.io, bytes) catch |e| return root.failed(what, path, e, CreateAnswer.failed);
            root.fsync_fd(file.handle) catch |e| return root.failed(what, path, e, CreateAnswer.failed);
        }
        root.fsync_dir(dir) catch |e| return root.failed(what, path, e, CreateAnswer.failed);
        return .created;
    }

    /// **THE WHOLE FILE AS `bytes`, ATOMICALLY**: a temporary beside it,
    /// fsynced, renamed over it, its folder fsynced. A stop before the
    /// rename leaves the old file whole. Its folder must exist.
    pub fn replace_file_with_utf8_bytes_atomically(root: *const DataRoot, path: []const u8, bytes: []const u8) ReplaceAnswer {
        const what = "replace_file_with_utf8_bytes_atomically";
        if (!path_rule(path)) return .path_refused;
        if (!std.unicode.utf8ValidateSlice(bytes)) return .not_utf8;
        const dir = root.walk(path, .open) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            error.FileNotFound, error.NotDir => .missing_directory,
            else => root.failed(what, path, e, ReplaceAnswer.failed),
        };
        defer root.close_walked(dir);
        const name = std.fs.path.basename(path);
        // A link at the name is refused. The rename never follows a link,
        // so one swapped in after this check is replaced, never written
        // through.
        refuse_link(root, dir, name) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            else => root.failed(what, path, e, ReplaceAnswer.failed),
        };
        var tmp_buf: [path_most + 16]u8 = undefined;
        const tmp = temporary_name(&tmp_buf, name);
        // A stopped replace's temporary goes first, so the exclusive create
        // never meets one; O_EXCL never follows a link.
        dir.deleteFile(root.io, tmp) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return root.failed(what, path, e, ReplaceAnswer.failed),
        };
        {
            const file = dir.createFile(root.io, tmp, .{ .exclusive = true }) catch |e| return root.failed(what, path, e, ReplaceAnswer.failed);
            defer file.close(root.io);
            file.writeStreamingAll(root.io, bytes) catch |e| return root.failed(what, path, e, ReplaceAnswer.failed);
            root.fsync_fd(file.handle) catch |e| return root.failed(what, path, e, ReplaceAnswer.failed);
        }
        if (root.fault_for_test == .stop_before_rename) return .failed;
        dir.rename(tmp, dir, name, root.io) catch |e| {
            dir.deleteFile(root.io, tmp) catch {};
            return root.failed(what, path, e, ReplaceAnswer.failed);
        };
        root.fsync_dir(dir) catch |e| return root.failed(what, path, e, ReplaceAnswer.failed);
        return .replaced;
    }

    /// **THE FOLDER, AND EACH FOLDER ABOVE IT, MADE AS NEEDED**: `made`
    /// when they all exist after, those already there included; each new
    /// folder's parent fsynced. A file in the way is `failed`.
    pub fn make_directory_and_its_parents(root: *const DataRoot, path: []const u8) MakeDirectoryAnswer {
        if (!path_rule(path)) return .path_refused;
        const dir = root.walk(path, .make) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            else => root.failed("make_directory_and_its_parents", path, e, MakeDirectoryAnswer.failed),
        };
        defer root.close_walked(dir);
        const last = std.fs.path.basename(path);
        var sub = root.make_and_open(dir, last) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            else => root.failed("make_directory_and_its_parents", path, e, MakeDirectoryAnswer.failed),
        };
        sub.close(root.io);
        return .made;
    }

    /// **THE NAMES IN A FOLDER**, sorted bytewise so every answer is the
    /// same, in `arena`; never a name starting with `.` (no path can name
    /// one). `not_utf8` when a name is not UTF-8.
    pub fn list_names_in_directory(root: *const DataRoot, arena: std.mem.Allocator, path: []const u8) ListAnswer {
        const what = "list_names_in_directory";
        if (!path_rule(path)) return .path_refused;
        const parent = root.walk(path, .open) catch |e| return switch (e) {
            error.IsLink => .path_refused,
            error.FileNotFound, error.NotDir => .missing,
            else => root.failed(what, path, e, @as(ListAnswer, .failed)),
        };
        defer root.close_walked(parent);
        const last = std.fs.path.basename(path);
        var dir = parent.openDir(root.io, last, .{ .iterate = true, .follow_symlinks = false }) catch |e| return switch (link_or(root, parent, last, e)) {
            error.IsLink => .path_refused,
            error.FileNotFound => .missing,
            else => |other| root.failed(what, path, other, @as(ListAnswer, .failed)),
        };
        defer dir.close(root.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (it.next(root.io) catch |e| return root.failed(what, path, e, @as(ListAnswer, .failed))) |entry| {
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (!std.unicode.utf8ValidateSlice(entry.name)) return .not_utf8;
            const copy = arena.dupe(u8, entry.name) catch |e| return root.failed(what, path, e, @as(ListAnswer, .failed));
            names.append(arena, copy) catch |e| return root.failed(what, path, e, @as(ListAnswer, .failed));
        }
        std.mem.sort([]const u8, names.items, {}, bytewise_before);
        return .{ .found = names.items };
    }

    /// A failure, said once on the server's log with the primitive, the
    /// path and the error, and answered as `answer`.
    fn failed(root: *const DataRoot, comptime what: []const u8, path: []const u8, e: anyerror, answer: anytype) @TypeOf(answer) {
        _ = root;
        log.warn(what ++ " {f}: {t}", .{ loggable(path), e });
        return answer;
    }

    const Walk = enum { open, make };

    /// **THE FOLDER `path` IS IN, OPENED A PART AT A TIME, EACH FROM THE
    /// ONE BEFORE, NONE THROUGH A LINK**: a link on the way is
    /// `error.IsLink`. `.make` makes each missing folder first. The root
    /// itself when `path` has one part (`close_walked` leaves it open).
    fn walk(root: *const DataRoot, path: []const u8, how: Walk) !Io.Dir {
        var dir = root.dir;
        errdefer root.close_walked(dir);
        var parts = std.mem.splitScalar(u8, path, '/');
        var part = parts.first();
        while (parts.next()) |after| : (part = after) {
            const next = switch (how) {
                .open => dir.openDir(root.io, part, .{ .follow_symlinks = false }) catch |e| return link_or(root, dir, part, e),
                .make => try root.make_and_open(dir, part),
            };
            root.close_walked(dir);
            dir = next;
        }
        return dir;
    }

    /// The folder `name` in `dir`, made first if it is missing (and `dir`
    /// fsynced, so the new entry is durable), opened with no link followed.
    fn make_and_open(root: *const DataRoot, dir: Io.Dir, name: []const u8) !Io.Dir {
        var made = true;
        dir.createDir(root.io, name, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => made = false,
            else => return e,
        };
        if (made) try root.fsync_dir(dir);
        return dir.openDir(root.io, name, .{ .follow_symlinks = false }) catch |e| return link_or(root, dir, name, e);
    }

    fn close_walked(root: *const DataRoot, dir: Io.Dir) void {
        if (dir.handle != root.dir.handle) dir.close(root.io);
    }

    fn fsync_fd(root: *const DataRoot, fd: linux.fd_t) !void {
        if (root.fault_for_test == .fsync_fails) return error.InputOutput;
        const rc = linux.fsync(fd);
        if (linux.errno(rc) != .SUCCESS) return error.InputOutput;
    }

    /// A folder fsynced, so its entries (a new file, a rename) are durable.
    /// **OPENED AGAIN TO BE FSYNCED**: a folder opened only to be walked
    /// (std's default, O_PATH) has a descriptor fsync refuses.
    fn fsync_dir(root: *const DataRoot, dir: Io.Dir) !void {
        var readable = try dir.openDir(root.io, ".", .{ .iterate = true });
        defer readable.close(root.io);
        try root.fsync_fd(readable.handle);
    }
};

fn bytewise_before(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// `openat(2)` on `dir`, for the flag std's options lack (O_APPEND).
fn open_at(dir: linux.fd_t, name: [*:0]const u8, flags: linux.O) !linux.fd_t {
    const rc = linux.openat(dir, name, flags, 0o644);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT => error.FileNotFound,
        // O_NOFOLLOW on a link.
        .LOOP => error.IsLink,
        .EXIST => error.PathAlreadyExists,
        .ISDIR => error.IsDir,
        .ACCES, .PERM => error.AccessDenied,
        else => |e| {
            log.warn("openat: {t}", .{e});
            return error.Unexpected;
        },
    };
}

fn write_all(fd: linux.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        switch (linux.errno(rc)) {
            .SUCCESS => done += rc,
            .INTR => {},
            else => return error.InputOutput,
        }
    }
}

/// **WHY AN O_NOFOLLOW OPEN FAILED**: a folder opened so answers `NotDir`
/// for a link and for a file alike, and a file `SymLinkLoop` for a link.
/// The entry is looked at (never followed) only to name the error; the open
/// already refused it, so there is nothing here to race.
fn link_or(root: *const DataRoot, dir: Io.Dir, name: []const u8, e: anyerror) anyerror {
    if (e != error.NotDir and e != error.SymLinkLoop) return e;
    const st = dir.statFile(root.io, name, .{ .follow_symlinks = false }) catch return e;
    return if (st.kind == .sym_link) error.IsLink else e;
}

/// `error.IsLink` when `name` in `dir` is a link; nothing there is fine.
fn refuse_link(root: *const DataRoot, dir: Io.Dir, name: []const u8) !void {
    const st = dir.statFile(root.io, name, .{ .follow_symlinks = false }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    if (st.kind == .sym_link) return error.IsLink;
}

/// **THE CLOCK**: whole seconds since 1970-01-01T00:00:00Z.
pub fn current_utc_seconds_since_epoch(io: Io) i64 {
    return Io.Clock.now(.real, io).toSeconds();
}

/// The most `fill_with_random_bytes` fills in one call.
pub const random_most = 1024;

/// **`buf` FILLED FROM THE OS'S SECURE RANDOM SOURCE**: an error when it
/// fails, never bytes that only look random.
pub fn fill_with_random_bytes(io: Io, buf: []u8) !void {
    try io.randomSecure(buf);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn test_root(tmp: *testing.TmpDir) DataRoot {
    return .{ .io = testing.io, .dir = tmp.dir };
}

/// Paths the rule refuses: empty, absolute, `.` and `..` anywhere, an empty
/// part, a hidden or temporary name, a NUL, and not UTF-8.
const refused_paths = [_][]const u8{
    "",
    "/etc/passwd",
    ".",
    "..",
    "../x",
    "a/../../x",
    "a/./x",
    "a//b",
    "a/",
    ".hidden",
    "a/.x.replacing",
    "a\x00b",
    "a/\xff",
};

test "path_rule: both sides" {
    for (refused_paths) |p| try testing.expect(!path_rule(p));
    for ([_][]const u8{ "x", "a/b/c", "chat/channel/general/plans/transcript", "a.b", "Zoë" }) |p| try testing.expect(path_rule(p));
    try testing.expect(path_rule(&@as([path_most]u8, @splat('a'))));
    try testing.expect(!path_rule(&@as([path_most + 1]u8, @splat('a'))));
}

test "read: found, missing, not UTF-8, refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = test_root(&tmp);
    try tmp.dir.createDirPath(testing.io, "d");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/t", .data = "Zoë\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/bad", .data = "a\xffb" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d/empty", .data = "" });
    try testing.expectEqualStrings("Zoë\n", root.read_utf8_bytes_from_file(a, "d/t").found);
    try testing.expectEqualStrings("", root.read_utf8_bytes_from_file(a, "d/empty").found);
    try testing.expectEqual(ReadAnswer.missing, root.read_utf8_bytes_from_file(a, "d/nope"));
    try testing.expectEqual(ReadAnswer.missing, root.read_utf8_bytes_from_file(a, "nope/t"));
    try testing.expectEqual(ReadAnswer.missing, root.read_utf8_bytes_from_file(a, "d/t/under_a_file"));
    try testing.expectEqual(ReadAnswer.not_utf8, root.read_utf8_bytes_from_file(a, "d/bad"));
    // A folder is no file: failed, never missing.
    try testing.expectEqual(ReadAnswer.failed, root.read_utf8_bytes_from_file(a, "d"));
    for (refused_paths) |p| try testing.expectEqual(ReadAnswer.path_refused, root.read_utf8_bytes_from_file(a, p));
}

test "loggable: printable ASCII kept, every other byte escaped" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/chat/channel/general/plans?x=1", try std.fmt.bufPrint(&buf, "{f}", .{loggable("/chat/channel/general/plans?x=1")}));
    try testing.expectEqualStrings("/a\\x0d\\x0awarning: forged\\x1b[2J\\x00Zo\\xc3\\xab", try std.fmt.bufPrint(&buf, "{f}", .{loggable("/a\r\nwarning: forged\x1b[2J\x00Zoë")}));
}

test "read: a file at the cap is read, one byte over it fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = test_root(&tmp);
    const big = try a.alloc(u8, read_most + 1);
    @memset(big, 'a');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "at", .data = big[0..read_most] });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "over", .data = big });
    try testing.expectEqual(read_most, root.read_utf8_bytes_from_file(a, "at").found.len);
    try testing.expectEqual(ReadAnswer.failed, root.read_utf8_bytes_from_file(a, "over"));
}

test "append: made when missing, then at the end; refused, not UTF-8, no folder" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = test_root(&tmp);
    try tmp.dir.createDirPath(testing.io, "log");
    try testing.expectEqual(AppendAnswer.appended, root.append_utf8_bytes_to_file("log/t", "first\n"));
    try testing.expectEqual(AppendAnswer.appended, root.append_utf8_bytes_to_file("log/t", "second é\n"));
    try testing.expectEqual(AppendAnswer.appended, root.append_utf8_bytes_to_file("log/t", ""));
    try testing.expectEqualStrings("first\nsecond é\n", root.read_utf8_bytes_from_file(a, "log/t").found);
    // Not UTF-8: nothing written.
    try testing.expectEqual(AppendAnswer.not_utf8, root.append_utf8_bytes_to_file("log/t", "x\xc3"));
    try testing.expectEqualStrings("first\nsecond é\n", root.read_utf8_bytes_from_file(a, "log/t").found);
    try testing.expectEqual(AppendAnswer.not_utf8, root.append_utf8_bytes_to_file("log/new", "\xff"));
    try testing.expectEqual(ReadAnswer.missing, root.read_utf8_bytes_from_file(a, "log/new"));
    // No folder: nothing made.
    try testing.expectEqual(AppendAnswer.missing_directory, root.append_utf8_bytes_to_file("nope/t", "x"));
    try testing.expectEqual(ListAnswer.missing, root.list_names_in_directory(a, "nope"));
    for (refused_paths) |p| try testing.expectEqual(AppendAnswer.path_refused, root.append_utf8_bytes_to_file(p, "x"));
}

test "create unless it exists: once, then already_exists, the first bytes kept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = test_root(&tmp);
    try tmp.dir.createDirPath(testing.io, "r");
    try testing.expectEqual(CreateAnswer.created, root.create_file_with_utf8_bytes_unless_it_exists("r/once", "first"));
    try testing.expectEqual(CreateAnswer.already_exists, root.create_file_with_utf8_bytes_unless_it_exists("r/once", "second"));
    try testing.expectEqualStrings("first", root.read_utf8_bytes_from_file(a, "r/once").found);
    // A folder at the name exists too.
    try testing.expectEqual(CreateAnswer.already_exists, root.create_file_with_utf8_bytes_unless_it_exists("r", "x"));
    try testing.expectEqual(CreateAnswer.not_utf8, root.create_file_with_utf8_bytes_unless_it_exists("r/bad", "\xff"));
    try testing.expectEqual(ReadAnswer.missing, root.read_utf8_bytes_from_file(a, "r/bad"));
    try testing.expectEqual(CreateAnswer.missing_directory, root.create_file_with_utf8_bytes_unless_it_exists("nope/x", "x"));
    for (refused_paths) |p| try testing.expectEqual(CreateAnswer.path_refused, root.create_file_with_utf8_bytes_unless_it_exists(p, "x"));
}

test "replace: whole, atomically; a stop before the rename leaves the old file whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root = test_root(&tmp);
    try tmp.dir.createDirPath(testing.io, "b");
    try testing.expectEqual(ReplaceAnswer.replaced, root.replace_file_with_utf8_bytes_atomically("b/note", "the old record\n"));
    try testing.expectEqualStrings("the old record\n", root.read_utf8_bytes_from_file(a, "b/note").found);

    root.fault_for_test = .stop_before_rename;
    try testing.expectEqual(ReplaceAnswer.failed, root.replace_file_with_utf8_bytes_atomically("b/note", "the new record, longer\n"));
    root.fault_for_test = .none;
    try testing.expectEqualStrings("the old record\n", root.read_utf8_bytes_from_file(a, "b/note").found);
    // The stopped replace's temporary is there, never listed, and the next
    // replace takes it.
    _ = try tmp.dir.statFile(testing.io, "b/.note.replacing", .{});
    try testing.expectEqual(1, root.list_names_in_directory(a, "b").found.len);
    try testing.expectEqual(ReplaceAnswer.replaced, root.replace_file_with_utf8_bytes_atomically("b/note", "the next\n"));
    try testing.expectEqualStrings("the next\n", root.read_utf8_bytes_from_file(a, "b/note").found);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "b/.note.replacing", .{}));

    // A failed fsync fails it before the rename: the old bytes stay.
    root.fault_for_test = .fsync_fails;
    try testing.expectEqual(ReplaceAnswer.failed, root.replace_file_with_utf8_bytes_atomically("b/note", "lost\n"));
    // An append's bytes are written before its fsync, so its failure says
    // only that they may not last.
    try testing.expectEqual(AppendAnswer.failed, root.append_utf8_bytes_to_file("b/log", "maybe\n"));
    root.fault_for_test = .none;
    try testing.expectEqualStrings("the next\n", root.read_utf8_bytes_from_file(a, "b/note").found);

    try testing.expectEqual(ReplaceAnswer.not_utf8, root.replace_file_with_utf8_bytes_atomically("b/note", "\xff"));
    try testing.expectEqualStrings("the next\n", root.read_utf8_bytes_from_file(a, "b/note").found);
    try testing.expectEqual(ReplaceAnswer.missing_directory, root.replace_file_with_utf8_bytes_atomically("nope/x", "x"));
    for (refused_paths) |p| try testing.expectEqual(ReplaceAnswer.path_refused, root.replace_file_with_utf8_bytes_atomically(p, "x"));
}

test "make a folder and its parents; list names, sorted, without dot names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = test_root(&tmp);
    try testing.expectEqual(MakeDirectoryAnswer.made, root.make_directory_and_its_parents("a/b/c"));
    // Already there: made all the same.
    try testing.expectEqual(MakeDirectoryAnswer.made, root.make_directory_and_its_parents("a/b/c"));
    try testing.expectEqual(MakeDirectoryAnswer.made, root.make_directory_and_its_parents("a"));
    try testing.expectEqual(AppendAnswer.appended, root.append_utf8_bytes_to_file("a/b/zed", "z"));
    try testing.expectEqual(AppendAnswer.appended, root.append_utf8_bytes_to_file("a/b/Zoë", "z"));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/b/.hidden", .data = "h" });
    const names = root.list_names_in_directory(a, "a/b").found;
    try testing.expectEqual(3, names.len);
    try testing.expectEqualStrings("Zoë", names[0]);
    try testing.expectEqualStrings("c", names[1]);
    try testing.expectEqualStrings("zed", names[2]);
    try testing.expectEqual(0, root.list_names_in_directory(a, "a/b/c").found.len);
    try testing.expectEqual(ListAnswer.missing, root.list_names_in_directory(a, "a/nope"));
    // A file is no folder: to list, or to make one under.
    try testing.expectEqual(ListAnswer.failed, root.list_names_in_directory(a, "a/b/zed"));
    try testing.expectEqual(MakeDirectoryAnswer.failed, root.make_directory_and_its_parents("a/b/zed/d"));
    try testing.expectEqual(MakeDirectoryAnswer.failed, root.make_directory_and_its_parents("a/b/zed"));
    // A name that is not UTF-8.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a/b/c/\xff", .data = "x" });
    try testing.expectEqual(ListAnswer.not_utf8, root.list_names_in_directory(a, "a/b/c"));
    for (refused_paths) |p| {
        try testing.expectEqual(ListAnswer.path_refused, root.list_names_in_directory(a, p));
        try testing.expectEqual(MakeDirectoryAnswer.path_refused, root.make_directory_and_its_parents(p));
    }
}

test "a link is refused by every primitive: as the file, as a folder on the way, inside or out" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = test_root(&tmp);

    const secret = "OUTSIDE-the-root";
    try outside.dir.writeFile(testing.io, .{ .sub_path = "x", .data = secret });
    const out_path = try outside.dir.realPathFileAlloc(testing.io, ".", a);
    const out_file = try std.fmt.allocPrint(a, "{s}/x", .{out_path});

    try tmp.dir.createDirPath(testing.io, "in");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "in/real", .data = "inside" });
    var in = try tmp.dir.openDir(testing.io, "in", .{});
    defer in.close(testing.io);
    try in.symLink(testing.io, out_file, "to_out", .{});
    try in.symLink(testing.io, "real", "to_real", .{});
    try tmp.dir.symLink(testing.io, "in", "via", .{});
    try tmp.dir.symLink(testing.io, out_path, "away", .{});
    try in.symLink(testing.io, try std.fmt.allocPrint(a, "{s}/made", .{out_path}), "dangling", .{});

    for ([_][]const u8{ "in/to_out", "in/to_real", "via/real", "away/x", "in/dangling", "away/new" }) |p| {
        try testing.expectEqual(ReadAnswer.path_refused, root.read_utf8_bytes_from_file(a, p));
        try testing.expectEqual(AppendAnswer.path_refused, root.append_utf8_bytes_to_file(p, "through"));
        try testing.expectEqual(CreateAnswer.path_refused, root.create_file_with_utf8_bytes_unless_it_exists(p, "through"));
        try testing.expectEqual(ReplaceAnswer.path_refused, root.replace_file_with_utf8_bytes_atomically(p, "through"));
    }
    for ([_][]const u8{ "via", "away", "away/sub" }) |p| {
        try testing.expectEqual(ListAnswer.path_refused, root.list_names_in_directory(a, p));
        try testing.expectEqual(MakeDirectoryAnswer.path_refused, root.make_directory_and_its_parents(p));
    }
    try testing.expectEqual(MakeDirectoryAnswer.path_refused, root.make_directory_and_its_parents("away/new/deeper"));

    // Nothing outside was read, written or made; the links stand.
    try testing.expectEqualStrings(secret, try outside.dir.readFileAlloc(testing.io, "x", a, .limited(100)));
    try testing.expectError(error.FileNotFound, outside.dir.statFile(testing.io, "made", .{}));
    try testing.expectError(error.FileNotFound, outside.dir.statFile(testing.io, "new", .{}));
    try testing.expectEqualStrings("inside", root.read_utf8_bytes_from_file(a, "in/real").found);
    for ([_][]const u8{ "in/to_out", "in/to_real", "via", "away", "in/dangling" }) |p| {
        try testing.expectEqual(Io.File.Kind.sym_link, (try tmp.dir.statFile(testing.io, p, .{ .follow_symlinks = false })).kind);
    }
}

test "missing and failed differ: a folder of mode 000 is a failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = test_root(&tmp);
    try tmp.dir.createDirPath(testing.io, "locked");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "locked/x", .data = "kept" });
    var locked = try tmp.dir.openDir(testing.io, "locked", .{ .iterate = true });
    defer locked.close(testing.io);
    try locked.setPermissions(testing.io, .fromMode(0o000));
    defer locked.setPermissions(testing.io, .fromMode(0o700)) catch {};
    // **ROOT IS REFUSED, NEVER SKIPPED**: root reads through a 000 folder,
    // so the test would prove nothing.
    if (linux.geteuid() == 0) return error.RunAsAUserNotRoot;
    try testing.expectEqual(ReadAnswer.failed, root.read_utf8_bytes_from_file(a, "locked/x"));
    try testing.expectEqual(ReadAnswer.failed, root.read_utf8_bytes_from_file(a, "locked/nope"));
    try testing.expectEqual(ListAnswer.failed, root.list_names_in_directory(a, "locked"));
    try testing.expectEqual(AppendAnswer.failed, root.append_utf8_bytes_to_file("locked/x", "lost"));
}

test "the clock and the random bytes" {
    const now = current_utc_seconds_since_epoch(testing.io);
    // After 2026-01-01 and before 2100-01-01.
    try testing.expect(now > 1_767_225_600 and now < 4_102_444_800);
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try fill_with_random_bytes(testing.io, &a);
    try fill_with_random_bytes(testing.io, &b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}
