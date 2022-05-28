const std = @import("std");
const client = @import("./client.zig");

const net = std.net;

const Allocator = std.mem.Allocator;
pub fn listen(comptime H: type, context: anytype, allocator: Allocator, port: u16) !void {
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();

    try server.listen(net.Address.parseIp("127.0.0.1", port) catch unreachable);
    std.log.info("listening at {}", .{server.listen_address});

    while (true) {
        if (server.accept()) |conn| {
            _ = async client.handle(H, client.NetStream, context, client.NetStream{ .stream = conn.stream }, allocator);
        } else |err| {
            std.log.err("failed to accept connection {}", .{err});
        }
    }
}
