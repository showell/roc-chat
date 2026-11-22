//! **THE COST CHECK** (`zig build cost-check`): what each request costs in
//! file calls, at two sizes of chat, held to the cost class its route
//! declares (app/RouteCost.roc).
//!
//! The real server runs in this process's task, twice: once on a data root
//! seeded with 10 humans, once with 300, each shaped alike (`seed`). For
//! every probe of app/route_cost_probes.txt, a line `<class> <who> <method>
//! <path>`, it asks once to warm the server (a human's first request tells
//! the others they came online, and a cache fills), then once more with the
//! data root's count of file calls cleared (`DataRoot.calls_for_test`), and
//! keeps the reads, listings and writes that request made, its head's
//! judgement and its answer both.
//!
//! A `Constant` probe must cost the same at both sizes; every other class
//! must cost more at 300 than at 10, so a class that is wrong either way
//! fails. Counts, not times, so a busy machine can't make it flaky.
//! app/RouteCostSpec.roc holds each probe's route to the class the line
//! names, so the two sides read one file.

const std = @import("std");
const Io = std.Io;
const http = @import("http.zig");
const files = @import("file_primitives.zig");

const probes_text = @embedFile("route_cost_probes");

/// The two sizes of chat, in humans.
const small = 10;
const big = 300;

/// The password both signed-in humans have, which no request checks.
const password = "cost check";

/// Each seeded invite's hash: the form of one, its code long gone.
const invite_hash: [64]u8 = @splat('a');

/// The topic every human may read, from the demo's seed.
const seed_path = "demo/data/chat/channel/general/roc-chat/transcript";

const Counts = struct {
    reads: u64,
    listings: u64,
    writes: u64,

    fn all(c: Counts) u64 {
        return c.reads + c.listings + c.writes;
    }

    pub fn format(c: Counts, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("{d}r {d}l {d}w", .{ c.reads, c.listings, c.writes });
    }
};

const Probe = struct {
    class: []const u8,
    who: enum { anyone, human },
    method: []const u8,
    path: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const a = init.arena.allocator();

    const probes = try readProbes(a);
    const hash = try passwordHash(a, io);
    const at_small = try measure(a, io, gpa, .{ .humans = small, .hash = hash, .probes = probes });
    const at_big = try measure(a, io, gpa, .{ .humans = big, .hash = hash, .probes = probes });

    var wrong: usize = 0;
    for (probes, at_small, at_big) |probe, s, b| {
        const ok = if (std.mem.eql(u8, probe.class, "Constant")) std.meta.eql(s, b) else b.all() > s.all();
        if (!ok) wrong += 1;
        std.debug.print("{s}  {s:<16} {s:<4} {s:<40} at {d}: {f:<16} at {d}: {f}\n", .{ if (ok) "PASS" else "FAIL", probe.class, probe.method, probe.path, small, s, big, b });
    }
    if (wrong > 0) {
        std.debug.print("cost-check: {d} of {d} probes cost other than their class says\n", .{ wrong, probes.len });
        return error.CostCheckFailed;
    }
    std.debug.print("cost-check: every probe costs as its class says, {d} probes\n", .{probes.len});
}

fn readProbes(a: std.mem.Allocator) ![]const Probe {
    var out: std.ArrayList(Probe) = .empty;
    var lines = std.mem.splitScalar(u8, probes_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const class = words.next() orelse return error.BadProbe;
        const who = words.next() orelse return error.BadProbe;
        const method = words.next() orelse return error.BadProbe;
        const path = words.next() orelse return error.BadProbe;
        if (words.next() != null) return error.BadProbe;
        try out.append(a, .{
            .class = class,
            .who = std.meta.stringToEnum(@FieldType(Probe, "who"), who) orelse return error.BadProbe,
            .method = method,
            .path = path,
        });
    }
    return out.items;
}

/// A bcrypt hash of `password`, as `roc-chat hash-password` writes one.
fn passwordHash(a: std.mem.Allocator, io: Io) ![]const u8 {
    var salt: [std.crypto.pwhash.bcrypt.salt_length]u8 = undefined;
    io.random(&salt);
    const buf = try a.alloc(u8, 60);
    return std.crypto.pwhash.bcrypt.strHashWithSalt(password, .{
        .params = .{ .rounds_log = 10, .silently_truncate_password = false },
        .encoding = .crypt,
    }, buf[0..60], salt);
}

const Size = struct { humans: u32, hash: []const u8, probes: []const Probe };

/// Each probe's counts on a server whose data root holds `size.humans`.
fn measure(a: std.mem.Allocator, io: Io, gpa: std.mem.Allocator, size: Size) ![]const Counts {
    const cwd = Io.Dir.cwd();
    var name_buf: [64]u8 = undefined;
    var random: [8]u8 = undefined;
    io.random(&random);
    const data_name = try std.fmt.bufPrint(&name_buf, ".zig-cache/cost-check-{x}", .{std.mem.readInt(u64, &random, .little)});
    try cwd.createDirPath(io, data_name);
    defer cwd.deleteTree(io, data_name) catch |e| std.debug.print("cost-check: {s} not removed ({t})\n", .{ data_name, e });
    const data = try cwd.openDir(io, data_name, .{});
    defer data.close(io);
    try seed(a, io, data, size);

    var calls: files.FileCalls = .{};
    const root: files.DataRoot = .{ .io = io, .dir = data, .calls_for_test = &calls };
    var server = try http.Server.listen(io, gpa, .{ .port = 0, .root = &root });
    var running = try io.concurrent(http.Server.run, .{&server});
    defer {
        server.stop();
        running.await(io) catch |e| std.debug.print("cost-check: the server's run: {t}\n", .{e});
    }
    const port = server.port();
    const cookie = try sessionCookie(a, io, data, size.hash);

    const counts = try a.alloc(Counts, size.probes.len);
    for (size.probes, counts) |probe, *c| {
        const request = try std.fmt.allocPrint(a, "{s} {s} HTTP/1.1\r\nhost: localhost:{d}\r\n{s}content-length: 0\r\n\r\n", .{
            probe.method,
            probe.path,
            port,
            switch (probe.who) {
                .anyone => "",
                .human => cookie,
            },
        });
        _ = try exchange(a, io, port, request);
        calls.clear();
        const status = try exchange(a, io, port, request);
        c.* = .{
            .reads = calls.reads.load(.monotonic),
            .listings = calls.listings.load(.monotonic),
            .writes = calls.writes.load(.monotonic),
        };
        if (status >= 500) {
            std.debug.print("cost-check: {s} {s} answered {d}\n", .{ probe.method, probe.path, status });
            return error.CostCheckProbeFailed;
        }
    }
    return counts;
}

