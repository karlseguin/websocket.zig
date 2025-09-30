const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_module = b.addModule("websocket", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/websocket.zig"),
    });

    {
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", false);
        websocket_module.addOptions("build", options);
    }

    {
        // run tests
        const test_filter = b.option([]const []const u8, "test-filter", "Filters for tests: specify multiple times for multiple filters");
        const tests = b.addTest(.{
            .root_module = websocket_module,
            .filters = test_filter orelse &.{},
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        tests.linkLibC();
        const force_blocking = b.option(bool, "force_blocking", "Force blocking mode") orelse false;
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", force_blocking);
        tests.root_module.addOptions("build", options);

        const run_test = b.addRunArtifact(tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_test.step);
    }
}
