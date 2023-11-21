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
	@setRuntimeSafety(false);
	const word_size = @sizeOf(usize);

	// not point optimizing this if it's a really short payload
	if (payload.len < word_size) {
		simpleMask(m, payload);
		return;
	}

	// We're going to xor this 1 word at a time.
	// But, our payload's length probably isn't a perfect multiple of word_size
	// so we'll first xor the bits until we have it aligned.
	var data = payload;
	const over = data.len % word_size;

	if (over > 0) {
		simpleMask(m, data[0..over]);
		data = data[over..];
	}

	// shift the mask based on the # bytes we already unmasked in the above loop
	var mask_template: [4]u8 = undefined;
	for (0..4) |i| {
		mask_template[i] = m[(i + over) & 3];
	}

	var i: usize = 0;
	const mask_vector = std.simd.repeat(word_size, @as(@Vector(4, u8), mask_template[0..4].*));
	while (i < data.len) : (i += word_size) {
		var slice = data[i..i+word_size][0..word_size];
		var masked_data_slice: @Vector(word_size, u8) = slice.*;
		slice.* = masked_data_slice ^ mask_vector;
	}
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
		std.mem.copy(u8, framed[2..], msg);
	} else if (len < 65536) {
		framed[1] = 126;
		framed[2] = @intCast((len >> 8) & 0xFF);
		framed[3] = @intCast(len & 0xFF);
		std.mem.copy(u8, framed[4..], msg);
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
		std.mem.copy(u8, framed[10..], msg);
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
		std.mem.copy(u8, payload, slice);
		mask(m[0..], payload[0..size]);

		for (slice, 0..) |b, i| {
			try t.expectEqual(b ^ m[i & 3], payload[i]);
		}

		size += 1;
	}
	t.allocator.free(original);
	t.allocator.free(payload);
}
