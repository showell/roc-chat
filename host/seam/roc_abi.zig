//! **ROC'S SIDE OF THE SEAM**: what the chat's Roc archive (app/, built for
//! the platform in platform/) needs from its host, and the lists it hands
//! across:
//!
//!   - the runtime: `roc_alloc`, `roc_realloc`, `roc_dealloc`,
//!     `roc_crashed`, `roc_dbg` and `roc_expect_failed`;
//!   - `RocBytes` (a `List(U8)`) and `RocBytesList` (a `List(List(U8))`).
//!
//! (From roc-webbox src/roc_abi.zig at 5a4314b, cut to what roc-chat uses:
//! no `RocStr`, no TODO app's records, no `roc_hooks`, since this binary
//! holds one Roc app.)
//!
//! **ONE CALL AT A TIME**: the host runs one handler at a time (the turn,
//! host/server.zig), so the call's allocator is held here, set by the call.

const std = @import("std");

/// A Roc `List(U8)` (roc's builtins/list.zig): pointer, length, then the
/// capacity (shifted), the bytes after a refcount word.
pub const RocBytes = extern struct {
    ptr: ?[*]u8,
    length: usize,
    capacity_or_alloc_ptr: usize,

    pub fn slice(b: *const RocBytes) []const u8 {
        const p = b.ptr orelse return "";
        return p[0..b.length];
    }

    /// A new list holding `bytes`, in the call's memory.
    pub fn from(bytes: []const u8) RocBytes {
        if (bytes.len == 0) return .{ .ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
        const data = withRefcount(bytes.len);
        @memcpy(data[0..bytes.len], bytes);
        return .{ .ptr = data, .length = bytes.len, .capacity_or_alloc_ptr = bytes.len << 1 };
    }
};

/// A Roc `List(List(U8))`: a list whose elements are refcounted (each a
/// `List(U8)`) has two words before them, the element count and then the
/// refcount.
pub const RocBytesList = extern struct {
    ptr: ?[*]RocBytes,
    length: usize,
    capacity_or_alloc_ptr: usize,

    pub fn slice(l: *const RocBytesList) []const RocBytes {
        const p = l.ptr orelse return &.{};
        return p[0..l.length];
    }

    /// A new list of `items`, each copied, in the call's memory.
    pub fn from(items: []const []const u8) RocBytesList {
        if (items.len == 0) return .{ .ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
        const w = @sizeOf(usize);
        const base = allocate(2 * w + items.len * @sizeOf(RocBytes), w);
        std.mem.writeInt(usize, base[0..w], items.len, .little);
        std.mem.writeInt(usize, base[w..][0..w], 1, .little);
        const elems: [*]RocBytes = @ptrCast(@alignCast(base + 2 * w));
        for (items, 0..) |it, k| elems[k] = .from(it);
        return .{ .ptr = elems, .length = items.len, .capacity_or_alloc_ptr = items.len << 1 };
    }
};

comptime {
    const w = @sizeOf(usize);
    std.debug.assert(@sizeOf(RocBytes) == 3 * w and @sizeOf(RocBytesList) == 3 * w);
}

// ── the call ────────────────────────────────────────────────────────────────

/// **EVERYTHING ROC ALLOCATES IN A CALL IS THE REQUEST'S**: the request's
/// own arena, handed over as the call starts (`useRequest`) and freed whole
/// when the request ends. So `roc_dealloc` frees nothing, and the refcounts
/// of what the host hands Roc need no keeping.
var direct: ?std.mem.Allocator = null;

/// The request's own allocator, for the call made while it is answered.
pub fn useRequest(request: std.mem.Allocator) void {
    direct = request;
}

/// The call is over: no allocator until the next one.
pub fn done() void {
    direct = null;
}

/// **ONE ROC CALL AT A TIME, AND NO ROC OUTSIDE ONE**: compiled Roc reaches
/// memory through context-free functions, so a call made beside another
/// would share the one allocator. The word is set by compare-and-swap as a
/// call starts, so a second is caught (the turn should make that
/// impossible; this says so loudly if it does not).
var busy = std.atomic.Value(bool).init(false);

/// A Roc call starts: refused when one is open.
pub fn enter() error{RocReentered}!void {
    if (busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.RocReentered;
}

/// The call is over.
pub fn leave() void {
    busy.store(false, .release);
}

/// Whether a Roc call is open (a hosted function's check).
pub fn inCall() bool {
    return busy.load(.monotonic);
}

fn inside(comptime what: []const u8) void {
    if (!inCall()) @panic(what ++ ": Roc ran outside a call");
}

/// The call's allocator: what a hosted function's answer is made in.
pub fn alloc() std.mem.Allocator {
    return direct orelse @panic("roc_abi.alloc: no request's allocator (useRequest)");
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

pub fn allocate(len: usize, alignment: usize) [*]u8 {
    std.debug.assert(alignment <= header);
    // **OUT OF MEMORY IS A CRASH OF THE CALL**: `crashed`, which inside a
    // guarded call (chat_abi.zig) jumps back to its start, so the request is
    // a 500 and the server goes on.
    const got = alloc().alignedAlloc(u8, .fromByteUnits(header), header + len) catch crashed("roc_alloc: out of memory");
    std.mem.writeInt(usize, got[0..@sizeOf(usize)], len, .little);
    return got.ptr + header;
}

/// `len` bytes of list data after a refcount word set to 1, as Roc's
/// `allocateWithRefcount` lays them (the word is a `usize`).
pub fn withRefcount(len: usize) [*]u8 {
    const w = @sizeOf(usize);
    const base = allocate(w + len, w);
    std.mem.writeInt(usize, base[0..w], 1, .little);
    return base + w;
}

pub fn roc_alloc(len: usize, alignment: usize) callconv(.c) *anyopaque {
    inside("roc_alloc");
    return allocate(len, alignment);
}

pub fn roc_realloc(ptr: *anyopaque, len: usize, alignment: usize) callconv(.c) *anyopaque {
    inside("roc_realloc");
    const old: [*]u8 = @ptrCast(ptr);
    const was = std.mem.readInt(usize, (old - header)[0..@sizeOf(usize)], .little);
    const new = allocate(len, alignment);
    @memcpy(new[0..@min(was, len)], old[0..@min(was, len)]);
    return new;
}

pub fn roc_dealloc(ptr: *anyopaque, alignment: usize) callconv(.c) void {
    inside("roc_dealloc");
    _ = ptr;
    _ = alignment;
}

/// What a Roc crash (an overflow, a `crash`: a bug in the app) does: by
/// default the process stops, saying Roc's message; a guarded call
/// (chat_abi.zig) jumps back to its start instead.
pub var crashed: *const fn (message: []const u8) noreturn = stop;

fn stop(message: []const u8) noreturn {
    std.debug.panic("roc crashed: {s}", .{message});
}

pub fn roc_crashed(bytes: [*]const u8, len: usize) callconv(.c) void {
    crashed(bytes[0..len]);
}

/// **A `dbg` OR A FAILED `expect` IS A CRASH HERE.** Roc's runtime links
/// both hooks when an app uses some builtins, though nothing a served app
/// runs should reach either: one that does is that call's crash, so it is
/// loud and ends only the call. The message is fixed, so nothing depends on
/// how Roc passes its arguments.
pub fn roc_dbg() callconv(.c) void {
    crashed("a `dbg` was reached in a served build");
}

pub fn roc_expect_failed() callconv(.c) void {
    crashed("an inline `expect` failed in a served build");
}

test "a list of bytes and a list of lists, there and back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    useRequest(arena.allocator());
    defer done();
    for ([_][]const u8{ "", "GET", &@as([1000]u8, @splat('z')) }) |t| {
        const b = RocBytes.from(t);
        try std.testing.expectEqualStrings(t, b.slice());
    }
    const l = RocBytesList.from(&.{ "a", "bc" });
    try std.testing.expectEqual(2, l.slice().len);
    try std.testing.expectEqualStrings("bc", l.slice()[1].slice());
}
