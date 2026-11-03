//! The server, and the one command that makes a password's hash:
//!
//!     gopher-roc <data folder> [--port <n>] [--public-origin https://<name>]
//!     gopher-roc hash-password
//!
//! The first serves the chat from the data folder on 127.0.0.1 (host/http.zig
//! says why only there), at port 9611 unless `--port` names another, until
//! it is stopped. `--public-origin` names the origin a proxy on this machine
//! serves it under, `https://` and a host name (and a port, if not 443):
//! requests with that `Host`, and pages of that origin, are then this
//! server's own as well as the local ones (app/RequestOrigin.roc).
//!
//! The second reads a password and writes its bcrypt hash, one line, to
//! stdout, as the app keeps a user's password. From a terminal it asks
//! twice, without echoing; else it reads the first line of stdin. So a
//! password reaches no log and no argument list: its owner types it on the
//! server's machine and redirects the hash into the user's `password` file
//! (docs/design.md, "Storage").

const std = @import("std");
const http = @import("http.zig");
const files = @import("file_primitives.zig");
const sign_in = @import("sign_in_primitives.zig");

const usage =
    \\usage: gopher-roc <data folder> [--port <n>] [--public-origin https://<name>]
    \\       gopher-roc hash-password
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len == 2 and std.mem.eql(u8, args[1], "hash-password")) return hash_password(io);
    var data: ?[]const u8 = null;
    var port: u16 = http.default_port;
    var public_origin: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i == args.len) std.process.fatal("{s}\n--port names no port", .{usage});
            port = std.fmt.parseInt(u16, args[i], 10) catch std.process.fatal("{s}\n--port {s} is no port", .{ usage, args[i] });
        } else if (std.mem.eql(u8, args[i], "--public-origin")) {
            i += 1;
            if (i == args.len) std.process.fatal("{s}\n--public-origin names no origin", .{usage});
            if (!is_public_origin(args[i])) std.process.fatal("{s}\n--public-origin {s} is not `https://` and a lowercase host name, with a port or none", .{ usage, args[i] });
            public_origin = args[i];
        } else if (data == null and !std.mem.startsWith(u8, args[i], "-")) {
            data = args[i];
        } else std.process.fatal("{s}\n{s} is not understood", .{ usage, args[i] });
    }
    const folder = data orelse std.process.fatal("{s}", .{usage});
    const dir = std.Io.Dir.cwd().openDir(io, folder, .{}) catch |e|
        std.process.fatal("the data folder {s} cannot be opened ({t})", .{ folder, e });
    const root: files.DataRoot = .{ .io = io, .dir = dir };
    var server = http.Server.listen(io, init.gpa, .{ .port = port, .root = &root, .public_origin = public_origin }) catch |e| switch (e) {
        error.SecretOpenToOthers => std.process.fatal(
            "{s}/{s} may be read or written by others than its owner, so it signs no session: `chmod 600` it, or remove it and start again to make a new one (every session then ends)",
            .{ folder, sign_in.secret_name },
        ),
        else => return e,
    };
    std.debug.print("gopher-roc: http://127.0.0.1:{d}/, its data in {s}{s}{s}\n", .{ server.port(), folder, if (public_origin.len > 0) ", public as " else "", public_origin });
    try server.run();
}

/// Whether `text` is an origin a proxy may serve this server under:
/// `https://`, then a host name of lowercase letters, digits, `-` and `.`,
/// not starting or ending with `.` or `-`, then a `:` and a port's digits,
/// or nothing. Nothing else, no path and no trailing `/`, so the app can
/// compare it byte for byte with a browser's `Origin`.
pub fn is_public_origin(text: []const u8) bool {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, text, scheme)) return false;
    const rest = text[scheme.len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':');
    const name = rest[0 .. colon orelse rest.len];
    if (name.len == 0 or name.len > 253) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '.')) return false;
    for ([_]u8{ name[0], name[name.len - 1] }) |end| if (end == '.' or end == '-') return false;
    if (colon) |at| {
        const digits = rest[at + 1 ..];
        if (digits.len == 0 or digits[0] == '0') return false;
        _ = std.fmt.parseInt(u16, digits, 10) catch return false;
        for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

test "a public origin: https and a host name, a port or none; nothing else" {
    for ([_][]const u8{ "https://chat.example.com", "https://chat.example.com:8443", "https://a", "https://x-1.example" }) |good| {
        try std.testing.expect(is_public_origin(good));
    }
    for ([_][]const u8{ "", "http://chat.example.com", "https://", "https://Chat.example.com", "https://chat.example.com/", "https://chat.example.com:", "https://chat.example.com:0", "https://chat.example.com:65536", "https://chat.example.com:+1", "https://.example.com", "https://example.com.", "https://-x", "https://a b", "https://a@b", "chat.example.com" }) |bad| {
        try std.testing.expect(!is_public_origin(bad));
    }
}

/// The longest password bcrypt reads whole. A longer one would be hashed
/// by a second scheme first, which another bcrypt would not read.
const password_most = 72;

/// A password read without echo, twice, from a terminal; or the first line
/// of stdin; then its bcrypt hash, one line, on stdout.
fn hash_password(io: std.Io) !void {
    const stdin = std.Io.File.stdin();
    var first: [password_most + 2]u8 = undefined;
    var second: [password_most + 2]u8 = undefined;
    const password = if (stdin.isTty(io) catch false) blk: {
        const a = try read_unechoed(io, "Password: ", &first);
        const b = try read_unechoed(io, "Again: ", &second);
        if (!std.mem.eql(u8, a, b)) fail("hash-password: the two differ; nothing written");
        break :blk a;
    } else try read_line(io, &first);
    if (password.len == 0) fail("hash-password: no password");
    if (password.len > password_most) fail("hash-password: bcrypt reads 72 bytes at most; choose a shorter password");
    var out: [sign_in.bcrypt_hash_length]u8 = undefined;
    const hash = sign_in.bcrypt_hash_of_password(io, password, &out);
    var out_buf: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &out_buf);
    try writer.interface.print("{s}\n", .{hash});
    try writer.interface.flush();
}

/// A line from the terminal on stdin, its echo off while it is typed,
/// after `prompt` on stderr.
fn read_unechoed(io: std.Io, prompt: []const u8, buf: []u8) ![]const u8 {
    std.debug.print("{s}", .{prompt});
    const fd = std.Io.File.stdin().handle;
    const before = try std.posix.tcgetattr(fd);
    var quiet = before;
    quiet.lflag.ECHO = false;
    try std.posix.tcsetattr(fd, .NOW, quiet);
    defer {
        std.posix.tcsetattr(fd, .NOW, before) catch {};
        std.debug.print("\n", .{});
    }
    return read_line(io, buf);
}

/// The first line of stdin, without its line end; a line longer than `buf`
/// stops the command.
fn read_line(io: std.Io, buf: []u8) ![]const u8 {
    var in_buf: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &in_buf);
    var at: usize = 0;
    while (true) {
        const byte = reader.interface.takeByte() catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (byte == '\n') break;
        if (at == buf.len) fail("hash-password: bcrypt reads 72 bytes at most; choose a shorter password");
        buf[at] = byte;
        at += 1;
    }
    return std.mem.trimEnd(u8, buf[0..at], "\r");
}

fn fail(why: []const u8) noreturn {
    std.debug.print("{s}\n", .{why});
    std.process.exit(1);
}
