const std = @import("std");
const builtin = @import("builtin");

const t = @import("t.zig");
const client = @import("client.zig");
const Request = @import("request.zig").Request;

const mem = std.mem;
const net = std.net;
const ascii = std.ascii;
const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;

const HandshakeError = error{
	Empty,
	InvalidProtocol,
	InvalidRequestLine,
	InvalidHeader,
	InvalidUpgrade,
	InvalidVersion,
	InvalidConnection,
	MissingHeaders,
};

pub const Handshake = struct {
	url: []const u8,
	key: []const u8,
	method: []const u8,
	headers: []const u8,

	pub fn parse(buf: []u8) !Handshake {
		@setRuntimeSafety(builtin.is_test);

		var data = buf;
		const request_line_end = mem.indexOfScalar(u8, data, '\r') orelse unreachable;
		var request_line = data[0..request_line_end];

		if (!ascii.endsWithIgnoreCase(request_line, "http/1.1")) {
			return HandshakeError.InvalidProtocol;
		}

		var key: []const u8 = "";
		var required_headers: u8 = 0;

		var request_length = request_line_end;

		data = data[request_line_end+2..];
		while (data.len > 4) {
			const index = mem.indexOfScalar(u8, data, '\r') orelse unreachable;
			const separator = mem.indexOfScalar(u8, data[0..index], ':') orelse return HandshakeError.InvalidHeader;

			const header = mem.trim(u8, toLower(data[0..separator]), &ascii.whitespace);
			var value = data[(separator + 1)..index]; // we'll trim/lowercase this as needed

			if (mem.eql(u8, "upgrade", header)) {
				if (!ascii.eqlIgnoreCase("websocket", mem.trim(u8, value, &ascii.whitespace))) {
					return HandshakeError.InvalidUpgrade;
				}
				required_headers |= 1;
			} else if (mem.eql(u8, "sec-websocket-version", header)) {
				if (!mem.eql(u8, "13", mem.trim(u8, value, &ascii.whitespace))) {
					return HandshakeError.InvalidVersion;
				}
				required_headers |= 2;
			} else if (mem.eql(u8, "connection", header)) {
				// find if connection header has upgrade in it, example header: 
				//		Connection: keep-alive, Upgrade
				if (ascii.indexOfIgnoreCase(value, "upgrade") == null) {
					return HandshakeError.InvalidConnection;
				}
				required_headers |= 4;
			} else if (mem.eql(u8, "sec-websocket-key", header)) {
				key = mem.trim(u8, value, &ascii.whitespace);
				required_headers |= 8;
			}
			const next = index + 2;
			request_length += next;
			data = data[next..];
		}

		if (required_headers != 15) {
			return HandshakeError.MissingHeaders;
		}

		// we already established that request_line ends with http/1.1, so this buys
		// us some leeway into parsing it
		const separator = mem.indexOfScalar(u8, request_line, ' ') orelse return HandshakeError.InvalidRequestLine;
		const method = request_line[0..separator];
		const url = mem.trim(u8, request_line[separator + 1 .. request_line.len - 9], &ascii.whitespace);

		return .{
			.key = key,
			.url = url,
			.method = method,
			.headers = buf[request_line_end+2..request_length+2],
		};
	}

	pub fn close(stream: Stream, err: anyerror) !void {
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

	pub fn reply(self: Handshake, stream: Stream) !void {
		var h: [20]u8 = undefined;
		//"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: BASE64_ENCODED_KEY_HASH_PLACEHOLDER_000\r\n\r\n";
		var buf = [_]u8{
			'H','T','T','P','/','1','.','1',' ', '1','0','1',' ', 'S','w','i','t','c','h','i','n','g',' ','P','r','o','t','o','c','o','l','s', '\r','\n',
			'U','p','g','r','a','d','e',':',' ','w','e','b','s','o','c','k','e','t','\r','\n',
			'C','o','n','n','e','c','t','i','o','n',':',' ','u','p','g','r','a','d','e','\r','\n',
			'S','e','c','-','W','e','b','s','o','c','k','e','t','-','A','c','c','e','p','t',':',' ',0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,'\r','\n',
			'\r','\n'
		};
		const key_pos = buf.len - 32;

		var hasher = std.crypto.hash.Sha1.init(.{});
		hasher.update(self.key);
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

test "handshake: parse" {
	var buffer: [512]u8 = undefined;
	var buf = buffer[0..];

	try t.expectEqual(testHandshake("GET / HTTP/1.0\r\n\r\n", buf), HandshakeError.InvalidProtocol);
	try t.expectEqual(testHandshake("GET / HTTP/1.1\r\n\r\n", buf), HandshakeError.MissingHeaders);
	try t.expectEqual(testHandshake("GET / HTTP/1.1\r\nConnection:  upgrade\r\n\r\n", buf), HandshakeError.MissingHeaders);
	try t.expectEqual(testHandshake("GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n", buf), HandshakeError.MissingHeaders);
	try t.expectEqual(testHandshake("GET / HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\n\r\n", buf), HandshakeError.MissingHeaders);

	{
		const h = try testHandshake("GET /test?a=1   HTTP/1.1\r\nConnection: upgrade\r\nUpgrade: websocket\r\nsec-websocket-version:13\r\nsec-websocket-key: 9000!\r\nCustom: Header-Value\r\n\r\n", buf);
		try t.expectString("9000!", h.key);
		try t.expectString("GET", h.method);
		try t.expectString("/test?a=1", h.url);
		try t.expectString("connection: upgrade\r\nupgrade: websocket\r\nsec-websocket-version:13\r\nsec-websocket-key: 9000!\r\ncustom: Header-Value\r\n", h.headers);
	}

	// fuzz tests
	{
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
			const request_buf = Request.read(&s, buf) catch unreachable;
			const h = Handshake.parse(request_buf) catch unreachable;
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
		.headers = "",
		.key = "this is my key",
	};
	try h.reply(&s);

	var pos: usize = 0;
	const expected = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: flzHu2DevQ2dSCSVqKSii5e9C2o=\r\n\r\n";
	for (s.received.items) |chunk| {
		try t.expectString(expected[pos..(pos+chunk.len)], chunk);
		pos += chunk.len;
	}
}

fn testHandshake(input: []const u8, buf: []u8) !Handshake {
	var s = t.Stream.init();
	_ = s.add(input);

	defer s.deinit();
	const request_buf = try Request.read( &s, buf);
	return Handshake.parse(request_buf);
}
