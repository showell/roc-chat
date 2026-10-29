//! The GitHub client against the fake GitHub, over localhost: each answer
//! the fake can give, and the client's typed failure for it.
const std = @import("std");
const Io = std.Io;
const github = @import("github");
const fake_github = @import("fake_github.zig");

const testing = std.testing;
const io = testing.io;

const creds: github.Credentials = .{ .client_id = fake_github.client_id, .client_secret = fake_github.client_secret };

fn config(fake: *fake_github.Fake) github.Config {
    return .{
        .oauth_base = fake.base(),
        .api_base = fake.base(),
        .user_agent = "roc-chat-test",
        .connect_timeout_ms = 1_000,
        .whole_timeout_ms = 400,
    };
}

fn msSince(t0: Io.Clock.Timestamp) i64 {
    return @intCast(@divTrunc(t0.untilNow(io).raw.nanoseconds, std.time.ns_per_ms));
}

test "a good code signs in: GitHub's id and login, and every request had a User-Agent" {
    const fake = try fake_github.Fake.start(io, testing.allocator);
    defer fake.stop();
    const who = try github.signIn(testing.allocator, io, config(fake), creds, "good");
    try testing.expectEqual(fake_github.user_id, who.id);
    try testing.expectEqualStrings(fake_github.user_login, who.login());
    try testing.expectEqual(@as(u32, 2), fake.requests.load(.acquire));
    try testing.expectEqual(@as(u32, 0), fake.without_user_agent.load(.acquire));
}

test "GitHub's no is Denied: a bad code, wrong client credentials, a revoked token, an empty code" {
    const fake = try fake_github.Fake.start(io, testing.allocator);
    defer fake.stop();
    try testing.expectError(error.Denied, github.signIn(testing.allocator, io, config(fake), creds, "bad"));
    const wrong: github.Credentials = .{ .client_id = fake_github.client_id, .client_secret = "fake secret" };
    try testing.expectError(error.Denied, github.signIn(testing.allocator, io, config(fake), wrong, "good"));
    try testing.expectError(error.Denied, github.signIn(testing.allocator, io, config(fake), creds, "user-revoked"));
    try testing.expectError(error.Denied, github.signIn(testing.allocator, io, config(fake), creds, ""));
}

test "a slow answer is a Timeout at the deadline, at either call" {
    const fake = try fake_github.Fake.start(io, testing.allocator);
    defer fake.stop();
    for ([_][]const u8{ "slow", "user-slow" }) |code| {
        const t0: Io.Clock.Timestamp = .now(io, .awake);
        try testing.expectError(error.Timeout, github.signIn(testing.allocator, io, config(fake), creds, code));
        const ms = msSince(t0);
        // The whole deadline is 400 ms; the fake would wait 30 s.
        try testing.expect(ms >= 350 and ms < 3_000);
    }
}

test "a malformed, an oversized or a header-breaking answer is a BadResponse" {
    const fake = try fake_github.Fake.start(io, testing.allocator);
    defer fake.stop();
    var cfg = config(fake);
    cfg.whole_timeout_ms = 5_000;
    for ([_][]const u8{ "malformed", "huge", "huge-chunked", "crlf-token", "user-malformed", "user-huge" }) |code| {
        _ = github.signIn(testing.allocator, io, cfg, creds, code) catch |e| {
            try testing.expectEqual(error.BadResponse, e);
            continue;
        };
        std.debug.print("code {s}: signed in\n", .{code});
        return error.TestExpectedError;
    }
}

test "the token is wiped after identify, whatever identify returned" {
    const fake = try fake_github.Fake.start(io, testing.allocator);
    defer fake.stop();
    var cfg = config(fake);
    cfg.whole_timeout_ms = 5_000;
    var s = try github.Session.init(testing.allocator, io, cfg);
    defer s.deinit();

    var token = try s.exchangeCode(creds, "good");
    try testing.expect(token.len > 0);
    _ = try s.identify(&token);
    try testing.expectEqual(@as(u8, 0), token.len);
    try testing.expect(std.mem.allEqual(u8, &token.buf, 0));

    var revoked = try s.exchangeCode(creds, "user-revoked");
    try testing.expectError(error.Denied, s.identify(&revoked));
    try testing.expectEqual(@as(u8, 0), revoked.len);
    try testing.expect(std.mem.allEqual(u8, &revoked.buf, 0));
}

test "nothing listening is Refused" {
    // A port just freed: bound, then closed.
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var l = try addr.listen(io, .{});
    const port = l.socket.address.getPort();
    l.deinit(io);
    var buf: [32]u8 = undefined;
    const base = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}", .{port});
    try testing.expectError(error.Refused, github.signIn(testing.allocator, io, .{ .oauth_base = base, .api_base = base }, creds, "good"));
}

test "a connect that never completes is a Timeout at the connect deadline, not the whole one" {
    // A listener whose accept queue is full drops the next SYN, so the
    // client's connect hangs: a backlog of 0, filled by one connect.
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", 0);
    var hole = try addr.listen(io, .{ .kernel_backlog = 0 });
    defer hole.deinit(io);
    const filler = try hole.socket.address.connect(io, .{ .mode = .stream });
    defer filler.close(io);

    var buf: [32]u8 = undefined;
    const base = try std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}", .{hole.socket.address.getPort()});
    const t0: Io.Clock.Timestamp = .now(io, .awake);
    try testing.expectError(error.Timeout, github.signIn(testing.allocator, io, .{
        .oauth_base = base,
        .api_base = base,
        .connect_timeout_ms = 200,
        .whole_timeout_ms = 10_000,
    }, creds, "good"));
    const ms = msSince(t0);
    try testing.expect(ms >= 150 and ms < 2_000);
}

test "a plain-HTTP base that is not a loopback literal is refused before any request" {
    try testing.expectError(error.BaseUrlRefused, github.signIn(testing.allocator, io, .{
        .oauth_base = "http://github.com",
    }, creds, "good"));
    try testing.expectError(error.BaseUrlRefused, github.signIn(testing.allocator, io, .{
        .api_base = "http://localhost:1",
    }, creds, "good"));
}
