const std = @import("std");
const lib = @import("lib.zig");
const t = lib.testing;

pub fn init() *Testing {
	var stream = t.allocator.create(t.Stream) catch unreachable;
	stream.* = t.Stream.init();

	var testing = t.allocator.create(Testing) catch unreachable;

	testing.* = .{
		.read_index = 0,
		.stream = stream,
		.received = null,
		.conn = lib.Conn{
			.closed = false,
			.stream = stream,
		},
	};

	return testing;
}

pub const Testing = struct {
	stream: *t.Stream,
	conn: lib.Conn,
	received: ?t.Received,
	read_index: usize,

	pub fn deinit(self: *Testing) void {
		self.stream.deinit();
		t.allocator.destroy(self.stream);
		if (self.received) |r| {
			r.deinit();
		}

		t.allocator.destroy(self);
	}

	pub fn textMessage(_: Testing, data: []const u8) lib.Message {
		return .{
			.data = data,
			.type = .text,
		};
	}

	pub fn expectText(self: *Testing, expected: []const u8) !void {
		self.ensureReceived();
		const read_index = self.read_index;
		const messages = self.received.?.messages;

		if (read_index == messages.len) {
			std.debug.print("\nNo messages received", .{});
			return error.NoMessages;
		}

		self.read_index = read_index + 1;

		const msg = messages[read_index];
		try t.expectEqual(@as(lib.MessageType, .text), msg.type);
		try t.expectString(expected, msg.data);
	}

	fn ensureReceived(self: *Testing) void {
		if (self.received == null) {
			self.received = self.stream.asReceived(false);
		}
	}
};
