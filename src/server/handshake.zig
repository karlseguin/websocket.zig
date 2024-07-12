const std = @import("std");

const posix = std.posix;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

const M = @This();

pub const Handshake = struct {
	url: []const u8,
	key: []const u8,
	method: []const u8,
	headers: KeyValue,
	raw_header: []const u8,

	pub const Pool = M.Pool;

	// returns null if the request isn't full
	pub fn parse(state: *State) !?Handshake {
		const request = state.buf[0..state.len];

		var buf = request;
		if (std.mem.endsWith(u8, buf, "\r\n\r\n") == false) {
			return null;
		}

		const request_line_end = std.mem.indexOfScalar(u8, buf, '\r') orelse unreachable;
		var request_line = buf[0..request_line_end];

		if (!ascii.endsWithIgnoreCase(request_line, "http/1.1")) {
			return error.InvalidProtocol;
		}

		var headers = state.headers;

		var key: []const u8 = "";
		var required_headers: u8 = 0;

		var request_length = request_line_end;

		buf = buf[request_line_end+2..];

		while (buf.len > 4) {
			const index = std.mem.indexOfScalar(u8, buf, '\r') orelse unreachable;
			const separator = std.mem.indexOfScalar(u8, buf[0..index], ':') orelse return error.InvalidHeader;

			const name = std.mem.trim(u8, toLower(buf[0..separator]), &ascii.whitespace);
			const value = std.mem.trim(u8, buf[(separator + 1)..index], &ascii.whitespace);

			switch (name.len) {
				7 => if (eql("upgrade", name)) {
					if (!ascii.eqlIgnoreCase("websocket", value)) {
						return error.InvalidUpgrade;
					}
					required_headers |= 1;
				},
				10 => if (eql("connection", name)) {
					// find if connection header has upgrade in it, example header:
					//		Connection: keep-alive, Upgrade
					if (std.ascii.indexOfIgnoreCase(value, "upgrade") == null) {
						return error.InvalidConnection;
					}
					required_headers |= 4;
				},
				17 => if (eql("sec-websocket-key", name)) {
					key = value;
					required_headers |= 8;
				},
				21 => if (eql("sec-websocket-version", name)) {
					if (value.len != 2 or value[0] != '1' or value[1] != '3') {
						return error.InvalidVersion;
					}
					required_headers |= 2;
				},
				else => headers.add(name, value),
			}
			const next = index + 2;
			request_length += next;
			buf = buf[next..];
		}

		if (required_headers != 15) {
			return error.MissingHeaders;
		}

		// we already established that request_line ends with http/1.1, so this buys
		// us some leeway into parsing it
		const separator = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.InvalidRequestLine;
		const method = request_line[0..separator];
		const url = std.mem.trim(u8, request_line[separator + 1 .. request_line.len - 9], &ascii.whitespace);

		return .{
			.key = key,
			.url = url,
			.method = method,
			.headers = headers,
			.raw_header = request[request_line_end+2..request_length+2],
		};
	}

	pub fn reply(self: *const Handshake) [129]u8 {
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

		var h: [20]u8 = undefined;
		var hasher = std.crypto.hash.Sha1.init(.{});
		hasher.update(self.key);
		hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
		hasher.final(&h);

		_ = std.base64.standard.Encoder.encode(buf[key_pos..key_pos+28], h[0..]);
		return buf;
	}

	// This is what we're pooling
	pub const State = struct {
		// length of data we have in buf
		len: usize = 0,

		// a buffer to read data into
		buf: []u8,

		// Headers
		headers: KeyValue,

		fn init(allocator: Allocator, buffer_size: usize, max_headers: usize) !State {
			const buf = try allocator.alloc(u8, buffer_size);
			errdefer allocator.free(buf);

			const headers = try KeyValue.init(allocator, max_headers);
			errdefer headers.deinit(allocator);

			return .{
				.buf = buf,
				.headers = headers,
			};
		}

		fn deinit(self: *State, allocator: Allocator) void {
			allocator.free(self.buf);
			self.headers.deinit(allocator);
		}

		fn reset(self: *State) void {
			self.len = 0;
			self.headers.len = 0;
		}
	};
};

pub const KeyValue = struct {
	len: usize,
	keys: [][]const u8,
	values: [][]const u8,

	fn init(allocator: Allocator, max: usize) !KeyValue {
		const keys = try allocator.alloc([]const u8, max);
		errdefer allocator.free(keys);

		const values = try allocator.alloc([]const u8, max);
		errdefer allocator.free(values);

		return .{
			.len = 0,
			.keys = keys,
			.values = values,
		};
	}

	fn deinit(self: KeyValue, allocator: Allocator) void {
		allocator.free(self.keys);
		allocator.free(self.values);
	}

	fn add(self: *KeyValue, key: []const u8, value: []const u8) void {
		const len = self.len;
		var keys = self.keys;
		if (len == keys.len) {
			return;
		}

		keys[len] = key;
		self.values[len] = value;
		self.len = len + 1;
	}

	pub fn get(self: KeyValue, needle: []const u8) ?[]const u8 {
		const keys = self.keys[0..self.len];
		loop: for (keys, 0..) |key, i| {
			// This is largely a reminder to myself that std.mem.eql isn't
			// particularly fast. Here we at least avoid the 1 extra ptr
			// equality check that std.mem.eql does, but we could do better
			// TODO: monitor https://github.com/ziglang/zig/issues/8689
			if (needle.len != key.len) {
				continue;
			}
			for (needle, key) |n, k| {
				if (n != k) {
					continue :loop;
				}
			}
			return self.values[i];
		}

		return null;
	}
};

