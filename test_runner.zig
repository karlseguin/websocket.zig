// in your build.zig, you can specify a custom test runner:
// const tests = b.addTest(.{
//    .root_module = $MODULE_BEING_TESTED,
//    .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
// });

pub const std_options = std.Options{ .log_scope_levels = &[_]std.log.ScopeLevel{
    .{ .scope = .websocket, .level = .warn },
} };

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const BORDER: [80]u8 = @splat('=');

// use in custom panic handler
var current_test: ?[]const u8 = null;

/// Io instance exposed for use by test code.
/// NOTE: test_runner.zig cannot directly set src/t.zig's test_io because
/// @import("src/t.zig") creates a duplicate module-path collision (websocket.zig
/// already imports t.zig as "t.zig" within the src/ root). A build.zig change
/// to expose "t" as a named module is needed to wire this properly (Phase 5).
/// For now, we initialize std.testing.io_instance so that std.testing.io works,
/// and t.zig's getRandom() uses std.testing.io.
pub var test_io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const environ = init.environ_map;

    // Initialize std.testing.io_instance so that std.testing.io is valid.
    // Tests and helpers that need Io (e.g. t.zig's getRandom) use std.testing.io.
    // Note: global_single_threaded does not support concurrency or cancellation,
    // but that is fine for the test suite.
    std.testing.io_instance = std.Io.Threaded.global_single_threaded.*;

    // Also expose the real Io from process.Init for callers who want it.
    test_io = io;

    const env = Env.init(environ);

    var slowest = SlowTracker.init(gpa, io, 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |tf| {
        if (isSetup(tf)) {
            tf.func() catch |err| {
                Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ tf.name, err });
                return err;
            };
        }
    }

    for (builtin.test_functions) |tf| {
        if (isSetup(tf) or isTeardown(tf)) {
            continue;
        }

        var status = Status.pass;
        slowest.startTiming();

        const is_unnamed_test = isUnnamed(tf);
        if (env.filter) |f| {
            if (!is_unnamed_test and std.mem.indexOf(u8, tf.name, f) == null) {
                continue;
            }
        }

        const friendly_name = blk: {
            const name = tf.name;
            var it = std.mem.splitScalar(u8, name, '.');
            while (it.next()) |value| {
                if (std.mem.eql(u8, value, "test")) {
                    const rest = it.rest();
                    break :blk if (rest.len > 0) rest else name;
                }
            }
            break :blk name;
        };

        current_test = friendly_name;
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        const result = tf.func();
        current_test = null;

        const ns_taken = slowest.endTiming(friendly_name);

        if (std.testing.allocator_instance.deinit() != 0) {
            leak += 1;
            Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        }

        if (result) |_| {
            pass += 1;
        } else |err| switch (err) {
            error.SkipZigTest => {
                skip += 1;
                status = .skip;
            },
            else => {
                status = .fail;
                fail += 1;
                Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
                if (env.fail_first) {
                    break;
                }
            },
        }

        if (env.verbose) {
            const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
            Printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
        } else {
            Printer.status(status, ".", .{});
        }
    }

    for (builtin.test_functions) |tf| {
        if (isTeardown(tf)) {
            tf.func() catch |err| {
                Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ tf.name, err });
                return err;
            };
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    Printer.fmt("\n", .{});
    try slowest.display();
    Printer.fmt("\n", .{});
    std.process.exit(if (fail == 0) 0 else 1);
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    allocator: Allocator,
    max: usize,
    slowest: SlowestQueue,
    io: std.Io,
    start: std.Io.Timestamp,

    fn init(allocator: Allocator, io: std.Io, count: u32) SlowTracker {
        var slowest = SlowestQueue.initContext({});
        slowest.ensureTotalCapacity(allocator, count) catch @panic("OOM");
        return .{
            .allocator = allocator,
            .max = count,
            .io = io,
            .start = std.Io.Timestamp.now(io, .awake),
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: *SlowTracker) void {
        self.slowest.deinit(self.allocator);
    }

    fn startTiming(self: *SlowTracker) void {
        self.start = std.Io.Timestamp.now(self.io, .awake);
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8) u64 {
        const end = std.Io.Timestamp.now(self.io, .awake);
        const duration = self.start.durationTo(end);
        const ns: u64 = @intCast(@max(0, duration.nanoseconds));

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.push(self.allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.popMin();
        slowest.push(self.allocator, TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.popMin()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    fn init(environ: *std.process.Environ.Map) Env {
        return .{
            .verbose = readEnvBool(environ, "TEST_VERBOSE", true),
            .fail_first = readEnvBool(environ, "TEST_FAIL_FIRST", false),
            .filter = readEnv(environ, "TEST_FILTER"),
        };
    }

    fn readEnv(environ: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
        return environ.get(key);
    }

    fn readEnvBool(environ: *std.process.Environ.Map, key: []const u8, deflt: bool) bool {
        const value = readEnv(environ, key) orelse return deflt;
        return std.ascii.eqlIgnoreCase(value, "true");
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n{s}\x1b[0m\n", .{ BORDER, ct, BORDER });
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(tf: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = tf.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(tf: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, tf.name, "tests:beforeAll");
}

fn isTeardown(tf: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, tf.name, "tests:afterAll");
}
