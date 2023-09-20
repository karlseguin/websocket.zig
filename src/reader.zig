const std = @import("std");
const lib = @import("lib.zig");

const framing = lib.framing;
const Message = lib.Message;
const MessageType = lib.MessageType;

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
	// Start position in buf of active data
	start: usize,

	// Length of active data. Can span more than one message
	// buf[start..start + len]
	len: usize,

	// Length of active message. message_len is always <= len
	// buf[start..start + message_len]
	message_len: usize,

	// Maximum supported message size
	max_size: usize,

	// The current buffer, can reference static, a buffer from the pool, or some
	// dynamically allocated memory
	buf: []u8,

	// Our static buffer. Initialized upfront.
	static: []u8,

	allocator: Allocator,

	// If we're dealing with a fragmented message (websocket fragment, not tcp
	// fragment), the state of the fragmented message is maintained here.)
	fragment: Fragmented,

	pub fn init(allocator: Allocator, buffer_size: usize, max_size: usize) !Reader {
		const static = try allocator.alloc(u8, buffer_size);

		return .{
			.start = 0,
			.len = 0,
			.message_len = 0,
			.buf = static,
			.static = static,
			.max_size = max_size,
			.allocator = allocator,
			.fragment = Fragmented.init(allocator),
		};
	}

	pub fn deinit(self: *Reader) void {
		self.fragment.deinit();

		const buf = self.buf;
		const static = self.static;
		const allocator = self.allocator;

		if (buf.ptr != static.ptr) {
			allocator.free(buf);
		}
		allocator.free(self.static);

		self.* = undefined;
	}

	pub fn readMessage(self: *Reader, stream: anytype) !?Message {
		var fragment = &self.fragment;

		var data_needed: usize = 2; // always need at least the first two bytes to start figuring things out
		var phase = ParsePhase.pre;
		var header_length: usize = 0;
		var length_of_length: usize = 0;

		var masked = true;
		var is_continuation = false;
		var message_type: MessageType = undefined;

		self.prepareForNewMessage();

		while (true) {
			if ((try self.read(stream, data_needed)) == false) {
				return error.Closed;
			}

			switch (phase) {
				.pre => {
					const msg = self.currentMessage();
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

					switch (byte1 & 15) {
						0 => is_continuation = true,
						1 => message_type = .text,
						2 => message_type = .binary,
						8 => message_type = .close,
						9 => message_type = .ping,
						10 => message_type = .pong,
						else => return error.InvalidMessageType,
					}


					// FIN, RSV1, RSV2, RSV3, OP,OP,OP,OP
					// none of the RSV bits should be set
					if (byte1 & 112 != 0) {
						return error.ReservedFlags;
					}

					if (!is_continuation and length_of_length != 0 and (message_type == .ping or message_type == .close or message_type == .pong)) {
						return error.LargeControl;
					}
				},
				.header => {
					const msg = self.currentMessage();
					var payload_length = switch (length_of_length) {
						2 => @as(u16, @intCast(msg[3])) | @as(u16, @intCast(msg[2])) << 8,
						8 => @as(u64, @intCast(msg[9])) | @as(u64, @intCast(msg[8])) << 8 | @as(u64, @intCast(msg[7])) << 16 | @as(u64, @intCast(msg[6])) << 24 | @as(u64, @intCast(msg[5])) << 32 | @as(u64, @intCast(msg[4])) << 40 | @as(u64, @intCast(msg[3])) << 48 | @as(u64, @intCast(msg[2])) << 56,
						else => msg[1] & 127,
					};
					data_needed += payload_length;
					phase = ParsePhase.payload;
				},
				.payload => {
					const msg = self.currentMessage();
					const fin = msg[0] & 128 == 128;
					var payload = msg[header_length..];

					if (masked) {
						const mask = msg[header_length - 4 .. header_length];
						framing.mask(mask, payload);
					}

					if (fin) {
						if (is_continuation) {
							if (try fragment.add(payload)) {
								return Message{ .type = fragment.type.?, .data = fragment.buf };
							}
							return error.UnfragmentedContinuation;
						}

						if (fragment.isFragmented() and (message_type == .text or message_type == .binary)) {
							return error.NestedFragment;
						}

						// just a normal single-fragment message (most common case)
						return Message{ .type = message_type, .data = payload };
					}

					if (is_continuation) {
						if (try fragment.add(payload)) {
							return null;
						}
						return error.UnfragmentedContinuation;
					} else if (message_type != .text and message_type != .binary) {
						return error.FragmentedControl;
					}

					if (fragment.isFragmented()) {
						return error.NestedFragment;
					}
					try fragment.new(message_type, payload);
					return null;
				},
			}
		}
	}

	fn prepareForNewMessage(self: *Reader) void {
		if (self.buf.ptr != self.static.ptr) {
			// The previous message was larger than static, so we allocated a buffer
			// to hold it. This buffer was sized exactly for the message, so we know that
			// it didn't overread.
			self.allocator.free(self.buf);
			self.buf = self.static;
			self.len = 0;
			self.start = 0;
			return;
		}

		const message_len = self.message_len;
		self.message_len = 0;
		if (message_len == self.len) {
			// The last read we did got exactly 1 message, no overread. This is good
			// since we can just reset our indexes to 0.
			self.len = 0;
			self.start = 0;
		} else {
			// We overread into the next message.
			self.len -= message_len;
			self.start += message_len;
		}
	}

	// Reads at least to_read bytes and returns true
	// When read fails, returns false
	fn read(self: *Reader, stream: anytype, to_read: usize) !bool {
		var len = self.len;

		if (to_read < len) {
			// we already have to_read bytes available
			self.message_len = to_read;
			return true;
		}
		const missing = to_read - len;

		var buf = self.buf;
		const start = self.start;
		const message_len = self.message_len;
		var read_start = start + len;

		if (missing > buf.len - read_start) {
			if (to_read <= buf.len) {
				// We have enough space to read this message in our
				// current buffer, but we need to recompact it.
				std.mem.copyForwards(u8, buf[0..], buf[start..read_start]);
				self.start = 0;
				read_start = len;
			} else if (to_read <= self.max_size) {
				std.debug.assert(buf.ptr == self.static.ptr);

				var dyn = try self.allocator.alloc(u8, to_read);
				if (len > 0) {
					@memcpy(dyn[0 .. len], buf[start .. start + len]);
				}

				buf = dyn;
				read_start = len;

				self.start = 0;
				self.buf = dyn;
				self.len = message_len;
			} else {
				return error.TooLarge;
			}
		}

		var total_read: usize = 0;
		while (total_read < missing) {
			const n = try stream.read(buf[(read_start + total_read)..]);
			if (n == 0) {
				return false;
			}
			total_read += n;
		}

		self.len += total_read;
		self.message_len = to_read;
		return true;
	}

	fn currentMessage(self: *Reader) []u8 {
		const start = self.start;
		return self.buf[start .. start + self.message_len];
	}
};

