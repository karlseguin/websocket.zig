const std = @import("std");
const lib = @import("lib.zig");

const posix = std.posix;
const ascii = std.ascii;
const Allocator = std.mem.Allocator;

pub const Handshake = struct {
	url: []const u8,
	key: []const u8,
	method: []const u8,
	headers: KeyValue,
	raw_header: []const u8,

	// we expect allocator to be an Arena
	pub fn parse(buf: []u8, allocator: Allocator, max_headers: usize) !Handshake {
		var data = buf;
		const request_line_end = std.mem.indexOfScalar(u8, data, '\r') orelse unreachable;
		var request_line = data[0..request_line_end];

		if (!ascii.endsWithIgnoreCase(request_line, "http/1.1")) {
			return error.InvalidProtocol;
		}

		var headers = try KeyValue.init(allocator, max_headers);
		errdefer headers.deinit(allocator); // allocator is an arena, but just to be safe

		var key: []const u8 = "";
		var required_headers: u8 = 0;

		var request_length = request_line_end;

		data = data[request_line_end+2..];

		while (data.len > 4) {
			const index = std.mem.indexOfScalar(u8, data, '\r') orelse unreachable;
			const separator = std.mem.indexOfScalar(u8, data[0..index], ':') orelse return error.InvalidHeader;

			const name = std.mem.trim(u8, toLower(data[0..separator]), &ascii.whitespace);
			const value = std.mem.trim(u8, data[(separator + 1)..index], &ascii.whitespace);

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
			data = data[next..];
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
			.raw_header = buf[request_line_end+2..request_length+2],
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
};

pub const KeyValue = struct {
	len: usize,
	keys: [][]const u8,
	values: [][]const u8,

	pub fn init(allocator: Allocator, max: usize) !KeyValue {
		const keys = try allocator.alloc([]const u8, max);
		const values = try allocator.alloc([]const u8, max);
		return .{
			.len = 0,
			.keys = keys,
			.values = values,
		};
	}

	pub fn deinit(self: KeyValue, allocator: Allocator) void {
		allocator.free(self.keys);
		allocator.free(self.values);
	}

	pub fn add(self: *KeyValue, key: []const u8, value: []const u8) void {
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

	pub fn reset(self: *KeyValue) void {
		self.len = 0;
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

const t = lib.testing;
// const readRequest = @import("server.zig").readRequest;
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

	kv.reset();
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
