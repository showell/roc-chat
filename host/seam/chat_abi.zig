//! **THE ROC CHAT'S SIDE OF THE SEAM** (platform/): the records
//! `roc_chat_handle` takes and answers, laid out as Roc lays them (Roc's
//! field order; sizes asserted below, and every record held to roc glue's
//! by glue_test.zig), and the hosted functions (platform/Host.roc), each
//! answered by the call's `Host`. The runtime and the call's memory are
//! roc_abi.zig's.
//!
//! (From roc-webbox src/chat_abi.zig at 5a4314b: `Host.of`, `Host.partly`,
//! the table made from a host's type, the crash guard and `call`, kept
//! whole; the records and hosted functions cut to the three roc-chat's
//! platform has so far, and `Answer` given `headers`.)
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

/// Chat.roc's `Request`.
pub const Request = extern struct {
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
/// Chat.roc's `Answer`: the lists by name, the U16, then the tags by name.
pub const Answer = extern struct {
    body: RocBytes,
    content_type: RocBytes,
    headers: HeaderList,
    status: u16,
    allow: Method,
    kind: route.Kind,
    sniff: route.Sniff,
};
/// Host.roc's `read_body!` answer: `{ bytes : List(U8), status : [Answered, Read] }`.
pub const Got = extern struct { bytes: RocBytes, status: route.BodyStatus };

comptime {
    const w = @sizeOf(usize);
    std.debug.assert(@sizeOf(Request) == 4 * w and @sizeOf(HeaderRec) == 6 * w and @sizeOf(Answer) == 10 * w and @sizeOf(Got) == 4 * w);
    std.debug.assert(@offsetOf(Answer, "status") == 9 * w and @offsetOf(Answer, "sniff") == 9 * w + 4);
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
    };
    return switch (A.len) {
        1 => S.f0,
        2 => S.f1,
        3 => S.f2,
        else => @compileError(name ++ ": a hosted function of more than two arguments"),
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
noinline fn guarded(path: []const u8, method: Method, out: *Answer) bool {
    if (sljmp.setjmp(&jump) != 0) return false;
    out.* = roc_chat_handle(.{ .path = .from(path), .method = method });
    return true;
}

/// The router's decision for `path` asked with `method`, Roc's memory and
/// the decision's bytes both in `alloc` (the request's arena), the Roc call
/// ended. A Roc crash is `error.RocCrashed`; a call inside or beside
/// another, `error.RocReentered`.
pub fn decide(alloc: std.mem.Allocator, path: []const u8, method: std.http.Method, with: Host) !Decision {
    try roc.enter();
    defer roc.leave();
    roc.useRequest(alloc);
    defer roc.done();
    host = with;
    defer host = null;
    const was = roc.crashed;
    roc.crashed = crashed;
    defer roc.crashed = was;
    var a: Answer = undefined;
    if (!guarded(path, .of(method), &a)) return error.RocCrashed;
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