const t = lib.testing;
test "Reader: exact read into static with no overflow" {
	// exact read into static with no overflow
	var s = t.Stream.init();
	_ = s.add("hello1");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 20, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 6));
	try t.expectString("hello1", r.currentMessage());
	try t.expectString("hello1", r.currentMessage());
}

test "Reader: overread into static with no overflow" {
	var s = t.Stream.init();
	_ = s.add("hello1world");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 20, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 6));
	try t.expectString("hello1", r.currentMessage());
	try t.expectString("hello1", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(&s, 5));
	try t.expectString("world", r.currentMessage());
}

test "Reader: incremental read of message" {
	var s = t.Stream.init();
	_ = s.add("12345");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 20, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 2));
	try t.expectString("12", r.currentMessage());

	try t.expectEqual(true, try r.read(&s, 5));
	try t.expectString("12345", r.currentMessage());
}

test "Reader: reads with overflow" {
	var s = t.Stream.init();
	_ = s.add("hellow").add("orld!");
	defer s.deinit();


	var r = try Reader.init(t.allocator, 6, 5);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 5));
	try t.expectString("hello", r.currentMessage());
	try t.expectString("hello", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(&s, 6));
	try t.expectString("world!", r.currentMessage());
}

test "Reader: reads too large" {
	var s = t.Stream.init();
	_ = s.add("12356");
	defer s.deinit();

	var r1 = try Reader.init(t.allocator, 5, 5);
	defer r1.deinit();
	try t.expectError(error.TooLarge, r1.read(&s, 6));

	var r2 = try Reader.init(t.allocator, 5, 10);
	defer r2.deinit();
	try t.expectError(error.TooLarge, r2.read(&s, 11));
}

