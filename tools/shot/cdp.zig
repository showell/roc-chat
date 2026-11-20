//! The browser, driven over the Chrome DevTools Protocol by a pipe: Chrome
//! started with `--remote-debugging-pipe` reads commands on its fd 3 and
//! writes answers and events on its fd 4, each message a JSON text ended by
//! a NUL byte. No websocket, no port: the protocol is the browser's alone.
//!
//! `launch` starts it, `attach` opens a page and takes its session, `call`
//! sends a command and waits for its answer, and `close` ends it. Events
//! are read as they pass; the one a step waits on, Page.loadEventFired, is
//! kept as a count (`loads`).
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

/// How long any one answer may take before the run stops.
const answer_ms: i32 = 30_000;

pub const Browser = struct {
    gpa: Allocator,
    pid: linux.pid_t,
    /// Our end of the browser's fd 3: what we write, it reads.
    to: linux.fd_t,
    /// Our end of the browser's fd 4: what it writes, we read.
    from: linux.fd_t,
    /// Bytes read and not yet taken as a message.
    inbox: std.ArrayList(u8) = .empty,
    next_id: u64 = 1,
    /// The page's session, once `attach` has one; every page command names it.
    session: ?[]const u8 = null,
    /// How many Page.loadEventFired events have passed.
    loads: u64 = 0,

    /// Sends `method` with `params` (a struct, made JSON) and gives its
    /// answer's `result`; an answer with an `error` is `error.Refused`, said.
    /// The caller frees the answer with `deinit`.
    pub fn call(self: *Browser, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        const id = self.next_id;
        self.next_id += 1;
        // `.{}` is an empty tuple, which JSON writes as `[]`; the protocol wants `{}`.
        const given = if (@typeInfo(@TypeOf(params)).@"struct".field_names.len == 0)
            try self.gpa.dupe(u8, "{}")
        else
            try std.fmt.allocPrint(self.gpa, "{f}", .{std.json.fmt(params, .{})});
        defer self.gpa.free(given);
        const text = if (self.session) |s|
            try std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"sessionId\":{f},\"method\":{f},\"params\":{s}}}\x00", .{ id, std.json.fmt(s, .{}), std.json.fmt(method, .{}), given })
        else
            try std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"method\":{f},\"params\":{s}}}\x00", .{ id, std.json.fmt(method, .{}), given });
        defer self.gpa.free(text);
        try writeAll(self.to, text);
        while (true) {
            var msg = try self.receive(answer_ms);
            const top = msg.value.object;
            if (top.get("id")) |got| {
                if (got == .integer and got.integer == id) {
                    if (top.get("error")) |e| {
                        say("shot: {s} refused: {f}\n", .{ method, std.json.fmt(e, .{}) });
                        msg.deinit();
                        return error.Refused;
                    }
                    return msg;
                }
            } else if (top.get("method")) |m| {
                if (m == .string and std.mem.eql(u8, m.string, "Page.loadEventFired")) self.loads += 1;
            }
            msg.deinit();
        }
    }

    /// Reads events until `loads` passes `seen`, or `ms` go by.
    pub fn awaitLoad(self: *Browser, seen: u64, ms: i32) !void {
        const start = nowMs();
        while (self.loads <= seen) {
            const left = ms - @as(i32, @intCast(nowMs() - start));
            if (left <= 0) return error.Timeout;
            var msg = try self.receive(left);
            defer msg.deinit();
            if (msg.value.object.get("method")) |m| {
                if (m == .string and std.mem.eql(u8, m.string, "Page.loadEventFired")) self.loads += 1;
            }
        }
    }

    /// A new page, its session taken for every command after.
    pub fn attach(self: *Browser) !void {
        var made = try self.call("Target.createTarget", .{ .url = "about:blank" });
        defer made.deinit();
        const target = made.value.object.get("result").?.object.get("targetId").?.string;
        var joined = try self.call("Target.attachToTarget", .{ .targetId = target, .flatten = true });
        defer joined.deinit();
        self.session = try self.gpa.dupe(u8, joined.value.object.get("result").?.object.get("sessionId").?.string);
    }

    /// Asks the browser to close, waits for it, and kills it if it lingers.
    pub fn close(self: *Browser) void {
        if (self.session) |s| self.gpa.free(s);
        self.session = null;
        defer self.inbox.deinit(self.gpa);
        if (self.call("Browser.close", .{})) |answer| {
            var a = answer;
            a.deinit();
        } else |_| {}
        // The pipes close once it has gone, so it never writes into a closed one.
        defer _ = linux.close(self.from);
        defer _ = linux.close(self.to);
        const start = nowMs();
        while (nowMs() - start < 5000) {
            var status: i32 = 0;
            if (linux.waitpid(self.pid, &status, linux.W.NOHANG) == self.pid) return;
            sleepMs(50);
        }
        kill(self.pid);
    }

    /// The next whole message, within `ms`.
    fn receive(self: *Browser, ms: i32) !std.json.Parsed(std.json.Value) {
        const start = nowMs();
        while (true) {
            if (std.mem.indexOfScalar(u8, self.inbox.items, 0)) |end| {
                const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, self.inbox.items[0..end], .{});
                const rest = self.inbox.items.len - end - 1;
                std.mem.copyForwards(u8, self.inbox.items[0..rest], self.inbox.items[end + 1 ..]);
                self.inbox.shrinkRetainingCapacity(rest);
                return parsed;
            }
            const left = ms - @as(i32, @intCast(nowMs() - start));
            if (left <= 0) return error.Timeout;
            var fds = [_]linux.pollfd{.{ .fd = self.from, .events = linux.POLL.IN }};
            const ready = linux.poll(&fds, 1, left);
            if (linux.errno(ready) == .INTR) continue;
            if (linux.errno(ready) != .SUCCESS) return error.Poll;
            if (ready == 0) return error.Timeout;
            var buf: [65536]u8 = undefined;
            const n = linux.read(self.from, &buf, buf.len);
            if (linux.errno(n) == .INTR) continue;
            if (linux.errno(n) != .SUCCESS) return error.Read;
            if (n == 0) return error.BrowserGone;
            try self.inbox.appendSlice(self.gpa, buf[0..n]);
        }
    }
};

