//! **THE SERVER**: `gopher-roc <data folder> [--port <n>]` serves the chat
//! from the data folder on 127.0.0.1 (host/http.zig says why only there),
//! at port 9611 unless `--port` names another, until it is stopped.

const std = @import("std");
const http = @import("http.zig");
const files = @import("file_primitives.zig");

const usage = "usage: gopher-roc <data folder> [--port <n>]";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var data: ?[]const u8 = null;
    var port: u16 = http.default_port;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i == args.len) std.process.fatal("{s}: --port names no port", .{usage});
            port = std.fmt.parseInt(u16, args[i], 10) catch std.process.fatal("{s}: --port {s} is no port", .{ usage, args[i] });
        } else if (data == null and !std.mem.startsWith(u8, args[i], "-")) {
            data = args[i];
        } else std.process.fatal("{s}: {s} is not understood", .{ usage, args[i] });
    }
    const folder = data orelse std.process.fatal("{s}", .{usage});
    const dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |e|
        std.process.fatal("the data folder {s} cannot be opened ({t})", .{ folder, e });
    const root: files.DataRoot = .{ .io = io, .dir = dir };
    var server = try http.Server.listen(io, init.gpa, port, .{}, &root);
    std.debug.print("gopher-roc: http://127.0.0.1:{d}/, its data in {s}\n", .{ server.port(), folder });
    try server.run();
}
