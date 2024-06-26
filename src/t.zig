const std = @import("std");
const builtin = @import("builtin");
const lib = @import("lib.zig");

const os = std.posix;
const mem = std.mem;
const ArrayList = std.ArrayList;

pub const allocator = std.testing.allocator;

pub fn expectEqual(expected: anytype, actual: anytype) !void {
	try std.testing.expectEqual(@as(@TypeOf(actual), expected), actual);
}

pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;
pub const expectSlice = std.testing.expectEqualSlices;

pub fn getRandom() std.Random.DefaultPrng {
	var seed: u64 = undefined;
	std.posix.getrandom(mem.asBytes(&seed)) catch unreachable;
	return std.Random.DefaultPrng.init(seed);
}

pub const SocketPair = struct {
	buf: std.ArrayList(u8),
	client: std.net.Stream,
	server: std.net.Stream,
	random: std.Random.DefaultPrng,

	pub fn init() SocketPair {
		var address = std.net.Address.parseIp("127.0.0.1", 0) catch unreachable;
		var address_len = address.getOsSockLen();

		const listener = os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, os.IPPROTO.TCP) catch unreachable;
		defer os.close(listener);

		{
			// setup our listener
			os.bind(listener, &address.any, address_len) catch unreachable;
			os.listen(listener, 1) catch unreachable;
			os.getsockname(listener, &address.any, &address_len) catch unreachable;
		}

		const client = os.socket(address.any.family, os.SOCK.STREAM, os.IPPROTO.TCP) catch unreachable;
		{
			// connect the client
			const flags =  os.fcntl(client, os.F.GETFL, 0) catch unreachable;
			_ = os.fcntl(client, os.F.SETFL, flags | os.SOCK.NONBLOCK) catch unreachable;
			os.connect(client, &address.any, address_len) catch |err| switch (err) {
				error.WouldBlock => {},
				else => unreachable,
			};
			_ = os.fcntl(client, os.F.SETFL, flags) catch unreachable;
		}

		const server = os.accept(listener, &address.any, &address_len, os.SOCK.CLOEXEC) catch unreachable;

		return .{
			.random = getRandom(),
			.client = .{.handle = client},
			.server = .{.handle = server},
			.buf = std.ArrayList(u8).init(allocator),
		};
	}

	pub fn deinit(self: *SocketPair) void {
		self.buf.deinit();
		// assume test closes self.server
		self.client.close();
	}

	pub fn handshakeRequest(self: SocketPair) void {
		self.client.writeAll("GET / HTTP/1.1\r\n" ++
			"Connection: upgrade\r\n" ++
			"Upgrade: websocket\r\n" ++
			"Sec-websocket-version: 13\r\n" ++
			"Sec-websocket-key: leto\r\n\r\n"
		) catch unreachable;
	}

	pub fn handshakeReply(self: SocketPair) !void {
		var pos: usize = 0;
		var buf: [1024]u8 = undefined;
		while (true) {
			const n = try self.client.read(buf[pos..]);
			if (n == 0) {
				return error.Closed;
			}
			pos += n;
			if (std.mem.endsWith(u8, buf[0..pos], "\r\n\r\n")) {
				return;
			}
		}
	}

	pub fn ping(self: *SocketPair) void {
		return self.pingPayload("");
	}

	pub fn pingPayload(self: *SocketPair, payload: []const u8) void {
		return self.frame(true, 9, payload, 0);
	}

	pub fn textFrame(self: *SocketPair, fin: bool, payload: []const u8) void {
		return self.frame(fin, 1, payload, 0);
	}

	pub fn binaryFrame(self: *SocketPair, fin: bool, payload: []const u8) void {
		return self.frame(fin, 2, payload, 0);
	}

	pub fn textFrameReserved(self: *SocketPair, fin: bool, payload: []const u8, reserved: u8) void {
		return self.frame(fin, 1, payload, reserved);
	}

	pub fn cont(self: *SocketPair, fin: bool, payload: []const u8) void {
		return self.frame(fin, 0, payload, 0);
	}

	pub fn frame(self: *SocketPair, fin: bool, op_code: u8, payload: []const u8, reserved: u8) void {
		var buf = &self.buf;

		const l = payload.len;
		var length_of_length: usize = 0;

		if (l > 125) {
			if (l < 65536) {
				length_of_length = 2;
			} else {
				length_of_length = 8;
			}
		}

		// 2 byte header + length_of_length + mask + payload_length
		const needed = 2 + length_of_length + 4 + l;
		buf.ensureUnusedCapacity(needed) catch unreachable;

		if (fin) {
			buf.appendAssumeCapacity(128 | op_code | reserved);
		} else {
			buf.appendAssumeCapacity(op_code | reserved);
		}

		if (length_of_length == 0) {
			buf.appendAssumeCapacity(128 | @as(u8, @intCast(l)));
		} else if (length_of_length == 2) {
			buf.appendAssumeCapacity(128 | 126);
			buf.appendAssumeCapacity(@intCast((l >> 8) & 0xFF));
			buf.appendAssumeCapacity(@intCast(l & 0xFF));
		} else {
			buf.appendAssumeCapacity(128 | 127);
			buf.appendAssumeCapacity(@intCast((l >> 56) & 0xFF));
			buf.appendAssumeCapacity(@intCast((l >> 48) & 0xFF));
			buf.appendAssumeCapacity(@intCast((l >> 40) & 0xFF));
			buf.appendAssumeCapacity(@intCast((l >> 32) & 0xFF));
			buf.appendAssumeCapacity(@intCast((l >> 24) & 0xFF));
			buf.appendAssumeCapacity(@intCast((l >> 16) & 0xFF));
			buf.appendAssumeCapacity(@intCast((l >> 8) & 0xFF));
			buf.appendAssumeCapacity(@intCast(l & 0xFF));
		}

		// +2 for the 2 byte prefix
		var mask: [4]u8 = undefined;
		self.random.random().bytes(&mask);
		buf.appendSliceAssumeCapacity(&mask);

		for (payload, 0..) |b, i| {
			buf.appendAssumeCapacity(b ^ mask[i & 3]);
		}
	}

	pub fn sendBuf(self: *SocketPair) void {
		self.client.writeAll(self.buf.items) catch unreachable;
		self.buf.clearRetainingCapacity();
	}

	pub fn asReceived(self: SocketPair) Received {
		var buf: [1024]u8 = undefined;
		var all = std.ArrayList(u8).init(allocator);
		errdefer all.deinit();

		while (true) {
			const n = self.client.read(&buf) catch 0;
			if (n == 0) {
				return Received.init(all);
			}
			all.appendSlice(buf[0..n]) catch unreachable;
		}
	}
};

