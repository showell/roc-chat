//! **WHAT A SYNC PER WRITE COSTS** (the host design's section 5, decision
//! D5): `write` and `append` timed on this disk, with the syncs and with
//! them skipped (`Fault.sync_skipped`), in `.zig-cache/files-bench/`,
//! removed after. `zig build bench-files`; never part of `zig build test`.

const std = @import("std");
const files = @import("files.zig");

const rounds = 300;
const record = "a chat line of about a hundred bytes, as a transcript's append or a small file's write would carry\n";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const folder = ".zig-cache/files-bench";
    cwd.deleteTree(io, folder) catch {};
    try cwd.createDirPath(io, folder);
    defer cwd.deleteTree(io, folder) catch {};
    var root = try cwd.openDir(io, folder, .{});
    defer root.close(io);

    std.debug.print("{d} rounds of a {d}-byte record, per op: median, then 90th percentile\n", .{ rounds, record.len });
    for ([_]files.Fault{ .none, .sync_skipped }) |fault| {
        const f: files.Files = .{ .io = io, .root = root, .fault_for_test = fault };
        var times: [rounds]i96 = undefined;
        for (&times, 0..) |*t, i| {
            var name_buf: [32]u8 = undefined;
            // A new file each round and one rewritten: a write is either.
            const name = if (i % 2 == 0) try std.fmt.bufPrint(&name_buf, "w/{t}/{d}", .{ fault, i }) else try std.fmt.bufPrint(&name_buf, "w/{t}/same", .{fault});
            const start = std.Io.Timestamp.now(io, .awake);
            try f.write(name, record);
            t.* = start.untilNow(io, .awake).toNanoseconds();
        }
        report("write!", fault, &times);
        for (&times) |*t| {
            var name_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "a/{t}/log", .{fault});
            const start = std.Io.Timestamp.now(io, .awake);
            _ = try f.append(name, record);
            t.* = start.untilNow(io, .awake).toNanoseconds();
        }
        report("append!", fault, &times);
    }
}

fn report(what: []const u8, fault: files.Fault, times: *[rounds]i96) void {
    std.mem.sort(i96, times, {}, std.sort.asc(i96));
    const us = struct {
        fn of(ns: i96) f64 {
            return @as(f64, @floatFromInt(ns)) / 1000.0;
        }
    }.of;
    std.debug.print("  {s:<8} {s:<12} {d:>9.1} us  {d:>9.1} us\n", .{ what, if (fault == .none) "synced" else "sync skipped", us(times[rounds / 2]), us(times[rounds * 9 / 10]) });
}