test "Reader: reads message larger than static" {
	var s = t.Stream.init();
	_ = s.add("hello world");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 5, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 11));
	try t.expectString("hello world", r.currentMessage());
}

test "Reader: reads fragmented message larger than static" {
	var s = t.Stream.init();
	_ = s.add("hello").add(" ").add("world!").add("nice");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 5, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(&s, 4));
	try t.expectString("nice", r.currentMessage());
}

test "Reader: reads large fragmented message after small message" {
	var s = t.Stream.init();
	_ = s.add("nice").add("hello").add(" ").add("world!");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 5, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 4));
	try t.expectString("nice", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(&s, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());
}

test "Reader: reads large fragmented message fragmented with small message" {
	var s = t.Stream.init();
	_ = s.add("nicehel").add("lo").add(" ").add("world!");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 7, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 4));
	try t.expectString("nice", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(&s, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());
}

test "Reader: reads large fragmented message with a small message when static buffer is smaller than read size" {
	var s = t.Stream.init();
	_= s.add("nicehel").add("lo").add(" ").add("world!");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 5, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 4));
	try t.expectString("nice", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(&s, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());
}

test "Reader: reads large fragmented message" {
	var s = t.Stream.init();
	_ = s.add("0").add("123456").add("789ABCabc").add("defghijklmn");
	defer s.deinit();

	var r = try Reader.init(t.allocator, 5, 20);
	defer r.deinit();

	try t.expectEqual(true, try r.read(&s, 1));
	try t.expectString("0", r.currentMessage());

	try t.expectEqual(true, try r.read(&s, 13));
	try t.expectString("0123456789ABC", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(&s, 14));
	try t.expectString("abcdefghijklmn", r.currentMessage());
}

test "Reader: fuzz" {
	const allocator = t.allocator;
	var rnd = t.getRandom();
	const random = rnd.random();

	// NOTE: there's an inner fuzzing loop also.
	// This loop generates 1 set of messages/expectations. The inner loop
	// generates random fragmentation over those messages.

	var outer: usize = 0;
	while (outer < 100) : (outer += 1) {
		// The number of message this iteration will be setting up/expecting
		const message_count = random.uintAtMost(usize, 10) + 1;
		var messages = allocator.alloc([]u8, message_count) catch unreachable;
		defer {
			for (messages) |m| {
				allocator.free(m);
			}
			allocator.free(messages);
		}

		var j: usize = 0;
		while (j < message_count) : (j += 1) {
			const len = random.uintAtMost(usize, 100) + 1;
			messages[j] = allocator.alloc(u8, len) catch unreachable;
			random.bytes(messages[j]);
		}

		// Now we have all ouf our expectations setup, let's setup our mock stream
		var stream = t.Stream.init();
		for (messages) |m| {
			_ = stream.fragmentedAdd(m);
		}

		// This is the inner fuzzing loop which takes a set of messages
		// and tries multiple time with random fragmentation
		var inner: usize = 0;
		while (inner < 10) : (inner += 1) {
			var s = stream.clone();
			defer s.deinit();

			var r = try Reader.init(t.allocator, 40, 101);
			defer r.deinit();

			for (messages) |m| {
				try t.expectEqual(true, try r.read(&s, m.len));
				try t.expectString(m, r.currentMessage());
				r.prepareForNewMessage();
			}

		}
		stream.deinit();
	}
}
