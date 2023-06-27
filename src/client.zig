const std = @import("std");
const t = @import("t.zig");
const builtin = @import("builtin");

const mem = std.mem;
const ascii = std.ascii;
const Allocator = mem.Allocator;
const Pool = @import("pool.zig").Pool;
const Buffer = @import("buffer.zig").Buffer;
const Request = @import("request.zig").Request;
const Handshake = @import("handshake.zig").Handshake;
const Fragmented = @import("fragmented.zig").Fragmented;

const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;
const Conn = if (builtin.is_test) *t.Stream else std.net.StreamServer.Connection;

pub const TEXT_FRAME = 128 | 1;
pub const BIN_FRAME = 128 | 2;
pub const CLOSE_FRAME = 128 | 8;
pub const PING_FRAME = 128 | 9;
pub const PONG_FRAME = 128 | 10;

pub const MessageType = enum {
	continuation,
	text,
	binary,
	close,
	ping,
	pong,
	invalid,
};

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

pub const Error = error{
	Closed,
	InvalidMessageType,
	FragmentedControl,
	MessageTooLarge,
	NestedFragment,
	UnfragmentedContinuation,
	LargeControl,
	ReservedFlags,
};

pub const Message = struct {
	type: MessageType,
	data: []const u8,
};

pub const Config = struct {
	max_size: usize,
	buffer_size: usize,
};

pub const Client = struct {
	stream: Stream,
	closed: bool = false,

	const Self = @This();

	pub fn writeBin(self: Self, data: []const u8) !void {
		try writeFrame(self.stream, BIN_FRAME, data);
	}

	pub fn write(self: Self, data: []const u8) !void {
		try writeFrame(self.stream, TEXT_FRAME, data);
	}

	pub fn writeFramed(self: Self, data: []const u8) !void {
		try self.steam.writeAll(data);
	}

	pub fn close(self: *Self) void {
		self.closed = true;
	}
};

pub fn handle(comptime H: type, allocator: Allocator, context: anytype, conn: Conn, config: Config, pool: *Pool) void {
	const stream = if (comptime builtin.is_test) conn else conn.stream;
	defer stream.close();
	handleLoop(H, allocator, context, stream, config, pool) catch return;
}

fn handleLoop(comptime H: type, allocator: Allocator, context: anytype, stream: Stream, config: Config, pool: *Pool) !void {
	var client = Client{ .stream = stream };
	var handler: H = undefined;

	{
		// This block represents handshake_state's lifetime
		var handshake_state = try pool.acquire();
		defer pool.release(handshake_state);

		const request = Request.read(stream, handshake_state.buffer) catch |err| {
			return Request.close(stream, err);
		};

		const h = Handshake.parse(request, &handshake_state.headers) catch |err| {
			return Handshake.close(stream, err);
		};

		handler = H.init(h, &client, context) catch |err| {
			return Handshake.close(stream, err);
		};

		// handshake_buffer (via `h` which references it), must be valid up until
		// this call to reply
		h.reply(stream) catch |err| {
			handler.close();
			return err;
		};
	}

	defer handler.close();

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

	while (true) {
		buf.next();
		const result = readFrame(stream, state) catch |err| {
			switch (err) {
				Error.LargeControl => try stream.writeAll(CLOSE_PROTOCOL_ERROR),
				Error.ReservedFlags => try stream.writeAll(CLOSE_PROTOCOL_ERROR),
				else => {},
			}
			return;
		};

		if (result) |message| {
			switch (message.type) {
				.text, .binary => {
					try handler.handle(message);
					state.fragment.reset();
					if (client.closed) {
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
			return Error.Closed;
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
					else => return Error.InvalidMessageType,
				};

				// FIN, RSV1, RSV2, RSV3, OP,OP,OP,OP
				// none of the RSV bits should be set
				if (byte1 & 112 != 0) {
					return Error.ReservedFlags;
				}

				if (length_of_length != 0 and (message_type == .ping or message_type == .close or message_type == .pong)) {
					return Error.LargeControl;
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
						return Error.UnfragmentedContinuation;
					}

					if (fragment.is_fragmented() and (message_type == MessageType.text or message_type == MessageType.binary)) {
						return Error.NestedFragment;
					}

					// just a normal single-fragment message (most common case)
					return Message{ .type = message_type, .data = payload };
				}

				switch (message_type) {
					.continuation => {
						if (try fragment.add(payload)) {
							return null;
						}
						return Error.UnfragmentedContinuation;
					},
					.text, .binary => {
						if (fragment.is_fragmented()) {
							return Error.NestedFragment;
						}
						try fragment.new(message_type, payload);
						return null;

						// we're going to get a fragmented message
						// var frag_buf = ArrayList(u8).init(allocator);
					},
					else => return Error.FragmentedControl,
				}
			},
		}
	}
}

