//! **THE ROC CHAT'S SIDE OF THE SEAM** (platform/): the records
//! `roc_chat_handle` takes and answers, laid out as Roc lays them (Roc's
//! field order; sizes asserted below, and every record held to roc glue's
//! by glue_test.zig), and the hosted functions (platform/Host.roc), each
//! answered by the call's `Host`. The runtime and the call's memory are
//! roc_abi.zig's.
//!
//! **THE DECISION LEAVES THE CALL**: `decide` copies what Roc answered into
//! the caller's allocator and ends the call before it returns, so the host
//! sends the answer with no Roc call open, and outside the turn.
//!
//! **EVERY `roc_chat_` FUNCTION IS `pub`**: glue_test.zig lists them so, and
//! holds each, record by record, to what `roc glue` makes of Host.roc.

const std = @import("std");
const roc = @import("roc_abi.zig");
const route = @import("chat_route.zig");
const sljmp = @import("sljmp.zig");
pub const Decision = route.Decision;
pub const Header = route.Header;

pub const RocBytes = roc.RocBytes;

const Method = route.Method;

/// Chat.roc's `Exchanged`: `{ github_id : U64, login : List(U8), status }`,
/// the 8-byte fields by name, then the tag. `github_id` and `login` are 0
/// and empty but when `status` is `known`.
pub const ExchangedRec = extern struct {
    github_id: u64,
    login: RocBytes,
    status: route.ExchangeStatus,

    fn of(e: route.Exchanged) ExchangedRec {
        return switch (e) {
            .known => |k| .{ .github_id = k.id, .login = .from(k.login), .status = .known },
            else => .{ .github_id = 0, .login = .from(""), .status = std.meta.activeTag(e) },
        };
    }
};

/// Chat.roc's `Request`: the records and lists by name, then the tag.
pub const Request = extern struct {
    exchanged: ExchangedRec,
    path: RocBytes,
    method: Method,
};
/// Chat.roc's `Header`: `{ name, value : List(U8) }`, by name.
pub const HeaderRec = extern struct { name: RocBytes, value: RocBytes };
/// A Roc `List(Chat.Header)`, read by the host, never made by it.
pub const HeaderList = extern struct {
    ptr: ?[*]HeaderRec,
    length: usize,
    capacity_or_alloc_ptr: usize,

    fn slice(l: *const HeaderList) []const HeaderRec {
        const p = l.ptr orelse return &.{};
        return p[0..l.length];
    }
};
/// Chat.roc's `Answer`: the lists by name (`body`, `content_type`,
/// `headers`, `stream_holder`, `stream_key`), the U16, then the tags by
/// name. `stream_holder` is whose stream it is (the stream cap is per holder), and
/// empty but for a stream.
pub const Answer = extern struct {
    body: RocBytes,
    content_type: RocBytes,
    headers: HeaderList,
    stream_holder: RocBytes,
    stream_key: RocBytes,
    status: u16,
    allow: Method,
    kind: route.Kind,
    sniff: route.Sniff,
};
/// Host.roc's `read_body!` answer: `{ bytes : List(U8), status : [Answered, Read] }`.
pub const Got = extern struct { bytes: RocBytes, status: route.BodyStatus };

// ── the files' records ──────────────────────────────────────────────────────

/// Host.roc's `read!` and `read_at!` answer: `{ bytes : List(U8), status :
/// [Failed, Found, Missing] }`.
pub const ReadRec = extern struct { bytes: RocBytes, status: route.ReadStatus };
/// One of Host.roc's `list!` entries: `{ kind : [Dir, File, Other], name : List(U8) }`.
pub const EntryRec = extern struct { name: RocBytes, kind: route.EntryKind };
/// Host.roc's `list!` answer: `{ entries : List(...), status : [Failed, Found, Missing] }`.
pub const ListRec = extern struct { entries: EntryList, status: route.ReadStatus };
/// Host.roc's `read_stat!` answer: `{ mtime : I64, size : U64, status :
/// [Failed, Found, Missing] }`. **THE 8-BYTE FIELDS FIRST, BY NAME, THEN THE
/// TAG**: 24 bytes. A missing or failed stat's size and mtime are 0.
pub const StatRec = extern struct { mtime: i64, size: u64, status: route.ReadStatus };
/// Host.roc's `append!` answer: `{ size : U64, status : [Appended, Failed] }`.
pub const AppendedRec = extern struct { size: u64, status: route.AppendStatus };

