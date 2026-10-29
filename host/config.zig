//! **THE ONE CONFIG FILE**: config.zon in the server's working directory,
//! beside the data root it names. No arguments and no environment: what a
//! server runs with is in one file, in the folder it runs in.

const std = @import("std");
const Io = std.Io;
const secrets = @import("auth/secrets.zig");
const github = @import("github/client.zig");

pub const file_name = "config.zon";

pub const Config = struct {
    /// The address it listens on.
    bind: []const u8 = "127.0.0.1",
    /// The port, 1 to 65535.
    port: u16,
    /// The data root, relative to the config's folder (or absolute).
    data: []const u8,
    /// The chat's public origin, `https://chat.lynrummy.com`: GitHub sends
    /// the browser back to its `/login/github`. No path, no trailing `/`.
    origin: []const u8,
    /// The secret files' names under the data root's `secrets/`
    /// (host/auth/secrets.zig): the OAuth app's client id and secret, and
    /// the signing key (made on first start).
    secrets: secrets.Paths,
    /// GitHub's base URLs and deadlines (host/github/client.zig): GitHub's
    /// own when not named; a test names its fake's.
    github: github.Config = .{},
    /// The first admin's GitHub id; none named, no first admin. The key
    /// keeps its first spelling: the deploy never rewrites prod's config.
    bootstrap_admin: ?u64 = null,
};

/// config.zon from `dir`, its values in `arena`. A file that is missing,
/// malformed, or names port 0 or an address that is not one stops the
/// server, saying which and why: never a default for a setting it could
/// not read.
pub fn load(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, dir: Io.Dir) !Config {
    const source = dir.readFileAllocOptions(io, file_name, arena, .limited(64 * 1024), .of(u8), 0) catch |e| {
        std.log.err("{s}: cannot read it in the working directory ({t}); dev/config.zon is an example", .{ file_name, e });
        return e;
    };
    var why: []const u8 = "";
    return parse(gpa, arena, source, &why) catch |e| {
        std.log.err("{s}", .{why});
        return e;
    };
}

/// The config `source` says, or an error with `why` the words for it.
pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8, why: *[]const u8) !Config {
    var diag: std.zon.parse.Diagnostics = undefined;
    const c = std.zon.parse.fromSlice(Config, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diag,
    }) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.ParseZon => {
            why.* = try std.fmt.allocPrint(arena, "{f}", .{diag.fmt(file_name)});
            return e;
        },
    };
    if (c.port == 0) {
        why.* = file_name ++ ": .port is 0; a port is 1 to 65535";
        return error.NotAPort;
    }
    _ = Io.net.IpAddress.parse(c.bind, c.port) catch {
        why.* = try std.fmt.allocPrint(arena, "{s}: .bind = \"{s}\" is not an IP address", .{ file_name, c.bind });
        return error.NotAnAddress;
    };
    if (c.data.len == 0) {
        why.* = file_name ++ ": .data is empty; it names the data root";
        return error.NoDataRoot;
    }
    if (!originOk(c.origin)) {
        why.* = file_name ++ ": .origin is not an origin (`https://host[:port]`, or `http://` for a test; no path, no trailing `/`)";
        return error.NotAnOrigin;
    }
    c.github.check() catch {
        why.* = file_name ++ ": .github's base URLs must be https://, or http:// to a loopback address; and its user_agent visible";
        return error.GitHubRefused;
    };
    return c;
}

/// `scheme://host[:port]`, nothing after, no byte a header could not carry.
fn originOk(origin: []const u8) bool {
    if (std.mem.indexOfAny(u8, origin, "\r\n\x00 ") != null) return false;
    const uri = std.Uri.parse(origin) catch return false;
    const scheme_ok = std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http");
    return scheme_ok and uri.host != null and uri.path.isEmpty() and uri.query == null and uri.fragment == null and uri.user == null;
}

test "a config read, and one that names port 0, no address or a port past 65535 refused, saying why" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gpa = std.testing.allocator;
    var why: []const u8 = "";
    const auth = ", .origin = \"https://chat.example\", .secrets = .{ .client_id = \"id\", .client_secret = \"s\", .signing_key = \"k\" } }";
    const c = try parse(gpa, a, ".{ .port = 9480, .data = \"data\"" ++ auth, &why);
    try std.testing.expectEqualStrings("https://github.com", c.github.oauth_base);
    try std.testing.expectEqual(null, c.bootstrap_admin);
    try std.testing.expectError(error.NotAnOrigin, parse(gpa, a, ".{ .port = 1, .data = \"d\", .origin = \"https://chat.example/\", .secrets = .{ .client_id = \"id\", .client_secret = \"s\", .signing_key = \"k\" } }", &why));
    try std.testing.expectError(error.GitHubRefused, parse(gpa, a, ".{ .port = 1, .data = \"d\", .origin = \"https://c.example\", .github = .{ .oauth_base = \"http://github.com\" }, .secrets = .{ .client_id = \"id\", .client_secret = \"s\", .signing_key = \"k\" } }", &why));
    try std.testing.expectEqual(9480, c.port);
    try std.testing.expectEqualStrings("127.0.0.1", c.bind);
    try std.testing.expectError(error.NotAPort, parse(gpa, a, ".{ .port = 0, .data = \"d\"" ++ auth, &why));
    try std.testing.expectError(error.NotAnAddress, parse(gpa, a, ".{ .bind = \"nowhere\", .port = 1, .data = \"d\"" ++ auth, &why));
    try std.testing.expect(std.mem.indexOf(u8, why, "nowhere") != null);
    try std.testing.expectError(error.ParseZon, parse(gpa, a, ".{ .port = 70000, .data = \"d\"" ++ auth, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "config.zon:1:"));
}
