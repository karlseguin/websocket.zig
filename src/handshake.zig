const std = @import("std");
const lib = @import("lib.zig");

const KeyValue = @import("key_value.zig").KeyValue;

const mem = std.mem;
const net = std.net;
const ascii = std.ascii;
const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

pub const Handshake = struct {
	url: []const u8,
	key: []const u8,
	method: []const u8,
	headers: *KeyValue,
	raw_header: []const u8,

	pub fn parse(buf: []u8, headers: *KeyValue) !Handshake {
		@setRuntimeSafety(lib.is_test);

		var data = buf;
		const request_line_end = mem.indexOfScalar(u8, data, '\r') orelse unreachable;
		var request_line = data[0..request_line_end];

		if (!ascii.endsWithIgnoreCase(request_line, "http/1.1")) {
			return error.InvalidProtocol;
		}

		var key: []const u8 = "";
		var required_headers: u8 = 0;

		var request_length = request_line_end;

		data = data[request_line_end+2..];

		while (data.len > 4) {
			const index = mem.indexOfScalar(u8, data, '\r') orelse unreachable;
			const separator = mem.indexOfScalar(u8, data[0..index], ':') orelse return error.InvalidHeader;

			const name = mem.trim(u8, toLower(data[0..separator]), &ascii.whitespace);
			const value = mem.trim(u8, data[(separator + 1)..index], &ascii.whitespace);
			headers.add(name, value);

			if (mem.eql(u8, "upgrade", name)) {
				if (!ascii.eqlIgnoreCase("websocket", value)) {
					return error.InvalidUpgrade;
				}
				required_headers |= 1;
			} else if (mem.eql(u8, "sec-websocket-version", name)) {
				if (!mem.eql(u8, "13", value)) {
					return error.InvalidVersion;
				}
				required_headers |= 2;
			} else if (mem.eql(u8, "connection", name)) {
				// find if connection header has upgrade in it, example header: 
				//		Connection: keep-alive, Upgrade
				if (ascii.indexOfIgnoreCase(value, "upgrade") == null) {
					return error.InvalidConnection;
				}
				required_headers |= 4;
			} else if (mem.eql(u8, "sec-websocket-key", name)) {
				key = value;
				required_headers |= 8;
			}
			const next = index + 2;
			request_length += next;
			data = data[next..];
		}

		if (required_headers != 15) {
			return error.MissingHeaders;
		}

		// we already established that request_line ends with http/1.1, so this buys
		// us some leeway into parsing it
		const separator = mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidRequestLine;
		const method = request_line[0..separator];
		const url = mem.trim(u8, request_line[separator + 1 .. request_line.len - 9], &ascii.whitespace);

		return .{
			.key = key,
			.url = url,
			.method = method,
			.headers = headers,
			.raw_header = buf[request_line_end+2..request_length+2],
		};
	}

	pub fn close(stream: anytype, err: anyerror) !void {
		try stream.writeAll("HTTP/1.1 400 Invalid\r\nerror: ");
		const s = switch (err) {
			error.Empty => "empty",
			error.InvalidProtocol => "invalidprotocol",
			error.InvalidRequestLine => "invalidrequestline",
			error.InvalidHeader => "invalidheader",
			error.InvalidUpgrade => "invalidupgrade",
			error.InvalidVersion => "invalidversion",
			error.InvalidConnection => "invalidconnection",
			error.MissingHeaders => "missingheaders",
			else => "unknown",
		};
		try stream.writeAll(s);
		try stream.writeAll("\r\n\r\n");
	}

	pub fn reply(key: []const u8, stream: anytype) !void {
		var h: [20]u8 = undefined;

		// HTTP/1.1 101 Switching Protocols\r\n
		// Upgrade: websocket\r\n
		// Connection: upgrade\r\n
		// Sec-Websocket-Accept: BASE64_ENCODED_KEY_HASH_PLACEHOLDER_000\r\n\r\n
		var buf = [_]u8{
			'H','T','T','P','/','1','.','1',' ', '1','0','1',' ', 'S','w','i','t','c','h','i','n','g',' ','P','r','o','t','o','c','o','l','s', '\r','\n',
			'U','p','g','r','a','d','e',':',' ','w','e','b','s','o','c','k','e','t','\r','\n',
			'C','o','n','n','e','c','t','i','o','n',':',' ','u','p','g','r','a','d','e','\r','\n',
			'S','e','c','-','W','e','b','s','o','c','k','e','t','-','A','c','c','e','p','t',':',' ',0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,'\r','\n',
			'\r','\n'
		};
		const key_pos = buf.len - 32;

		var hasher = std.crypto.hash.Sha1.init(.{});
		hasher.update(key);
		hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
		hasher.final(&h);

		_ = std.base64.standard.Encoder.encode(buf[key_pos..key_pos+28], h[0..]);
		try stream.writeAll(&buf);
	}
};

