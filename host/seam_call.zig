//! **THE CALL, ITS LISTS AND THE RUNTIME**: what every part of the seam
//! (host/seam.zig) stands on. The call the Roc runs in, set as it begins
//! and the one place its arena, data root and hub are held; the Roc lists
//! the host makes, each in that arena; and the runtime the Roc links
//! against (`roc_alloc`, `roc_realloc`, `roc_dealloc`, `roc_crashed`,
//! `roc_dbg`, `roc_expect_failed`).
//!
//! **ONE CALL AT A TIME, ITS MEMORY ONE ARENA**: the server makes one Roc
//! call at a time (the turn, host/http.zig), so the call's arena, data
//! root and hub are held here, set as the call begins (`begin`). A
//! password's check lets the turn go while bcrypt runs, and a GitHub code's
//! exchange while GitHub answers, each setting its call aside and taking it
//! back with the turn (`set_aside`, `take_back`). Everything Roc
//! allocates is in that arena, freed whole when the request ends, so
//! `roc_dealloc` frees nothing and nothing is refcounted by hand.
//!
//! **A ROC CRASH STOPS THE PROCESS**, saying Roc's message: a `crash` is a
//! promise the app broke, and the server does not answer on after one.

const std = @import("std");
const Io = std.Io;
const files = @import("file_primitives.zig");
const bus = @import("bus.zig");
const sse = @import("sse.zig");
const sign_in = @import("sign_in_primitives.zig");
const github = @import("github_client.zig");
const remembered = @import("remembered_seconds.zig");
const search_index = @import("search_index.zig");

// ── the lists ───────────────────────────────────────────────────────────────

/// A Roc `List(U8)`: pointer, length, then the capacity (shifted), the
/// bytes after a refcount word.
pub const RocBytes = extern struct {
    ptr: ?[*]u8,
    length: usize,
    capacity_or_alloc_ptr: usize,

    pub fn slice(b: *const RocBytes) []const u8 {
        const p = b.ptr orelse return "";
        return p[0..b.length];
    }

    /// A new list holding `bytes`, in the call's arena.
    pub fn from(bytes: []const u8) RocBytes {
        if (bytes.len == 0) return .{ .ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
        const w = @sizeOf(usize);
        const base = allocate(w + bytes.len, w);
        std.mem.writeInt(usize, base[0..w], 1, .little);
        const data = base + w;
        @memcpy(data[0..bytes.len], bytes);
        return .{ .ptr = data, .length = bytes.len, .capacity_or_alloc_ptr = bytes.len << 1 };
    }
};

/// A Roc list of `Rec`, each made of an `Item` by `rec`. Its elements hold
/// refcounted lists, so it has two words before them: the element count,
/// then the refcount.
pub fn RocList(comptime Rec: type, comptime Item: type, comptime rec: fn (Item) Rec) type {
    return extern struct {
        ptr: ?[*]Rec,
        length: usize,
        capacity_or_alloc_ptr: usize,

        pub fn slice(l: *const @This()) []const Rec {
            const p = l.ptr orelse return &.{};
            return p[0..l.length];
        }

        pub fn from(items: []const Item) @This() {
            if (items.len == 0) return .{ .ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
            const w = @sizeOf(usize);
            const base = allocate(2 * w + items.len * @sizeOf(Rec), w);
            std.mem.writeInt(usize, base[0..w], items.len, .little);
            std.mem.writeInt(usize, base[w..][0..w], 1, .little);
            const elems: [*]Rec = @ptrCast(@alignCast(base + 2 * w));
            for (items, 0..) |it, k| elems[k] = rec(it);
            return .{ .ptr = elems, .length = items.len, .capacity_or_alloc_ptr = items.len << 1 };
        }
    };
}

/// A Roc `List(List(U8))`.
pub const RocBytesList = RocList(RocBytes, []const u8, RocBytes.from);

/// A Roc `List(U64)`: its elements hold no lists, so one word before them,
/// the refcount.
pub const RocU64List = extern struct {
    ptr: ?[*]u64,
    length: usize,
    capacity_or_alloc_ptr: usize,

    pub fn from(items: []const u64) RocU64List {
        if (items.len == 0) return .{ .ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
        const w = @sizeOf(usize);
        const base = allocate(w + items.len * @sizeOf(u64), w);
        std.mem.writeInt(usize, base[0..w], 1, .little);
        const elems: [*]u64 = @ptrCast(@alignCast(base + w));
        @memcpy(elems[0..items.len], items);
        return .{ .ptr = elems, .length = items.len, .capacity_or_alloc_ptr = items.len << 1 };
    }
};

// ── the call ────────────────────────────────────────────────────────────────

/// What a call to the Roc may use, set for its length: its arena, and,
/// for the server's, the data root and the Io the primitives answer with,
/// the hub its frames are published on, the slots of its held streams, the
/// secret it signs with, the bucket its password checks are taken from,
/// the turn it holds, which a password's check lets go of, GitHub's
/// settings if it has them, and the allocator GitHub's client uses.
pub const Call = struct {
    arena: std.mem.Allocator,
    root: ?*const files.DataRoot = null,
    io: ?Io = null,
    hub: ?*bus.Hub = null,
    slots: ?*sse.Slots = null,
    secret: ?*const sign_in.ServerSecret = null,
    password_checks: ?*sign_in.PasswordChecks = null,
    turn: ?*Io.Mutex = null,
    github: ?*const github.Settings = null,
    gpa: ?std.mem.Allocator = null,
    seconds: ?*remembered.RememberedSeconds = null,
    search: ?*search_index.SearchIndex = null,
};

var current: ?Call = null;

/// **A CALL BEGINS**: its arena holds everything it allocates; its root,
/// Io and hub answer the hosted functions (none for the demo, which asks
/// none). A call begun inside another is a bug in the host.
pub fn begin(c: Call) void {
    if (current != null) @panic("seam.begin: a call is already open (one call at a time)");
    current = c;
}

/// The call is over.
pub fn end() void {
    current = null;
}

/// The call is set aside while its turn is let go (a password's check,
/// GitHub's exchange): no call is open until `take_back`.
pub fn set_aside() void {
    current = null;
}

/// The call set aside is open again, its turn held once more.
pub fn take_back(c: Call) void {
    current = c;
}

pub fn call(comptime what: []const u8) Call {
    return current orelse @panic(what ++ ": the Roc ran outside a call");
}

pub fn root_of(comptime what: []const u8) *const files.DataRoot {
    return call(what).root orelse @panic(what ++ ": this call has no data root (the demo's asks for no file)");
}

pub fn io_of(comptime what: []const u8) Io {
    return call(what).io orelse @panic(what ++ ": this call has no Io (the demo's asks for none)");
}

pub fn hub_of(comptime what: []const u8) *bus.Hub {
    return call(what).hub orelse @panic(what ++ ": this call has no hub (the demo's publishes nothing)");
}

pub fn slots_of(comptime what: []const u8) *sse.Slots {
    return call(what).slots orelse @panic(what ++ ": this call has no streams (only the server's holds any)");
}

pub fn secret_of(comptime what: []const u8) []const u8 {
    const s = call(what).secret orelse @panic(what ++ ": this call has no secret (only the server's signs)");
    return s.slice();
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
    const got = call("roc_alloc").arena.alignedAlloc(u8, .fromByteUnits(header), header + len) catch
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