/// A Roc list of `Rec`, each made of an `Item` by `rec`: its elements hold
/// a refcounted list, so it has the two-word header (count, refcount) a
/// `List(List(U8))` has.
fn RecList(comptime Rec: type, comptime Item: type, comptime rec: fn (Item) Rec) type {
    return extern struct {
        ptr: ?[*]Rec,
        length: usize,
        capacity_or_alloc_ptr: usize,

        fn from(items: []const Item) @This() {
            if (items.len == 0) return .{ .ptr = null, .length = 0, .capacity_or_alloc_ptr = 0 };
            const w = @sizeOf(usize);
            const base = roc.allocate(2 * w + items.len * @sizeOf(Rec), w);
            std.mem.writeInt(usize, base[0..w], items.len, .little);
            std.mem.writeInt(usize, base[w..][0..w], 1, .little);
            const elems: [*]Rec = @ptrCast(@alignCast(base + 2 * w));
            for (items, 0..) |it, k| elems[k] = rec(it);
            return .{ .ptr = elems, .length = items.len, .capacity_or_alloc_ptr = items.len << 1 };
        }
    };
}

pub const EntryList = RecList(EntryRec, route.Entry, struct {
    fn rec(it: route.Entry) EntryRec {
        return .{ .name = .from(it.name), .kind = it.kind };
    }
}.rec);

comptime {
    const w = @sizeOf(usize);
    std.debug.assert(@sizeOf(ReadRec) == 4 * w and @sizeOf(EntryRec) == 4 * w and @sizeOf(ListRec) == 4 * w);
    std.debug.assert(@sizeOf(StatRec) == 24 and @offsetOf(StatRec, "size") == 8 and @offsetOf(StatRec, "status") == 16);
    std.debug.assert(@sizeOf(AppendedRec) == 16 and @offsetOf(AppendedRec, "status") == 8);
}

comptime {
    const w = @sizeOf(usize);
    std.debug.assert(@sizeOf(ExchangedRec) == 5 * w and @offsetOf(ExchangedRec, "status") == 4 * w);
    std.debug.assert(@sizeOf(Request) == 9 * w and @offsetOf(Request, "path") == 5 * w and @sizeOf(HeaderRec) == 6 * w and @sizeOf(Answer) == 16 * w and @sizeOf(Got) == 4 * w);
    std.debug.assert(@offsetOf(Answer, "status") == 15 * w and @offsetOf(Answer, "sniff") == 15 * w + 4);
}

pub extern fn roc_chat_handle(req: Request) callconv(.c) Answer;

