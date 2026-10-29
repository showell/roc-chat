//! **ROC GLUE HOLDS EVERY SEAM RECORD**: each `roc_chat_` function `roc
//! glue` declares (Host.roc's hosted functions, and `roc_chat_handle`, the
//! app's entry) is held at compile time to chat_abi.zig's function of that
//! symbol, argument by argument and the answer: a record field by field by
//! name (its offset, and what it holds, down through records and lists), a
//! list by its element, a tag union tag by tag by number, a number by its
//! type. Two same-sized fields swapped in a hand-laid record pass its size
//! asserts and fail here, naming the function, the path to the field, and
//! both offsets.
//!
//! **MATCHED BY SIGNATURE, NEVER BY GLUE'S NAMES**: glue names an anonymous
//! record by a hash that changes when the record does, so a record is reached
//! through the hosted symbol's parameter or answer, never named. Nothing is
//! replaced: the hand-laid records stay the seam (the request's arena, where
//! glue's model is per-argument refcounts), and this says whether glue agrees.
//!
//! **NOTHING IS SKIPPED**: a function either side has and the other has not
//! fails the build. A hosted function added to Host.roc and to chat_abi.zig
//! fails here until the snapshot is regenerated, and is then checked like the
//! rest. glue/chat_platform_abi.zig is glue's output, `zig fmt`ed:
//!
//!     shale tools/chat_glue.shale

const std = @import("std");
const abi = @import("chat_abi.zig");
const route = @import("chat_route.zig");
const glue = @import("glue/chat_platform_abi.zig");

/// The seam's symbols: each function of `M` named `roc_chat_...` (in
/// chat_abi.zig, the `pub` ones, which is every one of the seam's).
fn seamNames(comptime M: type) []const []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var names: []const []const u8 = &.{};
        for (@typeInfo(M).@"struct".decl_names) |n| {
            if (std.mem.startsWith(u8, n, "roc_chat_") and @typeInfo(@TypeOf(@field(M, n))) == .@"fn")
                names = names ++ &[_][]const u8{n};
        }
        return names;
    }
}

const glue_names = seamNames(glue);
const abi_names = seamNames(abi);

