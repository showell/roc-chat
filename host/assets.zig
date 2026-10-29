//! **THE CHAT CLIENT'S SCRIPTS** (chat-client's `bundles`, compiled in),
//! served when the Roc asks (Host.serve_script!): each script's bytes, its
//! hash its ETag, and a 304 when the browser already has those bytes. The
//! cache rule is `no-cache`: the browser keeps a copy and asks each time,
//! so a new build's script is never stale behind an old one.

const std = @import("std");
const bundles = @import("chat_client").bundles;

pub const Bundle = @TypeOf(bundles[0]);

pub const content_type = "text/javascript; charset=utf-8";
pub const cache_control = "no-cache";

/// The script named `name`, or null.
pub fn find(name: []const u8) ?*const Bundle {
    for (&bundles) |*b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}

/// The ETag of `body`: its hash, quoted (a strong validator).
pub fn etagOf(body: []const u8) [18]u8 {
    var out: [18]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "\"{x:0>16}\"", .{std.hash.Wyhash.hash(0, body)}) catch unreachable;
    return out;
}

/// Whether an `If-None-Match` value names `etag` (a list, or `*`).
pub fn notModified(if_none_match: []const u8, etag: []const u8) bool {
    var it = std.mem.splitScalar(u8, if_none_match, ',');
    while (it.next()) |raw| {
        var tag = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, tag, "W/")) tag = tag[2..];
        if (std.mem.eql(u8, tag, "*") or std.mem.eql(u8, tag, etag)) return true;
    }
    return false;
}

test "a script found by name, and its ETag matched in a list or by a weak tag" {
    const b = find("chat.js") orelse return error.NoChatJs;
    const tag = etagOf(b.body);
    try std.testing.expect(find("nope.js") == null);
    try std.testing.expect(notModified(&tag, &tag));
    var buf: [64]u8 = undefined;
    try std.testing.expect(notModified(try std.fmt.bufPrint(&buf, "\"x\", W/{s}", .{&tag}), &tag));
    try std.testing.expect(!notModified("\"x\"", &tag));
}
