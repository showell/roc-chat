//! An allocator that zeroes every byte it gives back, for the GitHub client:
//! std.http.Client keeps the token, the client secret and the answers in
//! buffers of its own (the connection's reader and writer, TLS's records),
//! and frees them without wiping. Under this allocator a freed buffer holds
//! zeros, whoever owned it.
//!
//! **NO BYTE LEAVES UNWIPED**: a free zeroes the whole block first; a shrink
//! is refused (`resize` false, `remap` null), so the caller copies to a new
//! block and frees the old one through `free`; a growth happens only in
//! place, since a child's relocating remap would free the old block unwiped.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Wiping = struct {
    child: Allocator,

    pub fn allocator(w: *Wiping) Allocator {
        return .{ .ptr = w, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const w: *Wiping = @ptrCast(@alignCast(ctx));
        return w.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const w: *Wiping = @ptrCast(@alignCast(ctx));
        if (new_len < memory.len) return false;
        return w.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const w: *Wiping = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, memory);
        w.child.rawFree(memory, alignment, ret_addr);
    }
};

const testing = std.testing;

/// Grows a block past a neighbor (so it must move), puts a secret in its
/// tail, shrinks it to before the secret, and frees everything.
fn leftAfterChurn(a: Allocator) !void {
    var s = try a.alloc(u8, 16);
    const neighbor = try a.alloc(u8, 8);
    s = try a.realloc(s, 600);
    @memcpy(s[580..596], "SECRET-0123456ab");
    s = try a.realloc(s, 16);
    a.free(neighbor);
    a.free(s);
}

// The control is a shrink: std's own `free` overwrites a block in a safe
// build, but a shrink in place leaves the tail as it was in every build
// mode, and ReleaseFast's `free` leaves the whole block.
test "a freed, moved or shrunk block keeps none of the secret; the bare allocator does" {
    var backing: [4096]u8 = @splat(0);
    {
        var fba: std.heap.FixedBufferAllocator = .init(&backing);
        try leftAfterChurn(fba.allocator());
        // The control: without the wrapper the secret survives, so the scan
        // below can see one.
        try testing.expect(std.mem.indexOf(u8, &backing, "SECRET") != null);
    }
    @memset(&backing, 0);
    {
        var fba: std.heap.FixedBufferAllocator = .init(&backing);
        var w: Wiping = .{ .child = fba.allocator() };
        try leftAfterChurn(w.allocator());
        try testing.expect(std.mem.indexOf(u8, &backing, "SECRET") == null);
    }
}
