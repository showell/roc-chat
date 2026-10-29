//! **A STUB, FOR THE BUS'S STUB ROUTE ALONE**: frames kept in memory by
//! key, so the stub app (app/main.roc's `/stub/`) has a backlog to read in
//! the turn that subscribes. Host.stub_append! and Host.stub_read! answer
//! from it. Step 6 of the host design replaces both with the store's
//! `append!` and `read!`, and this file goes.

const std = @import("std");

pub const StubLog = struct {
    gpa: std.mem.Allocator,
    keys: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: []u8, frames: std.ArrayList([]u8) = .empty };

    pub fn deinit(l: *StubLog) void {
        for (l.keys.items) |*e| {
            for (e.frames.items) |f| l.gpa.free(f);
            e.frames.deinit(l.gpa);
            l.gpa.free(e.key);
        }
        l.keys.deinit(l.gpa);
    }

    /// `frame` (copied) after `key`'s others. Called in the turn alone.
    pub fn append(l: *StubLog, key: []const u8, frame: []const u8) !void {
        const e = for (l.keys.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) break e;
        } else e: {
            const k = try l.gpa.dupe(u8, key);
            errdefer l.gpa.free(k);
            try l.keys.append(l.gpa, .{ .key = k });
            break :e &l.keys.items[l.keys.items.len - 1];
        };
        const copy = try l.gpa.dupe(u8, frame);
        errdefer l.gpa.free(copy);
        try e.frames.append(l.gpa, copy);
    }

    /// `key`'s frames, oldest first. Called in the turn alone.
    pub fn read(l: *const StubLog, key: []const u8) []const []const u8 {
        for (l.keys.items) |e| if (std.mem.eql(u8, e.key, key)) return e.frames.items;
        return &.{};
    }
};