/// Starts `argv` (its program a path) with the protocol's pipes as its fd 3
/// and fd 4, and `env` its environment; `arena` holds the argv as execve
/// takes it, and `gpa` what the Browser keeps.
pub fn launch(gpa: Allocator, arena: Allocator, argv: []const []const u8, env: [*:null]const ?[*:0]const u8) !Browser {
    const argz = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argz[i] = try arena.dupeSentinel(u8, arg, 0);
    var commands: [2]linux.fd_t = undefined;
    var answers: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&commands, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    if (linux.errno(linux.pipe2(&answers, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    const forked = linux.fork();
    if (linux.errno(forked) != .SUCCESS) return error.Fork;
    if (forked == 0) {
        // The child: each end moved above 9 first, so neither dup2 below
        // lands on the other's fd; a dup2's fd stays open across the exec.
        const in_hi: linux.fd_t = @intCast(linux.fcntl(commands[0], linux.F.DUPFD_CLOEXEC, 10));
        const out_hi: linux.fd_t = @intCast(linux.fcntl(answers[1], linux.F.DUPFD_CLOEXEC, 10));
        _ = linux.dup2(in_hi, 3);
        _ = linux.dup2(out_hi, 4);
        _ = linux.execve(argz[0].?, argz.ptr, env);
        linux.exit_group(127);
    }
    _ = linux.close(commands[0]);
    _ = linux.close(answers[1]);
    return .{ .gpa = gpa, .pid = @intCast(forked), .to = commands[1], .from = answers[0] };
}

pub fn kill(pid: linux.pid_t) void {
    _ = linux.kill(pid, .KILL);
    var status: i32 = 0;
    _ = linux.waitpid(pid, &status, 0);
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const n = linux.write(fd, bytes[at..].ptr, bytes.len - at);
        if (linux.errno(n) == .INTR) continue;
        if (linux.errno(n) != .SUCCESS) return error.BrowserGone;
        at += n;
    }
}

pub fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

pub fn sleepMs(ms: i64) void {
    const ts: linux.timespec = .{ .sec = @divTrunc(ms, 1000), .nsec = @mod(ms, 1000) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}

/// Prints to stdout, unbuffered: a line at a time is all this program says.
pub fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    writeAll(1, text) catch {};
}
