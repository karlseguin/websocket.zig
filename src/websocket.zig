const std = @import("std");
const lib = @import("lib.zig");
pub const testing = @import("testing.zig");

const client = @import("client.zig");
const server = @import("server.zig");

pub const listen = server.listen;
pub const connect = client.connect;

pub const Conn = server.Conn;
pub const Message = lib.Message;
pub const Handshake = lib.Handshake;
pub const Client = client.Client(client.Stream);

pub const Config = struct{
	pub const Server = server.Config;
	pub const Client = client.Config;
};

pub fn frameText(comptime msg: []const u8) [lib.framing.frameLen(msg)]u8 {
	return lib.framing.frame(lib.framing.TEXT, msg);
}

pub fn frameBin(comptime msg: []const u8) [lib.framing.frameLen(msg)]u8 {
	return lib.framing.frame(lib.framing.BIN, msg);
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
