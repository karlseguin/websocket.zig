const std = @import("std");
const lib = @import("lib.zig");

const buffer = lib.buffer;

const Allocator = std.mem.Allocator;
const MessageType = lib.MessageType;

pub const Fragmented = struct {
	type: MessageType,
	buf: std.ArrayList(u8),

	pub fn init(bp: *buffer.Provider, message_type: MessageType, value: []const u8) !Fragmented {
		var buf = std.ArrayList(u8).init(bp.allocator);
		try buf.ensureTotalCapacity(value.len * 2);
		buf.appendSliceAssumeCapacity(value);

		return .{
			.buf = buf,
			.type = message_type,
		};
	}

	pub fn deinit(self: Fragmented) void {
		self.buf.deinit();
	}

	pub fn add(self: *Fragmented, value: []const u8) !void {
		try self.buf.appendSlice(value);
	}
};

const t = lib.testing;
test "fragmented" {
	var bp = buffer.Provider.initNoPool(t.allocator);

	{
		var f = try Fragmented.init(&bp, .text, "hello");
		defer f.deinit();

		try t.expectString("hello", f.buf.items);

		try f.add(" ");
		try t.expectString("hello ", f.buf.items);

		try f.add("world");
		try t.expectString("hello world", f.buf.items);
	}

	{
		var r = std.rand.DefaultPrng.init(0);
		var random = r.random();

		var count: usize = 0;
		var buf: [100]u8 = undefined;
		while (count < 1000) : (count += 1) {

			var payload = buf[0..random.uintAtMost(usize, 99) + 1];
			random.bytes(payload);

			var f = try Fragmented.init(&bp, .binary, payload);
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
			try t.expectString(expected.items, f.buf.items);
		}
	}
}