pub const Pool = struct {
	mutex: std.Thread.Mutex,
	available: usize,
	allocator: Allocator,
	buffer_size: usize,
	max_headers: usize,
	states: []*Handshake.State,

	pub fn init(allocator: Allocator, count: usize, buffer_size: usize, max_headers: usize) !Pool {
		const states = try allocator.alloc(*Handshake.State, count);

		for (0..count) |i| {
			const state = try allocator.create(Handshake.State);
			errdefer allocator.destroy(state);

			state.* = try Handshake.State.init(allocator, buffer_size, max_headers);
			states[i] = state;
		}

		return .{
			.mutex = .{},
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
			allocator.destroy(s);
		}
		allocator.free(self.states);
	}

	pub fn acquire(self: *Pool) !*Handshake.State {
		const states = self.states;

		self.mutex.lock();
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			self.mutex.unlock();

			const allocator = self.allocator;
			const state = try allocator.create(Handshake.State);
			errdefer allocator.destroy(state);
			state.* = try Handshake.State.init(self.allocator, self.buffer_size, self.max_headers);
			return state;
		}
		const index = available - 1;
		const state = states[index];
		self.available = index;
		self.mutex.unlock();
		return state;
	}

	pub fn release(self: *Pool, state: *Handshake.State) void {
		state.reset();
		var states = self.states;

		self.mutex.lock();
		const available = self.available;
		if (available == states.len) {
			self.mutex.unlock();
			state.deinit(self.allocator);
			self.allocator.destroy(state);
			return;
		}
		states[available] = state;
		self.available = available + 1;
		self.mutex.unlock();
	}
};

fn toLower(str: []u8) []u8 {
	for (str, 0..) |c, i| {
		str[i] = ascii.toLower(c);
	}
	return str;
}

// avoids the len check and pointer check of std.mem.eql
// we can skip the length check because this is only called when a.len == b.len
fn eql(a: []const u8, b: []const u8) bool {
	for (a, b) |aa, bb| {
		if (aa != bb) {
			return false;
		}
	}

	return true;
}

const t = @import("../t.zig");
// test "handshake: parse" {
// 	var buffer: [512]u8 = undefined;
// 	const buf = buffer[0..];
// 	var headers = try KeyValue.init(t.allocator, 10);
// 	defer headers.deinit(t.allocator);

// 	try t.expectError(error.InvalidProtocol, testHandshake("GET / HTTP/1.0\r\n\r\n", buf, &headers));
// 	try t.expectError(error.MissingHeaders, testHandshake("GET / HTTP/1.1\r\n\r\n", buf, &headers));
// 	try t.expectError(error.MissingHeaders, testHandshake("GET / HTTP/1.1\r\nConnection:  upgrade\r\n\r\n", buf, &headers));
// 	try t.expectError(error.MissingHeaders, testHandshake("GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n", buf, &headers));
// 	try t.expectError(error.MissingHeaders, testHandshake("GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\n\r\n", buf, &headers));

// 	{
// 		headers.reset();
// 		const h = try testHandshake("GET /test?a=1   HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\nsec-websocket-key: 9000!\r\nCustom:  Header-Value\r\n\r\n", buf, &headers);
// 		try t.expectString("9000!", h.key);
// 		try t.expectString("GET", h.method);
// 		try t.expectString("/test?a=1", h.url);
// 		try t.expectString("connection: upgrade\r\nupgrade: websocket\r\nsec-websocket-version:13\r\nsec-websocket-key: 9000!\r\ncustom:  Header-Value\r\n", h.raw_header);
// 		try t.expectString("upgrade", headers.get("connection").?);
// 		try t.expectString("websocket", headers.get("upgrade").?);
// 		try t.expectString("13", headers.get("sec-websocket-version").?);
// 		try t.expectString("9000!", headers.get("sec-websocket-key").?);
// 		try t.expectString("Header-Value", headers.get("custom").?);
// 	}

// 	// fuzz tests
// 	{
// 		headers.reset();
// 		var r = t.getRandom();
// 		var random = r.random();
// 		var count: usize = 0;
// 		const valid = "GET / HTTP/1.1\r\nsec-websocket-key: 1139329\r\nConnection: upgrade\r\nUpgrade:WebSocket\r\nSEC-WEBSOCKET-VERSION:   13  \r\n\r\n";
// 		while (count < 1000) : (count += 1) {
// 			var pair = t.SocketPair.init();
// 			defer pair.deinit();

