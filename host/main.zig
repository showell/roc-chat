//! **THE DEMO'S HOST**: `demo <topic> <transcript>` reads the transcript
//! file, hands it to the Roc (app/main.roc's `page`), and writes the page
//! to stdout. The runtime the Roc archive needs is below it; every
//! allocation of the one call is in one arena, so `roc_dealloc` frees
//! nothing. The list layout is roc-markdown's judge/roc_host.zig's.

const std = @import("std");
const Io = std.Io;

/// A Roc `List(U8)`: pointer, length, then the capacity (shifted), the
/// bytes after a refcount word.
const RocBytes = extern struct {
    ptr: ?[*]u8,
    length: usize,
    capacity_or_alloc_ptr: usize,

    fn slice(b: *const RocBytes) []const u8 {
        const p = b.ptr orelse return "";
        return p[0..b.length];
    }

    fn from(bytes: []const u8) RocBytes {
        if (bytes.len == 0) return .{ .ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
        const w = @sizeOf(usize);
        const base = allocate(w + bytes.len, w);
        std.mem.writeInt(usize, base[0..w], 1, .little);
        const data = base + w;
        @memcpy(data[0..bytes.len], bytes);
        return .{ .ptr = data, .length = bytes.len, .capacity_or_alloc_ptr = bytes.len << 1 };
    }
};

extern fn roc_page(topic: RocBytes, transcript: RocBytes) callconv(.c) RocBytes;

var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) std.process.fatal("usage: demo <topic> <transcript file>", .{});
    const text = try Io.Dir.cwd().readFileAlloc(io, args[2], a, .unlimited);
    const html = roc_page(.from(args[1]), .from(text));
    var buf: [64 * 1024]u8 = undefined;
    var out = Io.File.stdout().writer(io, &buf);
    try out.interface.writeAll(html.slice());
    try out.interface.flush();
}

// ── the runtime ─────────────────────────────────────────────────────────────

comptime {
    @export(&roc_alloc, .{ .name = "roc_alloc" });
    @export(&roc_realloc, .{ .name = "roc_realloc" });
    @export(&roc_dealloc, .{ .name = "roc_dealloc" });
    @export(&roc_crashed, .{ .name = "roc_crashed" });
    @export(&roc_dbg, .{ .name = "roc_dbg" });
    @export(&roc_expect_failed, .{ .name = "roc_expect_failed" });
}

/// Each allocation's size, just before what Roc is given, so `roc_realloc`
/// knows how much to copy. 16 bytes: Roc asks for at most 16's alignment.
const header = 16;

fn allocate(len: usize, alignment: usize) [*]u8 {
    std.debug.assert(alignment <= header);
    const got = arena.allocator().alignedAlloc(u8, .fromByteUnits(header), header + len) catch
        std.debug.panic("roc_alloc: out of memory ({d} bytes)", .{len});
    std.mem.writeInt(usize, got[0..@sizeOf(usize)], len, .little);
    return got.ptr + header;
}

fn roc_alloc(len: usize, alignment: usize) callconv(.c) *anyopaque {
    return allocate(len, alignment);
}

fn roc_realloc(ptr: *anyopaque, len: usize, alignment: usize) callconv(.c) *anyopaque {
    const old: [*]u8 = @ptrCast(ptr);
    const was = std.mem.readInt(usize, (old - header)[0..@sizeOf(usize)], .little);
    const new = allocate(len, alignment);
    @memcpy(new[0..@min(was, len)], old[0..@min(was, len)]);
    return new;
}

fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    _ = ptr;
    _ = alignment;
}

fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    std.debug.panic("roc crashed: {s}", .{bytes[0..len]});
}

fn roc_dbg() callconv(.c) void {
    std.debug.panic("roc: a `dbg` was reached", .{});
}

fn roc_expect_failed() callconv(.c) void {
    std.debug.panic("roc: an inline `expect` failed", .{});
}
