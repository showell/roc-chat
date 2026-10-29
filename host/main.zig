//! **ROC-CHAT**: the Roc chat's own server. It reads config.zon from its
//! working directory (no arguments), makes the data root it names, and
//! serves until it is stopped.

const std = @import("std");
const config = @import("config.zig");
const server = @import("server.zig");
const files = @import("files.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const c = try config.load(io, init.gpa, arena, cwd);
    cwd.createDirPath(io, c.data) catch |e| {
        std.log.err("{s}: .data = \"{s}\": cannot make it ({t})", .{ config.file_name, c.data, e });
        return e;
    };
    const data = cwd.openDir(io, c.data, .{}) catch |e| {
        std.log.err("{s}: .data = \"{s}\": cannot open it ({t})", .{ config.file_name, c.data, e });
        return e;
    };
    // Before the first request, so no write is in flight.
    const swept = (files.Files{ .io = io, .root = data }).sweepTemps() catch |e| {
        std.log.err("{s}: the temporaries a stopped write left cannot be swept ({t})", .{ c.data, e });
        return e;
    };
    if (swept > 0) std.log.info("{s}: {d} temporaries a stopped write left, swept", .{ c.data, swept });
    const addr = try std.Io.net.IpAddress.parse(c.bind, c.port);
    var s = try server.Server.init(io, init.gpa, addr, .{}, data);
    std.debug.print("roc-chat: http://{f}, its data in {s}\n", .{ addr, c.data });
    try s.run();
}
