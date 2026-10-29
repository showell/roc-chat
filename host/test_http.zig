//! **THE SERVER'S TEST HARNESS**: a server on a port of its own (port 0) in
//! this process, with whichever Roc archive the test links (the chat's in
//! server_test.zig, the planted crashes' in crash_test.zig), and clients
//! that speak HTTP by hand over TCP.

const std = @import("std");
const Io = std.Io;
const server = @import("server.zig");

pub const io = std.testing.io;
pub const gpa = std.testing.allocator;

const RunResult = @typeInfo(@TypeOf(server.Server.run)).@"fn".return_type.?;

/// A server running on its own task, on a port of its own.
pub const Running = struct {
    server: server.Server,
    run: Io.Future(RunResult),
    /// The server's data root, a folder of the test's own.
    data: std.testing.TmpDir,

    pub fn start(limits: server.Limits) !*Running {
        const r = try gpa.create(Running);
        errdefer gpa.destroy(r);
        r.data = std.testing.tmpDir(.{});
        errdefer r.data.cleanup();
        r.server = try .init(io, gpa, try .parse("127.0.0.1", 0), limits, r.data.dir);
        r.run = try io.concurrent(server.Server.run, .{&r.server});
        return r;
    }

    pub fn stop(r: *Running) void {
        r.server.stop();
        r.run.await(io) catch |e| std.debug.print("the server's run: {t}\n", .{e});
        r.data.cleanup();
        gpa.destroy(r);
    }

    pub fn port(r: *const Running) u16 {
        return r.server.port();
    }

    pub fn turns(r: *const Running) u32 {
        return r.server.stats.turns.load(.acquire);
    }
};

/// A client's connection: bytes written as the test says, read to the end.
pub const Client = struct {
    stream: Io.net.Stream,

    pub fn open(port: u16) !Client {
        const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
        return .{ .stream = try addr.connect(io, .{ .mode = .stream }) };
    }

    pub fn send(c: Client, bytes: []const u8) !void {
        var w = c.stream.writer(io, &.{});
        try w.interface.writeAll(bytes);
    }

    /// Everything the server sends until it closes.
    pub fn rest(c: Client, arena: std.mem.Allocator) ![]u8 {
        var buf: [4096]u8 = undefined;
        var r = c.stream.reader(io, &buf);
        return r.interface.allocRemaining(arena, .limited(4 * 1024 * 1024));
    }

    pub fn close(c: Client) void {
        c.stream.close(io);
    }
};

/// One request on a connection of its own, and all the server sends back.
pub fn exchange(arena: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    const c = try Client.open(port);
    defer c.close();
    try c.send(request);
    return c.rest(arena);
}

/// A response as the tests read it.
pub const Response = struct {
    status: u16,
    head: []const u8,
    body: []const u8,

    pub fn of(bytes: []const u8) !Response {
        if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 ") or bytes.len < 12) return error.NotAResponse;
        const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.NoHeadEnd;
        return .{
            .status = try std.fmt.parseInt(u16, bytes[9..12], 10),
            .head = bytes[0 .. end + 2],
            .body = bytes[end + 4 ..],
        };
    }

    /// Header `name`'s value (lowercase, as std writes them), or null.
    pub fn header(r: Response, comptime name: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, r.head, "\r\n" ++ name ++ ": ") orelse return null;
        const from = at + name.len + 4;
        const to = std.mem.indexOfPos(u8, r.head, from, "\r\n") orelse return null;
        return r.head[from..to];
    }
};

pub fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

pub fn msSince(t0: Io.Timestamp) i64 {
    return t0.untilNow(io, .awake).toMilliseconds();
}
