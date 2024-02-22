const std = @import("std");
const lib = @import("lib.zig");

const buffer = lib.buffer;

const Allocator = std.mem.Allocator;
const MessageType = lib.MessageType;

pub const Fragmented = struct {
	type: MessageType,
	max_size: usize,
	buf: std.ArrayList(u8),

	pub fn init(bp: *buffer.Provider, max_size: usize, message_type: MessageType, value: []const u8) !Fragmented {
		var buf = std.ArrayList(u8).init(bp.allocator);
		try buf.ensureTotalCapacity(value.len * 2);
		buf.appendSliceAssumeCapacity(value);

		return .{
			.buf = buf,
			.max_size = max_size,
			.type = message_type,
		};
	}

	pub fn deinit(self: Fragmented) void {
		self.buf.deinit();
	}

	pub fn add(self: *Fragmented, value: []const u8) !void {
		if (self.buf.items.len + value.len > self.max_size) {
			return error.TooLarge;
		}
		try self.buf.appendSlice(value);
	}

	// Optimization so that we don't over-allocate on our last frame.
	pub fn last(self: *Fragmented, value: []const u8) ![]u8 {
		const total_len = self.buf.items.len + value.len;
		if (total_len > self.max_size) {
			return error.TooLarge;
		}
		try self.buf.ensureTotalCapacityPrecise(total_len);
		self.buf.appendSliceAssumeCapacity(value);
		return self.buf.items;
	}
};

const t = lib.testing;
test "fragmented" {
	var bp = buffer.Provider.initNoPool(t.allocator);

	{
		var f = try Fragmented.init(&bp, 500, .text, "hello");
		defer f.deinit();

		try t.expectString("hello", f.buf.items);

		try f.add(" ");
		try t.expectString("hello ", f.buf.items);

		try f.add("world");
		try t.expectString("hello world", f.buf.items);
	}

	{
		var f = try Fragmented.init(&bp, 10, .text, "hello");
		defer f.deinit();
		try f.add(" ");
		try t.expectError(error.TooLarge, f.add("world"));
	}

	{
		var r = std.rand.DefaultPrng.init(0);
		var random = r.random();

		var count: usize = 0;
		var buf: [100]u8 = undefined;
		while (count < 1000) : (count += 1) {
			var payload = buf[0..random.uintAtMost(usize, 99) + 1];
			random.bytes(payload);

			var f = try Fragmented.init(&bp, 5000, .binary, payload);
			defer f.deinit();

			var expected = std.ArrayList(u8).init(t.allocator);
			defer expected.deinit();
			try expected.appendSlice(payload);

			const number_of_adds = random.uintAtMost(usize, 30);
			for (0..number_of_adds) |_| {
				payload = buf[0..random.uintAtMost(usize, 99) + 1];
				random.bytes(payload);
				try f.add(payload);
				try expected.appendSlice(payload);
			}
			payload = buf[0..random.uintAtMost(usize, 99) + 1];
			random.bytes(payload);
			try expected.appendSlice(payload);

			try t.expectString(expected.items, try f.last(payload));
		}
	}
}