// 			var data: []const u8 = valid[0..];
// 			while (data.len > 0) {
// 				const l = random.uintAtMost(usize, data.len - 1) + 1;
// 				_ = try pair.client.writeAll(data[0..l]);
// 				data = data[l..];
// 			}
// 			const request_buf = readRequest(pair.server, buf, null) catch unreachable;
// 			const h = Handshake.parse(request_buf, &headers) catch unreachable;
// 			try t.expectString("1139329", h.key);
// 			try t.expectString("/", h.url);
// 			try t.expectString("GET", h.method);
// 		}
// 	}
// }

// test "handshake: reply" {
// 	var pair = t.SocketPair.init();
// 	defer pair.deinit();

// 	const h = Handshake{
// 		.url = "",
// 		.method = "",
// 		.raw_header = "",
// 		.headers = undefined,
// 		.key = "this is my key",
// 	};
// 	try Handshake.reply(h.key, pair.server);

// 	const expected = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n";
// 	var buf: [expected.len]u8 = undefined;
// 	_ = try pair.client.readAll(&buf);
// 	try t.expectString(&buf, expected);
// }

// fn testHandshake(input: []const u8, buf: []u8, headers: *KeyValue) !Handshake {
// 	var pair = t.SocketPair.init();
// 	defer pair.deinit();
// 	try pair.client.writeAll(input);

// 	const request_buf = try readRequest(pair.server, buf, null);
// 	return Handshake.parse(request_buf, headers);
// }


test "KeyValue: get" {
	const allocator = t.allocator;
	var kv = try KeyValue.init(allocator, 2);
	defer kv.deinit(t.allocator);

	var key = "content-type".*;
	kv.add(&key, "application/json");

	try t.expectString("application/json", kv.get("content-type").?);

	kv.len = 0;
	try t.expectEqual(null, kv.get("content-type"));
	kv.add(&key, "application/json2");
	try t.expectString("application/json2", kv.get("content-type").?);
}

test "KeyValue: ignores beyond max" {
	var kv = try KeyValue.init(t.allocator, 2);
	defer kv.deinit(t.allocator);

	var n1 = "content-length".*;
	kv.add(&n1, "cl");

	var n2 = "host".*;
	kv.add(&n2, "www");

	var n3 = "authorization".*;
	kv.add(&n3, "hack");

	try t.expectString("cl", kv.get("content-length").?);
	try t.expectString("www", kv.get("host").?);
	try t.expectEqual(null, kv.get("authorization"));
}


test "pool: acquire and release" {
	// not 100% sure this is testing exactly what I want, but it's ....something ?
	var p = try Pool.init(t.allocator, 2, 10, 3);
	defer p.deinit();

	var hs1a = p.acquire() catch unreachable;
	var hs2a = p.acquire() catch unreachable;
	var hs3a = p.acquire() catch unreachable; // this should be dynamically generated

	try t.expectEqual(false, &hs1a.buf[0] == &hs2a.buf[0]);
	try t.expectEqual(false, &hs2a.buf[0] == &hs3a.buf[0]);
	try t.expectEqual(10, hs1a.buf.len);
	try t.expectEqual(10, hs2a.buf.len);
	try t.expectEqual(10, hs3a.buf.len);
	try t.expectEqual(0, hs1a.headers.len);
	try t.expectEqual(0, hs2a.headers.len);
	try t.expectEqual(0, hs3a.headers.len);
	try t.expectEqual(3, hs1a.headers.keys.len);
	try t.expectEqual(3, hs2a.headers.keys.len);
	try t.expectEqual(3, hs3a.headers.keys.len);

	p.release(hs1a);

	var hs1b = p.acquire() catch unreachable;
	try t.expectEqual(true, &hs1a.buf[0] == &hs1b.buf[0]);

	p.release(hs3a);
	p.release(hs2a);
	p.release(hs1b);
}

test "Handshake.Pool: threadsafety" {
	var p = try Pool.init(t.allocator, 4, 10, 2);
	defer p.deinit();

	for (p.states) |hs| {
		hs.buf[0] = 0;
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
		std.debug.assert(hs.buf[0] == 0);
		hs.buf[0] = 255;
		std.time.sleep(random.uintAtMost(u32, 100000));
		hs.buf[0] = 0;
		p.release(hs);
	}
}

// fn testHandshake(input: []const u8, buf: []u8, headers: *KeyValue) !Handshake {
// 	var pair = t.SocketPair.init();
// 	defer pair.deinit();
// 	try pair.client.writeAll(input);

// 	const request_buf = try readRequest(pair.server, buf, null);
// 	return Handshake.parse(request_buf, headers);
// }