/// **THE HOSTED FUNCTIONS, AS A HOST ANSWERS THEM**: each one's Zig side,
/// named as Host.roc names it (a host declares `pub fn read_body`, for
/// `read_body!`), its context first. Made from a host's type at compile
/// time (`Host.of`, `Host.partly`), never by hand. Bytes handed in are the
/// call's, good until it ends; bytes handed back are the host's, copied
/// into the call by the seam.
const Table = struct {
    /// **AFTER THE HOST HAS ANSWERED, IT DOES NOTHING MORE** for the call
    /// (a body too big). The seam asks first (`ask`) and answers the Roc its
    /// "nothing done" without asking the host. A host that declares none is
    /// never dead.
    dead: *const fn (*anyopaque) bool,
    /// Host.read_body!: the body, read before the call, if it is at most
    /// `limit` bytes; null when it is longer and the host has answered (a
    /// 413).
    read_body: *const fn (*anyopaque, u64) ?[]const u8,
    /// Host.read_header!: a request header's values, by its name in any
    /// case, from the host's copy.
    read_header: *const fn (*anyopaque, []const u8) []const []const u8,
    /// Host.serve_script!: the script `name` of the chat client's bundles
    /// answered by the host, or `.missing` (nothing answered).
    serve_script: *const fn (*anyopaque, []const u8) route.ScriptServed,

    // The files (host/files.zig), each path relative to the data root.
    // **A FAILED ANSWER HAS FAILED THE REQUEST**, but `read_at`'s, a
    // cache's, which the host logs.

    /// Host.read!: the file's bytes, nothing there, or a failed read.
    read: *const fn (*anyopaque, []const u8) route.Read,
    /// Host.read_at!: at most `max` bytes from `offset`.
    read_at: *const fn (*anyopaque, []const u8, u64, u64) route.Read,
    /// Host.read_stat!: the file's size and last change.
    read_stat: *const fn (*anyopaque, []const u8) route.Stat,
    /// Host.list!: the folder's entries.
    list: *const fn (*anyopaque, []const u8) route.Listing,
    /// Host.write!: the file made to hold exactly `bytes`, atomically.
    write: *const fn (*anyopaque, []const u8, []const u8) route.Written,
    /// Host.append!: `bytes` at the file's end; its size after.
    append: *const fn (*anyopaque, []const u8, []const u8) route.Appended,
    /// Host.remove!: the file gone (one not there is gone already).
    remove: *const fn (*anyopaque, []const u8) route.Removed,

    // Sign-in (host/auth/, host/signin.zig). **THE ROC NEVER HOLDS THE
    // SIGNING KEY**: `sign` and `verify` use the host's.

    /// Host.read_query!: a query field's values, as written, from the
    /// host's copy of the target.
    read_query: *const fn (*anyopaque, []const u8) []const []const u8,
    /// Host.read_time!: the request's time, Unix seconds.
    read_time: *const fn (*anyopaque) i64,
    /// Host.random_bytes!: `n` bytes of the OS's entropy.
    random_bytes: *const fn (*anyopaque, u64) []const u8,
    /// Host.hash!: SHA-256 of the bytes.
    hash: *const fn (*anyopaque, []const u8) []const u8,
    /// Host.sign!: HMAC-SHA256 of the bytes under the site key.
    sign: *const fn (*anyopaque, []const u8) []const u8,
    /// Host.verify!: whether the MAC is the site key's for the bytes,
    /// compared in constant time.
    verify: *const fn (*anyopaque, []const u8, []const u8) route.Verified,
    /// Host.read_config!: a public setting, never a secret.
    read_config: *const fn (*anyopaque, route.ConfigName) []const u8,
    /// Host.publish!: a frame to every stream held on a key (host/bus.zig),
    /// the bytes copied.
    publish: *const fn (*anyopaque, []const u8, []const u8) void,
};

/// **WHAT ANSWERS THE HOSTED FUNCTIONS** during a call: a host's value and
/// its type's answers. There is one `roc_chat_` export of each, and a binary
/// holds several hosts (a server's, a test's), so the call's host is chosen
/// as the call begins (`decide`), never at link time.
pub const Host = struct {
    ctx: *anyopaque,
    table: *const Table,

    /// **EVERY HOSTED FUNCTION ANSWERED**: `ctx`'s type declares each of
    /// them (`pub`), or the build fails naming the one it lacks. A server's.
    pub fn of(ctx: anytype) Host {
        return .{ .ctx = ctx, .table = &Answers(&.{@TypeOf(ctx.*)}, @TypeOf(ctx), true).table };
    }

    /// **WHAT `by` ANSWERS, AND A PANIC FOR THE REST** (a test's host): each
    /// function from the first type in `by` that declares it, taking `ctx`
    /// first. One none declares panics, naming it, when the Roc asks for it.
    pub fn partly(comptime by: []const type, ctx: anytype) Host {
        return .{ .ctx = ctx, .table = &Answers(by, @TypeOf(ctx), false).table };
    }

    fn dead(h: Host) bool {
        return h.table.dead(h.ctx);
    }

    fn call(h: Host, comptime name: []const u8, args: anytype) Returns(name) {
        return @call(.auto, @field(h.table, name), .{h.ctx} ++ args);
    }
};

