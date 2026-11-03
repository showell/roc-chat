//! The host's sign-in primitives: a password hashed and checked with
//! bcrypt, and bytes signed and checked with the server's secret by
//! HMAC-SHA256. They know nothing of chats: the app decides what is a
//! password, which file keeps its hash, and what a signed session says.
//!
//! The server's secret is a file in the data root, `.session-secret`, made
//! once, at the server's first start, from 32 random bytes written as 64
//! hex digits, readable by its owner alone; the server refuses to start on
//! one that its group or anyone else may read or write. Its name starts
//! with `.`, so the path rule (host/file_primitives.zig) keeps it from every
//! file primitive: the app can sign and check bytes with it, and can never
//! read it. Removing the file and starting the server again makes a new
//! one, and every session signed with the old one stops admitting anyone.

const std = @import("std");
const Io = std.Io;
const bcrypt = std.crypto.pwhash.bcrypt;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// bcrypt's cost: 2^10 rounds, the common default, as the passwords this
/// chat reads were written.
pub const bcrypt_cost: u6 = 10;

/// A bcrypt hash in its modular-crypt form, `$2b$10$` and 53 more bytes.
pub const bcrypt_hash_length = 60;

/// The length of an HMAC-SHA256.
pub const mac_length = HmacSha256.mac_length;

/// The secret file's name in the data root.
pub const secret_name = ".session-secret";

/// The fewest bytes a secret may be, and the most read.
pub const secret_fewest = 32;
pub const secret_most = 256;

