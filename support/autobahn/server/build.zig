const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "autobahn_test_server",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const websocket = b.dependency("websocket", .{}).module("websocket");
    exe.root_module.addImport("websocket", websocket);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
