// This file is only internally referenced.
// Modules don't need to know where all the other modules are, they just need
// to know about this one (which I think works much better for these small libs).

const std = @import("std");
const builtin = @import("builtin");

pub const testing = @import("t.zig");
pub const buffer = @import("buffer.zig");
pub const framing = @import("framing.zig");
pub const Conn = @import("conn.zig").Conn;
pub const Reader = @import("reader.zig").Reader;
pub const Handshake = @import("handshake.zig").Handshake;

pub const is_test = builtin.is_test;

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

const force_blocking: bool = blk: {
	const build = @import("build");
	if (@hasDecl(build, "force_blocking")) {
		break :blk  build.force_blocking;
	}
	break :blk false;
};

pub fn blockingMode() bool {
	return true;
	// if (force_blocking) {
	// 	return true;
	// }
	// return switch (builtin.os.tag) {
	// 	.linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => false,
	// 	else => true,
	// };
}
