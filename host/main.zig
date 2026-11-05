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
//! server's own as well as the local ones (app/RequestOrigin.roc). GitHub's
//! settings are files in the data folder (host/github_client.zig).
//!
//! The second reads a password and writes its bcrypt hash, one line, to
//! stdout, as the app keeps a user's password. From a terminal it asks
//! twice, without echoing, and puts the echo back however it ends; else it
//! reads the first line of stdin. It refuses a password the sign-in form
//! would refuse, by asking the app (`password_verdict`). So a
//! password reaches no log and no argument list: its owner types it on the
//! server's machine and redirects the hash into the user's `password` file
//! (docs/design.md, "Storage").

const std = @import("std");
const http = @import("http.zig");
const files = @import("file_primitives.zig");
const sign_in = @import("sign_in_primitives.zig");
const seam = @import("seam.zig");
const github = @import("github_client.zig");

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
        error.GitHubSettingsPartial => std.process.fatal("{s} holds some of GitHub's settings but not both of {s} and {s}", .{ folder, github.client_id_name, github.client_secret_name }),
        error.GitHubSettingOpenToOthers => std.process.fatal("one of the `.github-` files in {s} may be read or written by others than its owner: `chmod 600` it", .{folder}),
        error.GitHubSettingUnusable => std.process.fatal("one of the `.github-` files in {s} is empty, too long, or holds a space or a byte that isn't ASCII", .{folder}),
        error.GitHubBaseRefused => std.process.fatal("{s} or {s} in {s} is no `https://` URL, or `http://` to a loopback address", .{ github.oauth_base_name, github.api_base_name, folder }),
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

/// The most bytes `hash-password` reads of a line: a bound on its memory
/// alone. What a password may be is the app's rule (`password_verdict` in
/// app/main.roc), asked through the seam, so the command and the sign-in
/// form keep one.
const line_most = 4096;

/// A password read without echo, twice, from a terminal; or the first line
/// of stdin; then its bcrypt hash, one line, on stdout.
fn hash_password(io: std.Io) !void {
    const stdin = std.Io.File.stdin();
    var first: [line_most]u8 = undefined;
    var second: [line_most]u8 = undefined;
    const password = if (stdin.isTty(io) catch false) blk: {
        restore_terminal_on_signals();
        const a = read_unechoed(io, "Password: ", &first) catch |e| return line_failure(e);
        const b = read_unechoed(io, "Again: ", &second) catch |e| return line_failure(e);
        if (!std.mem.eql(u8, a, b)) fail("hash-password: the two differ; nothing written");
        break :blk a;
    } else read_line(io, &first) catch |e| return line_failure(e);
    if (!is_password(password)) fail("hash-password: that is no password the sign-in form takes (app/Password.roc says which); nothing written");
    var out: [sign_in.bcrypt_hash_length]u8 = undefined;
    const hash = sign_in.bcrypt_hash_of_password(io, password, &out);
    var out_buf: [128]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &out_buf);
    try writer.interface.print("{s}\n", .{hash});
    try writer.interface.flush();
}

/// Whether the app takes `password` as the sign-in form would.
fn is_password(password: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    seam.begin(.{ .arena = arena_state.allocator() });
    defer seam.end();
    return seam.roc_password_verdict(.from(password)) == .accepted;
}

/// A line that could not be read: one past `line_most` said so, and the
/// command stopped; any other error handed on.
fn line_failure(e: anyerror) anyerror {
    if (e == error.LineTooLong) fail(std.fmt.comptimePrint("hash-password: a line of more than {d} bytes; nothing written", .{line_most}));
    return e;
}

/// The terminal as it was before its echo went off, while it is off, so
/// that a signal can put it back.
var terminal_before: ?struct { fd: std.posix.fd_t, termios: std.posix.termios } = null;

/// The terminal's echo back on, if this command turned it off.
fn restore_terminal() void {
    if (terminal_before) |t| std.posix.tcsetattr(t.fd, .NOW, t.termios) catch {};
}

/// Ctrl-C (SIGINT), and a hang-up, a quit or a stop asked for (SIGHUP,
/// SIGQUIT, SIGTERM), put the terminal back before the command ends, as a
/// signal's default would end it with the echo still off.
fn restore_terminal_on_signals() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = end_on_signal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .INT, .HUP, .QUIT, .TERM }) |sig| std.posix.sigaction(sig, &action, null);
}

/// The handler: the terminal put back, a line end so the shell's prompt
/// starts its own line, and the command ended as the signal ends one,
/// 128 and the signal's number. Each call is one system call, safe in a
/// handler.
fn end_on_signal(sig: std.posix.SIG) callconv(.c) void {
    restore_terminal();
    _ = std.os.linux.write(2, "\n", 1);
    std.os.linux.exit_group(128 + @as(i32, @intCast(@intFromEnum(sig))));
}

/// A line from the terminal on stdin, its echo off while it is typed,
/// after `prompt` on stderr. The echo is back on before it returns, however
/// it returns.
fn read_unechoed(io: std.Io, prompt: []const u8, buf: []u8) ![]const u8 {
    std.debug.print("{s}", .{prompt});
    const fd = std.Io.File.stdin().handle;
    const before = try std.posix.tcgetattr(fd);
    var quiet = before;
    quiet.lflag.ECHO = false;
    terminal_before = .{ .fd = fd, .termios = before };
    defer {
        restore_terminal();
        terminal_before = null;
        std.debug.print("\n", .{});
    }
    try std.posix.tcsetattr(fd, .NOW, quiet);
    return read_line(io, buf);
}

/// The first line of stdin, without its line end; `error.LineTooLong` for
/// one longer than `buf`.
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
        if (at == buf.len) return error.LineTooLong;
        buf[at] = byte;
        at += 1;
    }
    return std.mem.trimEnd(u8, buf[0..at], "\r");
}

fn fail(why: []const u8) noreturn {
    std.debug.print("{s}\n", .{why});
    std.process.exit(1);
}
