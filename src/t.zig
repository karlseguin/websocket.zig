const std = @import("std");

const mem = std.mem;
const ArrayList = std.ArrayList;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub fn getRandom() std.rand.DefaultPrng {
	var seed: u64 = undefined;
	std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
	return std.rand.DefaultPrng.init(seed);
}

pub const Stream = struct {
	closed: bool,
	buf_index: usize,
	read_index: usize,
	frames: ?[]u8,
	handshake_index: ?usize,
	to_read: ArrayList([]const u8),
	random: std.rand.DefaultPrng,
	received: ArrayList([]const u8),

	pub fn init() Stream {
		return .{
			.closed = false,
			.buf_index = 0,
			.read_index = 0,
			.frames = null,
			.random = getRandom(),
			.handshake_index = null,
			.to_read = ArrayList([]const u8).init(allocator),
			.received = ArrayList([]const u8).init(allocator),
		};
	}

	// init's the stream + sets up a valid handshake
	const HANDSHAKE = "GET / HTTP/1.1\r\n" ++
		"Connection: upgrade\r\n" ++
		"Upgrade: websocket\r\n" ++
		"Sec-websocket-version: 13\r\n" ++
		"Sec-websocket-key: leto\r\n\r\n";

	pub fn handshake() Stream {
		var s = init();
		s.handshake_index = 0;
		return s;
	}

	// When bytes are added via add, the call to read will return the
	// bytes exactly as they were added, provided the destination has
	// enough space. This is different than adding the bytes via a frame
	// method which will cause random fragmentation (those framing methods
	// ultimate end up calling add).
	pub fn add(self: *Stream, value: []const u8) *Stream {
		// Take ownership of this data so that we can consistently free each
		// (necessary because we need to allocate data for frames)
		var copy = allocator.alloc(u8, value.len) catch unreachable;
		mem.copy(u8, copy, value);
		self.to_read.append(copy) catch unreachable;
		return self;
	}

	pub fn fragmentedAdd(self: *Stream, value: []const u8) *Stream {
		var start: usize = 0;
		var frames: []u8 = undefined;

		if (self.frames) |f| {
			start = f.len;
			frames = allocator.realloc(f, start + value.len) catch unreachable;
		} else {
			frames = allocator.alloc(u8, value.len) catch unreachable;
		}
		mem.copy(u8, frames[start..], value);
		self.frames = frames;
		return self;
	}

	pub fn ping(self: *Stream) *Stream {
		return self.pingPayload("");
	}

	pub fn pingPayload(self: *Stream, payload: []const u8) *Stream {
		return self.frame(true, 9, payload, 0);
	}

	pub fn textFrame(self: *Stream, fin: bool, payload: []const u8) *Stream {
		return self.frame(fin, 1, payload, 0);
	}

	pub fn textFrameReserved(self: *Stream, fin: bool, payload: []const u8, reserved: u8) *Stream {
		return self.frame(fin, 1, payload, reserved);
	}

	pub fn cont(self: *Stream, fin: bool, payload: []const u8) *Stream {
		return self.frame(fin, 0, payload, 0);
	}

	pub fn frame(self: *Stream, fin: bool, op_code: u8, payload: []const u8, reserved: u8) *Stream {
		const l = payload.len;
		var length_of_length: usize = 0;

		if (l > 125) {
			if (l < 65536) {
				length_of_length = 2;
			} else {
				length_of_length = 8;
			}
		}

		var start: usize = 0;
		var frames: []u8 = undefined;

		// 2 byte header + length_of_length + mask + payload_length
		var needed = 2 + length_of_length + 4 + l;

		if (self.frames) |f| {
			start = f.len;
			frames = allocator.realloc(f, f.len + needed) catch unreachable;
		} else {
			frames = allocator.alloc(u8, needed) catch unreachable;
		}

		if (fin) {
			frames[start] = 128 | op_code | reserved;
		} else {
			frames[start] = op_code | reserved;
		}

		if (length_of_length == 0) {
			frames[start + 1] = 128 | @intCast(u8, l);
		} else if (length_of_length == 2) {
			frames[start + 1] = 128 | 126;
			frames[start + 2] = @intCast(u8, (l >> 8) & 0xFF);
			frames[start + 3] = @intCast(u8, l & 0xFF);
		} else {
			frames[start + 1] = 128 | 127;
			frames[start + 2] = @intCast(u8, (l >> 56) & 0xFF);
			frames[start + 3] = @intCast(u8, (l >> 48) & 0xFF);
			frames[start + 4] = @intCast(u8, (l >> 40) & 0xFF);
			frames[start + 5] = @intCast(u8, (l >> 32) & 0xFF);
			frames[start + 6] = @intCast(u8, (l >> 24) & 0xFF);
			frames[start + 7] = @intCast(u8, (l >> 16) & 0xFF);
			frames[start + 8] = @intCast(u8, (l >> 8) & 0xFF);
			frames[start + 9] = @intCast(u8, l & 0xFF);
		}

		// +2 for the 2 byte prefix
		const mask_start = start + 2 + length_of_length;
		const mask = frames[mask_start .. mask_start + 4];
		self.random.random().bytes(mask);
		// frames[mask_start] = 0;
		// frames[mask_start + 1] = 0;
		// frames[mask_start + 2] = 0;
		// frames[mask_start + 3] = 0;

		const payload_start = mask_start + 4;
		for (payload, 0..) |b, i| {
			frames[payload_start + i] = b ^ mask[i & 3];
		}

		self.frames = frames;
		return self;
	}

	pub fn read(self: *Stream, buf: []u8) !usize {
		std.debug.assert(!self.closed);

		if (self.handshake_index) |index| {
			std.mem.copy(u8, buf, HANDSHAKE[index..]);
			const written = std.math.min(buf.len, HANDSHAKE.len - index);
			if (written < buf.len) {
				self.handshake_index = null;
			} else {
				self.handshake_index.? += written;
			}
			return written;
		}

		// The first time we call read with frames we will fragment the messages.
		// The goal is to simulate TCP fragmentation. This doesn't just mean making
		// some reads smaller than a frame, it also means making some reads overread
		// one frame plus part (or all) of the next.
		// This can be voided by using the add function directly.
		if (self.frames) |frames| {
			var data = frames;
			var random = self.random.random();
			while (data.len > 0) {
				const l = random.uintAtMost(usize, data.len - 1) + 1;
				_ = self.add(data[0..l]);
				data = data[l..];
			}
			allocator.free(frames);
			self.frames = null;
		}

		const items = self.to_read.items;
		if (self.read_index == items.len) {
			return 0;
		}

		var data = items[self.read_index][self.buf_index..];
		if (data.len > buf.len) {
			// we have more data than we have space in buf (our target)
			// we'll fill the target buffer, and keep track of where
			// we our in our source buffer, so that that on the next read
			// we'll use the same source buffer, but at the offset
			self.buf_index += buf.len;
			data = data[0..buf.len];
		} else {
			// ok, fully read this one, next time we can move on
			self.buf_index = 0;
			self.read_index += 1;
		}

		for (data, 0..) |b, i| {
			buf[i] = b;
		}

		return data.len;
	}

	// store messages that are written to the stream
	pub fn write(self: *Stream, data: []const u8) !void {
		std.debug.assert(!self.closed);
		var copy = allocator.alloc(u8, data.len) catch unreachable;
		mem.copy(u8, copy, data);
		self.received.append(copy) catch unreachable;
	}

	pub fn close(self: *Stream) void {
		self.closed = true;
	}

	// self should continue to be valid after this call (since we can clone
	// it multiple times)
	pub fn clone(self: *Stream) Stream {
		var c = Stream.init();
		if (self.frames) |f| {
			var copy = allocator.alloc(u8, f.len) catch unreachable;
			mem.copy(u8, copy, f);
			c.frames = copy;
		}
		c.handshake_index = self.handshake_index;
		return c;
	}

	pub fn deinit(self: *Stream) void {
		for (self.to_read.items) |buf| {
			allocator.free(buf);
		}
		self.to_read.deinit();

		if (self.frames) |frames| {
			allocator.free(frames);
			self.frames = null;
		}

		if (self.received.items.len > 0) {
			for (self.received.items) |buf| {
				allocator.free(buf);
			}
			self.received.deinit();
		}

		self.* = undefined;
	}
};
