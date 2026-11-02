const std = @import("std");

/// gopher-roc's build: app/main.roc built to one archive by the pinned Roc
/// (roc-version), linked into each of the host's programs. The Roc's tests
/// are the gate's (tools/verify.shale); the host's are `test` here.
///
///   zig build demo -- <topic> <file>         a transcript's page, to stdout
///   zig build serve -- <data> [--port <n>]   the server, on 127.0.0.1
///   zig build test                           the host's tests
///   zig build end-to-end                     the server, driven over HTTP
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const roc = rocCompiler(b);

    const archive = b.addSystemCommand(&.{ roc, "build", "app/main.roc", "--target=x64musl", "--opt=dev" });
    archive.setCwd(b.path("."));
    for ([_][]const u8{ "app", "platform", markdown_package }) |folder| rocInputs(b, archive, folder);
    archive.addFileInput(.{ .cwd_relative = roc });
    const app = archive.addPrefixedOutputFileArg("--output=", "app-x64musl.a");

    const demo_exe = withApp(b, "demo", "host/demo.zig", app, target, optimize);
    b.installArtifact(demo_exe);
    const demo = b.addRunArtifact(demo_exe);
    demo.addPassthruArgs();
    demo.stdio = .inherit;
    b.step("demo", "A transcript's page: -- <topic> <transcript file>").dependOn(&demo.step);

    const server_exe = withApp(b, "gopher-roc", "host/main.zig", app, target, optimize);
    b.installArtifact(server_exe);
    const serve = b.addRunArtifact(server_exe);
    serve.addPassthruArgs();
    serve.stdio = .inherit;
    b.step("serve", "The server on 127.0.0.1: -- <data folder> [--port <n>] (9611 by default)").dependOn(&serve.step);

    // **THE HOST'S TESTS**: the file primitives alone; the seam held to
    // roc glue's layout; the HTTP layer with the app linked.
    const tests = b.step("test", "The host's tests: the file primitives, the seam against roc glue, the HTTP layer");
    const primitives = b.createModule(.{ .root_source_file = b.path("host/file_primitives.zig"), .target = target, .optimize = optimize });
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = primitives })).step);
    for ([_][]const u8{ "host/seam_test.zig", "host/http_test.zig" }) |root| {
        const m = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize });
        m.addObjectFile(app);
        tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }

    // **THE END TO END** (host/end_to_end.zig): the real server, in its own
    // process's task, against a temporary data root, driven over HTTP.
    const e2e = b.addRunArtifact(withApp(b, "end-to-end", "host/end_to_end.zig", app, target, optimize));
    e2e.setCwd(b.path("."));
    e2e.has_side_effects = true;
    b.step("end-to-end", "The server against a temporary data root: GET, POST, GET, the file on disk").dependOn(&e2e.step);
}

/// The program `name`, from `root`, with the app's archive linked.
fn withApp(b: *std.Build, name: []const u8, root: []const u8, app: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize });
    mod.addObjectFile(app);
    return b.addExecutable(.{ .name = name, .root_module = mod });
}

/// **THE MARKDOWN PACKAGE app/main.roc IMPORTS** (`md`), roc-markdown
/// checked out beside this repo, from the build's root.
const markdown_package = "../roc-markdown/package";

/// **EVERY ROC MODULE IS AN INPUT, FOUND, NEVER LISTED**: each `.roc` in
/// `folder`, so a change to any module, ours or the markdown package's,
/// builds the archive again. The listing is a dependency of the configure
/// step too (`dependOnDirectoryContents`): Zig caches what `build` decided,
/// and without it a module added after the first build is no input, so
/// edits to it never rebuild the archive.
fn rocInputs(b: *std.Build, run: *std.Build.Step.Run, folder: []const u8) void {
    b.dependOnDirectoryContents(b.path(folder));
    const io = b.graph.io;
    var dir = b.root.root_dir.handle.openDir(io, folder, .{ .iterate = true }) catch |e|
        std.process.fatal("the Roc: cannot open {s} ({t})", .{ folder, e });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |e| std.process.fatal("the Roc: cannot list {s} ({t})", .{ folder, e })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".roc")) continue;
        run.addFileInput(b.path(b.fmt("{s}/{s}", .{ folder, entry.name })));
    }
}

const roc_pin = std.mem.trim(u8, @embedFile("roc-version"), " \n");

/// **THE ROC IS PINNED** (roc-version): `~/tools/roc-<pin>/roc`, as
/// roc-markdown's build finds it.
fn rocCompiler(b: *std.Build) []const u8 {
    const home = b.graph.environ_map.get("HOME") orelse std.process.fatal("no HOME to find ~/tools/roc-{s}/roc", .{roc_pin});
    return b.fmt("{s}/tools/roc-{s}/roc", .{ home, roc_pin });
}
