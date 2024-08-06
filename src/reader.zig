const std = @import("std");
const lib = @import("lib.zig");
const builtin = @import("builtin");

const buffer = lib.buffer;
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

pub const Reader = struct {
	// Where we go to get buffers. Hides the buffer-getting details, which is
	// based on both how we're configured as well as how large a buffer we need
	bp: *buffer.Provider,

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
	buf: buffer.Buffer,

	// Our static buffer. Initialized upfront.
	static: buffer.Buffer,

	// If we're dealing with a fragmented message (websocket fragment, not tcp
	// fragment), the state of the fragmented message is maintained here.)
	fragment: ?Fragmented,

	pub fn init(buffer_size: usize, max_size: usize, bp: *buffer.Provider) !Reader {
		const static = try bp.static(buffer_size);

		return .{
			.bp = bp,
			.len = 0,
			.start = 0,
			.buf = static,
			.static = static,
			.message_len = 0,
			.fragment = null,
			.max_size = max_size,
		};
	}

	pub fn deinit(self: *Reader) void {
		if (self.fragment) |f| {
			f.deinit();
		}

		if (self.buf.type != .static) {
			self.bp.free(self.buf);
		}

		// the reader owns static, when it goes, static goes
		self.bp.free(self.static);
	}

	pub fn handled(self: *Reader) void {
		if (self.fragment) |f| {
			f.deinit();
			self.fragment = null;
		}
	}

	pub fn readMessage(self: *Reader, stream: anytype) !Message {
		// Our inner loop reads 1 websocket frame, which may not form a whole message
		// due to the fact that websocket has its own annoying fragmentation thing
		// going on.
		// Besides an error, we only want to return from here if we have a full message
		// which would either be:
		//  - a control frame within a fragmented message,
		//  - a fragmented message that we have all the pieces to,
		//  - a single frame (control or otherwise) that forms a full message
		//    (this last one is the most common case)
		outer: while (true) {
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
						const byte1 = msg[0];
						const byte2 = msg[1];
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
						const payload_length = switch (length_of_length) {
							2 => @as(u16, @intCast(msg[3])) | @as(u16, @intCast(msg[2])) << 8,
							8 => @as(u64, @intCast(msg[9])) | @as(u64, @intCast(msg[8])) << 8 | @as(u64, @intCast(msg[7])) << 16 | @as(u64, @intCast(msg[6])) << 24 | @as(u64, @intCast(msg[5])) << 32 | @as(u64, @intCast(msg[4])) << 40 | @as(u64, @intCast(msg[3])) << 48 | @as(u64, @intCast(msg[2])) << 56,
							else => msg[1] & 127,
						};

						if (comptime builtin.target.ptrBitWidth() < 64) {
							if (payload_length > std.math.maxInt(usize)) {
								return error.TooLarge;
							}
						}
						data_needed += @intCast(payload_length);
						phase = ParsePhase.payload;
					},
					.payload => {
						const msg = self.currentMessage();
						const fin = msg[0] & 128 == 128;
						const payload = msg[header_length..];

						if (masked) {
							const mask = msg[header_length - 4 .. header_length];
							framing.mask(mask, payload);
						}

						if (fin) {
							if (is_continuation) {
								if (self.fragment) |*f| {
									return Message{ .type = f.type, .data = try f.last(payload) };
								}
								return error.UnfragmentedContinuation;
							}

							if (self.fragment != null and (message_type == .text or message_type == .binary)) {
								return error.NestedFragment;
							}

							// just a normal single-fragment message (most common case)
							return Message{ .type = message_type, .data = payload };
						}

						if (is_continuation) {
							if (self.fragment) |*f| {
								try f.add(payload);
								continue :outer;
							}
							return error.UnfragmentedContinuation;
						} else if (message_type != .text and message_type != .binary) {
							return error.FragmentedControl;
						}

						if (self.fragment != null) {
							return error.NestedFragment;
						}
						self.fragment = try Fragmented.init(self.bp, self.max_size, message_type, payload);
						continue :outer;
					},
				}
			}
		}
	}

	fn prepareForNewMessage(self: *Reader) void {
		if (self.buf.type != .static) {
			self.bp.release(self.buf);
			self.buf = self.static;
			self.len = 0;
			self.start = 0;
			return;
		}

		// self.buf is this reader's static buffer, we might have overread
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
		const len = self.len;

		if (to_read < len) {
			// we already have to_read bytes available
			self.message_len = to_read;
			return true;
		}

		var buf = self.buf.data;

		// the position, in buf, where the current message starts
		const start = self.start;

		// the position in buf up to which we have valid data, this is where
		// we should start filling it up from.
		var pos = start + len;

		// how much data we're missing to satifisfy to_read
		const missing = to_read - len;

		if (missing > buf.len - pos) {
			if (to_read <= buf.len) {
				// We have enough space to read this message in our
				// current buffer, but we need to compact it.
				std.mem.copyForwards(u8, buf[0..], buf[start..pos]);
				self.start = 0;
				pos = len;
			} else if (to_read <= self.max_size) {
				const new_buf = try self.bp.alloc(to_read);
				if (len > 0) {
					@memcpy(new_buf.data[0..len], buf[start..pos]);
				}

				// bp.alloc can return a larger buffer (e.g. from a pool). But we don't
				// want to over-read data here, since we want to be able to cleanly
				// revert back to our static buffer
				buf = new_buf.data[0..to_read];
				pos = len;

				self.start = 0;
				self.buf = new_buf;
				self.len = self.message_len;
			} else {
				return error.TooLarge;
			}
		}

		// Once pos reaches this position, then we have to_read bytes
		const need_pos = pos + missing;

		// We can overread if this is our static buffer
		const buf_end = if (buf.ptr == self.static.data.ptr) buf.len else need_pos;

		while (pos < need_pos) {
			const n = try stream.read(buf[pos..buf_end]);
			if (n == 0) {
				return false;
			}
			pos += n;
		}

		self.len = pos - self.start;
		self.message_len = to_read;
		return true;
	}

	fn currentMessage(self: *Reader) []u8 {
		const start = self.start;
		return self.buf.data[start .. start + self.message_len];
	}
};

