const std = @import("std");
const lib = @import("lib.zig");

const HandshakePool = @import("handshake.zig").Pool;

const framing = lib.framing;
const Reader = lib.Reader;
const NetConn = lib.NetConn;
const OpCode = framing.OpCode;

const os = std.os;
const net = std.net;
const Loop = std.event.Loop;
const log = std.log.scoped(.websocket);

const Allocator = std.mem.Allocator;

pub const Config = struct {
	port: u16 = 9223,
	max_size: usize = 65536,
	max_headers: usize = 0,
	buffer_size: usize = 4096,
	address: []const u8 = "127.0.0.1",
	handshake_max_size: usize = 1024,
	handshake_pool_count: usize = 50,
	handshake_timeout_ms: ?u32 = 10_000,
	handle_ping: bool = false,
	handle_pong: bool = false,
	handle_close: bool = false,
};

pub fn listen(comptime H: type, allocator: Allocator, context: anytype, config: Config) !void {
	var server = net.StreamServer.init(.{ .reuse_address = true });
	defer server.deinit();

	var handshake_pool = try HandshakePool.init(allocator, config.handshake_pool_count, config.handshake_max_size, config.max_headers);
	defer handshake_pool.deinit();

	try server.listen(net.Address.parseIp(config.address, config.port) catch unreachable);
	// TODO: I believe this should work, but it currently doesn't on 0.11-dev. Instead I have to
	// hardcode 1 for the setsocopt NODELAY option
	// if (@hasDecl(os.TCP, "NODELAY")) {
	// 	try os.setsockopt(server.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
	// }
	try os.setsockopt(server.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));

	while (true) {
		if (server.accept()) |conn| {
			const args = .{ H, allocator, context, conn, &config, &handshake_pool };
			if (comptime std.io.is_async) {
				try Loop.instance.?.runDetached(allocator, clientLoop, args);
			} else {
				const thread = try std.Thread.spawn(.{}, clientLoop, args);
				thread.detach();
			}
		} else |err| {
			log.err("failed to accept connection {}", .{err});
		}
	}
}

fn clientLoop(comptime H: type, allocator: Allocator, context: anytype, net_conn: NetConn, config: *const Config, handshake_pool: *HandshakePool) void {
	const Handshake = lib.Handshake;

	std.os.maybeIgnoreSigpipe();

	const stream = net_conn.stream;
	defer stream.close();

	var handler: H = undefined;
	var conn = Conn{
		.stream = stream,
		._handle_ping = config.handle_ping,
		._handle_pong = config.handle_pong,
		._handle_close = config.handle_close,
	};

	{
		// This block represents handshake_state's lifetime
		var handshake_state = handshake_pool.acquire() catch |err| {
			log.err("Failed to get a handshake state from the handshake pool, connection is being closed. The error was: {}", .{err});
			return;
		};
		defer handshake_pool.release(handshake_state);

		const request = readRequest(stream, handshake_state.buffer, config.handshake_timeout_ms) catch |err| {
			const s = switch (err) {
				error.Invalid => "HTTP/1.1 400 Invalid\r\nerror: invalid\r\ncontent-length: 0\r\n\r\n",
				error.TooLarge => "HTTP/1.1 400 Invalid\r\nerror: too large\r\ncontent-length: 0\r\n\r\n",
				error.Timeout => "HTTP/1.1 400 Invalid\r\nerror: timeout\r\ncontent-length: 0\r\n\r\n",
				else => "HTTP/1.1 400 Invalid\r\nerror: unknown\r\ncontent-length: 0\r\n\r\n",
			};
			stream.writeAll(s) catch {};
			return;
		};

		const h = Handshake.parse(request, &handshake_state.headers) catch |err| {
			Handshake.close(stream, err) catch {};
			return;
		};

		handler = H.init(h, &conn, context) catch |err| {
			Handshake.close(stream, err) catch {};
			return;
		};

		// handshake_buffer (via `h` which references it), must be valid up until
		// this call to reply
		h.reply(stream) catch {
			handler.close();
			return;
		};
	}

	defer handler.close();
	if (comptime std.meta.trait.hasFn("afterInit")(H)) {
		handler.afterInit() catch return;
	}

	var reader = Reader.init(allocator, config.buffer_size, config.max_size) catch |err| {
		log.err("Failed to create a Reader, connection is being closed. The error was: {}", .{err});
		return;
	};
	defer reader.deinit();
	conn.readLoop(H, handler, &reader) catch {};
}

