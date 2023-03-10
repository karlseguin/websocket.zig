const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("wsz", "websocket.zig");
    lib.setBuildMode(mode);
    lib.install();

    const tests = b.addTest("websocket.zig");
    tests.setBuildMode(mode);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
