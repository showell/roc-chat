const std = @import("std");

/// gopher-roc's build, for now the demo: app/main.roc built to an archive
/// by the pinned Roc (roc-version), linked into host/main.zig.
///
///   zig build test                       roc test app/main.roc
///   zig build demo -- <topic> <file>     a transcript's page, to stdout
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const roc = rocCompiler(b);

    const archive = b.addSystemCommand(&.{ roc, "build", "app/main.roc", "--target=x64musl", "--opt=dev" });
    archive.setCwd(b.path("."));
    for ([_][]const u8{ "app/main.roc", "app/Message.roc", "app/Transcript.roc", "app/Conversation.roc", "platform/main.roc" }) |f| archive.addFileInput(b.path(f));
    archive.addFileInput(.{ .cwd_relative = roc });
    const page = archive.addPrefixedOutputFileArg("--output=", "page-x64musl.a");

    const mod = b.createModule(.{ .root_source_file = b.path("host/main.zig"), .target = target, .optimize = optimize });
    mod.addObjectFile(page);
    const exe = b.addExecutable(.{ .name = "demo", .root_module = mod });
    b.installArtifact(exe);
    const demo = b.addRunArtifact(exe);
    demo.addPassthruArgs();
    demo.stdio = .inherit;
    b.step("demo", "A transcript's page: -- <topic> <transcript file>").dependOn(&demo.step);

    const roc_test = b.addSystemCommand(&.{ roc, "test", "app/main.roc" });
    roc_test.setCwd(b.path("."));
    roc_test.has_side_effects = true;
    b.step("test", "roc test app/main.roc").dependOn(&roc_test.step);
}

const roc_pin = std.mem.trim(u8, @embedFile("roc-version"), " \n");

/// **THE ROC IS PINNED** (roc-version): `~/tools/roc-<pin>/roc`, as
/// roc-markdown's build finds it.
fn rocCompiler(b: *std.Build) []const u8 {
    const home = b.graph.environ_map.get("HOME") orelse std.process.fatal("no HOME to find ~/tools/roc-{s}/roc", .{roc_pin});
    return b.fmt("{s}/tools/roc-{s}/roc", .{ home, roc_pin });
}
