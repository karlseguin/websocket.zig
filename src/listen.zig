const std = @import("std");
const client = @import("./client.zig");

const net = std.net;
const Loop = std.event.Loop;

pub const Config = struct {
	port: u16,
	max_size: usize,
	path: []const u8,
	buffer_size: usize,
	address: []const u8,
	max_request_size: usize,
};

// const ParseFn = fn (parser: *Parser) anyerror!void;

const Allocator = std.mem.Allocator;
pub fn listen(comptime H: type, context: anytype, allocator: Allocator, config: Config) !void {
	var server = net.StreamServer.init(.{ .reuse_address = true });
	defer server.deinit();

	try server.listen(net.Address.parseIp(config.address, config.port) catch unreachable);
	std.log.info("listening at {}", .{server.listen_address});
	const client_config = client.Config{
		.path = config.path,
		.max_size = config.max_size,
		.buffer_size = config.buffer_size,
		.max_request_size = config.max_request_size,
	};

	while (true) {
		if (server.accept()) |conn| {
			const stream = client.NetStream{ .stream = conn.stream };
			const args = .{ H, client.NetStream, context, stream, client_config, allocator };
			if (comptime std.io.is_async) {
				try Loop.instance.?.runDetached(allocator, client.handle, args);
			} else {
				const t = try std.Thread.spawn(.{}, client.handle, args);
				t.detach();
			}
		} else |err| {
			std.log.err("failed to accept connection {}", .{err});
		}
	}
}