pub const Received = struct {
	raw: std.ArrayList(u8),
	messages: []lib.Message,

	fn init(raw: std.ArrayList(u8)) Received {
		var pos: usize = 0;
		const buf = raw.items;

		var messages = std.ArrayList(lib.Message).init(allocator);
		defer messages.deinit();

		while (pos < buf.len) {
			const message_type = switch (buf[pos] & 15) {
				1 => lib.MessageType.text,
				2 => lib.MessageType.binary,
				8 => lib.MessageType.close,
				10 => lib.MessageType.pong,
				else => unreachable,
			};
			pos += 1;

			// Let's figure out if this message is all within this single frame
			// or if it's split between this frame and the next.
			// If it is split, then this frame will contain OP + LENGTH_PREFIX + LENGTH
			// and the next one will be the full payload (and nothing else)
			const length_of_length: u8 = switch (buf[pos] & 127) {
				126 => 2,
				127 => 8,
				else => 0,
			};

			const payload_length = switch (length_of_length) {
				2 => @as(u16, @intCast(buf[pos+2])) | (@as(u16, @intCast(buf[pos+1])) << 8),
				8 => @as(u64, @intCast(buf[pos+8])) | @as(u64, @intCast(buf[pos+7])) << 8 | @as(u64, @intCast(buf[pos+6])) << 16 | @as(u64,  @intCast(buf[pos+5])) << 24 | @as(u64, @intCast(buf[pos+4])) << 32 | @as(u64, @intCast(buf[pos+3])) << 40 | @as(u64, @intCast(buf[pos+2])) << 48 | @as(u64, @intCast(buf[pos+1])) << 56,
				else => buf[pos],
			};
			pos += 1 + length_of_length;
			const end = pos + payload_length;

			messages.append(.{
				.data = buf[pos..end],
				.type = message_type,
			}) catch unreachable;

			pos = end;
		}

		const owned = allocator.alloc(lib.Message, messages.items.len) catch unreachable;
		for (messages.items, 0..) |message, i| {
			owned[i] = message;
		}

		return .{
			.raw = raw,
			.messages = owned
		};
	}

	pub fn deinit(self: Received) void {
		self.raw.deinit();
		allocator.free(self.messages);
	}
};
