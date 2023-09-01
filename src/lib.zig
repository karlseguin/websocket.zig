// This file is only internally referenced.
// Modules don't need to know where all the other modules are, they just need
// to know about this one (which I think works much better for these small libs).

const std = @import("std");
const builtin = @import("builtin");

pub const testing = @import("t.zig");
pub const framing = @import("framing.zig");

pub const is_test = builtin.is_test;

pub const Stream = if (is_test) *testing.Stream else std.net.Stream;
pub const NetConn = if (is_test) testing.NetConn else std.net.StreamServer.Connection;

pub const Reader = @import("reader.zig").Reader;
pub const Handshake = @import("handshake.zig").Handshake;

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
