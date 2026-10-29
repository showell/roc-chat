//! **THE HOST'S ONE PATH RULE**: a relative path with no empty, `.` or `..`
//! part stays under the folder it is joined to (`secrets/` for
//! host/auth/secrets.zig, the data root for host/files.zig). Both ask `ok`;
//! neither keeps a copy.
//!
//! **IT LIVES IN host/auth/, AND HAS NO TESTS**: secrets.zig's test module is
//! rooted here, and Zig refuses an import above a module's root, so the rule
//! sits beside it. Each importer's tests hold it to its own bad paths; a test
//! here would run once per importer.

const std = @import("std");

pub fn ok(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    }
    return true;
}
