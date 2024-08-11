const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();

    const allocator = gpa.allocator();

    const cases = [_][]const u8{
        "1.1.1",   "1.1.2",   "1.1.3",   "1.1.4",   "1.1.5",   "1.1.6",   "1.1.7",   "1.1.8",   "1.2.1",   "1.2.2",   "1.2.3",   "1.2.4",   "1.2.5",   "1.2.6",   "1.2.7",   "1.2.8",
        "2.1",     "2.10",    "2.11",    "2.2",     "2.3",     "2.4",     "2.5",     "2.6",     "2.7",     "2.8",     "2.9",     "3.1",     "3.2",     "3.3",     "3.4",     "3.5",
        "3.6",     "3.7",     "4.1.1",   "4.1.2",   "4.1.3",   "4.1.4",   "4.1.5",   "4.2.1",   "4.2.2",   "4.2.3",   "4.2.4",   "4.2.5",   "5.1",     "5.2",     "5.3",     "5.4",
        "5.5",     "5.6",     "5.7",     "5.8",     "5.9",     "5.10",    "5.11",    "5.12",    "5.13",    "5.14",    "5.15",    "5.16",    "5.17",    "5.18",    "5.19",    "5.20",
        "6.1.1",   "6.1.2",   "6.1.3",   "6.2.1",   "6.2.2",   "6.2.3",   "6.2.4",   "6.3.1",   "6.3.2",   "6.4.1",   "6.4.2",   "6.4.3",   "6.4.4",   "6.5.1",   "6.5.2",   "6.5.3",
        "6.5.4",   "6.5.5",   "6.6.1",   "6.6.2",   "6.6.3",   "6.6.4",   "6.6.5",   "6.6.6",   "6.6.7",   "6.6.8",   "6.6.9",   "6.6.10",  "6.6.11",  "6.7.1",   "6.7.2",   "6.7.3",
        "6.7.4",   "6.8.1",   "6.8.2",   "6.9.1",   "6.9.2",   "6.9.3",   "6.9.4",   "6.10.1",  "6.10.2",  "6.10.3",  "6.11.1",  "6.11.2",  "6.11.3",  "6.11.4",  "6.11.5",  "6.12.1",
        "6.12.2",  "6.12.3",  "6.12.4",  "6.12.5",  "6.12.6",  "6.12.7",  "6.12.8",  "6.13.1",  "6.13.2",  "6.13.3",  "6.13.4",  "6.13.5",  "6.14.1",  "6.14.2",  "6.14.3",  "6.14.4",
        "6.14.5",  "6.14.6",  "6.14.7",  "6.14.8",  "6.14.9",  "6.14.10", "6.15.1",  "6.16.1",  "6.16.2",  "6.16.3",  "6.17.1",  "6.17.2",  "6.17.3",  "6.17.4",  "6.17.5",  "6.18.1",
        "6.18.2",  "6.18.3",  "6.18.4",  "6.18.5",  "6.19.1",  "6.19.2",  "6.19.3",  "6.19.4",  "6.19.5",  "6.20.1",  "6.20.2",  "6.20.3",  "6.20.4",  "6.20.5",  "6.20.6",  "6.20.7",
        "6.21.1",  "6.21.2",  "6.21.3",  "6.21.4",  "6.21.5",  "6.21.6",  "6.21.7",  "6.21.8",  "6.22.1",  "6.22.10", "6.22.11", "6.22.12", "6.22.13", "6.22.14", "6.22.15", "6.22.16",
        "6.22.17", "6.22.18", "6.22.19", "6.22.2",  "6.22.20", "6.22.21", "6.22.22", "6.22.23", "6.22.24", "6.22.25", "6.22.26", "6.22.27", "6.22.28", "6.22.29", "6.22.3",  "6.22.30",
        "6.22.31", "6.22.32", "6.22.33", "6.22.34", "6.22.4",  "6.22.5",  "6.22.6",  "6.22.7",  "6.22.8",  "6.22.9",  "6.23.1",  "6.23.2",  "6.23.3",  "6.23.4",  "6.23.5",  "6.23.6",
        "6.23.7",  "7.1.1",   "7.1.2",   "7.1.3",   "7.1.4",   "7.1.5",   "7.1.6",   "7.3.1",   "7.3.2",   "7.3.3",   "7.3.4",   "7.3.5",   "7.3.6",   "7.5.1",   "7.7.1",   "7.7.2",
        "7.7.3",   "7.7.4",   "7.7.5",   "7.7.6",   "7.7.7",   "7.7.8",   "7.7.9",   "7.7.10",  "7.7.11",  "7.7.12",  "7.7.13",  "7.9.1",   "7.9.2",   "7.9.3",   "7.9.4",   "7.9.5",
        "7.9.6",   "7.9.7",   "7.9.8",   "7.9.9",   "7.13.1",  "7.13.2",  "9.1.1",   "9.1.2",   "9.1.3",   "9.1.4",   "9.1.5",   "9.1.6",   "9.2.1",   "9.2.2",   "9.2.3",   "9.2.4",
        "9.2.5",   "9.2.6",   "9.3.1",   "9.3.2",   "9.3.3",   "9.3.4",   "9.3.5",   "9.3.6",   "9.3.7",   "9.3.8",   "9.3.9",   "9.4.1",   "9.4.2",   "9.4.3",   "9.4.4",   "9.4.5",
        "9.4.6",   "9.4.7",   "9.4.8",   "9.4.9",   "9.5.1",   "9.5.2",   "9.5.3",   "9.5.4",   "9.5.5",   "9.5.6",   "9.6.1",   "9.6.2",   "9.6.3",   "9.6.4",   "9.6.5",   "9.6.6",
        "9.7.1",   "9.7.2",   "9.7.3",   "9.7.4",   "9.7.5",   "9.7.6",   "9.8.1",   "9.8.2",   "9.8.3",   "9.8.4",   "9.8.5",   "9.8.6",   "10.1.1",
    };

    // wait 5 seconds for autobanh server to be up
    std.time.sleep(std.time.ns_per_s * 5);

    var buffer_provider = try websocket.bufferProvider(allocator, .{ .count = 10, .size = 32768, .max = 20_000_000 });
    defer buffer_provider.deinit();

    for (cases, 0..) |case, i| {
        // if (!std.mem.eql(u8, case, "6.3.1")) continue;
        std.debug.print("running case: {s}\n", .{case});

        {
            var handler = try Handler.init(allocator, &buffer_provider, case);
            defer handler.deinit();
            handler.readLoop() catch |err| switch (err) {
                // Each of these error cases reqiuer that we close the connection, as per
                // the spec. You probably just want to re-connect. But, for the autobahn tests
                // we don't want to shutdown, since autobahn is testing these invalid cases.
                error.LargeControl => {},
                error.ReservedFlags => {},
                error.NestedFragment => {},
                error.FragmentedControl => {},
                error.InvalidMessageType => {},
                error.UnfragmentedContinuation => {},
                else => return err,
            };
        }

        if (@rem(i, 10) == 0) {
            try updateReport(allocator);
        }
    }
    try updateReport(allocator);
}