fn toLower(str: []u8) []u8 {
	for (str, 0..) |c, i| {
		str[i] = ascii.toLower(c);
	}
	return str;
}

// This is what we're pooling
const HandshakeState = struct {
	// a buffer to read data into
	buffer: []u8,

	// Headers
	headers: KeyValue,

	fn init(allocator: Allocator, buffer_size: usize, max_headers: usize) !*HandshakeState {
		const hs = try allocator.create(HandshakeState);
		hs.* = .{
			.buffer = try allocator.alloc(u8, buffer_size),
			.headers = try KeyValue.init(allocator, max_headers),
		};
		return hs;
	}

	fn deinit(self: *HandshakeState, allocator: Allocator) void {
		allocator.free(self.buffer);
		self.headers.deinit(allocator);
		allocator.destroy(self);
	}

	fn reset(self: *HandshakeState) void {
		self.headers.reset();
	}
};

pub const Pool = struct {
	mutex: Mutex,
	available: usize,
	allocator: Allocator,
	buffer_size: usize,
	max_headers: usize,
	states: []*HandshakeState,

	pub fn init(allocator: Allocator, count: usize, buffer_size: usize, max_headers: usize) !Pool {
		const states = try allocator.alloc(*HandshakeState, count);

		for (0..count) |i| {
			states[i] = try HandshakeState.init(allocator, buffer_size, max_headers);
		}

		return .{
			.mutex = Mutex{},
			.states = states,
			.allocator = allocator,
			.available = count,
			.max_headers = max_headers,
			.buffer_size = buffer_size,
		};
	}

	pub fn deinit(self: *Pool) void {
		const allocator = self.allocator;
		for (self.states) |s| {
			s.deinit(allocator);
		}
		allocator.free(self.states);
	}

	pub fn acquire(self: *Pool) !*HandshakeState {
		const states = self.states;

		self.mutex.lock();
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			self.mutex.unlock();
			return try HandshakeState.init(self.allocator, self.buffer_size, self.max_headers);
		}
		const index = available - 1;
		const state = states[index];
		self.available = index;
		self.mutex.unlock();
		return state;
	}

	pub fn release(self: *Pool, state: *HandshakeState) void {
		state.reset();
		var states = self.states;

		self.mutex.lock();
		const available = self.available;
		if (available == states.len) {
			self.mutex.unlock();
			state.deinit(self.allocator);
			return;
		}
		states[available] = state;
		self.available = available + 1;
		self.mutex.unlock();
	}
};

