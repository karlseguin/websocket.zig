const std = @import("std");
const proto = @import("../proto.zig");
const buffer = @import("../buffer.zig");

const net = std.net;
const posix = std.posix;
const tls = std.crypto.tls;

const Reader = proto.Reader;
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;

pub const Client = struct {
	stream: Stream,
	_reader: Reader,
	_closed: bool,

	// When creating a client, we can either be given a BufferProvider or create
	// one ourselves. If we create it ourselves (in init), we "own" it and must
	// free it on deinit. (The reference to the buffer provider is already in the
	// reader, no need to hold another reference in the client).
	_own_bp: bool,

	// For advanced cases, a custom masking function can be provided. Masking
	// is a security feature that only really makes sense in the browser. If you
	// aren't running websockets in the browser AND you control both the client
	// and the server, you could get a performance boost by not masking.
	_mask_fn: *const fn() [4]u8,

	pub const Config = struct {
		port: u16,
		host: []const u8,
		tls: bool = false,
		max_size: usize = 65536,
		buffer_size: usize = 4096,
		ca_bundle: ?Bundle = null,
		mask_fn: *const fn() [4]u8 = generateMask,
		buffer_provider: ?*buffer.Provider = null,
	};

	pub const HandshakeOpts = struct {
		timeout_ms: u32 = 10000,
		headers: ?[]const u8 = null,
	};

	pub fn init(allocator: Allocator, config: Config) !Client {
		const net_stream = try net.tcpConnectToHost(allocator, config.host, config.port);

		var tls_client: ?tls.Client = null;
		if (config.tls) {
			var own_bundle = false;
			var bundle = config.ca_bundle orelse blk: {
				own_bundle = true;
				var b = Bundle{};
				try b.rescan(allocator);
				break :blk b;
			};
			defer if (own_bundle) {
				bundle.deinit(allocator);
			};
			tls_client = try tls.Client.init(net_stream, bundle, config.host);
		}
		const stream = Stream.init(net_stream, tls_client);

		var own_bp = false;
		var buffer_provider: *buffer.Provider = undefined;

		// If a buffer_provider is provided, we'll use that.
		// If it isn't, we need to create one which also means we now "own" it
		// and we're responsible for cleaning it up
		if (config.buffer_provider) |shared_bp| {
			buffer_provider = shared_bp;
		} else {
			own_bp = true;
			buffer_provider = try allocator.create(buffer.Provider);
			errdefer allocator.destroy(buffer_provider);
			buffer_provider.* = try buffer.Provider.init(allocator, .{
				.size = 0,
				.count = 0,
				.max = config.max_size,
			});
		}

		errdefer if (own_bp) {
			buffer_provider.deinit();
			allocator.destroy(buffer_provider);
		};

		const reader_buf = try buffer_provider.allocator.alloc(u8, config.buffer_size);
		errdefer buffer_provider.allocator.free(reader_buf);

		return .{
			.stream = stream,
			._closed = false,
			._own_bp = own_bp,
			._mask_fn = config.mask_fn,
			._reader = Reader.init(reader_buf, buffer_provider),
		};
	}

	pub fn deinit(self: *Client) void {
		self.close();

		const larger_buffer_provider = self._reader.large_buffer_provider;
		const allocator = larger_buffer_provider.allocator;
		allocator.free(self._reader.static);

		self._reader.deinit();

		if (self._own_bp) {
			larger_buffer_provider.deinit();
			allocator.destroy(larger_buffer_provider);
		}
	}

	pub fn handshake(self: *Client, path: []const u8, opts: HandshakeOpts) !void {
		const stream = &self.stream;
		errdefer self.closeWithCode(1002);

		// we've already setup our reader, and the reader has a static buffer
		// we might as well use it!
		const buf = self._reader.static;

		const key = blk: {
			const bin_key = generateKey();
			var encoded_key: [24]u8 = undefined;
			break :blk std.base64.standard.Encoder.encode(&encoded_key, &bin_key);
		};

		try sendHandshake(path, key, buf, &opts, stream);

		const over_read = try readHandshakeReply(buf, key, &opts, stream);
		// We might have read more than handshake response. If so, readHandshakeReply
		// has positioned the extra data at the start of the buffer, but we need
		// to set the length.
		self._reader.pos = over_read;
	}

	pub fn readLoop(self: *Client, handler: anytype) !void {
		const H = @TypeOf(handler);

		var reader = &self._reader;
		const stream = &self.stream;

		defer if (comptime std.meta.hasFn(H, "close")) {
			handler.close();
		};

		while (true) {
			// for a single fill, we might have multiple messages to process
			while (true) {
				const has_more, const message = reader.read() catch |err| {
					self.closeWithCode(1002);
					return err;
				} orelse break; // orelse, we don't have enough data, so break out of the inner loop, and go get more data from the socket in the outer loop


				const message_type = message.type;
				defer reader.done(message_type);

				switch (message_type) {
					.text, .binary => {
						switch (comptime @typeInfo(@TypeOf(H.handleMessage)).Fn.params.len) {
							2 => try handler.handleMessage(message.data),
							3 => try handler.handleMessage(message.data, if (message_type == .text) .text else .binary),
							else => @compileError(@typeName(H) ++ ".handleMessage must accept 2 or 3 parameters"),
						}
					},
					.ping => if (comptime std.meta.hasFn(H, "handlePing")) {
						try handler.handlePing(message.data);
					} else {
						// @constCast is safe because we know message.data points to
						// reader.buffer.buf, which we own and which can be mutated
						try self.writeFrame(.pong, @constCast(message.data));
					},
					.close => {
						if (comptime std.meta.hasFn(H, "handleClose")) {
							try handler.handleClose(message.data);
						} else {
							self.close();
						}
						return;
					},
					.pong => if (comptime std.meta.hasFn(H, "handlePong")) {
						try handler.handlePong();
					},
				}

				if (has_more == false) {
					// break out of the inner loop, and back into the outer loop
					// to fill the buffer with more data from the socket
					break;
				}
			}

			// Wondering why we don't call fill at the start of the outer loop?
			// When we read the handshake response, we might already have a message
			// (or part of a message) to process. So we always want to run reader.next()
			// first, to process any initial message we might have.
			// If we call fill first, we might block forever, despite there being
			// an initial message waiting.
			reader.fill(stream) catch |err| switch (err) {
				error.Closed, error.ConnectionResetByPeer, error.BrokenPipe, error.NotOpenForReading => {
					_ = @cmpxchgStrong(bool, &self._closed, false, true, .monotonic, .monotonic);
					return;
				},
				else => {
					self.closeWithCode(1002);
					return err;
				},
			};
		}
	}

	pub fn readLoopInNewThread(self: *Client, h: anytype) !std.Thread {
		return std.Thread.spawn(.{}, readLoopOwnedThread, .{self, h});
	}

	fn readLoopOwnedThread(self: *Client, h: anytype) void {
		self.readLoop(h) catch {};
	}

	pub fn write(self: *Client, data: []u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn writeText(self: *Client, data: []u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn writeBin(self: *Client, data: []u8) !void {
		return self.writeFrame(.binary, data);
	}

	pub fn writePing(self: *Client, data: []u8) !void {
		return self.writeFrame(.ping, data);
	}

	pub fn writePong(self: *Client, data: []u8) !void {
		return self.writeFrame(.pong, data);
	}

	pub fn writeFrame(self: *Client, op_code: proto.OpCode, data: []u8) !void {
		const l = data.len;
		const mask = self._mask_fn();
		var stream = &self.stream;

		// maximum possible prefix length. op_code + length_type + 8byte length + 4 byte mask
		var buf: [14]u8 = undefined;
		buf[0] = @intFromEnum(op_code);

		if (l <= 125) {
			buf[1] = @as(u8, @intCast(l)) | 128;
			@memcpy(buf[2..6], &mask);
			try stream.writeAll(buf[0..6]);
		} else if (l < 65536) {
			buf[1] = 254; // 126 | 128
			buf[2] = @intCast((l >> 8) & 0xFF);
			buf[3] = @intCast(l & 0xFF);
			@memcpy(buf[4..8], &mask);
			try stream.writeAll(buf[0..8]);
		} else {
			buf[1] = 255; // 127 | 128
			buf[2] = @intCast((l >> 56) & 0xFF);
			buf[3] = @intCast((l >> 48) & 0xFF);
			buf[4] = @intCast((l >> 40) & 0xFF);
			buf[5] = @intCast((l >> 32) & 0xFF);
			buf[6] = @intCast((l >> 24) & 0xFF);
			buf[7] = @intCast((l >> 16) & 0xFF);
			buf[8] = @intCast((l >> 8) & 0xFF);
			buf[9] = @intCast(l & 0xFF);
			@memcpy(buf[10..], &mask);
			try stream.writeAll(buf[0..]);
		}

		if (l > 0) {
			proto.mask(&mask, data);
			try stream.writeAll(data);
		}
	}

	pub fn close(self: *Client) void {
		if (@cmpxchgStrong(bool, &self._closed, false, true, .monotonic, .monotonic) == null) {
			self.writeFrame(.close, "") catch {};
			self.stream.close();
		}
	}

	pub fn closeWithCode(self: *Client, code: u16) void {
		if (@cmpxchgStrong(bool, &self._closed, false, true, .monotonic, .monotonic) == null) {
			var buf: [2]u8 = undefined;
			buf[0] = @intCast((code >> 8) & 0xFF);
			buf[1] = @intCast(code & 0xFF);
			self.writeFrame(.close, &buf) catch {};
			self.stream.close();
		}
	}
};

// wraps a net.Stream and optional a tls.Client
pub const Stream = struct {
	stream: net.Stream,
	tls_client: ?tls.Client = null,

	pub fn init(stream: net.Stream, tls_client: ?tls.Client) Stream {
		return .{
			.stream = stream,
			.tls_client = tls_client,
		};
	}

	pub fn close(self: *Stream) void {
		if (self.tls_client) |*tls_client| {
			_ = tls_client.writeEnd(self.stream, "", true) catch {};
		}
		self.stream.close();
	}

	pub fn read(self: *Stream, buf: []u8) !usize {
		if (self.tls_client) |*tls_client| {
			return tls_client.read(self.stream, buf);
		}
		return self.stream.read(buf);
	}

	pub fn writeAll(self: *Stream, data: []const u8) !void {
		if (self.tls_client) |*tls_client| {
			return tls_client.writeAll(self.stream, data);
		}
		return self.stream.writeAll(data);
	}

	const zero_timeout = std.mem.toBytes(posix.timeval{.sec = 0, .usec = 0});
	pub fn writeTimeout(self: *const Stream, ms: u32) !void {
		if (ms == 0) {
			return self.setsockopt(posix.SO.SNDTIMEO, &zero_timeout);
		}

		const timeout = std.mem.toBytes(posix.timeval{
			.sec = @intCast(@divTrunc(ms, 1000)),
			.usec = @intCast(@mod(ms, 1000) * 1000),
		});
		return self.setsockopt(posix.SO.SNDTIMEO, &timeout);
	}

	pub fn receiveTimeout(self: *const Stream, ms: u32) !void {
		if (ms == 0) {
			return self.setsockopt(posix.SO.RCVTIMEO, &zero_timeout);
		}

		const timeout = std.mem.toBytes(posix.timeval{
			.sec = @intCast(@divTrunc(ms, 1000)),
			.usec = @intCast(@mod(ms, 1000) * 1000),
		});
		return self.setsockopt(posix.SO.RCVTIMEO, &timeout);
	}

	pub fn setsockopt(self: *const Stream, optname: u32, value: []const u8) !void {
		return posix.setsockopt(self.stream.handle, posix.SOL.SOCKET, optname, value);
	}
};

fn generateKey() [16]u8 {
	if (comptime @import("builtin").is_test) {
		return [16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
	}
	var key: [16]u8 = undefined;
	std.crypto.random.bytes(&key);
	return key;
}

fn generateMask() [4]u8 {
	var m: [4]u8 = undefined;
	std.crypto.random.bytes(&m);
	return m;
}

fn sendHandshake(path: []const u8, key: []const u8, buf: []u8, opts: *const Client.HandshakeOpts, stream: anytype) !void {
	@memcpy(buf[0..4], "GET ");
	var pos: usize = 4;
	var end = pos + path.len;

	{
		@memcpy(buf[pos..end], path);
		pos = end;
	}

	{
		const headers = " HTTP/1.1\r\ncontent-length: 0\r\nupgrade: websocket\r\nsec-websocket-version: 13\r\nconnection: upgrade\r\nsec-websocket-key: ";
		end = pos + headers.len;
		@memcpy(buf[pos..end], headers);

		pos = end;
		end = pos + key.len;
		@memcpy(buf[pos..end], key);

		pos = end;
		end = pos + 2;
		@memcpy(buf[pos..end], "\r\n");
		pos = end;
	}

	if (opts.headers) |extra_headers| {
		end = pos + extra_headers.len;
		@memcpy(buf[pos..end], extra_headers);
		pos = end;
		if (!std.mem.endsWith(u8, extra_headers, "\r\n")) {
			buf[pos] = '\r';
			buf[pos+1] = '\n';
			pos += 2;
		}
	}
	buf[pos] = '\r';
	buf[pos+1] = '\n';

	try stream.writeTimeout(opts.timeout_ms);
	try stream.writeAll(buf[0..pos + 2]);
	try stream.writeTimeout(0);
}

fn readHandshakeReply(buf: []u8, key: []const u8, opts: *const Client.HandshakeOpts, stream: anytype) !usize {
	const ascii = std.ascii;

	const timeout_ms = opts.timeout_ms;
	const deadline = std.time.milliTimestamp() + timeout_ms;
	try stream.receiveTimeout(timeout_ms);

	var pos: usize = 0;
	var line_start: usize = 0;
	var complete_response: u8 = 0;

	while (true) {
		const n = try stream.read(buf[pos..]);
		if (n == 0) {
			return error.ConnectionClosed;
		}

		pos += n;
		while (std.mem.indexOfScalar(u8, buf[line_start..pos], '\r')) |relative_end| {
			if (relative_end == 0) {
				if (complete_response != 15) {
					return error.InvalidHandshakeResponse;
				}
				const over_read = pos - (line_start + 2);
				std.mem.copyForwards(u8, buf[0..over_read], buf[line_start+2..pos]);
				try stream.receiveTimeout(0);
				return over_read;
			}

			const line_end = line_start + relative_end;
			const line = buf[line_start..line_end];

			// the next line starts where this line ends, skip over the \r\n
			line_start = line_end + 2;

			if (complete_response == 0) {
				if (!ascii.startsWithIgnoreCase(line, "HTTP/1.1 101 ")) {
					return error.InvalidHandshakeResponse;
				}
				complete_response |= 1;
				continue;
			}

			for (line, 0..) |b, i| {
				// find the colon and lowercase the header while we're iterating
				if ('A' <= b and b <= 'Z') {
					line[i] = b + 32;
					continue;
				}

				if (b != ':') {
					continue;
				}

				switch (i) {
					7 => if (eql(line[0..i], "upgrade")) {
						if (!ascii.eqlIgnoreCase(std.mem.trim(u8, line[i+1..], &ascii.whitespace), "websocket")) {
							return error.InvalidUpgradeHeader;
						}
						complete_response |= 2;
					},
					10 => if (eql(line[0..i], "connection")) {
						if (!ascii.eqlIgnoreCase(std.mem.trim(u8, line[i+1..], &ascii.whitespace), "upgrade")) {
							return error.InvalidConnectionHeader;
						}
						complete_response |= 4;
					},
					20 => if (eql(line[0..i], "sec-websocket-accept")) {
						var h: [20]u8 = undefined;
						{
							var hasher = std.crypto.hash.Sha1.init(.{});
							hasher.update(key);
							hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
							hasher.final(&h);
						}

						var encoded_buf: [28]u8 = undefined;
						const sec_hash = std.base64.standard.Encoder.encode(&encoded_buf, &h);
						const header_value = std.mem.trim(u8, line[i+1..], &ascii.whitespace);

						if (!std.mem.eql(u8, header_value, sec_hash)) {
							return error.InvalidWebsocketAcceptHeader;
						}
						complete_response |= 8;
					},
					else => {}, // some other header we don't care about
				}
			}
		}

		if (std.time.milliTimestamp() > deadline) {
			return error.Timeout;
		}

		if (pos == buf.len) {
			return error.ResponseTooLarge;
		}
	}
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
test "Client: handshake" {
	{
		// empty response
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
	}

	{
		// invalid websocket response
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 200 OK\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
	}

	{
		// missing upgrade header
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
	}

	{
		// wrong upgrade header
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: nope\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try t.expectError(error.InvalidUpgradeHeader, client.handshake("/", .{}));
	}

	{
		// missing connection header
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: websocket\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
	}

	{
		// wrong connection header
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: something\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try t.expectError(error.InvalidConnectionHeader, client.handshake("/", .{}));
	}

	{
		// missing Sec-Websocket-Accept header
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: websocket\r\nConnection: upgrade\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
	}

	{
		// wrong Sec-Websocket-Accept header
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: hack\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try t.expectError(error.InvalidWebsocketAcceptHeader, client.handshake("/", .{}));
	}

	{
		// ok for successful
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: C/0nmHhBztSRGR1CwL6Tf4ZjwpY=\r\n\r\n");

		var client = testClient(pair.server);
		defer client.deinit();
		try client.handshake("/", .{});
		try t.expectEqual(0, client._reader.pos);
	}

	{
		// ok for successful, with overread
		var pair = t.SocketPair.init();
		defer pair.deinit();
		try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: C/0nmHhBztSRGR1CwL6Tf4ZjwpY=\r\n\r\nSome Random Data Which is Part Of the Next Message");

		var client = testClient(pair.server);
		defer client.deinit();
		try client.handshake("/", .{});
		try t.expectEqual(50, client._reader.pos);
	}
}

fn testClient(stream: net.Stream) Client {
	const bp = t.allocator.create(buffer.Provider) catch unreachable;
	bp.* = buffer.Provider.init(t.allocator, .{.count = 0, .size = 0, .max = 4096}) catch unreachable;

	const reader_buf = bp.allocator.alloc(u8, 1024) catch unreachable;

	return .{
		._closed = false,
		._own_bp = true,
		._mask_fn = generateMask,
		.stream = .{.stream = stream},
		._reader = Reader.init(reader_buf, bp),
	};
}