/// The server's signing secret, read once at the start.
pub const ServerSecret = struct {
    bytes: [secret_most]u8,
    len: usize,

    pub fn slice(s: *const ServerSecret) []const u8 {
        return s.bytes[0..s.len];
    }

    /// The secret in `dir`, the data root: made first when there is none.
    /// A secret file its group or anyone else may read or write is refused
    /// (`error.SecretOpenToOthers`), as one shorter than 32 bytes or longer
    /// than 256 is (`error.SecretUnusable`), rather than used.
    pub fn load_or_create(io: Io, dir: Io.Dir) !ServerSecret {
        create(io, dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        var s: ServerSecret = .{ .bytes = undefined, .len = 0 };
        var buf: [secret_most + 1]u8 = undefined;
        // The mode is read from the file that is read, so a file swapped
        // between the two is never the one judged.
        const file = try dir.openFile(io, secret_name, .{ .allow_directory = false });
        defer file.close(io);
        const st = try file.stat(io);
        if (st.permissions.toMode() & 0o077 != 0) return error.SecretOpenToOthers;
        var reader = file.reader(io, &.{});
        const n = reader.interface.readSliceShort(&buf) catch |e| switch (e) {
            error.ReadFailed => return reader.err.?,
        };
        const read = buf[0..n];
        if (read.len < secret_fewest or read.len > secret_most) return error.SecretUnusable;
        @memcpy(s.bytes[0..read.len], read);
        s.len = read.len;
        return s;
    }

    /// A new secret file, never over one that is there: 32 random bytes as
    /// 64 hex digits, readable by its owner alone, fsynced.
    fn create(io: Io, dir: Io.Dir) !void {
        var random: [32]u8 = undefined;
        try io.randomSecure(&random);
        const hex = std.fmt.bytesToHex(random, .lower);
        const file = try dir.createFile(io, secret_name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, &hex);
        try file.sync(io);
    }
};

/// A fresh bcrypt hash of `password`, under a salt from the OS's secure
/// source, into `out`. No randomness stops the server: nothing safe can be
/// handed back.
pub fn bcrypt_hash_of_password(io: Io, password: []const u8, out: *[bcrypt_hash_length]u8) []const u8 {
    var salt: [bcrypt.salt_length]u8 = undefined;
    io.randomSecure(&salt) catch |e| std.debug.panic("bcrypt_hash_of_password: no random salt ({t})", .{e});
    return hash_with_salt(password, out, salt);
}

fn hash_with_salt(password: []const u8, out: *[bcrypt_hash_length]u8, salt: [bcrypt.salt_length]u8) []const u8 {
    return bcrypt.strHashWithSalt(password, .{
        .params = .{ .rounds_log = bcrypt_cost, .silently_truncate_password = false },
        .encoding = .crypt,
    }, out, salt) catch |e| std.debug.panic("bcrypt_hash_of_password: {t}", .{e});
}

/// The lowest and the highest cost a stored hash may name. Below 10 a hash
/// is cheap to guess against; above 14 one check takes over a second, a
/// cost a planted file could make every sign-in pay.
pub const bcrypt_cost_lowest = 10;
pub const bcrypt_cost_highest = 14;

/// Whether `hash` is a bcrypt hash this server checks against: 60 bytes,
/// `$2a$`, `$2b$` or `$2y$`, then a cost of two digits from
/// `bcrypt_cost_lowest` to `bcrypt_cost_highest`, then a `$`. std checks the
/// salt and the digest after it.
pub fn is_acceptable_bcrypt_hash(hash: []const u8) bool {
    if (hash.len != bcrypt_hash_length) return false;
    const scheme = hash[0..4];
    if (!std.mem.eql(u8, scheme, "$2a$") and !std.mem.eql(u8, scheme, "$2b$") and !std.mem.eql(u8, scheme, "$2y$")) return false;
    if (!std.ascii.isDigit(hash[4]) or !std.ascii.isDigit(hash[5]) or hash[6] != '$') return false;
    const cost = (hash[4] - '0') * 10 + (hash[5] - '0');
    return cost >= bcrypt_cost_lowest and cost <= bcrypt_cost_highest;
}

/// Whether `password` is the one `hash` was made from; `not_a_bcrypt_hash`
/// when `hash` is no bcrypt hash this server accepts
/// (`is_acceptable_bcrypt_hash`), so a torn file is never read as a wrong
/// password. A hash written as `$2a$` or `$2y$` is read as `$2b$`: the
/// three name one computation, and std checks the whole string.
/// `too_many_checks` is the seam's alone (host/seam.zig): the bucket
/// refused the check, and nothing was compared.
pub const PasswordVerdict = enum(u8) { does_not_match, matches, not_a_bcrypt_hash, too_many_checks };

pub fn password_matches_bcrypt_hash(password: []const u8, hash: []const u8) PasswordVerdict {
    if (!is_acceptable_bcrypt_hash(hash)) return .not_a_bcrypt_hash;
    var buf: [bcrypt_hash_length]u8 = undefined;
    @memcpy(&buf, hash);
    buf[2] = 'b';
    bcrypt.strVerify(&buf, password, .{ .silently_truncate_password = false }) catch |e| return switch (e) {
        error.PasswordVerificationFailed => .does_not_match,
        else => .not_a_bcrypt_hash,
    };
    return .matches;
}

/// The password checks the server lets run, one bucket for every client:
/// it holds `burst` checks, and gains one back each `refill_ms`. A check it
/// refuses is answered without running bcrypt. Behind a proxy every client
/// is 127.0.0.1, so the bucket is the server's, not a client's. It is taken
/// from only in the turn (host/http.zig), so it needs no lock of its own.
pub const PasswordChecks = struct {
    burst: u32,
    refill_ms: u32,
    /// What the bucket holds, in milliseconds of refill: a check spends
    /// `refill_ms` of it.
    held_ms: i64,
    /// When `held_ms` was last brought up to date, on the awake clock.
    at_ms: i64,
    /// How many checks the bucket has let run, which the tests read from
    /// outside the turn.
    spent: std.atomic.Value(u64) = .init(0),

    /// A full bucket at `now_ms`.
    pub fn init(limits: struct { burst: u32, refill_ms: u32 }, now_ms: i64) PasswordChecks {
        std.debug.assert(limits.burst > 0 and limits.refill_ms > 0);
        return .{
            .burst = limits.burst,
            .refill_ms = limits.refill_ms,
            .held_ms = @as(i64, limits.burst) * limits.refill_ms,
            .at_ms = now_ms,
        };
    }

    /// Whether a check may run at `now_ms`, spending it from the bucket
    /// when it may. A clock read earlier than the last one gains nothing.
    pub fn take(c: *PasswordChecks, now_ms: i64) bool {
        const full = @as(i64, c.burst) * c.refill_ms;
        if (now_ms > c.at_ms) {
            c.held_ms = @min(full, c.held_ms + (now_ms - c.at_ms));
            c.at_ms = now_ms;
        }
        if (c.held_ms < c.refill_ms) return false;
        c.held_ms -= c.refill_ms;
        return true;
    }
};

/// The HMAC-SHA256 of `bytes` under `secret`.
pub fn hmac_sha256(secret: []const u8, bytes: []const u8) [mac_length]u8 {
    var mac: [mac_length]u8 = undefined;
    HmacSha256.create(&mac, bytes, secret);
    return mac;
}

/// Whether `mac` is the HMAC-SHA256 of `bytes` under `secret`, compared in
/// constant time; a `mac` of any other length does not match.
pub const MacVerdict = enum(u8) { does_not_match, matches };

pub fn hmac_sha256_matches(secret: []const u8, bytes: []const u8, mac: []const u8) MacVerdict {
    if (mac.len != mac_length) return .does_not_match;
    const computed = hmac_sha256(secret, bytes);
    return if (std.crypto.timing_safe.eql([mac_length]u8, computed, mac[0..mac_length].*)) .matches else .does_not_match;
}

// ── tests

const testing = std.testing;

/// A hash written by golang.org/x/crypto/bcrypt at cost 10, `$2a$`, of
/// "correct horse battery staple": a known answer from outside this code.
const known_hash = "$2a$10$TC9LJ0KU0TIrFl9Hk8FCAeU1bThg2GoSYXAqsjQLdIBSHIxGVfDza";
const known_password = "correct horse battery staple";

test "a known bcrypt hash: its password matches, a near one does not, and a `$2b$` copy matches too" {
    try testing.expectEqual(PasswordVerdict.matches, password_matches_bcrypt_hash(known_password, known_hash));
    try testing.expectEqual(PasswordVerdict.does_not_match, password_matches_bcrypt_hash(known_password ++ "X", known_hash));
    try testing.expectEqual(PasswordVerdict.does_not_match, password_matches_bcrypt_hash("", known_hash));
    try testing.expectEqual(PasswordVerdict.matches, password_matches_bcrypt_hash(known_password, "$2b$" ++ known_hash[4..]));
}

test "a hash is made at cost 10, and the password it was made from matches it; the same salt makes the known hash" {
    var out: [bcrypt_hash_length]u8 = undefined;
    const made = bcrypt_hash_of_password(testing.io, "hunter2", &out);
    try testing.expect(std.mem.startsWith(u8, made, "$2b$10$"));
    try testing.expectEqual(PasswordVerdict.matches, password_matches_bcrypt_hash("hunter2", made));
    try testing.expectEqual(PasswordVerdict.does_not_match, password_matches_bcrypt_hash("hunter3", made));
    const codec = std.base64.Base64Decoder.init("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".*, null);
    var salt: [bcrypt.salt_length]u8 = undefined;
    try codec.decode(&salt, known_hash[7..29]);
    var again: [bcrypt_hash_length]u8 = undefined;
    try testing.expectEqualStrings("$2b$" ++ known_hash[4..], hash_with_salt(known_password, &again, salt));
}

test "no hash: empty, short, long, another scheme, or torn, is never a wrong password" {
    for ([_][]const u8{ "", "$2b$10$", known_hash ++ "x", &@as([bcrypt_hash_length]u8, @splat('x')), "$2b$10$" ++ @as([53]u8, @splat('!')) }) |hash| {
        try testing.expectEqual(PasswordVerdict.not_a_bcrypt_hash, password_matches_bcrypt_hash(known_password, hash));
    }
}

test "a stored hash: `$2a$`, `$2b$` or `$2y$` at a cost of 10 to 14 is checked; any other scheme or cost is no hash" {
    const rest = known_hash[7..];
    inline for (.{ "$2a$10$", "$2b$10$", "$2y$10$", "$2b$11$", "$2b$14$" }) |head| {
        try testing.expect(is_acceptable_bcrypt_hash(head ++ rest));
    }
    inline for (.{ "$2b$09$", "$2b$04$", "$2b$15$", "$2b$99$", "$2b$1a$", "$2b$10x", "$2x$10$", "$2$$10$", "$3b$10$", "x2b$10$" }) |head| {
        try testing.expect(!is_acceptable_bcrypt_hash(head ++ rest));
    }
    // A real hash at cost 4, which std would check, is no hash here; the
    // same password and salt at cost 10 matches.
    const codec = std.base64.Base64Decoder.init("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".*, null);
    var salt: [bcrypt.salt_length]u8 = undefined;
    try codec.decode(&salt, known_hash[7..29]);
    var cheap_buf: [bcrypt_hash_length]u8 = undefined;
    const cheap = try bcrypt.strHashWithSalt(known_password, .{
        .params = .{ .rounds_log = 4, .silently_truncate_password = false },
        .encoding = .crypt,
    }, &cheap_buf, salt);
    try testing.expectEqual(PasswordVerdict.not_a_bcrypt_hash, password_matches_bcrypt_hash(known_password, cheap));
    try testing.expectEqual(PasswordVerdict.matches, password_matches_bcrypt_hash(known_password, known_hash));
}

test "the checks' bucket: a burst of 5 runs, the sixth is refused; one comes back a second later, and no more than the burst ever" {
    var c: PasswordChecks = .init(.{ .burst = 5, .refill_ms = 1000 }, 50_000);
    for (0..5) |_| try testing.expect(c.take(50_000));
    try testing.expect(!c.take(50_000));
    try testing.expect(!c.take(50_999));
    try testing.expect(c.take(51_000));
    try testing.expect(!c.take(51_000));
    // A clock read from before the last gains nothing.
    try testing.expect(!c.take(40_000));
    // Long idle, the bucket is full again, and holds the burst alone.
    for (0..5) |_| try testing.expect(c.take(1_000_000));
    try testing.expect(!c.take(1_000_000));
}

test "an HMAC matches its bytes and its secret alone, at its own length alone" {
    const secret = "0123456789abcdef0123456789abcdef";
    const mac = hmac_sha256(secret, "1\n1700000000");
    try testing.expectEqual(MacVerdict.matches, hmac_sha256_matches(secret, "1\n1700000000", &mac));
    try testing.expectEqual(MacVerdict.does_not_match, hmac_sha256_matches(secret, "1\n1700000001", &mac));
    try testing.expectEqual(MacVerdict.does_not_match, hmac_sha256_matches("another secret, 32 bytes or more", "1\n1700000000", &mac));
    var flipped = mac;
    flipped[31] ^= 1;
    try testing.expectEqual(MacVerdict.does_not_match, hmac_sha256_matches(secret, "1\n1700000000", &flipped));
    try testing.expectEqual(MacVerdict.does_not_match, hmac_sha256_matches(secret, "1\n1700000000", mac[0..31]));
    try testing.expectEqual(MacVerdict.does_not_match, hmac_sha256_matches(secret, "1\n1700000000", &(mac ++ [_]u8{0})));
    // RFC 4231's second case: a known answer from outside this code.
    const rfc = hmac_sha256("Jefe", "what do ya want for nothing?");
    try testing.expectEqualStrings("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", &std.fmt.bytesToHex(rfc, .lower));
}

test "the secret: made once, 64 hex digits, its owner's alone; read the same after; too short or too long refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try ServerSecret.load_or_create(testing.io, tmp.dir);
    try testing.expectEqual(64, first.len);
    for (first.slice()) |c| try testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    const again = try ServerSecret.load_or_create(testing.io, tmp.dir);
    try testing.expectEqualStrings(first.slice(), again.slice());
    const st = try tmp.dir.statFile(testing.io, secret_name, .{});
    try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = secret_name, .data = &@as([secret_fewest - 1]u8, @splat('x')) });
    try testing.expectError(error.SecretUnusable, ServerSecret.load_or_create(testing.io, tmp.dir));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = secret_name, .data = &@as([secret_fewest]u8, @splat('x')) });
    try testing.expectEqualStrings(&@as([secret_fewest]u8, @splat('x')), (try ServerSecret.load_or_create(testing.io, tmp.dir)).slice());
    try tmp.dir.writeFile(testing.io, .{ .sub_path = secret_name, .data = &@as([secret_most + 1]u8, @splat('x')) });
    try testing.expectError(error.SecretUnusable, ServerSecret.load_or_create(testing.io, tmp.dir));
}

test "the secret: refused when its group or anyone else may read, write or run it; its owner's alone, read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try ServerSecret.load_or_create(testing.io, tmp.dir);
    for ([_]u32{ 0o640, 0o620, 0o610, 0o604, 0o602, 0o601, 0o644, 0o666 }) |mode| {
        try tmp.dir.setFilePermissions(testing.io, secret_name, .fromMode(mode), .{});
        try testing.expectError(error.SecretOpenToOthers, ServerSecret.load_or_create(testing.io, tmp.dir));
    }
    for ([_]u32{ 0o600, 0o400, 0o700 }) |mode| {
        try tmp.dir.setFilePermissions(testing.io, secret_name, .fromMode(mode), .{});
        try testing.expectEqualStrings(first.slice(), (try ServerSecret.load_or_create(testing.io, tmp.dir)).slice());
    }
}
