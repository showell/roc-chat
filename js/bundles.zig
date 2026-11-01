//! **ROC-CHAT'S OWN BROWSER SCRIPTS** (docs/design/browser-client.md):
//! hand-written JavaScript, no build step, each served verbatim at
//! `/<name>` (host/assets.zig), beside chat-client's scripts, whose names
//! these must not take (assets.zig refuses a build where they do).

/// One script: its name and its bytes.
pub const Script = struct { name: []const u8, body: []const u8 };

pub const scripts = [_]Script{
    .{ .name = "feed.js", .body = @embedFile("feed.js") },
};