/// What hosted function `name` answers.
fn Returns(comptime name: []const u8) type {
    return @typeInfo(@typeInfo(@FieldType(Table, name)).pointer.child).@"fn".return_type.?;
}

/// The table of `by`'s answers for a context of type `Ctx`, made once.
fn Answers(comptime by: []const type, comptime Ctx: type, comptime whole: bool) type {
    return struct {
        const table: Table = blk: {
            var t: Table = undefined;
            for (@typeInfo(Table).@"struct".field_names) |name| @field(t, name) = answerOf(by, Ctx, whole, name);
            break :blk t;
        };
    };
}

/// The first type in `by` that declares `name`, or null.
fn answering(comptime by: []const type, comptime name: []const u8) ?type {
    for (by) |H| if (@hasDecl(H, name)) return H;
    return null;
}

/// **A HOST'S FUNCTION IS THE TABLE'S EXACTLY**: its context, then the
/// table's arguments and answer, type for type; never one Zig would coerce
/// (a u32 where the Roc hands a u64).
fn answerOf(
    comptime by: []const type,
    comptime Ctx: type,
    comptime whole: bool,
    comptime name: []const u8,
) @FieldType(Table, name) {
    const want = @typeInfo(@typeInfo(@FieldType(Table, name)).pointer.child).@"fn";
    const R = want.return_type.?;
    const A = want.param_types;
    const H = answering(by, name);
    const never_dead = std.mem.eql(u8, name, "dead");
    if (H == null and whole and !never_dead) @compileError(@typeName(by[0]) ++ " answers no " ++ name ++ " (a `pub fn " ++ name ++ "`, as Host.roc names it)");
    if (H) |T| {
        const has = @typeInfo(@TypeOf(@field(T, name))).@"fn";
        var same = has.param_types.len == A.len and has.param_types[0].? == Ctx and has.return_type.? == R;
        if (same) for (A[1..], has.param_types[1..]) |a, g| {
            if (a.? != g.?) same = false;
        };
        if (!same) @compileError(@typeName(T) ++ "." ++ name ++ " is " ++ @typeName(@TypeOf(@field(T, name))) ++ "; the seam asks for " ++ @typeName(Ctx) ++ " then " ++ @typeName(@typeInfo(@FieldType(Table, name)).pointer.child));
    }
    const S = struct {
        fn go(ctx: *anyopaque, args: anytype) R {
            if (H) |T| {
                return @call(.auto, @field(T, name), .{@as(Ctx, @ptrCast(@alignCast(ctx)))} ++ args);
            } else if (never_dead) {
                return false;
            } else @panic(name ++ " asked of " ++ @typeName(by[0]) ++ ", which does not answer it");
        }
        fn f0(ctx: *anyopaque) R {
            return go(ctx, .{});
        }
        fn f1(ctx: *anyopaque, a: A[1].?) R {
            return go(ctx, .{a});
        }
        fn f2(ctx: *anyopaque, a: A[1].?, b: A[2].?) R {
            return go(ctx, .{ a, b });
        }
        fn f3(ctx: *anyopaque, a: A[1].?, b: A[2].?, c: A[3].?) R {
            return go(ctx, .{ a, b, c });
        }
    };
    return switch (A.len) {
        1 => S.f0,
        2 => S.f1,
        3 => S.f2,
        4 => S.f3,
        else => @compileError(name ++ ": a hosted function of more than three arguments"),
    };
}

