//! **THE END TO END**: the real server, with the app linked, on a free
//! port of 127.0.0.1, on a task of this process, against a temporary data
//! root seeded from demo/data. Driven over HTTP, one step a line, timed:
//!
//!   1. GET the seeded conversation: exactly the demo's frozen page;
//!   2. POST a message to it: a 303 to its page;
//!   3. GET it again: the message is there;
//!   4. the transcript on disk: the seed and exactly one record more, dated
//!      by the host's clock;
//!   5. GET a DM's conversation with no transcript: the 404 page;
//!   6. POST to it: its transcript made, holding exactly the one record.
//!
//! The server stops and the data root goes before it returns, pass or
//! fail, so nothing is left running and nothing is left behind.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const files = @import("file_primitives.zig");

const seed_path = "demo/data/chat/channel/general/gopher-roc/transcript";
const frozen_page = "demo/gopher-roc.html";
const channel_url = "/chat/channel/general/gopher-roc";
const dm_url = "/chat/dm/1_1/plans";

const RunResult = @typeInfo(@TypeOf(http.Server.run)).@"fn".return_type.?;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const a = init.arena.allocator();
    const cwd = Io.Dir.cwd();
    const began = Io.Clock.now(.awake, io);

    var name_buf: [64]u8 = undefined;
    var random: [8]u8 = undefined;
    io.random(&random);
    const data_name = try std.fmt.bufPrint(&name_buf, ".zig-cache/end-to-end-{x}", .{std.mem.readInt(u64, &random, .little)});
    try cwd.createDirPath(io, data_name);
    defer cwd.deleteTree(io, data_name) catch |e| std.debug.print("end-to-end: {s} not removed ({t})\n", .{ data_name, e });
    const data = try cwd.openDir(io, data_name, .{});
    defer data.close(io);

    const seed = try cwd.readFileAlloc(io, seed_path, a, .limited(1024 * 1024));
    try data.createDirPath(io, std.fs.path.dirname(seed_path["demo/data/".len..]).?);
    try data.writeFile(io, .{ .sub_path = seed_path["demo/data/".len..], .data = seed });

    const root: files.DataRoot = .{ .io = io, .dir = data };
    var server = try http.Server.listen(io, gpa, 0, .{}, &root);
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch |e| std.debug.print("end-to-end: the server's run: {t}\n", .{e});
    }
    const port = server.port();
    const t: Steps = .{ .io = io, .began = began };

    // 1.
    const first = try get(a, io, port, channel_url);
    try t.check("GET the seeded conversation: 200, exactly the demo's frozen page", first.status == 200 and
        std.mem.eql(u8, first.body, try cwd.readFileAlloc(io, frozen_page, a, .limited(1024 * 1024))));

    // 2.
    const before = files.current_utc_seconds_since_epoch(io);
    const posted = try post(a, io, port, channel_url, "markdown=Hello+from+the+**end+to+end**%21%0D%0A%0D%0A-------------");
    const after = files.current_utc_seconds_since_epoch(io);
    try t.check("POST a message: 303 to the conversation's page", posted.status == 303 and
        std.mem.eql(u8, posted.header("location") orelse "", channel_url));

    // 3.
    const again = try get(a, io, port, channel_url);
    try t.check("GET it again: 200, the message rendered, as message 6", again.status == 200 and
        has(again.body, "<strong>end to end</strong>!") and has(again.body, "id=\"msg-6\"") and has(again.body, ">MSG_gopher-roc_6</a>"));

    // 4.
    const body = "Hello from the **end to end**!\n\n\\-------------";
    const on_disk = try data.readFileAlloc(io, seed_path["demo/data/".len..], a, .limited(1024 * 1024));
    try t.check("the file on disk: the seed and exactly one record, dated by the host's clock", recordFits(a, on_disk, seed, "gopher-roc_6", body, before, after));

    // 5.
    const missing = try get(a, io, port, dm_url);
    try t.check("GET a DM's conversation with no transcript: 404, saying so", missing.status == 404 and
        has(missing.body, "No such conversation: " ++ dm_url));

    // 6.
    const before_dm = files.current_utc_seconds_since_epoch(io);
    const started = try post(a, io, port, dm_url, "markdown=Note+to+self");
    const after_dm = files.current_utc_seconds_since_epoch(io);
    const dm_file = data.readFileAlloc(io, "chat/dm/1_1/plans/transcript", a, .limited(1024 * 1024)) catch "";
    try t.check("POST to it: 303, its transcript made, exactly one record", started.status == 303 and
        recordFits(a, dm_file, "", "plans_1", "Note to self", before_dm, after_dm));

    std.debug.print("end-to-end: every step passed, in {d} ms\n", .{began.untilNow(io, .awake).toMilliseconds()});
}