const t = lib.testing;
const readRequest = @import("server.zig").readRequest;
test "handshake: parse" {
	var buffer: [512]u8 = undefined;
	const buf = buffer[0..];
	var headers = try KeyValue.init(t.allocator, 10);
	defer headers.deinit(t.allocator);

	try t.expectError(error.InvalidProtocol, testHandshake("GET / HTTP/1.0\r\n\r\n", buf, &headers));
	try t.expectError(error.MissingHeaders, testHandshake("GET / HTTP/1.1\r\n\r\n", buf, &headers));
	try t.expectError(error.MissingHeaders, testHandshake("GET / HTTP/1.1\r\nConnection:  upgrade\r\n\r\n", buf, &headers));
	try t.expectError(error.MissingHeaders, testHandshake("GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n", buf, &headers));
	try t.expectError(error.MissingHeaders, testHandshake("GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\n\r\n", buf, &headers));

	{
		headers.reset();
		const h = try testHandshake("GET /test?a=1   HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\nsec-websocket-key: 9000!\r\nCustom:  Header-Value\r\n\r\n", buf, &headers);
		try t.expectString("9000!", h.key);
		try t.expectString("GET", h.method);
		try t.expectString("/test?a=1", h.url);
		try t.expectString("connection: upgrade\r\nupgrade: websocket\r\nsec-websocket-version:13\r\nsec-websocket-key: 9000!\r\ncustom:  Header-Value\r\n", h.raw_header);
		try t.expectString("upgrade", headers.get("connection").?);
		try t.expectString("websocket", headers.get("upgrade").?);
		try t.expectString("13", headers.get("sec-websocket-version").?);
		try t.expectString("9000!", headers.get("sec-websocket-key").?);
		try t.expectString("Header-Value", headers.get("custom").?);
	}

	// fuzz tests
	{
		headers.reset();
		var r = t.getRandom();
		var random = r.random();
		var count: usize = 0;
		const valid = "GET / HTTP/1.1\r\nsec-websocket-key: 1139329\r\nConnection: upgrade\r\nUpgrade:WebSocket\r\nSEC-WEBSOCKET-VERSION:   13  \r\n\r\n";
		while (count < 5000) : (count += 1) {
			var s = t.Stream.init();
			var data: []const u8 = valid[0..];
			while (data.len > 0) {
				const l = random.uintAtMost(usize, data.len - 1) + 1;
				_ = s.add(data[0..l]);
				data = data[l..];
			}
			const request_buf = readRequest(&s, buf, null) catch unreachable;
			const h = Handshake.parse(request_buf, &headers) catch unreachable;
			try t.expectString("1139329", h.key);
			try t.expectString("/", h.url);
			try t.expectString("GET", h.method);
			s.deinit();
		}
	}
}

test "handshake: reply" {
	var s = t.Stream.init();
	defer s.deinit();

	const h = Handshake{
		.url = "",
		.method = "",
		.raw_header = "",
		.headers = undefined,
		.key = "this is my key",
	};
	try Handshake.reply(h.key, &s);

	var pos: usize = 0;
	const expected = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n";
	for (s.received.items) |chunk| {
		try t.expectString(expected[pos..(pos+chunk.len)], chunk);
		pos += chunk.len;
	}
}

test "pool: acquire and release" {
	// not 100% sure this is testing exactly what I want, but it's ....something ?
	var p = try Pool.init(t.allocator, 2, 10, 3);
	defer p.deinit();

	var hs1a = p.acquire() catch unreachable;
	var hs2a = p.acquire() catch unreachable;
	var hs3a = p.acquire() catch unreachable; // this should be dynamically generated

	try t.expectEqual(false, &hs1a.buffer[0] == &hs2a.buffer[0]);
	try t.expectEqual(false, &hs2a.buffer[0] == &hs3a.buffer[0]);
	try t.expectEqual(10, hs1a.buffer.len);
	try t.expectEqual(10, hs2a.buffer.len);
	try t.expectEqual(10, hs3a.buffer.len);
	try t.expectEqual(0, hs1a.headers.len);
	try t.expectEqual(0, hs2a.headers.len);
	try t.expectEqual(0, hs3a.headers.len);
	try t.expectEqual(3, hs1a.headers.keys.len);
	try t.expectEqual(3, hs2a.headers.keys.len);
	try t.expectEqual(3, hs3a.headers.keys.len);

	p.release(hs1a);

	var hs1b = p.acquire() catch unreachable;
	try t.expectEqual(true, &hs1a.buffer[0] == &hs1b.buffer[0]);

	p.release(hs3a);
	p.release(hs2a);
	p.release(hs1b);
}

test "pool: threadsafety" {
	var p = try Pool.init(t.allocator, 4, 10, 2);
	defer p.deinit();

	for (p.states) |hs| {
		hs.buffer[0] = 0;
	}

	const t1 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t2 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t3 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t4 = try std.Thread.spawn(.{}, testPool, .{&p});

	t1.join(); t2.join(); t3.join(); t4.join();
}

fn testPool(p: *Pool) void {
	var r = t.getRandom();
	const random = r.random();

	for (0..5000) |_| {
		var hs = p.acquire() catch unreachable;
		std.debug.assert(hs.buffer[0] == 0);
		hs.buffer[0] = 255;
		std.time.sleep(random.uintAtMost(u32, 100000));
		hs.buffer[0] = 0;
		p.release(hs);
	}
}

fn testHandshake(input: []const u8, buf: []u8, headers: *KeyValue) !Handshake {
	var s = t.Stream.init();
	_ = s.add(input);

	defer s.deinit();
	const request_buf = try readRequest(&s, buf, null);
	return Handshake.parse(request_buf, headers);
}
