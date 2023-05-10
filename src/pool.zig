const std = @import("std");
const t = @import("t.zig");

const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

pub const Pool = struct {
	mutex: Mutex,
	buffers: [][] u8,
	available: usize,
	allocator: Allocator,
	buffer_size: usize,

	pub fn init(allocator: Allocator, buffer_count: usize, buffer_size: usize) !Pool {
		const buffers = try allocator.alloc([]u8, buffer_count);

		for (0..buffer_count) |i| {
			buffers[i] = try allocator.alloc(u8, buffer_size);
		}

		return .{
			.mutex = Mutex{},
			.buffers = buffers,
			.allocator = allocator,
			.available = buffer_count,
			.buffer_size = buffer_size,
		};
	}

	pub fn deinit(self: *Pool) void {
		const allocator = self.allocator;
		for (self.buffers) |b| {
			allocator.free(b);
		}
		allocator.free(self.buffers);
	}

	pub fn acquire(self: *Pool) ![]u8 {
		self.mutex.lock();

		const buffers = self.buffers;
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			self.mutex.unlock();
			return self.allocator.alloc(u8, self.buffer_size);
		}
		const index = available - 1;
		const buffer = buffers[index];
		self.available = index;
		self.mutex.unlock();
		return buffer;
	}

	pub fn release(self: *Pool, buffer: []u8) void {
		self.mutex.lock();

		var buffers = self.buffers;
		const available = self.available;
		if (available == buffers.len) {
			self.mutex.unlock();
			self.allocator.free(buffer);
			return;
		}
		buffers[available] = buffer;
		self.available = available + 1;
		self.mutex.unlock();
	}
};

test "pool: acquire and release" {
	// not 100% sure this is testing exactly what I want, but it's ....something ?
	var p = try Pool.init(t.allocator, 2, 10);
	defer p.deinit();

	var b1a = p.acquire() catch unreachable;
	var b2a = p.acquire() catch unreachable;
	var b3a = p.acquire() catch unreachable; // this should be dynamically generated

	try t.expectEqual(false, &b1a[0] == &b2a[0]);
	try t.expectEqual(false, &b2a[0] == &b3a[0]);
	try t.expectEqual(@as(usize, 10), b1a.len);
	try t.expectEqual(@as(usize, 10), b2a.len);
	try t.expectEqual(@as(usize, 10), b3a.len);

	p.release(b1a);

	var b1b = p.acquire() catch unreachable;
	try t.expectEqual(true, &b1a[0] == &b1b[0]);

	p.release(b3a);
	p.release(b2a);
	p.release(b1b);
}


test "pool: threadsafety" {
	var p = try Pool.init(t.allocator, 4, 10);
	defer p.deinit();

	for (p.buffers) |b| {
		b[0] = 0;
	}

	const t1 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t2 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t3 = try std.Thread.spawn(.{}, testPool, .{&p});
	const t4 = try std.Thread.spawn(.{}, testPool, .{&p});

	t1.join(); t2.join(); t3.join(); t4.join();
}

fn testPool(p: *Pool) void {
	var r = t.getRandom();
	const random = r.random();

	for (0..5000) |_| {
		var buf = p.acquire() catch unreachable;
		std.debug.assert(buf[0] == 0);
		buf[0] = 255;
		std.time.sleep(random.uintAtMost(u32, 100000));
		buf[0] = 0;
		p.release(buf);
	}
}
