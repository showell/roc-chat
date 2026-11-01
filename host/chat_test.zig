//! **THE CHAT'S OWN ROUTES, BY THE HOST'S HARNESS** (host/test_http.zig): a
//! server on a port of its own with the chat's Roc linked, no sign-in, and
//! clients that speak HTTP by hand. Sign-in is host/signin_test.zig's, and
//! a conversation signed in end to end is host/e2e.zig's (`zig build e2e`).

const std = @import("std");
const h = @import("test_http.zig");

const gpa = h.gpa;
const Running = h.Running;
const Response = h.Response;
const exchange = h.exchange;
const has = h.has;

test "GET / is the Roc's hello page, saying nobody is signed in, with the Roc's own cache-control header" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try Running.start(.{});
    defer r.stop();
    const got = try Response.of(try exchange(arena.allocator(), r.port(), "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(200, got.status);
    try std.testing.expect(has(got.body, "You're not signed in. <a href=/login>Sign in with GitHub</a>."));
    try std.testing.expectEqualStrings("no-store", got.header("cache-control").?);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", got.header("content-type").?);
    try std.testing.expectEqual(1, r.turns());
}

test "a topic, or a channel's list of them, asked of nobody signed in is a 401; a page, a 303 to /login; a method its route does not take, a 405; a path that is none, the conversation kind's included, a 404" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    const signed_out = try Response.of(try exchange(a, r.port(), "GET /channels/Lobby/topics/ChitChat HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(401, signed_out.status);
    const posted = try Response.of(try exchange(a, r.port(), "POST /channels/Lobby/topics/ChitChat/messages HTTP/1.1\r\nhost: t\r\ncontent-length: 2\r\nconnection: close\r\n\r\nhi"));
    try std.testing.expectEqual(401, posted.status);
    const listed = try Response.of(try exchange(a, r.port(), "GET /channels/Lobby/topics HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(401, listed.status);
    const wrong = try Response.of(try exchange(a, r.port(), "DELETE /channels/Lobby/topics/ChitChat/messages HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(405, wrong.status);
    try std.testing.expectEqualStrings("POST", wrong.header("allow").?);
    for ([_][]const u8{ "/chat", "/chat/channel/Lobby/ChitChat" }) |path| {
        const page = try Response.of(try exchange(a, r.port(), try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", .{path})));
        try std.testing.expectEqual(303, page.status);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "/login?next={s}", .{if (std.mem.eql(u8, path, "/chat")) "%2Fchat" else "%2Fchat%2Fchannel%2FLobby%2FChitChat"}), page.header("location").?);
    }
    for ([_][]const u8{ "/conversations", "/conversations/1", "/conversations/1/stream", "/chat/1", "/chat/1/stream", "/stub/notes", "/echo" }) |path| {
        const got = try Response.of(try exchange(a, r.port(), try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n", .{path})));
        try std.testing.expectEqual(404, got.status);
    }
}

test "a chat client script: a 200 with its ETag, then a 304 when the browser has those bytes; a script there is not, a 404" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try Running.start(.{});
    defer r.stop();
    const first = try Response.of(try exchange(a, r.port(), "GET /chat.js HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(200, first.status);
    try std.testing.expectEqualStrings("text/javascript; charset=utf-8", first.header("content-type").?);
    try std.testing.expect(first.body.len > 1000);
    const etag = first.header("etag").?;
    const again = try std.fmt.allocPrint(a, "GET /chat.js HTTP/1.1\r\nhost: t\r\nif-none-match: {s}\r\nconnection: close\r\n\r\n", .{etag});
    const second = try Response.of(try exchange(a, r.port(), again));
    try std.testing.expectEqual(304, second.status);
    try std.testing.expectEqual(0, second.body.len);
    const none = try Response.of(try exchange(a, r.port(), "GET /nope.js HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"));
    try std.testing.expectEqual(404, none.status);
}