const EMPTY_PONG = ([2]u8{ @intFromEnum(OpCode.pong), 0 })[0..];
// CLOSE, 2 length, code
const CLOSE_NORMAL = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 234 })[0..]; //code: 1002

pub const Conn = struct {
	stream: lib.Stream,
	closed: bool = false,
	_handle_pong: bool = false,
	_handle_ping: bool = false,
	_handle_close: bool = false,

	pub fn writeBin(self: Conn, data: []const u8) !void {
		return self.writeFrame(.binary, data);
	}

	pub fn writeText(self: Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn write(self: Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn writePing(self: *Conn, data: []u8) !void {
		return self.writeFrame(.ping, data);
	}

	pub fn writePong(self: *Conn, data: []u8) !void {
		return self.writeFrame(.pong, data);
	}

	pub fn writeClose(self: *Conn) !void {
		return self.stream.writeAll(CLOSE_NORMAL);
	}

	pub fn writeCloseWithCode(self: *Conn, code: u16) !void {
		var buf: [2]u8 = undefined;
		std.mem.writeInt(u16, &buf, code, .Big);
		return self.writeFrame(.close, &buf);
	}

	pub fn writeFrame(self: Conn, op_code: OpCode, data: []const u8) !void {
		const stream = self.stream;
		const l = data.len;

		// maximum possible prefix length. op_code + length_type + 8byte length
		var buf: [10]u8 = undefined;
		buf[0] = @intFromEnum(op_code);

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

	pub fn writeFramed(self: Conn, data: []const u8) !void {
		try self.steam.writeAll(data);
	}

	pub fn close(self: *Conn) void {
		self.closed = true;
	}

	fn readLoop(self: *Conn, comptime H: type, handler: H, reader: *Reader) !void {
		var h = handler;
		const stream = self.stream;
		const handle_ping = self._handle_ping;
		const handle_pong = self._handle_pong;
		const handle_close = self._handle_close;

		while (true) {
			const message = reader.readMessage(stream) catch |err| {
				switch (err) {
					error.LargeControl => try stream.writeAll(CLOSE_PROTOCOL_ERROR),
					error.ReservedFlags => try stream.writeAll(CLOSE_PROTOCOL_ERROR),
					else => {},
				}
				return;
			};

			switch (message.type) {
				.text, .binary => {
					try h.handle(message);
					reader.handled();
					if (self.closed) {
						return;
					}
				},
				.pong => {
					if (handle_pong) {
						try h.handle(message);
					}
				},
				.ping => {
					if (handle_ping) {
						try h.handle(message);
					} else {
						const data = message.data;
						if (data.len == 0) {
							try stream.writeAll(EMPTY_PONG);
						} else {
							try self.writeFrame(.pong, data);
						}
					}
				},
				.close => {
					if (handle_close) {
						return h.handle(message);
					}

					const data = message.data;
					const l = data.len;

					if (l == 0) {
						return self.writeClose();
					}

					if (l == 1) {
						// close with a payload always has to have at least a 2-byte payload,
						// since a 2-byte code is required
						return stream.writeAll(CLOSE_PROTOCOL_ERROR);
					}

					const code = @as(u16, @intCast(data[1])) | (@as(u16, @intCast(data[0])) << 8);
					if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
						return stream.writeAll(CLOSE_PROTOCOL_ERROR);
					}

					if (l == 2) {
						return try stream.writeAll(CLOSE_NORMAL);
					}

					const payload = data[2..];
					if (!std.unicode.utf8ValidateSlice(payload)) {
						// if we have a payload, it must be UTF8 (why?!)
						return try stream.writeAll(CLOSE_PROTOCOL_ERROR);
					}
					return self.writeClose();
				},
			}
		}
	}
};

// used in handshake tests
pub fn readRequest(stream: anytype, buf: []u8, timeout: ?u32) ![]u8 {
	var poll_fd = [_]os.pollfd{os.pollfd{
		.fd = stream.handle,
		.events = os.POLL.IN,
		.revents = undefined,
	}};
	var deadline: ?i64 = null;
	var read_timeout: i32 = 0;
	if (timeout) |ms| {
		// our timeout for each individual read
		read_timeout = @intCast(ms);
		// our absolute deadline for reading the header
		deadline = std.time.milliTimestamp() + ms;
	}

	var total: usize = 0;
	while (true) {
		if (total == buf.len) {
			return error.TooLarge;
		}

		if (read_timeout != 0) {
			if (try os.poll(&poll_fd, read_timeout) == 0) {
				return error.Timeout;
			}
		}

		var n = try stream.read(buf[total..]);
		if (n == 0) {
			return error.Invalid;
		}
		total += n;
		const request = buf[0..total];
		if (std.mem.endsWith(u8, request, "\r\n\r\n")) {
			return request;
		}

		if (deadline) |dl| {
			if (std.time.milliTimestamp() > dl) {
				return error.Timeout;
			}
		}
	}
}

const t = lib.testing;
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
		// Simple fragmented (websocket fragmentation)
		var expected = [_]Expect{Expect.text("over 9000!")};
		var stream = t.Stream.handshake();
		try testReadFrames(stream
			.textFrame(false, "over")
			.cont(true, " 9000!"), expected[0..]);
	}

	{
		// large fragmented (websocket fragmentation)
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

test "readFrame errors" {
	{
		// Nested non-control fragmented (websocket fragmentation)
		var expected = [_]Expect{};
		var s = t.Stream.handshake();
		try testReadFrames(s
			.textFrame(false, "over")
			.textFrame(false, " 9000!"), expected[0..]);
	}

	{
		// Nested non-control fragmented FIN (websocket fragmentation)
		var expected = [_]Expect{};
		var s = t.Stream.handshake();
		try testReadFrames(s
			.textFrame(false, "over")
			.textFrame(true, " 9000!"), expected[0..]);
	}

	{
		// control too big
		const msg = [_]u8{'z'} ** 126;
		var expected = [_]Expect{Expect.close(&.{3, 234})};
		var s = t.Stream.handshake();
		try testReadFrames(s.pingPayload(msg[0..]), expected[0..]);
	}

	{
		// reserved bit1
		var expected = [_]Expect{Expect.close(&.{3, 234})};
		var s = t.Stream.handshake();
		_ = s.textFrameReserved(true, "over9000", 64);
		try testReadFrames(&s, expected[0..]);
	}

	{
		// reserved bit2
		var expected = [_]Expect{Expect.close(&.{3, 234})};
		var s = t.Stream.handshake();
		_ = s.textFrameReserved(true, "over9000", 32);
		try testReadFrames(&s, expected[0..]);
	}

	{
		// reserved bit3
		var expected = [_]Expect{Expect.close(&.{3, 234})};
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
		.handshake_timeout_ms = null,
	};

	var handshake_pool = try HandshakePool.init(t.allocator, 10, 512, 10);
	defer handshake_pool.deinit();

	while (count < 100) : (count += 1) {
		var stream = s.clone();
		clientLoop(TestHandler, t.allocator, context, NetConn{.stream = &stream}, &config, &handshake_pool);
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

const TEST_BUFFER_SIZE = 512;
const TestContext = struct {};
const TestHandler = struct {
	conn: *Conn,

	pub fn init(_: anytype, conn: *Conn, _: TestContext) !TestHandler {
		return TestHandler{
			.conn = conn,
		};
	}

	// echo it back, so that it gets written back into our t.Stream
	pub fn handle(self: TestHandler, message: lib.Message) !void {
		const data = message.data;
		switch (message.type) {
			.binary => try self.conn.writeBin(data),
			.text => try self.conn.write(data),
			else => unreachable,
		}
	}

	pub fn close(_: TestHandler) void {}
};

const Expect = struct {
	data: []const u8,
	type: lib.MessageType,

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
			.data = data,
			.type = .close,
		};
	}
};