// **EVERY HOSTED FUNCTION IS ONE NAME**: Host.roc's, the export's
// (`roc_chat_` and it) and the host's, but `dead`, which is the host's alone.
comptime {
    for (@typeInfo(Table).@"struct".field_names) |name| {
        const host_only = std.mem.eql(u8, name, "dead");
        if (!host_only and !@hasDecl(@This(), "roc_chat_" ++ name)) @compileError("the hosted function `" ++ name ++ "` has no export roc_chat_" ++ name);
    }
}

var host: ?Host = null;

/// The call's host, or a panic for a hosted function Roc ran outside one.
fn current(comptime name: []const u8) Host {
    if (!roc.inCall()) @panic("roc_chat_" ++ name ++ ": Roc asked outside a call");
    return host orelse @panic("roc_chat_" ++ name ++ ": Roc asked outside a call (chat_abi.decide sets it)");
}

/// **ONCE THE HOST IS DEAD, NOTHING MORE IS ASKED OF IT** (Table.dead): the
/// call's host answering `name`, or `nothing`, the Roc's "nothing done"
/// for it, without asking the host.
fn ask(comptime name: []const u8, nothing: Returns(name), args: anytype) Returns(name) {
    const h = current(name);
    return if (h.dead()) nothing else h.call(name, args);
}

pub export fn roc_chat_read_body(limit: u64) callconv(.c) Got {
    const b = ask("read_body", null, .{limit}) orelse return .{ .bytes = .from(""), .status = .answered };
    return .{ .bytes = .from(b), .status = .read };
}

pub export fn roc_chat_read_header(name: RocBytes) callconv(.c) roc.RocBytesList {
    return .from(ask("read_header", &.{}, .{name.slice()}));
}

pub export fn roc_chat_serve_script(name: RocBytes) callconv(.c) route.ScriptServed {
    return ask("serve_script", .missing, .{name.slice()});
}

// ── the files ──────────────────────────────────────────────────────────────

fn readRec(r: route.Read) ReadRec {
    return switch (r) {
        .found => |b| .{ .bytes = .from(b), .status = .found },
        .missing => .{ .bytes = .from(""), .status = .missing },
        .failed => .{ .bytes = .from(""), .status = .failed },
    };
}

pub export fn roc_chat_read(path: RocBytes) callconv(.c) ReadRec {
    return readRec(ask("read", .failed, .{path.slice()}));
}

/// **NEVER MORE THAN `max`**: a host that hands back more is cut to it
/// here, so the Roc's window is the window it asked for.
pub export fn roc_chat_read_at(path: RocBytes, offset: u64, max: u64) callconv(.c) ReadRec {
    return readRec(switch (ask("read_at", .failed, .{ path.slice(), offset, max })) {
        .found => |b| .{ .found = b[0..@min(b.len, max)] },
        else => |r| r,
    });
}

pub export fn roc_chat_read_stat(path: RocBytes) callconv(.c) StatRec {
    return switch (ask("read_stat", .failed, .{path.slice()})) {
        .found => |st| .{ .mtime = st.mtime, .size = st.size, .status = .found },
        .missing => .{ .mtime = 0, .size = 0, .status = .missing },
        .failed => .{ .mtime = 0, .size = 0, .status = .failed },
    };
}

pub export fn roc_chat_list(path: RocBytes) callconv(.c) ListRec {
    return switch (ask("list", .failed, .{path.slice()})) {
        .found => |entries| .{ .entries = .from(entries), .status = .found },
        .missing => .{ .entries = .from(&.{}), .status = .missing },
        .failed => .{ .entries = .from(&.{}), .status = .failed },
    };
}

pub export fn roc_chat_write(path: RocBytes, bytes: RocBytes) callconv(.c) route.Written {
    return ask("write", .failed, .{ path.slice(), bytes.slice() });
}

pub export fn roc_chat_append(path: RocBytes, bytes: RocBytes) callconv(.c) AppendedRec {
    return switch (ask("append", .failed, .{ path.slice(), bytes.slice() })) {
        .appended => |size| .{ .size = size, .status = .appended },
        .failed => .{ .size = 0, .status = .failed },
    };
}

