const std = @import("std");

/// The screenshot driver's own build, apart from the server's: it links no
/// Roc, so a change to the app never rebuilds it.
///
///   zig build run -- <chrome> <profile folder> <shot list> <out folder>
///   zig build test     the shot list's parser
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "shot", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.stdio = .inherit;
    b.step("run", "The browser driven through a shot list: -- <chrome> <profile folder> <shot list> <out folder>").dependOn(&run.step);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "The shot list's parser").dependOn(&tests.step);
}
