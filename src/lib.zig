// This file is only internally referenced.
// Modules don't need to know where all the other modules are, they just need
// to know about this one (which I think works much better for these small libs).

const std = @import("std");
const builtin = @import("builtin");

pub const testing = @import("t.zig");
pub const is_test = builtin.is_test;

pub const Stream = if (is_test) *testing.Stream else std.net.Stream;
pub const NetConn = if (is_test) testing.NetConn else std.net.StreamServer.Connection;

pub const Conn = @import("conn.zig").Conn;
pub const Pool = @import("pool.zig").Pool;
pub const Buffer = @import("buffer.zig").Buffer;
pub const Request = @import("request.zig").Request;
pub const Handshake = @import("handshake.zig").Handshake;
pub const Fragmented = @import("fragmented.zig").Fragmented;

pub const MessageType = enum {
	continuation,
	text,
	binary,
	close,
	ping,
	pong,
	invalid,
};

pub const Message = struct {
	type: MessageType,
	data: []const u8,
};

pub const TEXT_FRAME = 128 | 1;
pub const BIN_FRAME = 128 | 2;
pub const CLOSE_FRAME = 128 | 8;
pub const PING_FRAME = 128 | 9;
pub const PONG_FRAME = 128 | 10;