/// The chat `size` holds: Steve, the founder; Tam, id 2, who joined long
/// ago, invited by him, and who signs in; and every other human invited by
/// Tam, an invite each, spent. Every human is in `general`, whose topic
/// `roc-chat` holds the demo's seed.
fn seed(a: std.mem.Allocator, io: Io, data: Io.Dir, size: Size) !void {
    try write(io, data, "auth/next-id.txt", try std.fmt.allocPrint(a, "{d}\n", .{size.humans + 1}));
    var members: std.ArrayList(u8) = .empty;
    var id: u32 = 1;
    while (id <= size.humans) : (id += 1) {
        try members.print(a, "{d}\n", .{id});
        const folder = try std.fmt.allocPrint(a, "auth/{d}", .{id});
        const name = switch (id) {
            1 => "Steve",
            2 => "Tam",
            else => try lettered(a, id),
        };
        try write(io, data, try std.fmt.allocPrint(a, "{s}/name", .{folder}), name);
        if (id >= 2) try write(io, data, try std.fmt.allocPrint(a, "{s}/inviter", .{folder}), if (id == 2) "1" else "2");
        if (id >= 3) {
            inline for (.{ .{ "created", "1000000000" }, .{ "expires", "1000604800" }, .{ "by", "2" }, .{ "state", "spent" }, .{ "hash", &invite_hash } }) |fact|
                try write(io, data, try std.fmt.allocPrint(a, "{s}/human-invites/1/" ++ fact[0], .{folder}), fact[1]);
        }
    }
    const password_file = try std.fmt.allocPrint(a, "{s}\n", .{size.hash});
    try write(io, data, "auth/1/password", password_file);
    try write(io, data, "auth/2/password", password_file);
    try write(io, data, "auth/2/joined", "1000000000");
    try write(io, data, "chat/channel/general.channel", members.items);
    try write(io, data, seed_path["demo/data/".len..], try Io.Dir.cwd().readFileAlloc(io, seed_path, a, .limited(1024 * 1024)));
}

/// A name for the human `id`, since a name holds no digit: `Human `, then
/// the id in base 26, each digit a letter.
fn lettered(a: std.mem.Allocator, id: u32) ![]const u8 {
    var letters: std.ArrayList(u8) = .empty;
    try letters.appendSlice(a, "Human ");
    var rest = id;
    var digits: [8]u8 = undefined;
    var n: usize = 0;
    while (true) {
        digits[n] = 'a' + @as(u8, @intCast(rest % 26));
        n += 1;
        rest /= 26;
        if (rest == 0) break;
    }
    while (n > 0) {
        n -= 1;
        try letters.append(a, digits[n]);
    }
    return letters.items;
}

/// The file `path` written holding `text`, its folders made first.
fn write(io: Io, data: Io.Dir, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |folder| try data.createDirPath(io, folder);
    try data.writeFile(io, .{ .sub_path = path, .data = text });
}

/// The header line of Tam's session, signed now with the server's secret
/// over her password's hash, as app/Session.roc signs one.
fn sessionCookie(a: std.mem.Allocator, io: Io, data: Io.Dir, hash: []const u8) ![]const u8 {
    const secret = try data.readFileAlloc(io, ".session-secret", a, .limited(256));
    const signed_at = files.current_utc_seconds_since_epoch(io);
    const signed = try std.fmt.allocPrint(a, "2\n{d}\n{s}", .{ signed_at, hash });
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, signed, secret);
    const b64 = std.base64.url_safe_no_pad.Encoder;
    const id_text = try a.alloc(u8, b64.calcSize(1));
    const mac_text = try a.alloc(u8, b64.calcSize(mac.len));
    return std.fmt.allocPrint(a, "cookie: __Host-gopher_auth={s}.{d}.{s}\r\n", .{ b64.encode(id_text, "2"), signed_at, b64.encode(mac_text, &mac) });
}

/// `request` on a connection of its own, read to the close: the status.
fn exchange(a: std.mem.Allocator, io: Io, port: u16, request: []const u8) !u16 {
    const addr: Io.net.IpAddress = try .parse("127.0.0.1", port);
    const connection = try addr.connect(io, .{ .mode = .stream });
    defer connection.close(io);
    var w = connection.writer(io, &.{});
    try w.interface.writeAll(request);
    var buf: [4096]u8 = undefined;
    var r = connection.reader(io, &buf);
    const bytes = try r.interface.allocRemaining(a, .limited(64 * 1024 * 1024));
    if (!std.mem.startsWith(u8, bytes, "HTTP/1.1 ") or bytes.len < 12) return error.NotAResponse;
    return std.fmt.parseInt(u16, bytes[9..12], 10);
}
