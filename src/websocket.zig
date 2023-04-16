const std = @import("std");
const t = @import("./t.zig");
const client = @import("./client.zig");

const l = @import("./listen.zig");

pub const listen = l.listen;
pub const Config = l.Config;
pub const Client = client.Client;
pub const Message = client.Message;
pub const testing = @import("testing.zig");

pub fn frameText(comptime msg: []const u8) [frameLen(msg)]u8 {
	return frameMsg(msg, client.TEXT_FRAME);
}

pub fn frameBin(comptime msg: []const u8) [frameLen(msg)]u8 {
	return frameMsg(msg, client.BIN_FRAME);
}

fn frameMsg(comptime msg: []const u8, op_code: u8) [frameLen(msg)]u8 {
	var framed: [frameLen(msg)]u8 = undefined;
	framed[0] = op_code;

	const len = msg.len;
	if (len <= 125) {
		framed[1] = @intCast(u8, len);
		std.mem.copy(u8, framed[2..], msg);
	} else if (len < 65536) {
		framed[1] = 126;
		framed[2] = @intCast(u8, (len >> 8) & 0xFF);
		framed[3] = @intCast(u8, len & 0xFF);
		std.mem.copy(u8, framed[4..], msg);
	} else {
		framed[1] = 127;
		framed[2] = @intCast(u8, (len >> 56) & 0xFF);
		framed[3] = @intCast(u8, (len >> 48) & 0xFF);
		framed[4] = @intCast(u8, (len >> 40) & 0xFF);
		framed[5] = @intCast(u8, (len >> 32) & 0xFF);
		framed[6] = @intCast(u8, (len >> 24) & 0xFF);
		framed[7] = @intCast(u8, (len >> 16) & 0xFF);
		framed[8] = @intCast(u8, (len >> 8) & 0xFF);
		framed[9] = @intCast(u8, len & 0xFF);
		std.mem.copy(u8, framed[10..], msg);
	}
	return framed;
}

fn frameLen(comptime msg: []const u8) usize {
	if (msg.len <= 125) return msg.len + 2;
	if (msg.len < 65536) return msg.len + 4;
	return msg.len + 10;
}

comptime {
	std.testing.refAllDecls(@This());
}

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
		try t.expectEqual(@as(u8, 129), framed[0]);

		// 2 byte length marker
		try t.expectEqual(@as(u8, 126), framed[1]);

		try t.expectEqual(@as(u8, 0), framed[2]);
		try t.expectEqual(@as(u8, 130), framed[3]);

		// payload
		for (framed[4..]) |f| {
			try t.expectEqual(@as(u8, 'A'), f);
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
		try t.expectEqual(@as(u8, 130), framed[0]);

		// 2 byte length marker
		try t.expectEqual(@as(u8, 126), framed[1]);

		try t.expectEqual(@as(u8, 0), framed[2]);
		try t.expectEqual(@as(u8, 130), framed[3]);

		// payload
		for (framed[4..]) |f| {
			try t.expectEqual(@as(u8, 'A'), f);
		}
	}
}
