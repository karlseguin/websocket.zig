const std = @import("std");
const lib = @import("lib.zig");

const Allocator = std.mem.Allocator;

pub const Buffer = struct {
	data: []u8,
	type: Type,

	const Type = enum{
		static,
		pooled,
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
	pool: *Pool,
	allocator: Allocator,

	// If this is 0, pool is undefined. We need this field here anyways.
	pool_buffer_size: usize,

	pub fn initNoPool(allocator: Allocator) Provider {
		return init(allocator, undefined, 0);
	}

	pub fn init(allocator: Allocator, pool: *Pool, pool_buffer_size: usize) Provider {
		return .{
			.pool = pool,
			.allocator = allocator,
			.pool_buffer_size = pool_buffer_size,
		};
	}

	// should only be called when created via websocket.bufferPool, which exists
	// to make it easier for applications to manage a buffer pool across multiple
	// clients.
	pub fn deinit(self: *Provider) void {
		self.pool.deinit();
		self.allocator.destroy(self.pool);
		self.allocator.destroy(self);
	}

	pub fn static(self: Provider, size: usize) !Buffer {
		return .{
			.type = .static,
			.data = try self.allocator.alloc(u8, size),
		};
	}

	pub fn alloc(self: *Provider, size: usize) !Buffer {
		// remember: if self.pool_buffer_size == 0, then self.pool is undefined.
		if (size < self.pool_buffer_size) {
			if (self.pool.acquire()) |buffer| {
				return buffer;
			}
		}
		return .{
			.type = .dynamic,
			.data = try self.allocator.alloc(u8, size),
		};
	}

	pub fn free(self: *Provider, buffer: Buffer) void {
		switch (buffer.type) {
			.pooled => self.pool.release(buffer),
			.static => self.allocator.free(buffer.data),
			.dynamic => self.allocator.free(buffer.data),
		}
	}

	pub fn release(self: *Provider, buffer: Buffer) void {
		switch (buffer.type) {
			.static => {},
			.pooled => self.pool.release(buffer),
			.dynamic => self.allocator.free(buffer.data),
		}
	}
};

pub const Pool = struct {
	available: usize,
	buffers: []Buffer,
	allocator: Allocator,
	mutex: std.Thread.Mutex,

	pub fn init(allocator: Allocator, count: usize, buffer_size: usize) !Pool {
		const buffers = try allocator.alloc(Buffer, count);

		for (0..count) |i| {
			buffers[i] = .{
				.type = .pooled,
				.data = try allocator.alloc(u8, buffer_size),
			};
		}

		return .{
			.mutex = .{},
			.buffers = buffers,
			.available = count,
			.allocator = allocator,
		};
	}

	pub fn deinit(self: *Pool) void {
		const allocator = self.allocator;
		for (self.buffers) |buf| {
			allocator.free(buf.data);
		}
		allocator.free(self.buffers);
	}

	pub fn acquire(self: *Pool) ?Buffer {
		const buffers = self.buffers;

		self.mutex.lock();
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			self.mutex.unlock();
			return null;
		}
		const index = available - 1;
		const buffer = buffers[index];
		self.available = index;
		self.mutex.unlock();

		return buffer;
	}

	pub fn release(self: *Pool, buffer: Buffer) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		const available = self.available;
		self.buffers[available] = buffer;
		self.available = available + 1;
	}
};

const t = lib.testing;
test "buffer provider: no pool" {
	var p = Provider.initNoPool(t.allocator);

	const buffer = try p.alloc(100);
	defer p.free(buffer);
	try t.expectEqual(.dynamic, buffer.type);
	try t.expectEqual(100, buffer.data.len);
}

test "buffer provider: pool" {
	var pool = try Pool.init(t.allocator, 2, 10);
	defer pool.deinit();

	var p = Provider.init(t.allocator, &pool, 10);

	{
		// bigger than our buffers in pool
		const buffer = try p.alloc(11);
		defer p.free(buffer);
		try t.expectEqual(.dynamic, buffer.type);
		try t.expectEqual(11, buffer.data.len);
	}

	{
		// bigger than our buffers in pool
		const buf1 = try p.alloc(4);
		try t.expectEqual(.pooled, buf1.type);
		try t.expectEqual(10, buf1.data.len);

		const buf2 = try p.alloc(5);
		try t.expectEqual(.pooled, buf2.type);
		try t.expectEqual(10, buf2.data.len);

		try t.expectEqual(false, &buf1.data[0] == &buf2.data[0]);


		// no more buffers in the pool, creats a dynamic buffer
		const buf3 = try p.alloc(6);
		try t.expectEqual(.dynamic, buf3.type);
		try t.expectEqual(6, buf3.data.len);

		p.release(buf1);
		p.release(buf2);
		p.release(buf3);
	}
}

test "buffer provider: static release " {
	var p = Provider.initNoPool(t.allocator);

	const buffer = try p.static(20);
	defer p.free(buffer);

	try t.expectEqual(.static, buffer.type);
	try t.expectEqual(20, buffer.data.len);

	p.release(buffer); // noop for static
	buffer.data[0] = 'a';
}

test "buffer pool" {
	var p = try Pool.init(t.allocator, 2, 10);
	defer p.deinit();

	const buf1a = p.acquire() orelse unreachable;
	try t.expectEqual(.pooled, buf1a.type);
	try t.expectEqual(10, buf1a.data.len);

	const buf2a = p.acquire() orelse unreachable;
	try t.expectEqual(.pooled, buf2a.type);
	try t.expectEqual(10, buf2a.data.len);

	// different buffers
	try t.expectEqual(false, &buf1a.data[0] == &buf2a.data[0]);

	// pool is empty
	try t.expectEqual(null, p.acquire());

	// pool now has a spare buffer
	p.release(buf2a);
	const buf2b = p.acquire() orelse unreachable;

	try t.expectEqual(.pooled, buf2b.type);
	try t.expectEqual(10, buf2b.data.len);
	try t.expectEqual(true, &buf2a.data[0] == &buf2b.data[0]);
}
