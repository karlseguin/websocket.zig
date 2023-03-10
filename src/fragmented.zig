const std = @import("std");
const t = @import("t.zig");
const client = @import("client.zig");

const Allocator = std.mem.Allocator;
const MessageType = client.MessageType;
const Error = client.Error;

pub const Fragmented = struct {
	buf: []u8,
	len: usize,
	type: MessageType,
	allocator: Allocator,

	const Self = @This();

	pub fn init(allocator: Allocator) Self {
		return Self{
			.len = 0,
			.buf = undefined,
			.allocator = allocator,
			.type = MessageType.invalid,
		};
	}

	pub fn is_fragmented(self: Self) bool {
		return self.type != MessageType.invalid;
	}

	pub fn new(self: *Self, message_type: MessageType, value: []const u8) !void {
		const l = value.len;
		self.type = message_type;
		self.buf = try self.allocator.alloc(u8, l);
		std.mem.copy(u8, self.buf, value);
		self.len = l;
	}

	pub fn add(self: *Self, value: []const u8) !bool {
		if (self.type == MessageType.invalid) {
			return false;
		}

		const len = self.len;
		const new_len = len + value.len;

		const buf = try self.allocator.realloc(self.buf, new_len);
		std.mem.copy(u8, buf[len..], value);

		self.buf = buf;
		self.len = new_len;
		return true;
	}

	pub fn reset(self: *Self) void {
		if (self.type == MessageType.invalid) {
			return;
		}
		self.len = 0;
		self.allocator.free(self.buf);
		self.type = MessageType.invalid;
	}

	pub fn deinit(self: *Self) void {
		self.reset();
	}
};

test "fragmented" {
	{
		var f = Fragmented.init(t.allocator);
		defer f.reset();

		try f.new(MessageType.text, "hello");
		try t.expectString(f.buf, "hello");

		try t.expectEqual(f.add(" "), true);
		try t.expectString(f.buf, "hello ");

		try t.expectEqual(f.add("world"), true);
		try t.expectString(f.buf, "hello world");
	}

	{
		var count: usize = 0;
		var data: [100]u8 = undefined;
		var buf = data[0..];
		var r = std.rand.DefaultPrng.init(0);
		var random = r.random();

		var f = Fragmented.init(t.allocator);
		while (count < 5000) : (count += 1) {
			var add_count: usize = 0;
			const number_of_adds = random.uintAtMost(usize, 30) + 1;

			var list = std.ArrayList(u8).init(t.allocator);

			while (add_count < number_of_adds) : (add_count += 1) {
				const c = random.uintAtMost(usize, 99) + 1;
				random.bytes(buf[0..c]);
				if (add_count == 0) {
					try f.new(MessageType.binary, buf[0..c]);
				} else {
					// add to our fragmented
					try t.expectEqual(f.add(buf[0..c]), true);
				}

				// add to our control
				for (buf[0..c]) |b| {
					list.append(b) catch unreachable;
				}
			}
			try t.expectString(list.items, f.buf);
			f.reset();
			list.deinit();
		}
	}
}
