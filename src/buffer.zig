const std = @import("std");
const lib = @import("lib.zig");

const Allocator = std.mem.Allocator;

pub const Buffer = struct {
	data: []u8,
	type: Type,

	const Type = enum{
		static,
		dynamic,
	};
};

// Provider manages all buffer access and types. It's where code goes to ask
// for and release buffers. One of the main reasons this exists is to handle
// the case where no Pool is configured, which is the default with client
// connections (unless a Pool is passed in the client config). Our reader
// doesn't really have to deal with that, it just calls provider.acquire()
// and it gets a buffer from somewhere.
pub const Provider = struct {
	allocator: Allocator,

	pub fn init(allocator: Allocator) !*Provider {
		const provider = try allocator.create(Provider);
		provider.* = .{
			.allocator = allocator,
		};
		return provider;
	}

	pub fn deinit(self: *Provider) void {
		self.allocator.destroy(self);
	}

	pub fn static(self: Provider, size: usize) !Buffer {
		return .{
			.type = .static,
			.data = try self.allocator.alloc(u8, size),
		};
	}

	pub fn alloc(self: Provider, size: usize) !Buffer {
		return .{
			.type = .dynamic,
			.data = try self.allocator.alloc(u8, size),
		};
	}

	pub fn free(self: Provider, buffer: Buffer) void {
		self.allocator.free(buffer.data);
	}

	pub fn release(self: Provider, buffer: Buffer) void {
		switch (buffer.type) {
			.static => {},
			.dynamic => self.allocator.free(buffer.data),
		}
	}
};

const t = lib.testing;
test "buffer provider: alloc" {
	var p = try Provider.init(t.allocator);
	defer p.deinit();

	const buffer = try p.alloc(100);
	defer p.free(buffer);
	try t.expectEqual(.dynamic, buffer.type);
	try t.expectEqual(100, buffer.data.len);
}

test "buffer provider: static release " {
	var p = try Provider.init(t.allocator);
	defer p.deinit();

	const buffer = try p.static(20);
	defer p.free(buffer);

	try t.expectEqual(.static, buffer.type);
	try t.expectEqual(20, buffer.data.len);

	p.release(buffer); // noop for static
	buffer.data[0] = 'a';
}