pub export fn roc_chat_remove(path: RocBytes) callconv(.c) route.Removed {
    return ask("remove", .failed, .{path.slice()});
}

// ── sign-in ────────────────────────────────────────────────────────────────

pub export fn roc_chat_read_query(name: RocBytes) callconv(.c) roc.RocBytesList {
    return .from(ask("read_query", &.{}, .{name.slice()}));
}

pub export fn roc_chat_read_time() callconv(.c) i64 {
    return ask("read_time", 0, .{});
}

pub export fn roc_chat_random_bytes(n: u64) callconv(.c) RocBytes {
    return .from(ask("random_bytes", "", .{n}));
}

pub export fn roc_chat_hash(bytes: RocBytes) callconv(.c) RocBytes {
    return .from(ask("hash", "", .{bytes.slice()}));
}

pub export fn roc_chat_sign(bytes: RocBytes) callconv(.c) RocBytes {
    return .from(ask("sign", "", .{bytes.slice()}));
}

pub export fn roc_chat_verify(bytes: RocBytes, mac: RocBytes) callconv(.c) route.Verified {
    return ask("verify", .invalid, .{ bytes.slice(), mac.slice() });
}

pub export fn roc_chat_read_config(name: route.ConfigName) callconv(.c) RocBytes {
    return .from(ask("read_config", "", .{name}));
}

pub export fn roc_chat_publish(key: RocBytes, frame: RocBytes) callconv(.c) void {
    ask("publish", {}, .{ key.slice(), frame.slice() });
}

// ── a crash is a 500 ────────────────────────────────────────────────────────

/// **A ROC CRASH ENDS THE CALL, NOT THE SERVER**: a Roc `crash`, an
/// overflow or a failed allocation calls `roc_crashed`, which, inside a
/// call, jumps back to where the call began (`guarded`), so `decide`
/// answers `error.RocCrashed` and the host a 500. What Roc held is the
/// request's arena, dropped with it.
var jump: sljmp.JmpBuf = undefined;

/// The last crash's message, for a test or a log (cut to its size).
pub var last_crash: [256]u8 = undefined;
pub var last_crash_len: usize = 0;

fn crashed(message: []const u8) noreturn {
    last_crash_len = @min(message.len, last_crash.len);
    @memcpy(last_crash[0..last_crash_len], message[0..last_crash_len]);
    sljmp.longjmp(&jump, 1);
}

/// The call, or false when Roc crashed inside it. Nothing of this frame is
/// read after the jump back but what `setjmp` answers: the answer is
/// written through `out` only on the way that returns normally. The
/// request's bytes are made here, after `setjmp`: they are the call's
/// first allocations, and one that fails must jump back to this frame.
noinline fn guarded(path: []const u8, method: Method, exchanged: route.Exchanged, out: *Answer) bool {
    if (sljmp.setjmp(&jump) != 0) {
        guard_top = 0;
        return false;
    }
    guard_top = @frameAddress();
    out.* = roc_chat_handle(.{ .exchanged = .of(exchanged), .path = .from(path), .method = method });
    guard_top = 0;
    return true;
}

// ── a stack overflow is a crash too ─────────────────────────────────────────

/// **A RECURSION PAST THE STACK IS THE CALL'S CRASH**: it calls no
/// `roc_crashed`; it faults on the thread stack's guard page, a SIGSEGV,
/// which would end the process. So a handler (`onFault`, on the thread's
/// signal stack, which std gives each thread it starts) takes a fault on
/// the guarded call's own stack, below where the call began, for the call's
/// crash, and jumps back as `crashed` does. Any other fault, in the call or
/// not, goes to what handled it before (std's, which says where and stops).
/// `SA.NODEFER`: the jump leaves the handler without a sigreturn, and
/// SIGSEGV must not stay blocked after it.
const posix = std.posix;

/// Where the guarded call's frame is, on the thread it runs on; 0 when no
/// call is guarded on this thread.
threadlocal var guard_top: usize = 0;

