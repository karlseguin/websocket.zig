const std = @import("std");
const lib = @import("lib.zig");
pub const testing = @import("testing.zig");

const buffer = lib.buffer;
const client = @import("client.zig");
const server = @import("server.zig");

pub const connect = client.connect;

// Many of these are only exposed for advanced integration (e.g. the http.zig
// and websocket.zig integration)
pub const Conn = lib.Conn;
pub const Message = lib.Message;
pub const Client = client.Client;
pub const Server = server.Server;
pub const OpCode = lib.framing.OpCode;
pub const Handshake = lib.Handshake;
pub const TextType = enum{
	text,
	binary,
};

pub const Config = struct{
	pub const Server = server.Config;
	pub const Client = client.Config;
};

const Allocator = std.mem.Allocator;
pub fn bufferProvider(allocator: Allocator, pool_buffer_count: u16, pool_buffer_size: usize) !*buffer.Provider {
	const pool = try allocator.create(buffer.Pool);
	pool.* = try buffer.Pool.init(allocator, pool_buffer_count, pool_buffer_size);

	const provider = try allocator.create(buffer.Provider);
	provider.* = buffer.Provider.init(allocator, pool, pool_buffer_size);
	return provider;
}

pub fn frameText(comptime msg: []const u8) [lib.framing.frameLen(msg)]u8 {
	return lib.framing.frame(.text, msg);
}

pub fn frameBin(comptime msg: []const u8) [lib.framing.frameLen(msg)]u8 {
	return lib.framing.frame(.binary, msg);
}

comptime {
	std.testing.refAllDecls(@This());
}

const t = lib.testing;
test "frameText" {
	{
		// short
		const framed = frameText("hello");
		try t.expectString(&[_]u8{129, 5, 'h', 'e', 'l', 'l', 'o'}, &framed);
	}

	{
		const msg = "A" ** 130;
		const framed = frameText(msg);

		try t.expectEqual(134, framed.len);

		// text type
		try t.expectEqual(129, framed[0]);

		// 2 byte length marker
		try t.expectEqual(126, framed[1]);

		try t.expectEqual(0, framed[2]);
		try t.expectEqual(130, framed[3]);

		// payload
		for (framed[4..]) |f| {
			try t.expectEqual('A', f);
		}
	}
}

test "frameBin" {
	{
		// short
		const framed = frameBin("hello");
		try t.expectString(&[_]u8{130, 5, 'h', 'e', 'l', 'l', 'o'}, &framed);
	}

	{
		const msg = "A" ** 130;
		const framed = frameBin(msg);

		try t.expectEqual(134, framed.len);

		// text type
		try t.expectEqual(130, framed[0]);

		// 2 byte length marker
		try t.expectEqual(126, framed[1]);

		try t.expectEqual(0, framed[2]);
		try t.expectEqual(130, framed[3]);

		// payload
		for (framed[4..]) |f| {
			try t.expectEqual('A', f);
		}
	}
}
