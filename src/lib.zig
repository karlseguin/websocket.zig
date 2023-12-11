// This file is only internally referenced.
// Modules don't need to know where all the other modules are, they just need
// to know about this one (which I think works much better for these small libs).

const std = @import("std");
const builtin = @import("builtin");

pub const testing = @import("t.zig");
pub const buffer = @import("buffer.zig");
pub const framing = @import("framing.zig");
pub const handshake = @import("handshake.zig");
pub const Conn = @import("server.zig").Conn;

pub const is_test = builtin.is_test;

pub const Reader = @import("reader.zig").Reader;

pub const MessageType = enum {
	text,
	binary,
	close,
	ping,
	pong,
};

pub const Message = struct {
	type: MessageType,
	data: []const u8,
};