/// Each step said on its own line, with the time since the start; a step
/// that fails fails the run, naming it.
const Steps = struct {
    io: Io,
    began: Io.Timestamp,

    fn check(s: Steps, comptime what: []const u8, ok: bool) !void {
        const ms: u64 = @intCast(s.began.untilNow(s.io, .awake).toMilliseconds());
        std.debug.print("{s}  {d:>5} ms  " ++ what ++ "\n", .{ if (ok) "PASS" else "FAIL", ms });
        if (!ok) return error.EndToEndStepFailed;
    }
};

/// Whether `file` is `seed` and one record more, `MSG_<reference>`, by
/// Steve, its markdown `body`, dated a second from `from` to `to`.
fn recordFits(a: std.mem.Allocator, file: []const u8, seed: []const u8, reference: []const u8, body: []const u8, from: i64, to: i64) bool {
    var second = from;
    while (second <= to) : (second += 1) {
        const want = std.fmt.allocPrint(a, "{s}-------------\nMSG_{s}\nfrom: Steve\ndate: {f}\n\n{s}\n\n", .{ seed, reference, Iso{ .seconds = second }, body }) catch return false;
        if (std.mem.eql(u8, file, want)) return true;
    }
    return false;
}

/// A time as a transcript writes it, YYYY-MM-DDTHH:MM:SSZ: std's calendar,
/// a second opinion on app/DateTime.roc's.
const Iso = struct {
    seconds: i64,

    pub fn format(t: Iso, w: *Io.Writer) Io.Writer.Error!void {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(t.seconds) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            yd.year,
            md.month.numeric(),
            md.day_index + 1,
            ds.getHoursIntoDay(),
            ds.getMinutesIntoHour(),
            ds.getSecondsIntoMinute(),
        });
    }
};

const Response = struct {
    status: u16,
    head: []const u8,
    body: []const u8,

    fn header(r: Response, comptime name: []const u8) ?[]const u8 {
        const at = std.mem.indexOf(u8, r.head, "\r\n" ++ name ++ ": ") orelse return null;
        const from = at + name.len + 4;
        const to = std.mem.indexOfPos(u8, r.head, from, "\r\n") orelse return null;
        return r.head[from..to];
    }
};

fn get(a: std.mem.Allocator, io: Io, port: u16, comptime path: []const u8) !Response {
    return exchange(a, io, port, "GET " ++ path ++ " HTTP/1.1\r\nhost: localhost\r\n\r\n");
}

fn post(a: std.mem.Allocator, io: Io, port: u16, comptime path: []const u8, comptime form: []const u8) !Response {
    return exchange(a, io, port, std.fmt.comptimePrint("POST " ++ path ++ " HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/x-www-form-urlencoded\r\ncontent-length: {d}\r\n\r\n" ++ form, .{form.len}));
}

/// `request` on a connection of its own, and the response, read to the
/// close.
fn exchange(a: std.mem.Allocator, io: Io, port: u16, request: []const u8) !Response {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const connection = try addr.connect(io, .{ .mode = .stream });
    defer connection.close(io);
    var w = connection.writer(io, &.{});
    try w.interface.writeAll(request);
    var buf: [4096]u8 = undefined;
    var r = connection.reader(io, &buf);
    const bytes = try r.interface.allocRemaining(a, .limited(4 * 1024 * 1024));
    if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 ") or bytes.len < 12) return error.NotAResponse;
    const end = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return error.NoHeadEnd;
    return .{ .status = try std.fmt.parseInt(u16, bytes[9..12], 10), .head = bytes[0 .. end + 2], .body = bytes[end + 4 ..] };
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}
