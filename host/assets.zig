//! **THE BROWSER'S SCRIPTS**: roc-chat's own (js/, the browser client's)
//! and chat-client's `bundles`, compiled in, served when the Roc asks
//! (Host.serve_script!): each script's bytes, its hash its ETag, and a 304
//! when the browser already has those bytes. The cache rule is `no-cache`:
//! the browser keeps a copy and asks each time, so a new build's script is
//! never stale behind an old one. **A NAME IS ONE SCRIPT'S**: a build
//! where roc-chat's own takes one of chat-client's names does not compile.

const std = @import("std");
const bundles = @import("chat_client").bundles;
const own = @import("roc_chat_js").scripts;

pub const Bundle = @TypeOf(bundles[0]);

/// Every script served: roc-chat's own, then chat-client's.
const all: [own.len + bundles.len]Bundle = blk: {
    var out: [own.len + bundles.len]Bundle = undefined;
    for (own, 0..) |s, i| {
        for (bundles) |b| if (std.mem.eql(u8, s.name, b.name)) @compileError("js/" ++ s.name ++ " takes the name of one of chat-client's scripts");
        out[i] = .{ .name = s.name, .body = s.body };
    }
    for (bundles, 0..) |b, i| out[own.len + i] = b;
    break :blk out;
};

pub const content_type = "text/javascript; charset=utf-8";
pub const cache_control = "no-cache";

/// The script named `name`, or null.
pub fn find(name: []const u8) ?*const Bundle {
    for (&all) |*b| if (std.mem.eql(u8, b.name, name)) return b;
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

test "roc-chat's own script is served, its own bytes" {
    const b = find("feed.js") orelse return error.NoFeedJs;
    try std.testing.expectEqualStrings(own[0].body, b.body);
}