const t = lib.testing;
test "Reader: readMessage too larrge" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	pair.textFrame(true, "hello world");
	pair.sendBuf();

	var bp = buffer.Provider.initNoPool(t.allocator);
	var r = try Reader.init(16, 16, &bp);
	defer r.deinit();
	try t.expectError(error.TooLarge, r.readMessage(pair.server));
}

test "Reader: readMessage too large over multiple fragments" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	pair.textFrame(false, "hello world");
	pair.cont(false, " !!!_!!! ");
	pair.cont(true, "how are you doing?");
	pair.sendBuf();

	var bp = buffer.Provider.initNoPool(t.allocator);
	var r = try Reader.init(32, 32, &bp);
	defer r.deinit();
	try t.expectError(error.TooLarge, r.readMessage(pair.server));
}

test "Reader: exact read into static with no overflow" {
	// exact read into static with no overflow
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("hello1");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(20, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 6));
	try t.expectString("hello1", r.currentMessage());
	try t.expectString("hello1", r.currentMessage());
}

test "Reader: overread into static with no overflow" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("hello1world");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(20, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 6));
	try t.expectString("hello1", r.currentMessage());
	try t.expectString("hello1", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 5));
	try t.expectString("world", r.currentMessage());
}

test "Reader: incremental read of message" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("12345");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(20, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 2));
	try t.expectString("12", r.currentMessage());

	try t.expectEqual(true, try r.read(pair.server, 5));
	try t.expectString("12345", r.currentMessage());
}

test "Reader: reads with overflow" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("hellow");
	try pair.client.writeAll("orld!");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(6, 5, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 5));
	try t.expectString("hello", r.currentMessage());
	try t.expectString("hello", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 6));
	try t.expectString("world!", r.currentMessage());
}

test "Reader: reads too large" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("123456");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r1 = try Reader.init(5, 5, &bp);
	defer r1.deinit();
	try t.expectError(error.TooLarge, r1.read(pair.server, 6));

	var r2 = try Reader.init(5, 10, &bp);
	defer r2.deinit();
	try t.expectError(error.TooLarge, r2.read(pair.server, 11));
}

test "Reader: reads message larger than static" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("hello world");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(5, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 11));
	try t.expectString("hello world", r.currentMessage());
}

test "Reader: reads fragmented message larger than static (no pool)" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("hello");
	try pair.client.writeAll(" ");
	try pair.client.writeAll("world!");
	try pair.client.writeAll("nice");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(5, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 4));
	try t.expectString("nice", r.currentMessage());
}

test "Reader: reads fragmented message larger than static smaller than pool" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("hello");
	try pair.client.writeAll(" ");
	try pair.client.writeAll("world!");
	try pair.client.writeAll("nice");

	var pool = try buffer.Pool.init(t.allocator, 2, 50);
	defer pool.deinit();
	var bp = buffer.Provider.init(t.allocator, &pool, 50);

	var r = try Reader.init(5, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 4));
	try t.expectString("nice", r.currentMessage());
}

test "Reader: reads large fragmented message after small message no pool" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("nice");
	try pair.client.writeAll("hello");
	try pair.client.writeAll(" ");
	try pair.client.writeAll("world!");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(5, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 4));
	try t.expectString("nice", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());
}

test "Reader: reads large fragmented message after small with pool" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("nice");
	try pair.client.writeAll("hello");
	try pair.client.writeAll(" ");
	try pair.client.writeAll("world!");

	var pool = try buffer.Pool.init(t.allocator, 2, 50);
	defer pool.deinit();
	var bp = buffer.Provider.init(t.allocator, &pool, 50);

	var r = try Reader.init(5, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 4));
	try t.expectString("nice", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());
}

