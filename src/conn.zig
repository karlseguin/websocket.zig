const std = @import("std");
const lib = @import("lib.zig");

const net = std.net;
const posix = std.posix;

const OpCode = lib.framing.OpCode;
const CLOSE_NORMAL = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 232 })[0..]; // code: 1000

pub const Conn = struct {
	_closed: bool,
	_io_mode: IOMode,
	_rw_mode: RWMode,
	stream: net.Stream,

	const IOMode = enum {
		blocking,
		nonblocking,
	};

	const RWMode = enum {
		none,
		read,
		write,
	};

	pub fn blocking(self: *Conn) !void {
		// in blockingMode, io_mode is ALWAYS blocking, so we can skip this
		if (comptime lib.blockingMode() == false) {
			if (@atomicRmw(IOMode, &self._io_mode, .Xchg, .blocking, .monotonic) == .nonblock) {
				// we don't care if the above check + this call isn't atomic.
				// at worse, we're doing an unecessary syscall
				_ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
			}
		}
	}

	// TODO: thread safety
	pub fn close(self: *Conn) void {
		self._closed = true;
	}

	pub fn writeBin(self: *Conn, data: []const u8) !void {
		return self.writeFrame(.binary, data);
	}

	pub fn writeText(self: *Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn write(self: *Conn, data: []const u8) !void {
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

	pub fn writeFrame(self: *Conn, op_code: OpCode, data: []const u8) !void {
		const l = data.len;
		const stream = self.stream;

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

	// TODO: SO MUCH
	// (WouldBlock handling, thread safety...)
	pub fn writeFramed(self: Conn, data: []const u8) !void {
		try self.stream.writeAll(data);
	}
};
