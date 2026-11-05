//! **THE DEMO**: `demo <url path> <transcript>` reads the transcript
//! file, hands it and the conversation's URL path (the one the server
//! shows it at, `/chat/channel/general/roc-chat`) to the Roc
//! (app/main.roc's `page`, through `roc_page`), and writes the page to
//! stdout. The seam and the runtime are host/seam.zig's;
//! the demo's one call asks for no file and no clock.

const std = @import("std");
const Io = std.Io;
const seam = @import("seam.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) std.process.fatal("usage: demo <conversation's URL path> <transcript file>", .{});
    const text = try Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    seam.begin(.{ .arena = a });
    const html = seam.roc_page(.from(args[1]), .from(text));
    seam.end();
    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    try out.interface.writeAll(html.slice());
    try out.interface.flush();
}
