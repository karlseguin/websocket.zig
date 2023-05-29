const std = @import("std");
const t = @import("t.zig");
const KeyValue = @import("key_value.zig").KeyValue;

const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

// This is what we're pooling
const HandshakeState = struct {
	// a buffer to read data into
	buffer: []u8,

	// Headers
	headers: KeyValue,

	fn init(allocator: Allocator, buffer_size: usize, max_headers: usize) !*HandshakeState {
		const hs = try allocator.create(HandshakeState);
		hs.* = .{
			.buffer = try allocator.alloc(u8, buffer_size),
			.headers = try KeyValue.init(allocator, max_headers),
		};
		return hs;
	}

	fn deinit(self: *HandshakeState, allocator: Allocator) void {
		allocator.free(self.buffer);
		self.headers.deinit(allocator);
		allocator.destroy(self);
	}

	fn reset(self: *HandshakeState) void {
		self.headers.reset();
	}
};

pub const Pool = struct {
	mutex: Mutex,
	available: usize,
	allocator: Allocator,
	buffer_size: usize,
	max_headers: usize,
	states: []*HandshakeState,

	pub fn init(allocator: Allocator, count: usize, buffer_size: usize, max_headers: usize) !Pool {
		const states = try allocator.alloc(*HandshakeState, count);

		for (0..count) |i| {
			states[i] = try HandshakeState.init(allocator, buffer_size, max_headers);
		}

		return .{
			.mutex = Mutex{},
			.states = states,
			.allocator = allocator,
			.available = count,
			.max_headers = max_headers,
			.buffer_size = buffer_size,
		};
	}

	pub fn deinit(self: *Pool) void {
		const allocator = self.allocator;
		for (self.states) |s| {
			s.deinit(allocator);
		}
		allocator.free(self.states);
	}

	pub fn acquire(self: *Pool) !*HandshakeState {
		self.mutex.lock();

		const states = self.states;
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			self.mutex.unlock();
			return try HandshakeState.init(self.allocator, self.buffer_size, self.max_headers);
		}
		const index = available - 1;
		const state = states[index];
		self.available = index;
		self.mutex.unlock();
		return state;
	}

	pub fn release(self: *Pool, state: *HandshakeState) void {
		state.reset();

		self.mutex.lock();

		var states = self.states;
		const available = self.available;
		if (available == states.len) {
			self.mutex.unlock();
			state.deinit(self.allocator);
			return;
		}
		states[available] = state;
		self.available = available + 1;
		self.mutex.unlock();
	}
};

test "pool: acquire and release" {
	// not 100% sure this is testing exactly what I want, but it's ....something ?
	var p = try Pool.init(t.allocator, 2, 10, 3);
	defer p.deinit();

	var hs1a = p.acquire() catch unreachable;
	var hs2a = p.acquire() catch unreachable;
	var hs3a = p.acquire() catch unreachable; // this should be dynamically generated

	try t.expectEqual(false, &hs1a.buffer[0] == &hs2a.buffer[0]);
	try t.expectEqual(false, &hs2a.buffer[0] == &hs3a.buffer[0]);
	try t.expectEqual(@as(usize, 10), hs1a.buffer.len);
	try t.expectEqual(@as(usize, 10), hs2a.buffer.len);
	try t.expectEqual(@as(usize, 10), hs3a.buffer.len);
	try t.expectEqual(@as(usize, 0), hs1a.headers.len);
	try t.expectEqual(@as(usize, 0), hs2a.headers.len);
	try t.expectEqual(@as(usize, 0), hs3a.headers.len);
	try t.expectEqual(@as(usize, 3), hs1a.headers.keys.len);
	try t.expectEqual(@as(usize, 3), hs2a.headers.keys.len);
	try t.expectEqual(@as(usize, 3), hs3a.headers.keys.len);

	p.release(hs1a);

	var hs1b = p.acquire() catch unreachable;
	try t.expectEqual(true, &hs1a.buffer[0] == &hs1b.buffer[0]);

	p.release(hs3a);
	p.release(hs2a);
	p.release(hs1b);
}

test "pool: threadsafety" {
	var p = try Pool.init(t.allocator, 4, 10, 2);
	defer p.deinit();

	for (p.states) |hs| {
		hs.buffer[0] = 0;
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
		var hs = p.acquire() catch unreachable;
		std.debug.assert(hs.buffer[0] == 0);
		hs.buffer[0] = 255;
		std.time.sleep(random.uintAtMost(u32, 100000));
		hs.buffer[0] = 0;
		p.release(hs);
	}
}
