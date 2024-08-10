const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_module = b.addModule("websocket", .{
        .root_source_file = b.path("src/websocket.zig"),
    });

    {
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", false);
        websocket_module.addOptions("build", options);
    }

    {
        // run tests
        const tests = b.addTest(.{
            .root_source_file = b.path("src/websocket.zig"),
            .target = target,
            .optimize = optimize,
            .test_runner = b.path("test_runner.zig"),
        });
        tests.linkLibC();
        const force_blocking = b.option(bool, "force_blocking", "Force blocking mode") orelse false;
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", force_blocking);
        tests.root_module.addOptions("build", options);

        const run_test = b.addRunArtifact(tests);
        run_test.has_side_effects = true;

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_test.step);
    }
}