test "Reader: reads large fragmented message fragmented with small message" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("nicehel");
	try pair.client.writeAll("lo");
	try pair.client.writeAll(" ");
	try pair.client.writeAll("world!");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(7, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 4));
	try t.expectString("nice", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());
}

test "Reader: reads large fragmented message with a small message when static buffer is smaller than read size" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("nicehel");
	try pair.client.writeAll("lo");
	try pair.client.writeAll(" ");
	try pair.client.writeAll("world!");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(5, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 4));
	try t.expectString("nice", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 12));
	try t.expectString("hello world!", r.currentMessage());
	try t.expectString("hello world!", r.currentMessage());
}

test "Reader: reads large fragmented message" {
	var pair = t.SocketPair.init();
	defer pair.deinit();
	try pair.client.writeAll("0");
	try pair.client.writeAll("123456");
	try pair.client.writeAll("789ABCabc");
	try pair.client.writeAll("defghijklmn");

	var bp = buffer.Provider.initNoPool(t.allocator);

	var r = try Reader.init(5, 20, &bp);
	defer r.deinit();

	try t.expectEqual(true, try r.read(pair.server, 1));
	try t.expectString("0", r.currentMessage());

	try t.expectEqual(true, try r.read(pair.server, 13));
	try t.expectString("0123456789ABC", r.currentMessage());

	r.prepareForNewMessage();
	try t.expectEqual(true, try r.read(pair.server, 14));
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
		var pair = t.SocketPair.init();
		defer pair.deinit();

		for (messages) |m| {
			try pair.client.writeAll(m);
		}

		var bp = buffer.Provider.initNoPool(t.allocator);
		var r = try Reader.init(40, 101, &bp);
		defer r.deinit();

		for (messages) |m| {
			try t.expectEqual(true, try r.read(pair.server, m.len));
			try t.expectString(m, r.currentMessage());
			r.prepareForNewMessage();
		}
	}
}

test "Reader: readMessage full" {
	var pair = t.SocketPair.init();
	defer pair.deinit();

	var thread = try std.Thread.spawn(.{}, testMessageReader, .{pair.server});

	try pair.client.writeAll(&.{129, 5, 's', 'h', 'o', 'r', 't'});
	std.time.sleep(std.time.ns_per_ms * 5);

	try pair.client.writeAll(&.{129, 5, 'a', 'b', 'c', 'd', 'e', 129});
	std.time.sleep(std.time.ns_per_ms * 5);

	try pair.client.writeAll(&.{4, '1', '2', '3', '4', 130, 15});
	std.time.sleep(std.time.ns_per_ms * 5);

	try pair.client.writeAll("-tKAjdmaij4j");
	std.time.sleep(std.time.ns_per_ms * 5);

	try pair.client.writeAll(&.{'9', '8', '7', 130, 4, 'A', 'B'});
	std.time.sleep(std.time.ns_per_ms * 5);
	try pair.client.writeAll(&.{'C', 'D'});

	try pair.client.writeAll(&.{129, 20});
	try pair.client.writeAll(&.{'1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'A', 'B', 'C', 'D', 'E', 'F', 'G'});
	std.time.sleep(std.time.ns_per_ms * 5);
	try pair.client.writeAll(&.{'H', 'I', 'J', 129, 3, 'j', 'k', 'l'});
	thread.join();
}

fn testMessageReader(stream: std.net.Stream) void {
	// done this way so we can try in our real function
	// probably a better way to do this
	tryTestMessageReader(stream) catch unreachable;
}

fn tryTestMessageReader(stream: std.net.Stream) !void {
	var bp = buffer.Provider.initNoPool(t.allocator);
	var r = try Reader.init(10, 100, &bp);
	defer r.deinit();

	{
		const msg = try r.readMessage(stream) ;
		try t.expectEqual(.text, msg.type);
		try t.expectString("short", msg.data);
	}

	{
		const msg = try r.readMessage(stream) ;
		try t.expectEqual(.text, msg.type);
		try t.expectString("abcde", msg.data);
	}

	{
		const msg = try r.readMessage(stream) ;
		try t.expectEqual(.text, msg.type);
		try t.expectString("1234", msg.data);
	}

	{
		const msg = try r.readMessage(stream) ;
		try t.expectEqual(.binary, msg.type);
		try t.expectString("-tKAjdmaij4j987", msg.data);
	}

	{
		const msg = try r.readMessage(stream) ;
		try t.expectEqual(.binary, msg.type);
		try t.expectString("ABCD", msg.data);
	}

	{
		const msg = try r.readMessage(stream) ;
		try t.expectEqual(.text, msg.type);
		try t.expectString("1234567890ABCDEFGHIJ", msg.data);
	}

	{
		const msg = try r.readMessage(stream) ;
		try t.expectEqual(.text, msg.type);
		try t.expectString("jkl", msg.data);
	}
}
