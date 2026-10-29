//! The auth core's crypto, kept in the host: random bytes from the OS,
//! SHA-256, and HMAC-SHA256 sign and verify. The Roc asks for these as facts
//! (`random_bytes!`, `hash!`, `sign!`, `verify!`) and never holds the key.
const std = @import("std");
const Io = std.Io;

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const digest_len = Sha256.digest_length;
pub const mac_len = HmacSha256.mac_length;

/// Fills `buffer` with fresh entropy from the OS (`getrandom`), never from
/// an in-process generator: a nonce, a session secret, a key secret.
pub fn randomBytes(io: Io, buffer: []u8) Io.RandomSecureError!void {
    return io.randomSecure(buffer);
}

pub fn sha256(message: []const u8) [digest_len]u8 {
    var out: [digest_len]u8 = undefined;
    Sha256.hash(message, &out, .{});
    return out;
}

pub fn sign(key: []const u8, message: []const u8) [mac_len]u8 {
    var out: [mac_len]u8 = undefined;
    HmacSha256.create(&out, message, key);
    return out;
}

/// Whether `mac` is `message`'s MAC under `key`. **THE COMPARE IS CONSTANT
/// TIME**: an early-out compare tells an attacker, byte by byte, how much of
/// a forged MAC was right. A wrong length is refused at once: the length is
/// public. `verify`'s body is held to this by the "verify compares in
/// constant time" test below.
pub fn verify(key: []const u8, message: []const u8, mac: []const u8) bool {
    if (mac.len != mac_len) return false;
    const expected = sign(key, message);
    return std.crypto.timing_safe.eql([mac_len]u8, expected, mac[0..mac_len].*);
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "SHA-256: the NIST vectors" {
    try testing.expectEqual(hex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), sha256(""));
    try testing.expectEqual(hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), sha256("abc"));
    try testing.expectEqual(
        hex("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    );
    try testing.expectEqual(
        hex("cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
        sha256("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
    );
    const million = try testing.allocator.alloc(u8, 1_000_000);
    defer testing.allocator.free(million);
    @memset(million, 'a');
    try testing.expectEqual(hex("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"), sha256(million));
}

const Rfc4231 = struct { key: []const u8, data: []const u8, mac: [mac_len]u8 };

const aa131: [131]u8 = @splat(0xaa);
const k0b: [20]u8 = @splat(0x0b);
const kaa: [20]u8 = @splat(0xaa);
const ddd: [50]u8 = @splat(0xdd);
const dcd: [50]u8 = @splat(0xcd);
const k0c: [20]u8 = @splat(0x0c);
const rfc4231 = [_]Rfc4231{
    .{ .key = &k0b, .data = "Hi There", .mac = hex("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7") },
    .{ .key = "Jefe", .data = "what do ya want for nothing?", .mac = hex("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843") },
    .{ .key = &kaa, .data = &ddd, .mac = hex("773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe") },
    .{ .key = &hex("0102030405060708090a0b0c0d0e0f10111213141516171819"), .data = &dcd, .mac = hex("82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b") },
    .{ .key = &aa131, .data = "Test Using Larger Than Block-Size Key - Hash Key First", .mac = hex("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54") },
    .{ .key = &aa131, .data = "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.", .mac = hex("9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2") },
};

test "HMAC-SHA256: the RFC 4231 vectors, signed and verified" {
    for (rfc4231) |v| {
        try testing.expectEqual(v.mac, sign(v.key, v.data));
        try testing.expect(verify(v.key, v.data, &v.mac));
    }
    // Case 5 is truncated to 128 bits: its first half.
    const case5 = sign(&k0c, "Test With Truncation");
    try testing.expectEqualSlices(u8, &hex("a3b6167473100ee06e0c796c2955552b"), case5[0..16]);
}

test "verify refuses every one-bit flip, a wrong length and a wrong key" {
    const key = "the site key";
    const msg = "state:nonce:1730000000";
    const good = sign(key, msg);
    try testing.expect(verify(key, msg, &good));
    for (0..mac_len * 8) |bit| {
        var bad = good;
        bad[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        try testing.expect(!verify(key, msg, &bad));
    }
    try testing.expect(!verify(key, msg, good[0 .. mac_len - 1]));
    try testing.expect(!verify(key, msg, ""));
    try testing.expect(!verify("another key", msg, &good));
    try testing.expect(!verify(key, "state:nonce:1730000001", &good));
}

test "verify compares in constant time (its body, by Zig's tokens)" {
    // A timing test would be flaky; this holds `verify` to its rule instead:
    // the compare is `timing_safe.eql`, and there is no loop, no `mem.eql`
    // and no `mem.order` in it to return early.
    const source = @embedFile("crypto.zig");
    const start = std.mem.indexOf(u8, source, "pub fn verify(").?;
    const body_end = std.mem.indexOfPos(u8, source, start, "\n}\n").?;
    const body = source[start..body_end];
    const z = try testing.allocator.dupeSentinel(u8, body, 0);
    defer testing.allocator.free(z);
    var tokens = std.zig.Tokenizer.init(z);
    var timing_safe = false;
    var prev2: []const u8 = "";
    var prev1: []const u8 = "";
    while (true) {
        const t = tokens.next();
        if (t.tag == .eof) break;
        const text = tokens.buffer[t.loc.start..t.loc.end];
        try testing.expect(t.tag != .keyword_for and t.tag != .keyword_while);
        if (std.mem.eql(u8, prev2, "mem") and std.mem.eql(u8, prev1, "."))
            try testing.expect(!std.mem.eql(u8, text, "eql") and !std.mem.eql(u8, text, "order"));
        if (std.mem.eql(u8, prev2, "timing_safe") and std.mem.eql(u8, prev1, ".") and std.mem.eql(u8, text, "eql"))
            timing_safe = true;
        prev2 = prev1;
        prev1 = text;
    }
    try testing.expect(timing_safe);
}

test "randomBytes: from the OS, and not the same twice" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try randomBytes(testing.io, &a);
    try randomBytes(testing.io, &b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expect(!std.mem.allEqual(u8, &a, 0));
}