fn has(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Why chat_abi.zig's `Want` is not laid out as roc glue's `Got`, at `at` (a
/// path from the function: `.field`, `[]` for a list's element), or null
/// when they agree.
fn mismatch(comptime Want: type, comptime Got: type, comptime at: []const u8) ?[]const u8 {
    @setEvalBranchQuota(1_000_000);
    return switch (@typeInfo(Got)) {
        .@"struct" => if (@hasField(Got, "elements_ptr"))
            listMismatch(Want, Got, at)
        else
            recordMismatch(Want, Got, at),
        .@"enum" => tagsMismatch(Want, Got, at),
        else => if (Want == Got) null else at ++ ": " ++ @typeName(Want) ++ " in chat_abi.zig, " ++ @typeName(Got) ++ " in roc glue",
    };
}

/// A Roc list as chat_abi.zig lays one out: an extern struct of three words,
/// the elements' pointer, the length and the capacity.
fn isList(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct" or info.@"struct".layout != .@"extern") return false;
    const s = info.@"struct";
    if (s.field_names.len != 3) return false;
    const P = s.field_types[0];
    if (@typeInfo(P) != .optional or @typeInfo(@typeInfo(P).optional.child) != .pointer) return false;
    return std.mem.eql(u8, s.field_names[1], "length") and s.field_types[1] == usize and
        std.mem.eql(u8, s.field_names[2], "capacity_or_alloc_ptr") and s.field_types[2] == usize;
}

fn elementOf(comptime List: type) type {
    return @typeInfo(@typeInfo(@typeInfo(List).@"struct".field_types[0]).optional.child).pointer.child;
}

fn listMismatch(comptime Want: type, comptime Got: type, comptime at: []const u8) ?[]const u8 {
    if (!isList(Want)) return at ++ ": a List in roc glue, " ++ @typeName(Want) ++ " in chat_abi.zig";
    if (@sizeOf(Want) != @sizeOf(Got) or @offsetOf(Want, "length") != @offsetOf(Got, "length") or
        @offsetOf(Want, "capacity_or_alloc_ptr") != @offsetOf(Got, "capacity_or_alloc_ptr"))
        return at ++ ": " ++ @typeName(Want) ++ " is no list as roc glue lays one out";
    return mismatch(elementOf(Want), elementOf(Got), at ++ "[]");
}

fn recordMismatch(comptime Want: type, comptime Got: type, comptime at: []const u8) ?[]const u8 {
    const info = @typeInfo(Want);
    if (info != .@"struct" or info.@"struct".layout != .@"extern")
        return at ++ ": a record in roc glue, " ++ @typeName(Want) ++ " in chat_abi.zig, no extern struct";
    const got = @typeInfo(Got).@"struct";
    for (got.field_names, got.field_types) |name, G| {
        const here = at ++ "." ++ name;
        if (!@hasField(Want, name)) return here ++ ": in roc glue, not in " ++ @typeName(Want);
        if (@offsetOf(Want, name) != @offsetOf(Got, name)) return std.fmt.comptimePrint(
            "{s}: at byte {d} of {s}, at byte {d} in roc glue",
            .{ here, @offsetOf(Want, name), @typeName(Want), @offsetOf(Got, name) },
        );
        if (mismatch(@FieldType(Want, name), G, here)) |m| return m;
    }
    for (info.@"struct".field_names) |name| {
        if (!@hasField(Got, name)) return at ++ "." ++ name ++ ": in " ++ @typeName(Want) ++ ", not in roc glue";
    }
    if (@sizeOf(Want) != @sizeOf(Got) or @alignOf(Want) != @alignOf(Got)) return std.fmt.comptimePrint(
        "{s}: {s} is {d} bytes aligned to {d}, roc glue's {d} aligned to {d}",
        .{ at, @typeName(Want), @sizeOf(Want), @alignOf(Want), @sizeOf(Got), @alignOf(Got) },
    );
    return null;
}

/// The tag of `Want` that is Roc's tag `glue_name`, or null. **NAMES MATCH
/// WITHOUT THEIR UNDERSCORES**: glue snake-cases `NotAUid` as `not_auid`,
/// the seam as `not_a_uid`.
fn tagNamed(comptime Want: type, comptime glue_name: []const u8) ?[:0]const u8 {
    for (@typeInfo(Want).@"enum".field_names) |name| {
        if (std.mem.eql(u8, bare(name), bare(glue_name))) return name;
    }
    return null;
}

fn bare(comptime name: []const u8) []const u8 {
    var out: []const u8 = "";
    for (name) |c| {
        if (c != '_') out = out ++ &[_]u8{c};
    }
    return out;
}

/// Tag by tag, by number.
fn tagsMismatch(comptime Want: type, comptime Got: type, comptime at: []const u8) ?[]const u8 {
    if (@typeInfo(Want) != .@"enum") return at ++ ": tags in roc glue, " ++ @typeName(Want) ++ " in chat_abi.zig";
    if (@sizeOf(Want) != @sizeOf(Got)) return at ++ ": " ++ @typeName(Want) ++ " is not roc glue's size";
    const got = @typeInfo(Got).@"enum";
    for (got.field_names, got.field_values) |glue_name, value| {
        const name = tagNamed(Want, glue_name) orelse
            return at ++ ": the tag `" ++ glue_name ++ "` is roc glue's, not " ++ @typeName(Want) ++ "'s";
        if (@backingInt(@field(Want, name)) != value) return std.fmt.comptimePrint(
            "{s}: the tag `{s}` is {d} in {s}, {d} in roc glue",
            .{ at, name, @backingInt(@field(Want, name)), @typeName(Want), value },
        );
    }
    if (@typeInfo(Want).@"enum".field_names.len != got.field_names.len)
        return at ++ ": " ++ @typeName(Want) ++ " has tags roc glue has not";
    return null;
}

/// Symbol `name`'s two declarations, argument by argument, then the answer.
fn fnMismatch(comptime name: []const u8) ?[]const u8 {
    if (!@hasDecl(abi, name)) return name ++ ": roc glue declares it, chat_abi.zig has no `pub` function of the name";
    const want = @typeInfo(@TypeOf(@field(abi, name))).@"fn";
    const got = @typeInfo(@TypeOf(@field(glue, name))).@"fn";
    if (want.param_types.len != got.param_types.len) return std.fmt.comptimePrint(
        "{s}: {d} arguments in chat_abi.zig, {d} in roc glue",
        .{ name, want.param_types.len, got.param_types.len },
    );
    for (want.param_types, got.param_types, 0..) |W, G, i| {
        if (mismatch(W.?, G.?, std.fmt.comptimePrint("{s} argument {d}", .{ name, i }))) |m| return m;
    }
    return mismatch(want.return_type.?, got.return_type.?, name ++ "'s answer");
}

comptime {
    @setEvalBranchQuota(1_000_000);
    if (abi_names.len == 0) @compileError("chat_abi.zig has no `pub` roc_chat_ function: the seam's must be `pub` for this check to list them");
    for (abi_names) |n| {
        if (!has(glue_names, n)) @compileError(n ++ ": chat_abi.zig has it, the roc glue snapshot has not; regenerate it: shale tools/chat_glue.shale");
    }
    for (glue_names) |n| {
        if (fnMismatch(n)) |m| @compileError("roc glue lays the seam out unlike chat_abi.zig: " ++ m);
    }
}

fn answerOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "roc glue declares every function chat_abi.zig has, and no other" {
    try std.testing.expectEqual(abi_names.len, glue_names.len);
    try std.testing.expectEqual(19, abi_names.len);
}

test "a field swap fails the check, naming the function, the field and the offsets" {
    // The answer's two first lists exchanged, the size the same.
    const Swapped = extern struct {
        content_type: abi.RocBytes,
        body: abi.RocBytes,
        headers: abi.HeaderList,
        status: u16,
        allow: route.Method,
        kind: route.Kind,
        sniff: route.Sniff,
    };
    const m = comptime mismatch(Swapped, answerOf(glue.roc_chat_handle), "roc_chat_handle's answer").?;
    try std.testing.expect(contains(m, "roc_chat_handle's answer.body: at byte 24 of "));
    try std.testing.expect(contains(m, "at byte 0 in roc glue"));
    // Inside a list's element: a header's name and value exchanged.
    const HeaderSwapped = extern struct { value: abi.RocBytes, name: abi.RocBytes };
    const Headers = extern struct { ptr: ?[*]HeaderSwapped, length: usize, capacity_or_alloc_ptr: usize };
    const Answer = extern struct {
        body: abi.RocBytes,
        content_type: abi.RocBytes,
        headers: Headers,
        status: u16,
        allow: route.Method,
        kind: route.Kind,
        sniff: route.Sniff,
    };
    const n = comptime mismatch(Answer, answerOf(glue.roc_chat_handle), "answer").?;
    try std.testing.expect(contains(n, "answer.headers[].name: at byte 24 of "));
    // Two tags renumbered.
    const Renumbered = enum(u8) { read, answered };
    const Got = extern struct { bytes: abi.RocBytes, status: Renumbered };
    const t = comptime mismatch(Got, answerOf(glue.roc_chat_read_body), "answer").?;
    try std.testing.expect(contains(t, "the tag `answered` is 1 in "));
}
