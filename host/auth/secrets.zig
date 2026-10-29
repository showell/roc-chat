//! The host's secrets: the OAuth app's client id and secret, and the site's
//! signing key, each a file under the data root's `secrets/` folder. The Roc
//! never reads one; it asks the host to sign, verify and exchange.
//!
//! **A SECRET FILE IS ITS OWNER'S ALONE**: a file any group or other user can
//! read or write (mode & 0o077) is refused, and so is a link or anything not
//! a regular file. The client id is public (the authorize URL carries it),
//! but it lives beside the secret and is held to the same rule: one rule for
//! the folder.
//!
//! **A SECRET IS NEVER PRINTED**: `Secret` and `SigningKey` format as
//! `<secret>`, and a load's `Diagnostic` names the file and the reason,
//! never its bytes.
const std = @import("std");
const Io = std.Io;
const crypto = @import("crypto.zig");

/// The folder under the data root that holds the secret files.
pub const folder = "secrets";

/// The most bytes a text secret (the client id or secret) may have.
pub const max_text_bytes = 4096;

pub const signing_key_len = 32;

/// The secret files' names under `secrets/`, from the config.
pub const Paths = struct {
    client_id: []const u8,
    client_secret: []const u8,
    signing_key: []const u8,
};

pub const Secret = struct {
    bytes: []u8,

    pub fn format(_: Secret, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("<secret>");
    }

    pub fn deinit(s: *Secret, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, s.bytes);
        gpa.free(s.bytes);
        s.bytes = &.{};
    }
};

pub const SigningKey = struct {
    bytes: [signing_key_len]u8,

    pub fn format(_: SigningKey, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll("<secret>");
    }

    pub fn wipe(k: *SigningKey) void {
        std.crypto.secureZero(u8, &k.bytes);
    }
};

pub const Secrets = struct {
    client_id: Secret,
    client_secret: Secret,
    signing_key: SigningKey,

    pub fn deinit(s: *Secrets, gpa: std.mem.Allocator) void {
        s.client_id.deinit(gpa);
        s.client_secret.deinit(gpa);
        s.signing_key.wipe();
    }
};

pub const LoadError = error{
    /// The path is empty, absolute, or has a `..` part.
    BadPath,
    Missing,
    /// A link, a folder, anything but a regular file.
    NotAFile,
    /// Group or other users may read or write it (mode & 0o077).
    TooOpen,
    TooLarge,
    Empty,
    /// The signing key is not exactly `signing_key_len` bytes.
    WrongLength,
    Unreadable,
    OutOfMemory,
} || Io.Cancelable;

/// What went wrong in a load, for the operator: which file, and why. Never
/// the file's bytes.
pub const Diagnostic = struct {
    path: []const u8 = "",
    reason: ?LoadError = null,

    pub fn format(d: Diagnostic, w: *Io.Writer) Io.Writer.Error!void {
        if (d.reason) |r| {
            try w.print("{s}/{s}: {t}", .{ folder, d.path, r });
        } else try w.writeAll("no failure");
    }
};

/// Loads all three secrets from `data_root`'s `secrets/` folder. The signing
/// key is made on first start (`loadOrCreateSigningKey`).
pub fn load(io: Io, gpa: std.mem.Allocator, data_root: Io.Dir, paths: Paths, diag: *Diagnostic) LoadError!Secrets {
    var dir = data_root.openDir(io, folder, .{}) catch |e| return fail(diag, "", switch (e) {
        error.FileNotFound => error.Missing,
        error.NotDir => error.NotAFile,
        error.Canceled => error.Canceled,
        else => error.Unreadable,
    });
    defer dir.close(io);
    var id = try loadText(io, gpa, dir, paths.client_id, diag);
    errdefer id.deinit(gpa);
    var secret = try loadText(io, gpa, dir, paths.client_secret, diag);
    errdefer secret.deinit(gpa);
    const key = try loadOrCreateSigningKey(io, dir, paths.signing_key, diag);
    return .{ .client_id = id, .client_secret = secret, .signing_key = key };
}

