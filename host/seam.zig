//! **THE SEAM**: what the Roc archive (app/ on platform/) needs from its
//! host, and what crosses between them:
//!
//!   - the runtime: `roc_alloc`, `roc_realloc`, `roc_dealloc`,
//!     `roc_crashed`, `roc_dbg` and `roc_expect_failed`;
//!   - the app's two entries: `roc_page` (the demo) and
//!     `roc_handle_http_request` (the server), and the records the second
//!     takes and answers (platform/Http.roc);
//!   - the hosted functions (platform/Host.roc), each exported under its
//!     Roc name and answered by host/file_primitives.zig, or, for a
//!     stream's frames, host/bus.zig.
//!
//! **EVERY RECORD IS LAID OUT AS ROC LAYS IT**: fields by alignment, then
//! by name; a tag union with no payloads is one byte, its tags numbered
//! alphabetically. host/seam_test.zig holds every record here, field by
//! field, and every enum, tag by tag, to what `roc glue` makes of the
//! platform.
//!
//! **ONE CALL AT A TIME, ITS MEMORY ONE ARENA**: the server makes one Roc
//! call at a time (the turn, host/http.zig), so the call's arena, data
//! root and hub are held here, set as the call begins (`begin`). Everything Roc
//! allocates is in that arena, freed whole when the request ends, so
//! `roc_dealloc` frees nothing and nothing is refcounted by hand.
//!
//! **A ROC CRASH STOPS THE PROCESS**, saying Roc's message: a `crash` is a
//! promise the app broke, and the server does not answer on after one.

