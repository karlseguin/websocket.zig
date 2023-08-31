const std = @import("std");

const mem = std.mem;
const ascii = std.ascii;

const Allocator = mem.Allocator;

const lib = @import("lib.zig");

const Stream = lib.Stream;
const Buffer = lib.Buffer;
const Message = lib.Message;
const Handshake = lib.Handshake;
const Fragmented = lib.Fragmented;
const MessageType = lib.MessageType;

const ParsePhase = enum {
	pre,
	header,
	payload,
};

const ReadFrameResultType = enum {
	message,
	fragment,
};

const ReadFrameResult = union(ReadFrameResultType) {
	message: Message,
	fragment: void,
};

const ReadState = struct {
	// The buffer that we're reading bytes into.
	buf: *Buffer,

	// If we're dealing with a fragmented message (websocket fragment, not tcp
	// fragment), the state of the fragmented message is maintained here.)
	fragment: *Fragmented,
};

pub const Conn = struct {
	stream: Stream,
	closed: bool = false,

	pub const Config = struct {
		max_size: usize,
		buffer_size: usize,
		handshake_timeout_ms: ?u32,
	};

	pub fn writeBin(self: Conn, data: []const u8) !void {
		try writeFrame(self.stream, lib.BIN_FRAME, data);
	}

	pub fn write(self: Conn, data: []const u8) !void {
		try writeFrame(self.stream, lib.TEXT_FRAME, data);
	}

	pub fn writeFramed(self: Conn, data: []const u8) !void {
		try self.steam.writeAll(data);
	}

	pub fn close(self: *Conn) void {
		self.closed = true;
	}

	pub fn readLoop(self: *Conn, comptime H: type, allocator: Allocator, handler: H, config: Conn.Config) !void {
		var buf = try Buffer.init(allocator, config.buffer_size, config.max_size);
		var fragment = Fragmented.init(allocator);

		var state = &ReadState{
			.buf = &buf,
			.fragment = &fragment,
		};

		defer {
			buf.deinit();
			state.fragment.deinit();
		}

		var h = handler;
		const stream = self.stream;

		while (true) {
			buf.next();
			const result = readFrame(stream, state) catch |err| {
				switch (err) {
					error.LargeControl => try stream.writeAll(CLOSE_PROTOCOL_ERROR),
					error.ReservedFlags => try stream.writeAll(CLOSE_PROTOCOL_ERROR),
					else => {},
				}
				return;
			};

			if (result) |message| {
				switch (message.type) {
					.text, .binary => {
						try h.handle(message);
						state.fragment.reset();
						if (self.closed) {
							return;
						}
					},
					.pong => {
						// TODO update aliveness?
					},
					.ping => try handlePong(stream, message.data),
					.close => {
						try handleClose(stream, message.data);
						return;
					},
					else => unreachable,
				}
			}
		}
	}
};

fn readFrame(stream: Stream, state: *const ReadState) !?Message {
	var buf = state.buf;
	var fragment = state.fragment;

	var data_needed: usize = 2; // always need at least the first two bytes to start figuring things out
	var phase = ParsePhase.pre;
	var header_length: usize = 0;
	var length_of_length: usize = 0;

	var masked = true;
	var message_type = MessageType.invalid;

	while (true) {
		if ((try buf.read(stream, data_needed)) == false) {
			return error.Closed;
		}

		switch (phase) {
			ParsePhase.pre => {
				const msg = buf.message();
				var byte1 = msg[0];
				var byte2 = msg[1];
				masked = byte2 & 128 == 128;
				length_of_length = switch (byte2 & 127) {
					126 => 2,
					127 => 8,
					else => 0,
				};
				phase = ParsePhase.header;
				header_length = 2 + length_of_length;
				if (masked) {
					header_length += 4;
				}
				data_needed = header_length;

				message_type = switch (byte1 & 15) {
					0 => MessageType.continuation,
					1 => MessageType.text,
					2 => MessageType.binary,
					8 => MessageType.close,
					9 => MessageType.ping,
					10 => MessageType.pong,
					else => return error.InvalidMessageType,
				};

				// FIN, RSV1, RSV2, RSV3, OP,OP,OP,OP
				// none of the RSV bits should be set
				if (byte1 & 112 != 0) {
					return error.ReservedFlags;
				}

				if (length_of_length != 0 and (message_type == .ping or message_type == .close or message_type == .pong)) {
					return error.LargeControl;
				}
			},
			ParsePhase.header => {
				const msg = buf.message();
				var payload_length = switch (length_of_length) {
					2 => @as(u16, @intCast(msg[3])) | @as(u16, @intCast(msg[2])) << 8,
					8 => @as(u64, @intCast(msg[9])) | @as(u64, @intCast(msg[8])) << 8 | @as(u64, @intCast(msg[7])) << 16 | @as(u64, @intCast(msg[6])) << 24 | @as(u64, @intCast(msg[5])) << 32 | @as(u64, @intCast(msg[4])) << 40 | @as(u64, @intCast(msg[3])) << 48 | @as(u64, @intCast(msg[2])) << 56,
					else => msg[1] & 127,
				};
				data_needed += payload_length;
				phase = ParsePhase.payload;
			},
			ParsePhase.payload => {
				const msg = buf.message();
				const fin = msg[0] & 128 == 128;
				var payload = msg[header_length..];
				if (masked) {
					const mask = msg[header_length - 4 .. header_length];
					applyMask(mask, payload);
				}

				if (fin) {
					if (message_type == MessageType.continuation) {
						if (try fragment.add(payload)) {
							return Message{ .type = fragment.type, .data = fragment.buf };
						}
						return error.UnfragmentedContinuation;
					}

					if (fragment.is_fragmented() and (message_type == MessageType.text or message_type == MessageType.binary)) {
						return error.NestedFragment;
					}

					// just a normal single-fragment message (most common case)
					return Message{ .type = message_type, .data = payload };
				}

				switch (message_type) {
					.continuation => {
						if (try fragment.add(payload)) {
							return null;
						}
						return error.UnfragmentedContinuation;
					},
					.text, .binary => {
						if (fragment.is_fragmented()) {
							return error.NestedFragment;
						}
						try fragment.new(message_type, payload);
						return null;

						// we're going to get a fragmented message
						// var frag_buf = ArrayList(u8).init(allocator);
					},
					else => return error.FragmentedControl,
				}
			},
		}
	}
}