fn updateReport(allocator: std.mem.Allocator) !void {
    var client = try websocket.Client.init(allocator, .{
        .port = 9001,
        .host = "localhost",
    });

    defer client.deinit();
    try client.handshake("/updateReports?agent=websocket.zig", .{
        .headers = "host: localhost:9001\r\n",
    });

    client.close(.{}) catch unreachable;
}

const Handler = struct {
    client: websocket.Client,

    fn init(allocator: Allocator, buffer_provider: *websocket.buffer.Provider, case: []const u8) !Handler {
        const path = try std.fmt.allocPrint(allocator, "/runCase?casetuple={s}&agent=websocket.zig", .{case});
        defer allocator.free(path);

        var client = try websocket.Client.init(allocator, .{
            .port = 9001,
            .host = "localhost",
            .buffer_provider = buffer_provider,
        });
        errdefer client.deinit();
        try client.handshake(path, .{
            .timeout_ms = 5000,
            .headers = "host: localhost:9001\r\n",
        });

        return .{
            .client = client,
        };
    }

    fn deinit(self: *Handler) void {
        self.client.deinit();
    }

    fn readLoop(self: *Handler) !void {
        return self.client.readLoop(self);
    }

    pub fn serverMessage(self: *Handler, data: []u8, tpe: websocket.MessageTextType) !void {
        switch (tpe) {
            .binary => try self.client.writeBin(data),
            .text => {
                if (std.unicode.utf8ValidateSlice(data)) {
                    try self.client.write(data);
                } else {
                    self.client.close(.{ .code = 1007 }) catch unreachable;
                }
            },
        }
    }
};
