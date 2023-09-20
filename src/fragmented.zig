const std = @import("std");
const lib = @import("lib.zig");

const Allocator = std.mem.Allocator;
const MessageType = lib.MessageType;

pub const Fragmented = struct {
	buf: []u8,
	len: usize,
	allocator: Allocator,
	type: ?MessageType,

	pub fn init(allocator: Allocator) Fragmented {
		return .{
			.len = 0,
			.type = null,
			.buf = undefined,
			.allocator = allocator,
		};
	}

	pub fn isFragmented(self: Fragmented) bool {
		return self.type != null;
	}

	pub fn new(self: *Fragmented, message_type: MessageType, value: []const u8) !void {
		const l = value.len;
		self.type = message_type;
		self.buf = try self.allocator.dupe(u8, value);
		self.len = l;
	}

	pub fn add(self: *Fragmented, value: []const u8) !bool {
		if (self.type == null) {
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

	pub fn reset(self: *Fragmented) void {
		if (self.type == null) {
			return;
		}
		self.len = 0;
		self.allocator.free(self.buf);
		self.type = null;
	}

	pub fn deinit(self: *Fragmented) void {
		self.reset();
	}
};

const t = lib.testing;
test "fragmented" {
	{
		var f = Fragmented.init(t.allocator);
		defer f.reset();

		try f.new(MessageType.text, "hello");
		try t.expectString("hello", f.buf);

		try t.expectEqual(true, f.add(" "));
		try t.expectString(f.buf, "hello ");

		try t.expectEqual(true, f.add("world"));
		try t.expectString("hello world", f.buf);
	}

	{
		var count: usize = 0;
		var data: [100]u8 = undefined;
		var buf = data[0..];
		var r = std.rand.DefaultPrng.init(0);
		var random = r.random();

		var f = Fragmented.init(t.allocator);
		while (count < 1000) : (count += 1) {
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
					try t.expectEqual(true, f.add(buf[0..c]));
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