fn applyMask(mask: []const u8, payload: []u8) void {
	@setRuntimeSafety(false);
	const word_size = @sizeOf(usize);

	// not point optimizing this if it's a really short payload
	if (payload.len < word_size * 2) {
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

	var i: usize = 0;
	var mask_word: [word_size]u8 = undefined;
	while (i < word_size) {
		mask_word[i] = mask[(i + over) & 3];
		i += 1;
	}
	const mask_value: usize = @bitCast(mask_word);

	i = 0;
	while (i < data.len) {
		const slice = data[i .. i + word_size];
		std.mem.bytesAsSlice(usize, slice)[0] ^= mask_value;
		i += word_size;
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

const EMPTY_PONG = ([2]u8{ PONG_FRAME, 0 })[0..];
fn handlePong(stream: Stream, data: []const u8) !void {
	if (data.len == 0) {
		try stream.writeAll(EMPTY_PONG);
	} else {
		try writeFrame(stream, PONG_FRAME, data);
	}
}

// CLOSE_FRAME, 2 lenght, code
const CLOSE_NORMAL = ([_]u8{ CLOSE_FRAME, 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ CLOSE_FRAME, 2, 3, 234 })[0..]; //code: 1002

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

const TEST_BUFFER_SIZE = 512;
const TestContext = struct {};
const TestHandler = struct {
	client: *Client,

	pub fn init(_: Handshake, client: *Client, _: TestContext) !TestHandler {
		return TestHandler{
			.client = client,
		};
	}

	// echo it back, so that it gets written back into our t.Stream
	pub fn handle(self: TestHandler, message: Message) !void {
		const data = message.data;
		switch (message.type) {
			.binary => try self.client.writeBin(data),
			.text => try self.client.write(data),
			else => unreachable,
		}
	}

	pub fn close(_: TestHandler) void {}
};

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

test "read messages" {
	{
		// simple small message
		var expected = [_]Expect{Expect.text("over 9000!")};
		var stream = t.Stream.handshake();
		try testReadFrames(stream.textFrame(true, "over 9000!"), expected[0..]);
	}

	{
		// single message exactly TEST_BUFFER_SIZE
		// header will be 8 bytes, so we make the messae TEST_BUFFER_SIZE - 8 bytes
		const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 8);
		var expected = [_]Expect{Expect.text(msg[0..])};
		var stream = t.Stream.handshake();
		try testReadFrames(stream.textFrame(true, msg[0..]), expected[0..]);
	}

	{
		// single message that is bigger than TEST_BUFFER_SIZE
		// header is 8 bytes, so if we make our message TEST_BUFFER_SIZE - 7, we'll
		// end up with a message which is exactly 1 byte larger than TEST_BUFFER_SIZE
		const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 7);
		var expected = [_]Expect{Expect.text(msg[0..])};
		var stream = t.Stream.handshake();
		try testReadFrames(stream.textFrame(true, msg[0..]), expected[0..]);
	}

	{
		// single message that is much bigger than TEST_BUFFER_SIZE
		const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE * 2);
		var expected = [1]Expect{Expect.text(msg[0..])};
		var stream = t.Stream.handshake();
		try testReadFrames(stream.textFrame(true, msg[0..]), expected[0..]);
	}

	{
		// multiple small messages
		var expected = [_]Expect{ Expect.text("over"), Expect.text(" "), Expect.pong(""), Expect.text("9000"), Expect.text("!") };
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(true, "over")
			.textFrame(true, " ")
			.ping()
			.textFrame(true, "9000")
			.textFrame(true, "!"), expected[0..]);
	}

	{
		// two messages, individually smaller than TEST_BUFFER_SIZE, but
		// their total length is greater than TEST_BUFFER_SIZE (this is an important
		// test as it requires special handling since the two messages are valid
		// but don't fit in a single buffer)
		const msg1 = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 100);
		const msg2 = [_]u8{'b'} ** 200;
		var expected = [_]Expect{ Expect.text(msg1[0..]), Expect.text(msg2[0..]) };
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(true, msg1[0..])
			.textFrame(true, msg2[0..]), expected[0..]);
	}

	{
		// two messages, the first bigger than TEST_BUFFER_SIZE, the second smaller
		const msg1 = [_]u8{'a'} ** (TEST_BUFFER_SIZE + 100);
		const msg2 = [_]u8{'b'} ** 200;
		var expected = [_]Expect{ Expect.text(msg1[0..]), Expect.text(msg2[0..]) };
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(true, msg1[0..])
			.textFrame(true, msg2[0..]), expected[0..]);
	}

	{
		// Simple fragmented (websocket fragementation)
		var expected = [_]Expect{Expect.text("over 9000!")};
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(false, "over")
			.cont(true, " 9000!"), expected[0..]);
	}

	{
		// large fragmented (websocket fragementation)
		const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE * 2 + 600);
		var expected  = [_]Expect{Expect.text(msg[0..])};
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(false, msg[0 .. TEST_BUFFER_SIZE + 100])
			.cont(true, msg[TEST_BUFFER_SIZE + 100 ..]), expected[0..]);
	}

	{
		// Fragmented with control in between
		var expected = [_]Expect{ Expect.pong(""), Expect.pong(""), Expect.text("over 9000!") };
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(false, "over")
			.ping()
			.cont(false, " ")
			.ping()
			.cont(true, "9000!"), expected[0..]);
	}

	{
		// Large Fragmented with control in between
		const msg = [_]u8{'b'} ** (TEST_BUFFER_SIZE * 2 + 600);
		var expected = [_]Expect{ Expect.pong(""), Expect.pong(""), Expect.text(msg[0..]) };
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(false, msg[0 .. TEST_BUFFER_SIZE + 100])
			.ping()
			.cont(false, msg[TEST_BUFFER_SIZE + 100 .. TEST_BUFFER_SIZE + 110])
			.ping()
			.cont(true, msg[TEST_BUFFER_SIZE + 110 ..]), expected[0..]);
	}

	{
		// Empty fragmented messages
		var expected = [_]Expect{Expect.text("")};
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(false, "")
			.cont(false, "")
			.cont(true, ""), expected[0..]);
	}

	{
		// max-size control
		const msg = [_]u8{'z'} ** 125;
		var expected = [_]Expect{Expect.pong(msg[0..])};
		var stream = t.Stream.handshake();
		try testReadFrames(stream.pingPayload(msg[0..]), expected[0..]);
	}
}

