//! The opt-in live smoke test, `zig build smoke`: one real call to
//! `https://api.github.com/zen` through the client's own request path (TLS
//! with the system CA bundle, the User-Agent, the deadlines). Never part of
//! `zig build test`: it needs the network and GitHub.
const std = @import("std");
const github = @import("client.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var s = try github.Session.init(init.gpa, io, .{ .user_agent = "roc-chat-smoke" });
    defer s.deinit();
    var buf: [1024]u8 = undefined;
    const t0: std.Io.Clock.Timestamp = .now(io, .awake);
    const zen = try s.zen(&buf);
    const ms = @divTrunc(t0.untilNow(io).raw.nanoseconds, std.time.ns_per_ms);
    std.debug.print("api.github.com/zen in {d} ms: {s}\n", .{ ms, zen });
}