/// A text secret: the file's bytes, a trailing newline (or CR LF) dropped.
pub fn loadText(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, path: []const u8, diag: *Diagnostic) LoadError!Secret {
    var buf: [max_text_bytes + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    const got = try readChecked(io, dir, path, &buf, diag);
    var n = got.len;
    if (n > 0 and got[n - 1] == '\n') n -= 1;
    if (n > 0 and got[n - 1] == '\r') n -= 1;
    if (n == 0) return fail(diag, path, error.Empty);
    if (n > max_text_bytes) return fail(diag, path, error.TooLarge);
    return .{ .bytes = try gpa.dupe(u8, got[0..n]) };
}

/// The site's signing key: `signing_key_len` raw bytes. **MADE ONCE**: on
/// first start the file is created exclusively, mode 0600, from the OS's
/// entropy; every later start reads that same key. Two starts racing to make
/// it both end with the one the winner wrote.
pub fn loadOrCreateSigningKey(io: Io, dir: Io.Dir, path: []const u8, diag: *Diagnostic) LoadError!SigningKey {
    if (!pathOk(path)) return fail(diag, path, error.BadPath);
    create: {
        var fresh: SigningKey = undefined;
        defer fresh.wipe();
        const file = dir.createFile(io, path, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch |e| switch (e) {
            error.PathAlreadyExists => break :create,
            error.Canceled => return error.Canceled,
            else => return fail(diag, path, error.Unreadable),
        };
        defer file.close(io);
        crypto.randomBytes(io, &fresh.bytes) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            // The file stays empty, so every later start fails as
            // `WrongLength` until someone looks: never a weak key.
            error.EntropyUnavailable => return fail(diag, path, error.Unreadable),
        };
        file.writeStreamingAll(io, &fresh.bytes) catch return fail(diag, path, error.Unreadable);
        file.sync(io) catch return fail(diag, path, error.Unreadable);
    }
    var buf: [signing_key_len + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    const got = try readChecked(io, dir, path, &buf, diag);
    if (got.len != signing_key_len) return fail(diag, path, error.WrongLength);
    return .{ .bytes = got[0..signing_key_len].* };
}

/// **THE HOST'S ONE PATH RULE**: a relative path with no empty, `.` or `..`
/// part stays under the folder it is joined to (`secrets/` here, the data
/// root for host/files.zig).
pub fn pathOk(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    }
    return true;
}

/// The file's bytes into `buf` (a file that fills `buf` is too large),
/// after the checks: a relative path under the folder, not a link, a
/// regular file, its owner's alone.
fn readChecked(io: Io, dir: Io.Dir, path: []const u8, buf: []u8, diag: *Diagnostic) LoadError![]u8 {
    if (!pathOk(path)) return fail(diag, path, error.BadPath);
    const file = dir.openFile(io, path, .{ .follow_symlinks = false }) catch |e| return fail(diag, path, switch (e) {
        error.FileNotFound => error.Missing,
        error.SymLinkLoop, error.IsDir => error.NotAFile,
        error.Canceled => error.Canceled,
        else => error.Unreadable,
    });
    defer file.close(io);
    const st = file.stat(io) catch |e| return fail(diag, path, switch (e) {
        error.Canceled => error.Canceled,
        else => error.Unreadable,
    });
    if (st.kind != .file) return fail(diag, path, error.NotAFile);
    if (st.permissions.toMode() & 0o077 != 0) return fail(diag, path, error.TooOpen);
    if (st.size >= buf.len) return fail(diag, path, error.TooLarge);
    const n = file.readPositionalAll(io, buf, 0) catch |e| return fail(diag, path, switch (e) {
        error.Canceled => error.Canceled,
        else => error.Unreadable,
    });
    if (n >= buf.len) return fail(diag, path, error.TooLarge);
    return buf[0..n];
}

fn fail(diag: *Diagnostic, path: []const u8, e: LoadError) LoadError {
    diag.* = .{ .path = path, .reason = e };
    return e;
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    _ = crypto;
}

const marker = "TOPSECRET-c0ffee";

fn put(dir: Io.Dir, path: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    const f = try dir.createFile(testing.io, path, .{ .permissions = .fromMode(mode) });
    defer f.close(testing.io);
    try f.writeStreamingAll(testing.io, bytes);
    // The mode exactly, whatever the umask made of it.
    try f.setPermissions(testing.io, .fromMode(mode));
}

const test_paths: Paths = .{ .client_id = "github_client_id", .client_secret = "github_client_secret", .signing_key = "signing_key" };

fn rootWithSecrets() !testing.TmpDir {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.createDir(testing.io, folder, .fromMode(0o700));
    var dir = try tmp.dir.openDir(testing.io, folder, .{});
    defer dir.close(testing.io);
    try put(dir, test_paths.client_id, "Iv1.fakeclientid\n", 0o600);
    try put(dir, test_paths.client_secret, marker ++ "\r\n", 0o600);
    return tmp;
}

test "load: the three secrets; the key made once, 0600, and the same at the next start" {
    var tmp = try rootWithSecrets();
    defer tmp.cleanup();
    var diag: Diagnostic = .{};
    var first = try load(testing.io, testing.allocator, tmp.dir, test_paths, &diag);
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("Iv1.fakeclientid", first.client_id.bytes);
    try testing.expectEqualStrings(marker, first.client_secret.bytes);

    const st = try tmp.dir.statFile(testing.io, folder ++ "/" ++ test_paths.signing_key, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    try testing.expectEqual(@as(u64, signing_key_len), st.size);

    var second = try load(testing.io, testing.allocator, tmp.dir, test_paths, &diag);
    defer second.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &first.signing_key.bytes, &second.signing_key.bytes);
    try testing.expect(!std.mem.allEqual(u8, &first.signing_key.bytes, 0));
}

test "a group- or world-readable secret is refused, and so is a link" {
    var tmp = try rootWithSecrets();
    defer tmp.cleanup();
    var dir = try tmp.dir.openDir(testing.io, folder, .{});
    defer dir.close(testing.io);
    for ([_]std.posix.mode_t{ 0o640, 0o604, 0o660, 0o602, 0o644 }) |mode| {
        const f = try dir.openFile(testing.io, test_paths.client_secret, .{});
        try f.setPermissions(testing.io, .fromMode(mode));
        f.close(testing.io);
        var diag: Diagnostic = .{};
        try testing.expectError(error.TooOpen, loadText(testing.io, testing.allocator, dir, test_paths.client_secret, &diag));
        try testing.expectEqualStrings(test_paths.client_secret, diag.path);
    }
    // A loose key file is refused, not rewritten.
    const loose: [signing_key_len]u8 = @splat(7);
    try put(dir, "loose_key", &loose, 0o644);
    var diag: Diagnostic = .{};
    try testing.expectError(error.TooOpen, loadOrCreateSigningKey(testing.io, dir, "loose_key", &diag));

    try dir.symLink(testing.io, test_paths.client_id, "linked", .{});
    try testing.expectError(error.NotAFile, loadText(testing.io, testing.allocator, dir, "linked", &diag));
}

test "bad paths, a missing file, an empty one, a key of the wrong length" {
    var tmp = try rootWithSecrets();
    defer tmp.cleanup();
    var dir = try tmp.dir.openDir(testing.io, folder, .{});
    defer dir.close(testing.io);
    var diag: Diagnostic = .{};
    for ([_][]const u8{ "", "/etc/passwd", "../x", "a/../b", "a//b", "./a" }) |p| {
        try testing.expectError(error.BadPath, loadText(testing.io, testing.allocator, dir, p, &diag));
        try testing.expectError(error.BadPath, loadOrCreateSigningKey(testing.io, dir, p, &diag));
    }
    try testing.expectError(error.Missing, loadText(testing.io, testing.allocator, dir, "nope", &diag));
    try put(dir, "empty", "\n", 0o600);
    try testing.expectError(error.Empty, loadText(testing.io, testing.allocator, dir, "empty", &diag));
    try put(dir, "short_key", "abc", 0o600);
    try testing.expectError(error.WrongLength, loadOrCreateSigningKey(testing.io, dir, "short_key", &diag));
    const big: [max_text_bytes + 10]u8 = @splat('x');
    try put(dir, "big", &big, 0o600);
    try testing.expectError(error.TooLarge, loadText(testing.io, testing.allocator, dir, "big", &diag));
}

test "a secret is never printed: not by its format, not by a failed load's diagnostic" {
    var tmp = try rootWithSecrets();
    defer tmp.cleanup();
    var diag: Diagnostic = .{};
    var s = try load(testing.io, testing.allocator, tmp.dir, test_paths, &diag);
    defer s.deinit(testing.allocator);

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try out.writer.print("{f} {f} {f}", .{ s.client_id, s.client_secret, s.signing_key });
    try testing.expectEqualStrings("<secret> <secret> <secret>", out.written());

    // A load that fails on a file holding the marker names it, not its bytes.
    var dir = try tmp.dir.openDir(testing.io, folder, .{});
    defer dir.close(testing.io);
    try put(dir, "loose", marker, 0o644);
    try testing.expectError(error.TooOpen, loadText(testing.io, testing.allocator, dir, "loose", &diag));
    out.clearRetainingCapacity();
    try out.writer.print("{f}", .{diag});
    try testing.expectEqualStrings("secrets/loose: TooOpen", out.written());
    try testing.expect(std.mem.indexOf(u8, out.written(), marker) == null);
}
