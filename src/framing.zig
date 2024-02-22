const std = @import("std");
const lib = @import("lib.zig");

pub const OpCode = enum(u8) {
	text = 128 | 1,
	binary = 128 | 2,
	close = 128 | 8,
	ping = 128 | 9,
	pong = 128 | 10,
};

pub fn mask(m: []const u8, payload: []u8) void {
	var data = payload;
	const vector_size = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);
	if (data.len >= vector_size) {
		const mask_vector = std.simd.repeat(vector_size, @as(@Vector(4, u8), m[0..4].*));
		while (data.len >= vector_size) {
			const slice = data[0..vector_size];
			const masked_data_slice: @Vector(vector_size, u8) = slice.*;
			slice.* = masked_data_slice ^ mask_vector;
			data = data[vector_size..];
		}
	}
	simpleMask(m, data);
}

fn simpleMask(m: []const u8, payload: []u8) void {
	@setRuntimeSafety(false);
	for (payload, 0..) |b, i| {
		payload[i] = b ^ m[i & 3];
	}
}

pub fn frame(op_code: OpCode, comptime msg: []const u8) [frameLen(msg)]u8 {
	var framed: [frameLen(msg)]u8 = undefined;
	framed[0] = @intFromEnum(op_code);

	const len = msg.len;
	if (len <= 125) {
		framed[1] = @intCast(len);
		@memcpy(framed[2..], msg);
	} else if (len < 65536) {
		framed[1] = 126;
		framed[2] = @intCast((len >> 8) & 0xFF);
		framed[3] = @intCast(len & 0xFF);
		@memcpy(framed[4..], msg);
	} else {
		framed[1] = 127;
		framed[2] = @intCast((len >> 56) & 0xFF);
		framed[3] = @intCast((len >> 48) & 0xFF);
		framed[4] = @intCast((len >> 40) & 0xFF);
		framed[5] = @intCast((len >> 32) & 0xFF);
		framed[6] = @intCast((len >> 24) & 0xFF);
		framed[7] = @intCast((len >> 16) & 0xFF);
		framed[8] = @intCast((len >> 8) & 0xFF);
		framed[9] = @intCast(len & 0xFF);
		@memcpy(framed[10..], msg);
	}
	return framed;
}

pub fn frameLen(comptime msg: []const u8) usize {
	if (msg.len <= 125) return msg.len + 2;
	if (msg.len < 65536) return msg.len + 4;
	return msg.len + 10;
}

const t = lib.testing;
test "mask" {
	var r = t.getRandom();
	const random = r.random();
	const m = [4]u8{ 10, 20, 55, 200 };

	var original = try t.allocator.alloc(u8, 10000);
	var payload = try t.allocator.alloc(u8, 10000);

	var size: usize = 0;
	while (size < 1000) {
		const slice = original[0..size];
		random.bytes(slice);
		@memcpy(payload[0..size], slice);
		mask(m[0..], payload[0..size]);

		for (slice, 0..) |b, i| {
			try t.expectEqual(b ^ m[i & 3], payload[i]);
		}

		size += 1;
	}
	t.allocator.free(original);
	t.allocator.free(payload);
}
