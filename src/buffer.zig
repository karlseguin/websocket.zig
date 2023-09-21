const std = @import("std");

const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

const BufferType = enum {
	pooled,
	static,
	dynamic,
};

pub fn static(allocator: Allocator, size: usize) !Buffer {
	return .{
		.type = .static,
		.buffer = try allocator.alloc(u8, size),
	};
}

pub fn dynamic(allocator: Allocator, size: usize) !Buffer {
	return .{
		.type = .dynamic,
		.buffer = try allocator.alloc(u8, size),
	};
}

pub const Buffer = struct {
	buffer: []u8,
	type: BufferType,

	pub fn release(self: Buffer, allocator: Allocator) bool {
		switch (self.type) {
			.static => return false,
			.dynamic => {
				allocator.free(self.buffer);
				return true;
			},
			.pooled => unreachable,
		}
	}
};

pub const Pool = struct {
	mutex: Mutex,
	available: usize,
	allocator: Allocator,
	buffer_size: usize,
	buffers: []Buffer,

	pub fn init(allocator: Allocator, count: usize, buffer_size: usize) !Pool {
		const buffers = try allocator.alloc(Buffer, count);

		for (0..count) |i| {
			buffers[i] = .{
				.type = .pooled,
				.buffer = try allocator.alloc(u8, buffer_size),
			};
		}

		return .{
			.mutex = Mutex{},
			.buffers = buffers,
			.available = count,
			.allocator = allocator,
		};
	}

	pub fn deinit(self: *Pool) void {
		const allocator = self.allocator;
		for (self.buffers) |buf| {
			allocator.free(buf.buffer);
		}
		allocator.free(self.buffers);
	}

	// The caller must make sure that size <= the configured buffer_size.
	// If the pool is depleted, a buffer of exactly size will be created and
	// returned as type = .dynamic.
	pub fn acquire(self: *Pool, size: usize) !Buffer {
		const buffers = self.buffers;

		self.mutex.lock();
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			self.mutex.unlock();
			return dynamic(self.allocator, size);
		}
		const index = available - 1;
		const buffer = buffers[index];
		self.available = index;
		self.mutex.unlock();

		return buffer;
	}

	pub fn release(self: *Pool, buffer: Buffer) void {
		std.debug.assert(buffer.type == .pooled);
		self.mutex.lock();
		defer self.mutex.unlock();
		const available = self.available;
		self.buffers[available] = buffer;
		self.available = available + 1;
	}
};