const std = @import("std");
const Io = std.Io;
const files = @import("file_primitives.zig");
const bus = @import("bus.zig");

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
fn RocList(comptime Rec: type, comptime Item: type, comptime rec: fn (Item) Rec) type {
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

// ── the HTTP records (platform/Http.roc) ────────────────────────────────────

/// Http.roc's `Header`: `{ name, value : List(U8) }`, by name.
pub const HeaderRec = extern struct { name: RocBytes, value: RocBytes };

pub const HeaderList = RocList(HeaderRec, std.http.Header, struct {
    fn rec(h: std.http.Header) HeaderRec {
        return .{ .name = .from(h.name), .value = .from(h.value) };
    }
}.rec);

/// Http.roc's `Request`: five lists, by name, then the U16.
pub const Request = extern struct {
    body: RocBytes,
    headers: HeaderList,
    method: RocBytes,
    path: RocBytes,
    query: RocBytes,
    port: u16,
};

/// Http.roc's `Response`'s `kind`, alphabetical.
pub const AnswerKind = enum(u8) { stream, whole };

/// Http.roc's `Response`: the lists by name, then the U16, then the tag.
pub const Response = extern struct {
    body: RocBytes,
    headers: HeaderList,
    stream_holder: RocBytes,
    stream_key: RocBytes,
    status: u16,
    kind: AnswerKind,
};

comptime {
    const w = @sizeOf(usize);
    std.debug.assert(@sizeOf(HeaderRec) == 6 * w and @sizeOf(Request) == 16 * w and @sizeOf(Response) == 13 * w);
}

// ── the file primitives' answers ────────────────────────────────────────────

/// Host.roc's `read_utf8_bytes_from_file!` status, alphabetical.
pub const ReadStatus = enum(u8) { failed, found, missing, not_utf8, path_refused };
/// Host.roc's `read_utf8_bytes_from_file!` answer: the list, then the tag.
pub const ReadRec = extern struct { bytes: RocBytes, status: ReadStatus };
/// Host.roc's `list_names_in_directory!` answer.
pub const ListRec = extern struct { names: RocBytesList, status: ReadStatus };

comptime {
    for (.{ ReadStatus, files.AppendAnswer, files.CreateAnswer, files.ReplaceAnswer, files.MakeDirectoryAnswer }) |E| {
        std.debug.assert(@sizeOf(E) == 1);
    }
}

// ── the call ────────────────────────────────────────────────────────────────

/// What a call to the Roc may use, set for its length: its arena, and,
/// for the server's, the data root and the Io the primitives answer with,
/// and the hub its frames are published on.
pub const Call = struct {
    arena: std.mem.Allocator,
    root: ?*const files.DataRoot = null,
    io: ?Io = null,
    hub: ?*bus.Hub = null,
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

fn call(comptime what: []const u8) Call {
    return current orelse @panic(what ++ ": the Roc ran outside a call");
}

fn root_of(comptime what: []const u8) *const files.DataRoot {
    return call(what).root orelse @panic(what ++ ": this call has no data root (the demo's asks for no file)");
}

fn io_of(comptime what: []const u8) Io {
    return call(what).io orelse @panic(what ++ ": this call has no Io (the demo's asks for none)");
}

fn hub_of(comptime what: []const u8) *bus.Hub {
    return call(what).hub orelse @panic(what ++ ": this call has no hub (the demo's publishes nothing)");
}

// ── the entries ─────────────────────────────────────────────────────────────

pub extern fn roc_page(topic: RocBytes, transcript: RocBytes) callconv(.c) RocBytes;
pub extern fn roc_handle_http_request(request: Request) callconv(.c) Response;

// ── the hosted functions ────────────────────────────────────────────────────

pub export fn read_utf8_bytes_from_file(path: RocBytes) callconv(.c) ReadRec {
    const what = "read_utf8_bytes_from_file";
    return switch (root_of(what).read_utf8_bytes_from_file(call(what).arena, path.slice())) {
        .found => |b| .{ .bytes = .from(b), .status = .found },
        .missing => .{ .bytes = .from(""), .status = .missing },
        .not_utf8 => .{ .bytes = .from(""), .status = .not_utf8 },
        .path_refused => .{ .bytes = .from(""), .status = .path_refused },
        .failed => .{ .bytes = .from(""), .status = .failed },
    };
}

pub export fn append_utf8_bytes_to_file(path: RocBytes, bytes: RocBytes) callconv(.c) files.AppendAnswer {
    return root_of("append_utf8_bytes_to_file").append_utf8_bytes_to_file(path.slice(), bytes.slice());
}

pub export fn create_file_with_utf8_bytes_unless_it_exists(path: RocBytes, bytes: RocBytes) callconv(.c) files.CreateAnswer {
    return root_of("create_file_with_utf8_bytes_unless_it_exists").create_file_with_utf8_bytes_unless_it_exists(path.slice(), bytes.slice());
}

pub export fn replace_file_with_utf8_bytes_atomically(path: RocBytes, bytes: RocBytes) callconv(.c) files.ReplaceAnswer {
    return root_of("replace_file_with_utf8_bytes_atomically").replace_file_with_utf8_bytes_atomically(path.slice(), bytes.slice());
}

pub export fn make_directory_and_its_parents(path: RocBytes) callconv(.c) files.MakeDirectoryAnswer {
    return root_of("make_directory_and_its_parents").make_directory_and_its_parents(path.slice());
}

pub export fn list_names_in_directory(path: RocBytes) callconv(.c) ListRec {
    const what = "list_names_in_directory";
    return switch (root_of(what).list_names_in_directory(call(what).arena, path.slice())) {
        .found => |names| .{ .names = .from(names), .status = .found },
        .missing => .{ .names = .from(&.{}), .status = .missing },
        .not_utf8 => .{ .names = .from(&.{}), .status = .not_utf8 },
        .path_refused => .{ .names = .from(&.{}), .status = .path_refused },
        .failed => .{ .names = .from(&.{}), .status = .failed },
    };
}

pub export fn current_utc_seconds_since_epoch() callconv(.c) i64 {
    return files.current_utc_seconds_since_epoch(io_of("current_utc_seconds_since_epoch"));
}

/// **MORE THAN `random_most`, OR NO RANDOMNESS, STOPS THE SERVER**: the
/// first is the app's bug, and the second leaves nothing safe to hand back.
pub export fn fill_with_random_bytes(count: u64) callconv(.c) RocBytes {
    const what = "fill_with_random_bytes";
    if (count > files.random_most) std.debug.panic(what ++ ": {d} bytes asked, at most {d}", .{ count, files.random_most });
    var buf: [files.random_most]u8 = undefined;
    const n: usize = @intCast(count);
    files.fill_with_random_bytes(io_of(what), buf[0..n]) catch |e| std.debug.panic(what ++ ": {t}", .{e});
    return .from(buf[0..n]);
}

/// The hub copies the bytes, so they outlive the call's arena.
pub export fn publish_bytes_to_streams_on_key(key: RocBytes, bytes: RocBytes) callconv(.c) void {
    hub_of("publish_bytes_to_streams_on_key").publish(key.slice(), bytes.slice());
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