fn applyMask(mask: []const u8, payload: []u8) void {
	@setRuntimeSafety(false);
	const word_size = @sizeOf(usize);

	// not point optimizing this if it's a really short payload
	if (payload.len < word_size) {
		applyMaskSimple(mask, payload);
		return;
	}

	// We're going to xor this 1 word at a time.
	// But, our payload's length probably isn't a perfect multiple of word_size
	// so we'll first xor the bits until we have it aligned.
	var data = payload;
	const over = data.len % word_size;

	if (over > 0) {
		applyMaskSimple(mask, data[0..over]);
		data = data[over..];
	}

	// shift the mask based on the # bytes we already unmasked in the above loop
	var mask_template: [4]u8 = undefined;
	for (0..4) |i| {
		mask_template[i] = mask[(i + over) & 3];
	}

	var i: usize = 0;
	const mask_vector = std.simd.repeat(word_size, @as(@Vector(4, u8), mask_template[0..4].*));
	while (i < data.len) : (i += word_size) {
		var slice = data[i..i+word_size][0..word_size];
		var masked_data_slice: @Vector(word_size, u8) = slice.*;
		slice.* = masked_data_slice ^ mask_vector;
	}
}

fn applyMaskSimple(mask: []const u8, payload: []u8) void {
	@setRuntimeSafety(false);
	for (payload, 0..) |b, i| {
		payload[i] = b ^ mask[i & 3];
	}
}

fn writeFrame(stream: Stream, op_code: u8, data: []const u8) !void {
	const l = data.len;

	// maximum possible prefix length. op_code + length_type + 8byte length
	var buf: [10]u8 = undefined;
	buf[0] = op_code;

	if (l <= 125) {
		buf[1] = @intCast(l);
		try stream.writeAll(buf[0..2]);
	} else if (l < 65536) {
		buf[1] = 126;
		buf[2] = @intCast((l >> 8) & 0xFF);
		buf[3] = @intCast(l & 0xFF);
		try stream.writeAll(buf[0..4]);
	} else {
		buf[1] = 127;
		buf[2] = @intCast((l >> 56) & 0xFF);
		buf[3] = @intCast((l >> 48) & 0xFF);
		buf[4] = @intCast((l >> 40) & 0xFF);
		buf[5] = @intCast((l >> 32) & 0xFF);
		buf[6] = @intCast((l >> 24) & 0xFF);
		buf[7] = @intCast((l >> 16) & 0xFF);
		buf[8] = @intCast((l >> 8) & 0xFF);
		buf[9] = @intCast(l & 0xFF);
		try stream.writeAll(buf[0..]);
	}
	if (l > 0) {
		try stream.writeAll(data);
	}
}

const EMPTY_PONG = ([2]u8{ lib.PONG_FRAME, 0 })[0..];
fn handlePong(stream: Stream, data: []const u8) !void {
	if (data.len == 0) {
		try stream.writeAll(EMPTY_PONG);
	} else {
		try writeFrame(stream, lib.PONG_FRAME, data);
	}
}

// CLOSE_FRAME, 2 length, code
const CLOSE_NORMAL = ([_]u8{ lib.CLOSE_FRAME, 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ lib.CLOSE_FRAME, 2, 3, 234 })[0..]; //code: 1002

fn handleClose(stream: Stream, data: []const u8) !void {
	const l = data.len;

	if (l == 0) {
		return try stream.writeAll(CLOSE_NORMAL);
	}
	if (l == 1) {
		// close with a payload always has to have at least a 2-byte payload,
		// since a 2-byte code is required
		return try stream.writeAll(CLOSE_PROTOCOL_ERROR);
	}
	const code = @as(u16, @intCast(data[1])) | (@as(u16, @intCast(data[0])) << 8);
	if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
		return try stream.writeAll(CLOSE_PROTOCOL_ERROR);
	}

	if (l == 2) {
		return try stream.writeAll(CLOSE_NORMAL);
	}

	const payload = data[2..];
	if (!std.unicode.utf8ValidateSlice(payload)) {
		// if we have a payload, it must be UTF8 (why?!)
		return try stream.writeAll(CLOSE_PROTOCOL_ERROR);
	}
	return try stream.writeAll(CLOSE_NORMAL);
}

const t = lib.testing;
test "mask" {
	var r = t.getRandom();
	const random = r.random();
	const mask = [4]u8{ 10, 20, 55, 200 };

	var original = try t.allocator.alloc(u8, 10000);
	var payload = try t.allocator.alloc(u8, 10000);

	var size: usize = 0;
	while (size < 10000) {
		var slice = original[0..size];
		random.bytes(slice);
		std.mem.copy(u8, payload, slice);
		applyMask(mask[0..], payload[0..size]);

		for (slice, 0..) |b, i| {
			try t.expectEqual(b ^ mask[i & 3], payload[i]);
		}

		size += 1;
	}
	t.allocator.free(original);
	t.allocator.free(payload);
}

// the rest of this module is all tested in listen.zig, which does more end-to-end
// testing of the client's read loop
