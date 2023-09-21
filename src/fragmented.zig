const std = @import("std");
const lib = @import("lib.zig");

const Buffer = lib.buffer.Buffer;
const Allocator = std.mem.Allocator;
const MessageType = lib.MessageType;

pub const Fragmented = struct {
	buf: []u8,
	len: usize,
	type: MessageType,
	allocator: Allocator,

	pub fn init(allocator: Allocator, message_type: MessageType, value: []const u8) !Fragmented {
		return .{
			.len = value.len,
			.type = message_type,
			.allocator = allocator,
			.buf = try allocator.dupe(u8, value),
		};
	}

	pub fn deinit(self: Fragmented) void {
		self.allocator.free(self.buf);
	}

	pub fn add(self: *Fragmented, value: []const u8) !void {
		const len = self.len;
		const new_len = len + value.len;

		const buf = try self.allocator.realloc(self.buf, new_len);
		std.mem.copy(u8, buf[len..], value);

		self.buf = buf;
		self.len = new_len;
	}
};

const t = lib.testing;
test "fragmented" {
	{
		var f = try Fragmented.init(t.allocator, .text, "hello");
		defer f.deinit();

		try t.expectString("hello", f.buf);

		try f.add(" ");
		try t.expectString(f.buf, "hello ");

		try f.add("world");
		try t.expectString("hello world", f.buf);
	}

	{
		var r = std.rand.DefaultPrng.init(0);
		var random = r.random();

		var count: usize = 0;
		var buf: [100]u8 = undefined;
		while (count < 1000) : (count += 1) {

			var payload = buf[0..random.uintAtMost(usize, 99) + 1];
			random.bytes(payload);

			var f = try Fragmented.init(t.allocator, .binary, payload);
			defer f.deinit();

			var expected = std.ArrayList(u8).init(t.allocator);
			defer expected.deinit();
			try expected.appendSlice(payload);

			var add_count: usize = 0;
			const number_of_adds = random.uintAtMost(usize, 30);
			while (add_count < number_of_adds) : (add_count += 1) {
				payload = buf[0..random.uintAtMost(usize, 99) + 1];
				random.bytes(payload);
				try f.add(payload);
				try expected.appendSlice(payload);
			}
			try t.expectString(expected.items, f.buf);
		}
	}
}
