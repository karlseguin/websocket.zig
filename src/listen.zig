const std = @import("std");
const lib = @import("lib.zig");

const Conn = lib.Conn;
const Pool = lib.Pool;
const NetConn = lib.NetConn;
const Request = lib.Request;
const Handshake = lib.Handshake;

const os = std.os;
const net = std.net;
const Loop = std.event.Loop;

const Allocator = std.mem.Allocator;

pub const Config = struct {
	port: u16 = 9223,
	max_size: usize = 65536,
	max_headers: usize = 0,
	buffer_size: usize = 4096,
	address: []const u8 = "127.0.0.1",
	handshake_max_size: usize = 1024,
	handshake_pool_size: usize = 50,
	handshake_timeout_ms: ?u32 = 10_000,
};

pub fn listen(comptime H: type, allocator: Allocator, context: anytype, config: Config) !void {
	var server = net.StreamServer.init(.{ .reuse_address = true });
	defer server.deinit();

	var pool = try Pool.init(allocator, config.handshake_pool_size, config.handshake_max_size, config.max_headers);
	defer pool.deinit();

	try server.listen(net.Address.parseIp(config.address, config.port) catch unreachable);
	// TODO: I believe this should work, but it currently doesn't on 0.11-dev. Instead I have to
	// hardcode 1 for the setsocopt NODELAY option
	// if (@hasDecl(os.TCP, "NODELAY")) {
	// 	try os.setsockopt(server.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
	// }
	try os.setsockopt(server.sockfd.?, os.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));


	while (true) {
		if (server.accept()) |conn| {
			const args = .{ H, allocator, context, conn, &config, &pool };
			if (comptime std.io.is_async) {
				try Loop.instance.?.runDetached(allocator, clientLoop, args);
			} else {
				const thread = try std.Thread.spawn(.{}, clientLoop, args);
				thread.detach();
			}
		} else |err| {
			std.log.err("failed to accept connection {}", .{err});
		}
	}
}

pub fn clientLoop(comptime H: type, allocator: Allocator, context: anytype, net_conn: NetConn, config: *const Config, pool: *Pool) void {
	std.os.maybeIgnoreSigpipe();

	const stream = net_conn.stream;
	defer stream.close();

	var handler: H = undefined;
	var conn = Conn{.stream = stream};

	{
		// This block represents handshake_state's lifetime
		var handshake_state = pool.acquire() catch |err| {
			std.log.err("websocket.zig: Failed to get a handshake state from the handshake pool, connection is being closed. The error was: {}", .{err});
			return;
		};
		defer pool.release(handshake_state);

		const request = Request.read(stream, handshake_state.buffer, config.handshake_timeout_ms) catch |err| {
			Request.close(stream, err) catch {};
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
		try handler.afterInit();
	}

	const conn_config = Conn.Config{
		.max_size = config.max_size,
		.buffer_size = config.buffer_size,
		.handshake_timeout_ms = config.handshake_timeout_ms,
	};

	conn.readLoop(H, allocator, handler, conn_config) catch {};
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

test "readFrame errors" {
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

	var pool = try Pool.init(t.allocator, 10, 512, 10);
	defer pool.deinit();

	while (count < 100) : (count += 1) {
		var stream = s.clone();
		clientLoop(TestHandler, t.allocator, context, NetConn{.stream = &stream}, &config, &pool);
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

	pub fn init(_: Handshake, conn: *Conn, _: TestContext) !TestHandler {
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
	type: lib.MessageType,
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
			.data = data,
			.type = .close,
		};
	}
};
