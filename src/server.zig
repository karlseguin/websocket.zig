const std = @import("std");
const lib = @import("lib.zig");
const builtin = @import("builtin");

const HandshakePool = @import("handshake.zig").Pool;

const buffer = lib.buffer;
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
	unix_path: ?[]const u8 = null,
	address: []const u8 = "127.0.0.1",
	handshake_max_size: usize = 1024,
	handshake_pool_count: usize = 50,
	handshake_timeout_ms: ?u32 = 10_000,
	handle_ping: bool = false,
	handle_pong: bool = false,
	handle_close: bool = false,
	large_buffer_pool_count: u16 = 32,
	large_buffer_size: usize = 32768,
};

pub fn listen(comptime H: type, allocator: Allocator, context: anytype, config: Config) !void {
	var server = net.StreamServer.init(.{
		.reuse_address = true,
		.kernel_backlog = 1024,
	});
	defer server.deinit();

	var buffer_pool = try buffer.Pool.init(allocator, config.large_buffer_pool_count, config.large_buffer_size);
	defer buffer_pool.deinit();

	var bp = buffer.Provider.init(allocator, &buffer_pool, config.large_buffer_size);

	var hp = try HandshakePool.init(allocator, config.handshake_pool_count, config.handshake_max_size, config.max_headers);
	defer hp.deinit();

	var no_delay = true;
	const address = blk: {
		if (comptime builtin.os.tag != .windows) {
			if (config.unix_path) |unix_path| {
				no_delay = false;
				std.fs.deleteFileAbsolute(unix_path) catch {};
				break :blk try net.Address.initUnix(unix_path);
			}
		}
		break :blk try net.Address.parseIp(config.address, config.port);
	};
	try server.listen(address);

	if (no_delay) {
		// TODO: Broken on darwin:
		// https://github.com/ziglang/zig/issues/17260
		// if (@hasDecl(os.TCP, "NODELAY")) {
		//  try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
		// }
		try os.setsockopt(server.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
	}

	while (true) {
		if (server.accept()) |conn| {
			const args = .{H, context, conn, &config, &hp, &bp};
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

fn clientLoop(comptime H: type, context: anytype, net_conn: NetConn, config: *const Config, hp: *HandshakePool, bp: *buffer.Provider) void {
	std.os.maybeIgnoreSigpipe();

	const Handshake = lib.Handshake;
	const stream = net_conn.stream;
	defer stream.close();

	var handler: H = undefined;
	var conn = Conn{
		.stream = stream,
		._bp = bp,
		._handle_ping = config.handle_ping,
		._handle_pong = config.handle_pong,
		._handle_close = config.handle_close,
	};

	{
		// This block represents handshake_state's lifetime
		var handshake_state = hp.acquire() catch |err| {
			log.err("Failed to get a handshake state from the handshake pool, connection is being closed. The error was: {}", .{err});
			return;
		};
		defer hp.release(handshake_state);

		const request = readRequest(stream, handshake_state.buffer, config.handshake_timeout_ms) catch |err| {
			const s = switch (err) {
				error.Invalid => "HTTP/1.1 400 Invalid\r\nerror: invalid\r\ncontent-length: 0\r\n\r\n",
				error.TooLarge => "HTTP/1.1 400 Invalid\r\nerror: too large\r\ncontent-length: 0\r\n\r\n",
				error.Timeout, error.WouldBlock => "HTTP/1.1 400 Invalid\r\nerror: timeout\r\ncontent-length: 0\r\n\r\n",
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
	if (comptime std.meta.hasFn(H, "afterInit")) {
		handler.afterInit() catch return;
	}

	var reader = Reader.init(config.buffer_size, config.max_size, bp) catch |err| {
		log.err("Failed to create a Reader, connection is being closed. The error was: {}", .{err});
		return;
	};
	defer reader.deinit();
	conn.readLoop(*H, &handler, &reader) catch {};
}

const EMPTY_PONG = ([2]u8{ @intFromEnum(OpCode.pong), 0 })[0..];
// CLOSE, 2 length, code
const CLOSE_NORMAL = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 234 })[0..]; //code: 1002

pub const Conn = struct {
	stream: lib.Stream,
	closed: bool = false,
	_bp: *buffer.Provider,
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

	pub fn writeBuffer(self: *Conn) !Writer {
		return Writer.init(self);
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

	pub const Writer = struct {
		pos: usize,
		conn: *Conn,
		bp: *buffer.Provider,
		buffer: buffer.Buffer,

		pub const Error = Allocator.Error;
		pub const IOWriter = std.io.Writer(*Writer, error{OutOfMemory}, Writer.write);

		fn init(conn: *Conn) !Writer {
			return .{
				.pos = 0,
				.conn = conn,
				.bp = conn._bp,
				.buffer = try conn._bp.allocPooledOr(512),
			};
		}

		pub fn deinit(self: *Writer) void {
			self.bp.free(self.buffer);
		}

		pub fn writer(self: *Writer) IOWriter {
			return .{.context = self};
		}

		pub fn write(self: *Writer, data: []const u8) Allocator.Error!usize {
			try self.ensureSpace(data.len);
			const pos = self.pos;
			const end_pos = pos + data.len;
			@memcpy(self.buffer.data[pos..end_pos], data);
			self.pos = end_pos;
			return data.len;
		}

		pub fn flush(self: *Writer, op_code: OpCode) !void {
			try self.conn.writeFrame(op_code, self.buffer.data[0..self.pos]);
		}

		fn ensureSpace(self: *Writer, n: usize) !void {
			const pos = self.pos;
			const buf = self.buffer;
			const required_capacity = pos + n;

			if (buf.data.len >= required_capacity) {
				// we have enough space in our body as-is
				return;
			}

			// taken from std.ArrayList
			var new_capacity = buf.data.len;
			while (true) {
				new_capacity +|= new_capacity / 2 + 8;
				if (new_capacity >= required_capacity) break;
			}
			self.buffer = try self.bp.grow(&self.buffer, pos, new_capacity);
		}
	};
};

const read_no_timeout = std.mem.toBytes(os.timeval{
	.tv_sec = 0,
	.tv_usec = 0,
});

// used in handshake tests
pub fn readRequest(stream: anytype, buf: []u8, timeout: ?u32) ![]u8 {
	var deadline: ?i64 = null;
	var read_timeout: ?[@sizeOf(os.timeval)]u8 = null;
	if (timeout) |ms| {
		// our timeout for each individual read
		read_timeout = std.mem.toBytes(os.timeval{
			.tv_sec = @intCast(@divTrunc(ms, 1000)),
			.tv_usec = @intCast(@mod(ms, 1000) * 1000),
		});
		// our absolute deadline for reading the header
		deadline = std.time.milliTimestamp() + ms;
	}

	var total: usize = 0;
	while (true) {
		if (total == buf.len) {
			return error.TooLarge;
		}

		if (read_timeout) |to| {
			try os.setsockopt(stream.handle, os.SOL.SOCKET, os.SO.RCVTIMEO, &to);
		}

		const n = try stream.read(buf[total..]);
		if (n == 0) {
			return error.Invalid;
		}
		total += n;
		const request = buf[0..total];
		if (std.mem.endsWith(u8, request, "\r\n\r\n")) {
			if (read_timeout != null) {
				try os.setsockopt(stream.handle, os.SOL.SOCKET, os.SO.RCVTIMEO, &read_no_timeout);
			}
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
test "clientLoop" {
	// we don't currently use this
	const context = TestContext{};
	const config = Config{
		.handshake_timeout_ms = null,
	};

	var hp = try HandshakePool.init(t.allocator, 1, 512, 5);
	defer hp.deinit();

	var bp = buffer.Provider.initNoPool(t.allocator);

	{
		var stream = t.Stream.handshake();
		defer stream.deinit();
		_ = stream.textFrame(true, &.{0}).textFrame(true, &.{0});
		clientLoop(TestHandler, context, NetConn{.stream = &stream}, &config, &hp, &bp);
		try t.expectEqual(stream.closed, true);

		const r = stream.asReceived(true);
		defer r.deinit();
		try t.expectSlice(u8, &.{2, 0, 0, 0}, r.messages[0].data);
		try t.expectSlice(u8, &.{3, 0, 0, 0}, r.messages[1].data);
	}
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

test "conn: writer" {
	var tf = TestConnFactory.init();
	defer tf.deinit();


	{
		// short message (no growth)
		var conn = tf.conn();
		var wb = try conn.writeBuffer();
		defer wb.deinit();

		try std.fmt.format(wb.writer(), "it's over {d}!!!", .{9000});
		try wb.flush(.text);
		try expectFrames(&.{Expect.text("it's over 9000!!!")}, conn.stream, false);
	}

	{
		// message requiring growth
		var conn = tf.conn();
		var wb = try conn.writeBuffer();
		defer wb.deinit();

		var writer = wb.writer();
		for (0..1000) |_| {
			try writer.writeAll(".");
		}
		try wb.flush(.binary);
		try expectFrames(&.{Expect.binary("." ** 1000)}, conn.stream, false);
	}
}

fn testReadFrames(s: *t.Stream, expected: []Expect) !void {
	defer s.deinit();

	// we don't currently use this
	const context = TestContext{};

	// test with various random  TCP fragmentations
	// our t.Stream automatically fragments the frames on the first
	// call to read. Note this is TCP fragmentation, not websocket fragmentation
	const config = Config{
		.buffer_size = TEST_BUFFER_SIZE,
		.max_size = TEST_BUFFER_SIZE * 10,
		.handshake_timeout_ms = null,
	};

	var hp = try HandshakePool.init(t.allocator, 10, 512, 10);
	defer hp.deinit();

	var bp = buffer.Provider.initNoPool(t.allocator);

	for (0..100) |_| {
		var stream = s.clone();
		defer stream.deinit();

		clientLoop(TestHandler, context, NetConn{.stream = &stream}, &config, &hp, &bp);
		try t.expectEqual(stream.closed, true);
		try expectFrames(expected, &stream, true);
	}
}

fn expectFrames(expected: []const Expect, stream: *t.Stream, skip_handshake: bool) !void {
	const r = stream.asReceived(skip_handshake);
	const messages = r.messages;
	defer r.deinit();

	try t.expectEqual(expected.len, messages.len);
	var i: usize = 0;
	while (i < expected.len) : (i += 1) {
		const e = expected[i];
		const actual = messages[i];
		try t.expectEqual(e.type, actual.type);
		try t.expectString(e.data, actual.data);
	}
}

const TEST_BUFFER_SIZE = 512;
const TestContext = struct {};
const TestHandler = struct {
	conn: *Conn,
	counter: i32,
	init_ptr: usize,

	pub fn init(_: anytype, conn: *Conn, _: TestContext) !TestHandler {
		return .{
			.conn = conn,
			.counter = 0,
			.init_ptr = 0,
		};
	}

	pub fn afterInit(self: *TestHandler) !void {
		self.counter = 1;
		self.init_ptr = @intFromPtr(self);
	}

	// echo it back, so that it gets written back into our t.Stream
	pub fn handle(self: *TestHandler, message: lib.Message) !void {
		self.counter += 1;
		const data = message.data;
		switch (message.type) {
			.binary => try self.conn.writeBin(data),
			.text => {
				if (data.len == 1 and data[0] == 0) {
					std.debug.assert(self.init_ptr == @intFromPtr(self));
					var buf: [4]u8 = undefined;
					std.mem.writeInt(i32, &buf, self.counter, .little);
					try self.conn.write(&buf);
				} else {
					try self.conn.write(data);
				}
			},
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

	fn binary(data: []const u8) Expect {
		return .{
			.data = data,
			.type = .binary,
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

const TestConnFactory = struct {
	stream: t.Stream,
	bp: buffer.Provider,

	fn init() TestConnFactory {
		const pool = t.allocator.create(buffer.Pool) catch unreachable;
		pool.* = buffer.Pool.init(t.allocator, 2, 100) catch unreachable;

		return .{
			.stream = t.Stream.init(),
			.bp = buffer.Provider.init(t.allocator, pool, 10),
		};
	}

	fn deinit(self: *TestConnFactory) void {
		self.bp.pool.deinit();
		t.allocator.destroy(self.bp.pool);
		self.stream.deinit();
	}

	fn conn(self: *TestConnFactory) Conn {
		self.stream.reset();
		return .{
			._bp = &self.bp,
			.stream = &self.stream,
		};
	}
};
