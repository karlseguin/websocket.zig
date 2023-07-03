const std = @import("std");
const builtin = @import("builtin");
const t = @import("t.zig");
const Pool = @import("pool.zig").Pool;
const client = @import("client.zig");

const Conn = if (builtin.is_test) *t.Stream else std.net.StreamServer.Connection;

const os = std.os;
const net = std.net;
const Loop = std.event.Loop;

pub const Config = struct {
	port: u16 = 9223,
	max_size: usize = 65536,
	max_headers: usize = 0,
	buffer_size: usize = 4096,
	address: []const u8 = "127.0.0.1",
	handshake_max_size: usize = 1024,
	handshake_pool_size: usize = 50,
	handshake_timeout_ms: ?u32 = 10_000,
};

const Allocator = std.mem.Allocator;
pub fn listen(comptime H: type, allocator: Allocator, context: anytype, config: Config) !void {
	var server = net.StreamServer.init(.{ .reuse_address = true });
	defer server.deinit();

	var pool = try Pool.init(allocator, config.handshake_pool_size, config.handshake_max_size, config.max_headers);
	defer pool.deinit();

	try server.listen(net.Address.parseIp(config.address, config.port) catch unreachable);
	// TODO: I believe this should work, but it currently doesn't on 0.11-dev. Instead I have to
	// hardcode 1 for the setsocopt NODELAY option
	// if (@hasDecl(os.TCP, "NODELAY")) {
	// 	try os.setsockopt(server.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
	// }
	try os.setsockopt(server.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));

	const client_config = client.Config{
		.max_size = config.max_size,
		.buffer_size = config.buffer_size,
		.handshake_timeout_ms = config.handshake_timeout_ms,
	};

	while (true) {
		if (server.accept()) |conn| {
			const c: Conn = if (comptime builtin.is_test) undefined else conn;
			const args = .{ H, allocator, context, c, client_config, &pool };
			if (comptime std.io.is_async) {
				try Loop.instance.?.runDetached(allocator, client.handle, args);
			} else {
				const thread = try std.Thread.spawn(.{}, client.handle, args);
				thread.detach();
			}
		} else |err| {
			std.log.err("failed to accept connection {}", .{err});
		}
	}
}