/// How far below `guard_top` a fault is the call's stack: the stack std
/// gives a thread (`default_stack_size`; the host sets no other) and its
/// guard page beneath. **NO WIDER**: a fault further down is not this
/// stack's overflow but a wild address (another thread's guard page, an
/// unmapped hole), memory gone wrong, which must stop the process, never
/// be answered as a 500 and served on from.
const stack_most = std.Thread.SpawnConfig.default_stack_size + std.heap.page_size_max;

const overflow_message = "the stack overflowed (a recursion too deep)";

var fault_handled = false;
var fault_before: posix.Sigaction = undefined;

/// The handler, put in place as the first call begins (a call at a time:
/// `roc.enter`).
fn handleFaults() void {
    if (fault_handled) return;
    fault_handled = true;
    const act: posix.Sigaction = .{
        .handler = .{ .sigaction = onFault },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO | posix.SA.ONSTACK | posix.SA.NODEFER,
    };
    posix.sigaction(.SEGV, &act, &fault_before);
}

fn onFault(sig: posix.SIG, info: *const posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = ctx;
    const at = @intFromPtr(info.fields.sigfault.addr);
    const top = guard_top;
    if (top != 0 and at < top and top - at <= stack_most) {
        guard_top = 0;
        crashed(overflow_message);
    }
    // Not the call's stack: the handler before is put back, and the fault,
    // run again as this returns, is its.
    posix.sigaction(.SEGV, &fault_before, null);
}

/// The router's decision for `path` asked with `method` (and, on a second
/// call, what GitHub's exchange came to: `exchanged`), Roc's memory and
/// the decision's bytes both in `alloc` (the request's arena), the Roc call
/// ended. A Roc crash is `error.RocCrashed`; a call inside or beside
/// another, `error.RocReentered`.
pub fn decide(alloc: std.mem.Allocator, path: []const u8, method: std.http.Method, exchanged: route.Exchanged, with: Host) !Decision {
    try roc.enter();
    defer roc.leave();
    roc.useRequest(alloc);
    defer roc.done();
    host = with;
    defer host = null;
    const was = roc.crashed;
    roc.crashed = crashed;
    defer roc.crashed = was;
    handleFaults();
    var a: Answer = undefined;
    if (!guarded(path, .of(method), exchanged, &a)) return error.RocCrashed;
    return switch (a.kind) {
        .respond => .{ .respond = .{
            .status = a.status,
            .content_type = try alloc.dupe(u8, a.content_type.slice()),
            .body = try alloc.dupe(u8, a.body.slice()),
            .nosniff = a.sniff == .forbid,
            .headers = try headersOf(alloc, a.headers),
        } },
        .not_allowed => .{
            .not_allowed = switch (a.allow) {
                .get => .GET,
                .head => .HEAD,
                .post => .POST,
                // The Roc's bug, the request's 500, never a panic.
                .other => return error.NotAllowedNoMethod,
            },
        },
        .answered => .answered,
        .not_found => .not_found,
        // The code is GitHub's (GitHubSignIn.is_code held it to letters,
        // digits, `-` and `_`); the body carries it.
        .exchange => .{ .exchange = try alloc.dupe(u8, a.body.slice()) },
        .stream => .{
            .stream = .{
                .key = try alloc.dupe(u8, a.stream_key.slice()),
                // Longer than the slots keep is the Roc's bug, the request's 500.
                .holder = if (a.stream_holder.slice().len > route.holder_most) return error.StreamHolderTooLong else try alloc.dupe(u8, a.stream_holder.slice()),
                .backlog = try alloc.dupe(u8, a.body.slice()),
            },
        },
    };
}

fn headersOf(alloc: std.mem.Allocator, list: HeaderList) ![]const Header {
    const recs = list.slice();
    const out = try alloc.alloc(Header, recs.len);
    for (recs, out) |r, *h| h.* = .{
        .name = try alloc.dupe(u8, r.name.slice()),
        .value = try alloc.dupe(u8, r.value.slice()),
    };
    return out;
}