test "readFrame erros" {
	{
		// Nested non-control fragmented (websocket fragementation)
		var expected = [_]Expect{};
		var s = t.Stream.handshake();
		try testReadFrames(s
			.textFrame(false, "over")
			.textFrame(false, " 9000!"), expected[0..]);
	}

	{
		// Nested non-control fragmented FIN (websocket fragementation)
		var expected = [_]Expect{};
		var s = t.Stream.handshake();
		try testReadFrames(s
			.textFrame(false, "over")
			.textFrame(true, " 9000!"), expected[0..]);
	}

	{
		// control too big
		const msg = [_]u8{'z'} ** 126;
		var expected = [_]Expect{Expect.close(CLOSE_PROTOCOL_ERROR)};
		var s = t.Stream.handshake();
		try testReadFrames(s.pingPayload(msg[0..]), expected[0..]);
	}

	{
		// reserved bit1
		var expected = [_]Expect{Expect.close(CLOSE_PROTOCOL_ERROR)};
		var s = t.Stream.handshake();
		_ = s.textFrameReserved(true, "over9000", 64);
		try testReadFrames(&s, expected[0..]);
	}

	{
		// reserved bit2
		var expected = [_]Expect{Expect.close(CLOSE_PROTOCOL_ERROR)};
		var s = t.Stream.handshake();
		_ = s.textFrameReserved(true, "over9000", 32);
		try testReadFrames(&s, expected[0..]);
	}

	{
		// reserved bit3
		var expected = [_]Expect{Expect.close(CLOSE_PROTOCOL_ERROR)};
		var s = t.Stream.handshake();
		_ = s.textFrameReserved(true, "over9000", 16);
		try testReadFrames(&s, expected[0..]);
	}
}

fn testReadFrames(s: *t.Stream, expected: []Expect) !void {
	defer s.deinit();
	errdefer s.deinit();

	var count: usize = 0;

	// we don't currently use this
	var context = TestContext{};

	// test with various random  TCP fragmentations
	// our t.Stream automatically fragments the frames on the first
	// call to read. Note this is TCP fragmentation, not websocket fragmentation
	const config = Config{
		.buffer_size = TEST_BUFFER_SIZE,
		.max_size = TEST_BUFFER_SIZE * 10,
	};

	var pool = try Pool.init(t.allocator, 10, 512, 10);
	defer pool.deinit();

	while (count < 100) : (count += 1) {
		var stream = s.clone();
		handle(TestHandler, t.allocator, context, &stream, config, &pool);
		try t.expectEqual(stream.closed, true);

		const r = stream.asReceived(true);
		const messages = r.messages;
		errdefer r.deinit();
		errdefer stream.deinit();

		try t.expectEqual(expected.len, messages.len);

		var i: usize = 0;
		while (i < expected.len) : (i += 1) {
			const e = expected[i];
			const actual = messages[i];
			try t.expectEqual(e.type, actual.type);
			try t.expectString(e.data, actual.data);
		}
		r.deinit();
		stream.deinit();
	}
}

const Expect = struct {
	type: MessageType,
	data: []const u8,

	fn text(data: []const u8) Expect {
		return .{
			.data = data,
			.type = .text,
		};
	}

	fn pong(data: []const u8) Expect {
		return .{
			.data = data,
			.type = .pong,
		};
	}

	fn close(data: []const u8) Expect {
		return .{
			// strip out the op_code + length
			.data = data[2..],
			.type = .close,
		};
	}
};
