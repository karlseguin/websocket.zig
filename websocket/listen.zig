const std = @import("std");
const client = @import("./client.zig");

const net = std.net;
const Loop = std.event.Loop;

pub const Config = struct {
    port: u16,
    max_size: usize,
    buffer_size: usize,
    address: []const u8,
};

const Allocator = std.mem.Allocator;
pub fn listen(comptime H: type, context: anytype, allocator: Allocator, config: Config) !void {
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    try server.listen(net.Address.parseIp(config.address, config.port) catch unreachable);
    std.log.info("listening at {}", .{server.listen_address});
    const max_size = config.max_size;
    const buffer_size = config.buffer_size;

    while (true) {
        if (server.accept()) |conn| {
            const stream = client.NetStream{ .stream = conn.stream };
            const args = .{ H, client.NetStream, context, stream, buffer_size, max_size, allocator };
            try Loop.instance.?.runDetached(allocator, client.handle, args);
        } else |err| {
            std.log.err("failed to accept connection {}", .{err});
        }
    }
}
