const std = @import("std");
const lib = @import("lib.zig");

const framing = lib.framing;
const Message = lib.Message;
const MessageType = lib.MessageType;

const Buffer = @import("buffer.zig").Buffer;
const Fragmented = @import("fragmented.zig").Fragmented;

const Allocator = std.mem.Allocator;

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

pub const Reader = struct {
	// The buffer that we're reading bytes into.
	buffer: Buffer,

	// If we're dealing with a fragmented message (websocket fragment, not tcp
	// fragment), the state of the fragmented message is maintained here.)
	fragment: Fragmented,

	pub fn init(allocator: Allocator, buffer_size: usize, max_size: usize) !Reader {
		return .{
			.buffer = try Buffer.init(allocator, buffer_size, max_size),
			.fragment = Fragmented.init(allocator),
		};
	}

	pub fn deinit(self: *Reader) void {
		self.buffer.deinit();
		self.fragment.deinit();
	}

	pub fn read(self: *Reader, stream: anytype) !?Message {
		var buf = &self.buffer;
		var fragment = &self.fragment;

		var data_needed: usize = 2; // always need at least the first two bytes to start figuring things out
		var phase = ParsePhase.pre;
		var header_length: usize = 0;
		var length_of_length: usize = 0;

		var masked = true;
		var message_type = MessageType.invalid;

		buf.next();

		while (true) {
			if ((try buf.read(stream, data_needed)) == false) {
				return error.Closed;
			}

			switch (phase) {
				.pre => {
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
				.header => {
					const msg = buf.message();
					var payload_length = switch (length_of_length) {
						2 => @as(u16, @intCast(msg[3])) | @as(u16, @intCast(msg[2])) << 8,
						8 => @as(u64, @intCast(msg[9])) | @as(u64, @intCast(msg[8])) << 8 | @as(u64, @intCast(msg[7])) << 16 | @as(u64, @intCast(msg[6])) << 24 | @as(u64, @intCast(msg[5])) << 32 | @as(u64, @intCast(msg[4])) << 40 | @as(u64, @intCast(msg[3])) << 48 | @as(u64, @intCast(msg[2])) << 56,
						else => msg[1] & 127,
					};
					data_needed += payload_length;
					phase = ParsePhase.payload;
				},
				.payload => {
					const msg = buf.message();
					const fin = msg[0] & 128 == 128;
					var payload = msg[header_length..];
					if (masked) {
						const mask = msg[header_length - 4 .. header_length];
						framing.mask(mask, payload);
					}

					if (fin) {
						if (message_type == .continuation) {
							if (try fragment.add(payload)) {
								return Message{ .type = fragment.type, .data = fragment.buf };
							}
							return error.UnfragmentedContinuation;
						}

						if (fragment.is_fragmented() and (message_type == .text or message_type == .binary)) {
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
};
