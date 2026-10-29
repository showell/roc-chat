const std = @import("std");

/// roc-chat's build: the chat's Roc (app/ on platform/) built to an archive
/// by the pinned Roc, linked into the host (host/), a std.http server.
///
/// **TO ADD A PART**: a host file is reached from host/main.zig and needs
/// nothing here; a test file is one more entry in `host_tests` (it gets the
/// app's archive and the `chat_client` module); a dependency is a
/// build.zig.zon entry and an import in `imports`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    linuxOnly(target.result);

    const chat_client = b.dependency("chat_client", .{ .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "chat_client", .module = chat_client.module("chat_client") },
    };

    const roc = rocCompiler(b);
    const app = appArchive(b, roc, rocOpt(optimize));

    const exe = b.addExecutable(.{ .name = "roc-chat", .root_module = b.createModule(.{
        .root_source_file = b.path("host/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    exe.root_module.addObjectFile(app);
    b.installArtifact(exe);

    // **`serve` RUNS IN dev/**: the host reads config.zon from its working
    // directory (no arguments), and dev/config.zon names dev/data.
    const serve = b.addRunArtifact(exe);
    serve.setCwd(b.path("dev"));
    serve.step.dependOn(b.getInstallStep());
    b.step("serve", "Serve the chat from dev/ (dev/config.zon: http://127.0.0.1:9480, its data in dev/data)").dependOn(&serve.step);

    // **A MEASUREMENT, NOT A TEST**: what a sync per write costs on this
    // disk (host/files_bench.zig), never in `test`.
    const bench = b.addRunArtifact(b.addExecutable(.{ .name = "files-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("host/files_bench.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    bench.setCwd(b.path("."));
    bench.has_side_effects = true;
    b.step("bench-files", "Time write! and append! with and without their syncs, on this disk").dependOn(&bench.step);

    // **ONE COMMAND RUNS EVERY TEST**: the Roc's own (`roc test`), then each
    // host test with the app's archive linked.
    const tests = b.step("test", "Every test: roc test, the host's tests through the Roc app, the glue check, the auth and GitHub tests");
    const roc_test = b.addSystemCommand(&.{ roc, "test", "app/main.roc" });
    roc_test.setCwd(b.path("."));
    for (rocInputs(b)) |f| roc_test.addFileInput(b.path(f));
    roc_test.has_side_effects = true;
    tests.dependOn(&roc_test.step);
    const host_tests = [_][]const u8{
        "host/server_test.zig",
        "host/signin_test.zig",
        "host/seam/glue_test.zig",
    };
    for (host_tests) |root| {
        const m = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        });
        m.addObjectFile(app);
        tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
    authSteps(b, tests, target, optimize);
}

/// The auth primitives (`host/auth/`), the GitHub client (`host/github/`)
/// and its tests against the fake GitHub, all in `test`; the live GitHub
/// call in `smoke` alone. None of them needs the Roc app.
fn authSteps(b: *std.Build, test_step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    const github = b.createModule(.{
        .root_source_file = b.path("host/github/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = github })).step);

    // secrets.zig's tests carry crypto.zig's, which it imports.
    const secrets = b.createModule(.{ .root_source_file = b.path("host/auth/secrets.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = secrets })).step);

    const github_test = b.createModule(.{ .root_source_file = b.path("host/github/github_test.zig"), .target = target, .optimize = optimize });
    github_test.addImport("github", github);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = github_test })).step);

    const smoke = b.addExecutable(.{ .name = "github-smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("host/github/smoke.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("smoke", "One live call to api.github.com/zen (needs the network)").dependOn(&b.addRunArtifact(smoke).step);
}

/// **LINUX ON X86-64 ONLY, SAID AT CONFIGURE**: the host is Linux's
/// (std.Io.Threaded, its sockets), and the Roc archive is built for x64musl.
fn linuxOnly(t: std.Target) void {
    if (t.os.tag != .linux or t.cpu.arch != .x86_64)
        std.process.fatal("roc-chat builds for x86-64 Linux only, not {t}-{t}", .{ t.cpu.arch, t.os.tag });
}

const roc_pin = std.mem.trim(u8, @embedFile("roc-version"), " \n");

/// **THE ROC IS PINNED** (roc-version): -Droc=<path>, or `roc` on the PATH,
/// and it must be the pinned one. (From roc-webbox's build.zig at 5a4314b.)
fn rocCompiler(b: *std.Build) []const u8 {
    const named = b.option([]const u8, "roc", "the Roc compiler (default: `roc` on the PATH); the version roc-version pins") orelse "roc";
    const none = "the chat is built from Roc, and there is no Roc compiler at `{s}`: put Roc {s} (roc-version) on the PATH (tools/get_roc.sh installs it), or name it with -Droc=<path>";
    const found = if (std.mem.indexOfScalar(u8, named, '/') == null)
        b.findProgram(.{ .names = &.{named} }) orelse std.process.fatal(none, .{ named, roc_pin })
    else
        b.root.root_dir.handle.realPathFileAlloc(b.graph.io, named, b.allocator) catch std.process.fatal(none, .{ named, roc_pin });
    const said = std.mem.trim(u8, b.run(&.{ found, "version" }), " \n");
    const version = if (std.mem.lastIndexOfScalar(u8, said, ' ')) |i| said[i + 1 ..] else said;
    if (!std.mem.eql(u8, version, roc_pin)) std.process.fatal("roc-chat is pinned to Roc {s} (roc-version), and `{s}` is {s}: put the pinned one on the PATH (tools/get_roc.sh) or name it with -Droc=<path>", .{ roc_pin, found, version });
    return found;
}

/// **ROC'S BUILD MODE FOLLOWS ZIG'S**: a Debug build (every test) takes
/// Roc's dev backend, a release build LLVM. Roc's own default is `speed`,
/// minutes where dev takes about a second.
const RocOpt = enum { dev, speed };

fn rocOpt(optimize: std.lang.Optimize) RocOpt {
    return if (optimize == .debug) .dev else .speed;
}

/// app/main.roc built for x64musl, as `chat-x64musl.a`.
fn appArchive(b: *std.Build, roc: []const u8, opt: RocOpt) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ roc, "build", "app/main.roc", "--target=x64musl", b.fmt("--opt={t}", .{opt}) });
    run.setCwd(b.path("."));
    for (rocInputs(b)) |f| run.addFileInput(b.path(f));
    // The compiler too: a new Roc builds the archive again.
    run.addFileInput(.{ .cwd_relative = roc });
    return run.addPrefixedOutputFileArg("--output=", "chat-x64musl.a");
}

/// **EVERY ROC MODULE IS AN INPUT, FOUND, NEVER LISTED**: each `.roc` in
/// app/ and platform/, then each in the folder of every package app/main.roc's
/// header names. A list kept by hand drifts, and a module missing from it
/// rebuilds nothing when edited.
fn rocInputs(b: *std.Build) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "app", "platform" }) |folder| rocFiles(b, folder, &out);
    packageFolders(b, "app/main.roc", &out);
    return out.items;
}

fn rocFiles(b: *std.Build, folder: []const u8, out: *std.ArrayList([]const u8)) void {
    const io = b.graph.io;
    var dir = b.root.root_dir.handle.openDir(io, folder, .{ .iterate = true }) catch |e|
        std.process.fatal("the chat's Roc: cannot open {s} ({t})", .{ folder, e });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |e| std.process.fatal("the chat's Roc: cannot list {s} ({t})", .{ folder, e })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".roc")) continue;
        out.append(b.allocator, b.fmt("{s}/{s}", .{ folder, entry.name })) catch @panic("OOM");
    }
}

/// **A PACKAGE'S MODULES ARE INPUTS TOO, FOUND FROM THE APP'S HEADER**: each
/// `name: "<path>/main.roc"` entry of `app`'s header (its `platform` is
/// platform/, listed already). The header is the one home of where a package
/// lives: roc-markdown, checked out beside roc-chat.
fn packageFolders(b: *std.Build, app: []const u8, out: *std.ArrayList([]const u8)) void {
    const io = b.graph.io;
    const source = b.root.root_dir.handle.readFileAlloc(io, app, b.allocator, .unlimited) catch |e| std.process.fatal("the chat's packages: cannot read {s} ({t})", .{ app, e });
    const app_at = std.mem.indexOf(u8, source, "\napp [") orelse std.process.fatal("{s}: no app header", .{app});
    const open = std.mem.indexOfScalarPos(u8, source, app_at, '{') orelse std.process.fatal("{s}: an app header with no {{", .{app});
    const close = std.mem.indexOfScalarPos(u8, source, open, '}') orelse std.process.fatal("{s}: an app header with no }}", .{app});
    var entries = std.mem.splitScalar(u8, source[open + 1 .. close], ',');
    while (entries.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        // `pf: platform "..."` is platform/, already an input.
        const colon = std.mem.indexOf(u8, entry, ": \"") orelse continue;
        const rel = std.mem.trimEnd(u8, entry[colon + 3 ..], "\"");
        const main = std.fs.path.resolvePosix(b.allocator, &.{ std.fs.path.dirname(app) orelse ".", rel }) catch @panic("OOM");
        const folder = std.fs.path.dirname(main) orelse ".";
        var dir = b.root.root_dir.handle.openDir(io, folder, .{}) catch |e|
            std.process.fatal("{s} names the package {s}, and its folder {s} cannot be opened ({t}): check out github.com/showell/roc-markdown beside roc-chat", .{ app, rel, folder, e });
        dir.close(io);
        rocFiles(b, folder, out);
    }
}
