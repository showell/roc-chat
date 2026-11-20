//! A shot list: one step a line, its first word the verb, the rest of the
//! line its argument, read whole (a selector or a script may hold spaces).
//! A blank line and a line starting `#` are nothing.
//!
//!   base http://localhost:9661   where `goto` and `cookie` point
//!   size 1280 800                the page's size, in CSS pixels
//!   cookie NAME=VALUE            a session cookie for `base`, Secure, HttpOnly
//!   goto /chat/dm/1_2/plans      load a page and wait for its load event
//!   click .sidebar .person-name  a real mouse click at the element's middle
//!   key ArrowUp                  a key pressed and let go: a name below, or one character
//!   type :sm                     text typed into what has the focus
//!   wait .person-popup           until the selector matches (5 s at most)
//!   eval localStorage.clear()    a script run in the page (a promise is awaited)
//!   shot dark-dm-person-card     the page as <out>/<name>.png
const std = @import("std");

pub const Verb = enum { base, size, cookie, goto, click, key, type, wait, eval, shot };

pub const Step = struct {
    verb: Verb,
    arg: []const u8,
    /// Its line in the list, for a stop to name.
    line: usize,
};

/// Every step of `text`, or the first line no verb starts, as `bad_line`.
pub fn parse(gpa: std.mem.Allocator, text: []const u8, bad_line: *usize) ![]Step {
    var out: std.ArrayList(Step) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const verb = std.meta.stringToEnum(Verb, line[0..space]) orelse {
            bad_line.* = n;
            return error.NoSuchVerb;
        };
        const arg = std.mem.trim(u8, line[space..], " \t");
        if (arg.len == 0) {
            bad_line.* = n;
            return error.NoArgument;
        }
        try out.append(gpa, .{ .verb = verb, .arg = arg, .line = n });
    }
    return out.toOwnedSlice(gpa);
}

/// A named key's code and Windows key code, which Chrome needs to act on
/// it as a real key (a page's keydown sees `key`; scrolling and focus see
/// the code). One character is not here: it is typed as text.
pub const NamedKey = struct { name: []const u8, vk: u8 };
pub const named_keys = [_]NamedKey{
    .{ .name = "Enter", .vk = 13 },
    .{ .name = "Escape", .vk = 27 },
    .{ .name = "Tab", .vk = 9 },
    .{ .name = "Backspace", .vk = 8 },
    .{ .name = "ArrowUp", .vk = 38 },
    .{ .name = "ArrowDown", .vk = 40 },
    .{ .name = "ArrowLeft", .vk = 37 },
    .{ .name = "ArrowRight", .vk = 39 },
    .{ .name = "Home", .vk = 36 },
    .{ .name = "End", .vk = 35 },
    .{ .name = "PageUp", .vk = 33 },
    .{ .name = "PageDown", .vk = 34 },
};

pub fn namedKey(name: []const u8) ?NamedKey {
    for (named_keys) |k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
}

test "a list's steps, its comments and blanks left out" {
    var bad: usize = 0;
    const steps = try parse(std.testing.allocator, "# a comment\n\nsize 390 844\nclick .a .b\n", &bad);
    defer std.testing.allocator.free(steps);
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqual(Verb.click, steps[1].verb);
    try std.testing.expectEqualStrings(".a .b", steps[1].arg);
    try std.testing.expectEqual(@as(usize, 4), steps[1].line);
}

test "a line no verb starts is named" {
    var bad: usize = 0;
    try std.testing.expectError(error.NoSuchVerb, parse(std.testing.allocator, "size 1 2\nclik .a\n", &bad));
    try std.testing.expectEqual(@as(usize, 2), bad);
}
