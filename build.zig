const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run every test");
    authSteps(b, test_step, target, optimize);
}

/// The auth primitives (`src/auth/`), the GitHub client (`src/github/`) and
/// its tests against the fake GitHub (`test/`), all in `test`; the live
/// GitHub call in `smoke` alone.
fn authSteps(b: *std.Build, test_step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const github = b.createModule(.{
        .root_source_file = b.path("src/github/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    // secrets.zig's tests carry crypto.zig's, which it imports.
    const roots = [_][]const u8{ "src/auth/secrets.zig", "test/github_test.zig" };
    for (roots) |root| {
        const mod = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
        if (std.mem.startsWith(u8, root, "test/")) mod.addImport("github", github);
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = github })).step);

    const smoke = b.addExecutable(.{ .name = "github-smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("src/github/smoke.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("smoke", "One live call to api.github.com/zen (needs the network)").dependOn(&b.addRunArtifact(smoke).step);
}
