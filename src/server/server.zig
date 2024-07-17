const std = @import("std");
const builtin = @import("builtin");
const proto = @import("../proto.zig");
const buffer = @import("../buffer.zig");

const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const log = std.log.scoped(.websocket);

const OpCode = proto.OpCode;
const Reader = proto.Reader;
const Message = proto.Message;
const Handshake = @import("handshake.zig").Handshake;
const FallbackAllocator = @import("fallback_allocator.zig").FallbackAllocator;

const MAX_TIMEOUT = 2_147_483_647;
const DEFAULT_WORKER_COUNT = 1;
const DEFAULT_MAX_HANDSHAKE_SIZE = 1024;

const EMPTY_PONG = ([2]u8{ @intFromEnum(OpCode.pong), 0 })[0..];
// CLOSE, 2 length, code
const CLOSE_NORMAL = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 234 })[0..]; //code: 1002

const force_blocking: bool = blk: {
	const build = @import("build");
	if (@hasDecl(build, "force_blocking")) {
		break :blk  build.force_blocking;
	}
	break :blk false;
};

pub fn blockingMode() bool {
	if (force_blocking) {
		return true;
	}
	return switch (builtin.os.tag) {
		.linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => false,
		else => true,
	};
}

pub const Config = struct {
	port: ?u16 = null,
	address: []const u8 = "127.0.0.1",
	unix_path: ?[]const u8 = null,

	worker_count: ?u8 = null,

	max_conn: usize = 16_384,
	max_message_size: usize = 65_536,
	connection_buffer_size: usize = 4_096,

	handshake: Config.Handshake = .{},
	shutdown: Shutdown = .{},
	thread_pool: ThreadPool = .{},
	large_buffers: Config.LargeBuffers = .{},

	pub const ThreadPool = struct {
		count: ?u16 = null,
		backlog: ?u32 = null,
		buffer_size: ?usize = null,
	};

	const Shutdown = struct {
		notify_client: bool = true,
		notify_handler: bool = true,
	};

	const Handshake = struct {
		timeout: u32 = 10,
		max_size: ?u16 = null,
		max_headers: ?u16 = null,
		pool_count: ?u16 = null,
	};

	const LargeBuffers = struct {
		count: ?u16 = null,
		size: ?usize = null,
	};
};

pub fn Server(comptime H: type) type {
	return struct {
		config: Config,
		allocator: Allocator,

		// used to synchornize staring the server and stopping the server
		run_mut: Thread.Mutex,
		run_cond: Thread.Condition,

		// used to synchronize listenInNewThread so that it only returns once
		// the server has actually started.
		launch_mut: Thread.Mutex,
		launch_cond: Thread.Condition,

		// these aren't used by the server themselves, but both Blocking and NonBlocking
		// workers need them, so we put them here, and reference them in the workers,
		// to avoid the duplicate code.
		handshake_pool: Handshake.Pool,
		buffer_provider: buffer.Provider,

		const Self = @This();

		pub fn init(allocator: Allocator, config: Config) !Self {
			var handshake_pool = try Handshake.Pool.init(allocator, config.handshake.pool_count orelse 32, config.handshake.max_size orelse 1024, config.handshake.max_headers orelse 10);
			errdefer handshake_pool.deinit();

			var buffer_provider = try buffer.Provider.init(allocator, .{
				.max = config.max_message_size,
				.count = config.large_buffers.count orelse 8,
				.size = config.large_buffers.size orelse @min(config.connection_buffer_size * 2, config.max_message_size),
			});
			errdefer buffer_provider.deinit();

			return .{
				.handshake_pool = handshake_pool,
				.buffer_provider = buffer_provider,
				.run_mut = .{},
				.run_cond = .{},
				.launch_mut = .{},
				.launch_cond = .{},
				.config = config,
				.allocator = allocator,
			};
		}

		pub fn deinit(self: *Self) void {
			self.handshake_pool.deinit();
			self.buffer_provider.deinit();
		}

		pub fn listenInNewThread(self: *Self, context: anytype) !Thread {
			self.launch_mut.lock();
			defer self.launch_mut.unlock();
			const thrd = try Thread.spawn(.{}, Self.listen, .{self, context});
			// this mess helps to minimze the window between this function
			self.launch_cond.wait(&self.launch_mut);
			return thrd;
		}

		pub fn listen(self: *Self, context: anytype) !void {
			self.run_mut.lock();
			errdefer self.run_mut.unlock();

			const config = &self.config;

			var no_delay = true;
			const address = blk: {
				if (config.unix_path) |unix_path| {
					if (comptime builtin.os.tag == .windows) {
						return error.UnixPathNotSupported;
					}
					no_delay = false;
					std.fs.deleteFileAbsolute(unix_path) catch {};
					break :blk try net.Address.initUnix(unix_path);
				} else {
					const listen_port = config.port.?;
					const listen_address = config.address;
					break :blk try net.Address.parseIp(listen_address, listen_port);
				}
			};

			const socket = blk: {
				var sock_flags: u32 = posix.SOCK.STREAM | posix.SOCK.CLOEXEC;
				if (blockingMode() == false) sock_flags |= posix.SOCK.NONBLOCK;

				const socket_proto = if (address.any.family == posix.AF.UNIX) @as(u32, 0) else posix.IPPROTO.TCP;
				break :blk try posix.socket(address.any.family, sock_flags, socket_proto);
			};

			if (no_delay) {
					// TODO: Broken on darwin:
					// https://github.com/ziglang/zig/issues/17260
					// if (@hasDecl(os.TCP, "NODELAY")) {
					//  try os.setsockopt(socket.sockfd.?, os.IPPROTO.TCP, os.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1)));
					// }
					try posix.setsockopt(socket, posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1)));
			}

			if (@hasDecl(posix.SO, "REUSEPORT_LB")) {
					try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
			} else if (@hasDecl(posix.SO, "REUSEPORT")) {
					try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
			} else {
					try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
			}

			{
				const socklen = address.getOsSockLen();
				try posix.bind(socket, &address.any, socklen);
				try posix.listen(socket, 1024); // kernel backlog
			}

			if (comptime blockingMode()) {
				errdefer posix.close(socket);
				var w = try Blocking(H).init(self);
				defer w.deinit();

				const thrd = try std.Thread.spawn(.{}, Blocking(H).run, .{&w, socket, context});
				log.info("starting blocking worker to listen on {}", .{address});
				self.launch_cond.signal();

				self.run_cond.wait(&self.run_mut);
				w.stop();
				posix.close(socket);
				thrd.join();
			} else {
				defer posix.close(socket);
				const C = @TypeOf(context);
				const Worker = NonBlocking(H, C);

				const allocator = self.allocator;
				const worker_count = config.worker_count orelse 1;

				const signals = try allocator.alloc([2]posix.fd_t, worker_count);
				const threads = try allocator.alloc(Thread, worker_count);
				const workers = try allocator.alloc(Worker, worker_count);

				var started: usize = 0;

				defer {
					for (0..started) |i| {
						posix.close(signals[i][1]);
						threads[i].join();
						workers[i].deinit();
					}
					allocator.free(signals);
					allocator.free(threads);
					allocator.free(workers);
				}

				for (0..worker_count) |i| {
					signals[i] = try posix.pipe2(.{.NONBLOCK = true});
					errdefer posix.close(signals[i][1]);

					workers[i] = try Worker.init(self, context);
					errdefer workers[i].deinit();

					threads[i] = try Thread.spawn(.{}, Worker.run, .{ &workers[i], socket, signals[i][0] });
					started += 1;
				}

				log.info("starting nonblocking worker to listen on {}", .{address});
				self.launch_cond.signal();

				// is this really the best way?
				self.run_cond.wait(&self.run_mut);
			}
		}

		pub fn stop(self: *Self) void {
			self.run_mut.lock();
			defer self.run_mut.unlock();
			self.run_cond.signal();
		}
	};
}

// This is our Blocking worker. It's very different than NonBlocking and much simpler.
fn Blocking(comptime H: type) type {
	return struct {
		running: bool,
		allocator: Allocator,
		config: *const Config,
		handshake_timeout: Timeout,
		handshake_pool: *Handshake.Pool,
		buffer_provider: *buffer.Provider,
		conn_manager: ConnManager(H),

		const Timeout = struct {
			sec: u32,
			timeval: [@sizeOf(std.posix.timeval)]u8,

			// if sec is null, it means we want to cancel the timeout.
			fn init(sec: u32) Timeout {
				return .{
					.sec = sec,
					.timeval = std.mem.toBytes(posix.timeval{ .tv_sec = @intCast(sec), .tv_usec = 0 }),
				};
			}

			pub const none = std.mem.toBytes(posix.timeval{.tv_sec = 0, .tv_usec = 0});
		};

		const Self = @This();

		pub fn init(server: *Server(H)) !Self {
			const config = &server.config;
			const allocator = server.allocator;

			var conn_manager = try ConnManager(H).init(allocator, &server.handshake_pool);
			errdefer conn_manager.deinit();

			return .{
				.running = true,
				.config = config,
				.conn_manager = conn_manager,
				.allocator = allocator,
				.handshake_pool = &server.handshake_pool,
				.buffer_provider = &server.buffer_provider,
				.handshake_timeout = Timeout.init(config.handshake.timeout),
			};
		}

		pub fn deinit(self: *Self) void {
			self.conn_manager.deinit();
		}

		pub fn stop(self: *Self) void {
			@atomicStore(bool, &self.running, false, .monotonic);
		}

		pub fn run(self: *Self, listener: posix.socket_t, context: anytype) void {
			while (true) {
				var address: net.Address = undefined;
				var address_len: posix.socklen_t = @sizeOf(net.Address);
				const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
					if (@atomicLoad(bool, &self.running, .monotonic) == false) {
						break;
					}
					log.err("failed to accept socket: {}", .{err});
					continue;
				};
				log.debug("({}) connected", .{address});

				const thread = std.Thread.spawn(.{}, Self.handleConnection, .{self, socket, address, context}) catch |err| {
					posix.close(socket);
					log.err("({}) failed to spawn connection thread: {}", .{address, err});
					continue;
				};
				thread.detach();
			}

			self.conn_manager.closeAll(self.config.shutdown);

			// wait up to 1 second for every connection to cleanly shutdown
			var i: usize = 0;
			while (i < 10) : (i += 1) {
				if (self.conn_manager.count() == 0) {
					break;
				}
				std.time.sleep(std.time.ns_per_ms * 100);
			}
		}

		// Called in a thread started above in listen.
		// Wrapper around _handleConnection so that we can handle erros
		fn handleConnection(self: *Self, socket: posix.socket_t, address: net.Address, context: anytype) void {
			self._handleConnection(socket, address, context) catch |err| {
				log.err("({}) uncaught error in connection handler: {}", .{address, err});
			};
		}

		fn _handleConnection(self: *Self, socket: posix.socket_t, address: net.Address, context: anytype) !void {
			const conn_manager = &self.conn_manager;
			const hc = try conn_manager.create(socket, address, timestamp());

			defer {
				hc.conn.close();
				conn_manager.cleanup(hc);
			}
			const timeout = self.handshake_timeout;
			const deadline = timestamp() + timeout.sec;
			try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout.timeval);

			while (true) {
				if (handleHandshake(H, self, hc, context) == false) {
					return;
				}
				if (hc.handler != null) {
					// if we have a handler, the our handshake completed
					break;
				}
				if (timestamp() > deadline) {
					return;
				}
			}
			try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &Timeout.none);

			while (true) {
				if (handleIncoming(H, hc, self.allocator, undefined) == false) {
					break;
				}
			}
		}
	};
}

fn NonBlocking(comptime H: type, comptime C: type) type {
	return struct {
		ctx: C,
		// KQueue or Epoll, depending on the platform
		loop: Loop,
		allocator: Allocator,
		config: *const Config,

		thread_pool: *ThreadPool,
		handshake_pool: *Handshake.Pool,
		buffer_provider: *buffer.Provider,

		max_conn: usize,
		conn_manager: ConnManager(H),

		const Self = @This();
		const ThreadPool = @import("thread_pool.zig").ThreadPool(Self.dataAvailable);

		const Loop = switch (@import("builtin").os.tag) {
			.macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue,
			.linux => EPoll,
			else => unreachable,
		};

		pub fn init(server: *Server(H), ctx: C) !Self {
			const config = &server.config;
			const allocator = server.allocator;

			const loop = try Loop.init();
			errdefer loop.deinit();

			var conn_manager = try ConnManager(H).init(allocator, &server.handshake_pool);
			errdefer conn_manager.deinit();

			var thread_pool = try ThreadPool.init(allocator, .{
				.count = config.thread_pool.count orelse 4,
				.backlog = config.thread_pool.backlog orelse 500,
				.buffer_size = config.thread_pool.buffer_size orelse 32_768,
			});
			errdefer thread_pool.deinit();

			return .{
				.ctx = ctx,
				.loop = loop,
				.config = config,
				.thread_pool = thread_pool,
				.handshake_pool = &server.handshake_pool,
				.buffer_provider = &server.buffer_provider,
				.allocator = allocator,
				.max_conn = config.max_conn,
				.conn_manager = conn_manager,
			};
		}

		pub fn deinit(self: *Self) void {
			self.conn_manager.deinit();
			self.loop.deinit();
			self.thread_pool.deinit();
		}

		pub fn run(self: *Self, listener: posix.socket_t, signal_read: posix.fd_t) void {
			self.loop.monitorAccept(listener) catch |err| {
				log.err("failed to add monitor to listening socket: {}", .{err});
				return;
			};

			self.loop.monitorSignal(signal_read) catch |err| {
				log.err("failed to add monitor to signal pipe: {}", .{err});
				return;
			};

			const thread_pool = self.thread_pool;
			const conn_manager = &self.conn_manager;
			const handshake_timeout = self.config.handshake.timeout;

			var now = timestamp();
			var oldest_pending_start_time: ?u32 = null;
			while (true) {
				const handshake_cutoff = now - handshake_timeout;
				const timeout = conn_manager.prepareToWait(handshake_cutoff) orelse blk: {
					if (oldest_pending_start_time) |started| {
						break :blk if (started < handshake_cutoff) 1 else @as(i32, @intCast(started - handshake_cutoff));
					}
					break :blk null;
				};

				var it = self.loop.wait(timeout) catch |err| {
					log.err("failed to wait on events: {}", .{err});
					std.time.sleep(std.time.ns_per_s);
					continue;
				};
				now = timestamp();
				oldest_pending_start_time = null;

				while (it.next()) |data| {
					if (data == 0) {
						self.accept(listener, now) catch |err| {
							log.err("accept error: {}", .{err});
							std.time.sleep(std.time.ns_per_ms);
						};
						continue;
					}

					if (data == 1) {
						log.info("received shutdown signal", .{});
						self.thread_pool.stop();
						conn_manager.closeAll(self.config.shutdown);
						// only thing signal is currently used for is to indicating a
						// shutdown
						// signal was closed, we're being told to shutdown
						return;
					}

					const hc: *HandlerConn(H) = @ptrFromInt(data);
					if (hc.state == .handshake) {
						// we need to get this out of the pending list, so that it doesn't
						// cause a timeout while we're processing it.
						// But we stll need to care about its timeout.
						if (oldest_pending_start_time) |s| {
							oldest_pending_start_time = @min(hc.conn.started, s);
						} else {
							oldest_pending_start_time = hc.conn.started;
						}
						self.conn_manager.activate(hc);
					}

					thread_pool.spawn(.{self, hc});
				}
			}
		}

		fn accept(self: *Self, listener: posix.fd_t, now: u32) !void {
			const max_conn = self.max_conn;
			const conn_manager = &self.conn_manager;

			while (conn_manager.count() < max_conn) {
				var address: net.Address = undefined;
				var address_len: posix.socklen_t = @sizeOf(net.Address);

				const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
					// When available, we use SO_REUSEPORT_LB or SO_REUSEPORT, so WouldBlock
					// should not be possible in those cases, but if it isn't available
					// this error should be ignored as it means another thread picked it up.
					return if (err == error.WouldBlock) {} else err;
				};

				log.debug("({}) connected", .{address});

				{
					errdefer posix.close(socket);
					// socket is _probably_ in NONBLOCKING mode (it inherits
					// the flag from the listening socket).
					const flags = try posix.fcntl(socket, posix.F.GETFL, 0);
					const nonblocking = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
					if (flags & nonblocking == nonblocking) {
						// Yup, it's in nonblocking mode. Disable that flag to
						// put it in blocking mode.
						_ = try posix.fcntl(socket, posix.F.SETFL, flags & ~nonblocking);
					}
				}

				const hc = try conn_manager.create(socket, address, now);
				self.loop.monitorRead(hc, false) catch |err| {
					conn_manager.cleanup(hc);
					return err;
				};
			}
		}

		// Called in a thread-pool thread/
		// !! Access to self has to be synchronized !!
		// There can only be 1 dataAvailable executing per HC at any given time.
		// Access to HC *should not* need to be synchronized. Access to hc.conn
		// needs to be synchronized once &hc.conn is passed to the handler during
		// handshake (Conn is self-synchronized).
		// Shutdown throws a wrench in our synchronization model, since we could
		// be shutting down while we're processing data...but hopefully the way we
		// shutdown (by waiting for all the thread pools threads to end) solves this.
		// Else, we'll need to throw a bunch of locking around HC just to handle shutdown.
		fn dataAvailable(self: *Self, hc: *HandlerConn(H), thread_buf: []u8) void {
			var ok: bool = undefined;
			if (hc.handler == null) {
				ok = handleHandshake(H, self, hc, self.ctx);
				if (ok and hc.handler == null) {
					self.conn_manager.inactive(hc);
				}
			} else {
				var fba = FixedBufferAllocator.init(thread_buf);
				ok = handleIncoming(H, hc, self.allocator, &fba);
			}

			var conn = &hc.conn;
			var closed: bool = undefined;
			if (ok == false) {
				conn.close();
				closed = true;
			} else {
				closed = conn.isClosed();
			}

			if (closed) {
				self.conn_manager.cleanup(hc);
			} else {
				self.loop.monitorRead(hc, true) catch |err| {
					log.debug("({}) failed to add read event monitor: {}", .{conn.address, err});
					conn.close();
					self.conn_manager.cleanup(hc);
				};
			}
		}
	};
}

const KQueue = struct {
	q: i32,
	change_count: usize,
	change_buffer: [16]Kevent,
	event_list: [64]Kevent,

	const Kevent = posix.Kevent;

	fn init() !KQueue {
		return .{
			.q = try posix.kqueue(),
			.change_count = 0,
			.change_buffer = undefined,
			.event_list = undefined,
		};
	}

	fn deinit(self: KQueue) void {
		posix.close(self.q);
	}

	fn monitorAccept(self: *KQueue, fd: c_int) !void {
		try self.change(fd, 0, posix.system.EVFILT_READ, posix.system.EV_ADD);
	}

	fn monitorSignal(self: *KQueue, fd: c_int) !void {
		try self.change(fd, 1, posix.system.EVFILT_READ, posix.system.EV_ADD);
	}

	fn monitorRead(self: *KQueue, hc: anytype, comptime rearm: bool) !void {
		if (rearm) {
			const event = Kevent{
				.ident = @intCast(hc.socket),
				.filter = posix.system.EVFILT_READ,
				.flags = posix.system.EV_ENABLE | posix.system.EV_DISPATCH,
				.fflags = 0,
				.data = 0,
				.udata = @intFromPtr(hc),
			};
			_ = try posix.kevent(self.q, &.{event}, &[_]Kevent{}, null);
		} else {
			try self.change(hc.socket, @intFromPtr(hc), posix.system.EVFILT_READ, posix.system.EV_ADD | posix.system.EV_ENABLE | posix.system.EV_DISPATCH);
		}
	}

	fn change(self: *KQueue, fd: posix.fd_t, data: usize, filter: i16, flags: u16) !void {
		var change_count = self.change_count;
		var change_buffer = &self.change_buffer;

		if (change_count == change_buffer.len) {
			// calling this with an empty event_list will return immediate
			_ = try posix.kevent(self.q, change_buffer, &[_]Kevent{}, null);
			change_count = 0;
		}
		change_buffer[change_count] = .{
			.ident = @intCast(fd),
			.filter = filter,
			.flags = flags,
			.fflags = 0,
			.data = 0,
			.udata = data,
		};
		self.change_count = change_count + 1;
	}

		fn wait(self: *KQueue, timeout_sec: ?i32) !Iterator {
			const event_list = &self.event_list;
			const timeout: ?posix.timespec = if (timeout_sec) |ts| posix.timespec{ .tv_sec = ts, .tv_nsec = 0 } else null;
			const event_count = try posix.kevent(self.q, self.change_buffer[0..self.change_count], event_list, if (timeout) |ts| &ts else null);
			self.change_count = 0;

			return .{
				.index = 0,
				.events = event_list[0..event_count],
			};
		}

	const Iterator = struct {
		index: usize,
		events: []Kevent,

		fn next(self: *Iterator) ?usize {
			const index = self.index;
			const events = self.events;
			if (index == events.len) {
				return null;
			}
			self.index = index + 1;
			return self.events[index].udata;
		}
	};
};

const EPoll = struct {
	q: i32,
	event_list: [64]EpollEvent,

	const linux = std.os.linux;
	const EpollEvent = linux.epoll_event;

	fn init() !EPoll {
		return .{
			.event_list = undefined,
			.q = try posix.epoll_create1(0),
		};
	}

	fn deinit(self: EPoll) void {
		posix.close(self.q);
	}

	fn monitorAccept(self: *EPoll, fd: c_int) !void {
		var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 0 } };
		return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
	}

	fn monitorSignal(self: *EPoll, fd: c_int) !void {
		var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .ptr = 1 } };
		return std.posix.epoll_ctl(self.q, linux.EPOLL.CTL_ADD, fd, &event);
	}

	fn monitorRead(self: *EPoll, hc: anytype, comptime rearm: bool) !void {
		const op = if (rearm) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
		var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .ptr = @intFromPtr(hc) } };
		return posix.epoll_ctl(self.q, op, hc.socket, &event);
	}

	fn wait(self: *EPoll, timeout_sec: ?i32) !Iterator {
		const event_list = &self.event_list;
		var timeout: i32 = -1;
		if (timeout_sec) |sec| {
			if (sec > 2147483) {
				// max supported timeout by epoll_wait.
				timeout = 2147483647;
			} else {
				timeout = sec * 1000;
			}
		}

		const event_count = posix.epoll_wait(self.q, event_list, timeout);
		return .{
			.index = 0,
			.events = event_list[0..event_count],
		};
	}

	const Iterator = struct {
		index: usize,
		events: []EpollEvent,

		fn next(self: *Iterator) ?usize {
			const index = self.index;
			const events = self.events;
			if (index == events.len) {
				return null;
			}
			self.index = index + 1;
			return self.events[index].data.ptr;
		}
	};
};

// We want to extract as much common logic as possible from the Blocking and
// NonBlockign workers. The code from this point on is meant to be used with
// both workers, independently from the blocking/nonblocking nonsense.

// In the Blocking worker, all the state could be stored on the spawn'd thread's
// stack. The only reason we use a HandlerConn(H) in there is to be able to re-use
// code with the NonBlocking worker.
//
// For the NonBlocking worker, HandlerConn(H) is critical as it contains all the
// state for a connection. It lives on the heap, a pointer is registered into
// the event loop, and passed back when data is ready to read.
// * If handler is null, it means we haven't done our handshake yet.
// * If handler is null, reader is always invalid.
// * If handler is not null, then reader is always valid and handshake is always null
// * If handler is null AND handshake is null, it means we havent' received
//   any data yet (we delay creating the handshake state until we at least have
//   some data ready).
fn HandlerConn(comptime H: type) type {
	return struct {
		state: State,
		conn: Conn,
		handler: ?H,
		reader: ?Reader,
		socket: posix.socket_t, // denormalization from conn.stream.handle
		handshake: ?*Handshake.State,
		next: ?*HandlerConn(H) = null,
		prev: ?*HandlerConn(H) = null,

		const State = enum {
			handshake,
			active,
		};
	};
}

fn ConnManager(comptime H: type) type {
	return struct {
		lock: Thread.Mutex,
		active: List(HandlerConn(H)),
		pending: List(HandlerConn(H)),
		pool: std.heap.MemoryPool(HandlerConn(H)),
		handshake_pool: *Handshake.Pool,

		const Self = @This();

		fn init(allocator: Allocator, handshake_pool: *Handshake.Pool) !Self {
			var pool = std.heap.MemoryPool(HandlerConn(H)).init(allocator);
			errdefer pool.deinit();

			return .{
				.lock = .{},
				.pool = pool,
				.active = .{},
				.pending = .{},
				.handshake_pool = handshake_pool,
			};
		}

		fn deinit(self: *Self) void {
			self.pool.deinit();
		}

		fn count(self: *Self) usize {
			self.lock.lock();
			defer self.lock.unlock();
			if (comptime blockingMode()) {
				return self.active.len;
			}
			return self.active.len  + self.pending.len;
		}

		fn create(self: *Self, socket: posix.socket_t, address: net.Address, now: u32) !*HandlerConn(H) {
			errdefer posix.close(socket);

			self.lock.lock();
			defer self.lock.unlock();

			const hc = try self.pool.create();
			hc.* = .{
				.state = if (comptime blockingMode()) .active else .handshake,
				.socket = socket,
				.handler = null,
				.handshake = null,
				.reader = null,
				.conn = .{
					._closed = false,
					.started = now,
					.address = address,
					.stream = .{.handle = socket},
				},
			};

			if (comptime blockingMode()) {
				self.active.insert(hc);
			} else {
				// only care about this in nonblocking mode, because in blocking mode
				// the handshake timeout is handled by the spawned thread for the connection
				self.pending.insert(hc);
			}
			return hc;
		}

		fn activate(self: *Self, hc: *HandlerConn(H)) void {
			std.debug.assert(blockingMode() == false);

			// our caller made sute this was the case
			std.debug.assert(hc.state == .handshake);
			self.lock.lock();
			defer self.lock.unlock();
			self.pending.remove(hc);
			self.active.insert(hc);
			hc.state = .active;
		}

		fn inactive(self: *Self, hc: *HandlerConn(H)) void {
			std.debug.assert(blockingMode() == false);

			// this should only be called when we need more data to complete the handshake
			// which should only happen on an active connection
			std.debug.assert(hc.state == .active);
			hc.state = .handshake;

			self.lock.lock();
			defer self.lock.unlock();
			self.active.remove(hc);
			self.pending.insert(hc);
		}

		fn cleanup(self: *Self, hc: *HandlerConn(H)) void {
			if (hc.handshake) |h| {
				self.handshake_pool.release(h);
			}

			if (hc.reader) |*r| {
				r.deinit();
			}

			if (hc.handler) |*h| {
				if (comptime std.meta.hasFn(H, "close")) {
					h.close();
				}
				hc.handler = null;
			}

			self.lock.lock();
			if (hc.state == .active) {
				self.active.remove(hc);
			} else {
				self.pending.remove(hc);
			}

			self.pool.destroy(hc);
			self.lock.unlock();
		}

		fn closeAll(self: *Self, shutdown: Config.Shutdown) void {
			self.lock.lock();
			defer self.lock.unlock();

			closeList(self.active.head, shutdown);
			if (comptime blockingMode() == false) {
				closeList(self.pending.head, shutdown);
			}
		}

		fn closeList(head: ?*HandlerConn(H), shutdown: Config.Shutdown) void {
			var next_node = head;
			while (next_node) |hc| {

				if (comptime std.meta.hasFn(H, "close")) {
					if (shutdown.notify_handler) {
						if (hc.handler) |*h| {
							h.close();
							hc.handler = null;
						}
					}
				}

				const conn = &hc.conn;
				if (conn.isClosed() == false) {
					if (shutdown.notify_client) {
						conn.writeClose();
					}
					conn.close();
				}
				next_node = hc.next;
			}
		}

		// Enforces timeouts, and returns when the next timeout should be checked.
		fn prepareToWait(self: *Self, cutoff: u32) ?i32 {
			std.debug.assert(blockingMode() == false);

			// always ordered from oldest to newest, so once we find a conneciton
			// that isn't timed out, we can stop
			self.lock.lock();
			defer self.lock.unlock();
			var next_conn = self.pending.head;
			while (next_conn) |hc| {
				const conn = &hc.conn;
				const started = conn.started;
				if (started > cutoff) {
					// This is the first connection which hasn't timed out
					// return the time until it times out.
					return @intCast(started - cutoff);
				}

				next_conn = hc.next;

				// this connection has timed out. Don't use self.cleanup since there's
				// a bunch of stuff we can assume here..like there's no handler or reader
				conn.close();
				log.debug("({}) handshake timeout", .{conn.address});
				if (hc.handshake) |h| {
					self.handshake_pool.release(h);
				}
				self.pending.remove(hc);
				self.pool.destroy(hc);
			}
			return null;
		}
	};
}

pub const Conn = struct {
	_closed: bool,
	started: u32,
	stream: net.Stream,
	address: net.Address,
	lock: Thread.Mutex = .{},

	pub fn isClosed(self: *Conn) bool {
		// don't use lock to protect _closed. `isClosed` is called from
		// the worker thread and we don't want that potentially blocked while
		// a write is going on.
		return @atomicLoad(bool, &self._closed, .monotonic);
	}

	pub fn close(self: *Conn) void {
		if (@atomicRmw(bool, &self._closed, .Xchg, true, .monotonic) == false) {
			posix.close(self.stream.handle);
		}
	}

	pub fn writeBin(self: *Conn, data: []const u8) !void {
		return self.writeFrame(.binary, data);
	}

	pub fn writeText(self: *Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn write(self: *Conn, data: []const u8) !void {
		return self.writeFrame(.text, data);
	}

	pub fn writePing(self: *Conn, data: []u8) !void {
		return self.writeFrame(.ping, data);
	}

	pub fn writePong(self: *Conn, data: []u8) !void {
		return self.writeFrame(.pong, data);
	}

	pub fn writeClose(self: *Conn) void {
		self.writeFramed(CLOSE_NORMAL) catch {};
	}

	pub fn writeCloseWithCode(self: *Conn, code: u16) void {
		var buf: [2]u8 = undefined;
		std.mem.writeInt(u16, &buf, code, .Big);
		self.writeFrame(.close, &buf) catch {};
	}

	pub fn writeFrame(self: *Conn, op_code: OpCode, data: []const u8) !void {
		const l = data.len;
		const stream = self.stream;

		// maximum possible prefix length. op_code + length_type + 8byte length
		var buf: [10]u8 = undefined;
		var header: []const u8 = undefined;
		buf[0] = @intFromEnum(op_code);

		if (l <= 125) {
			buf[1] = @intCast(l);
			header = buf[0..2];
		} else if (l < 65536) {
			buf[1] = 126;
			buf[2] = @intCast((l >> 8) & 0xFF);
			buf[3] = @intCast(l & 0xFF);
			header = buf[0..4];
		} else {
			buf[1] = 127;
			buf[2] = @intCast((l >> 56) & 0xFF);
			buf[3] = @intCast((l >> 48) & 0xFF);
			buf[4] = @intCast((l >> 40) & 0xFF);
			buf[5] = @intCast((l >> 32) & 0xFF);
			buf[6] = @intCast((l >> 24) & 0xFF);
			buf[7] = @intCast((l >> 16) & 0xFF);
			buf[8] = @intCast((l >> 8) & 0xFF);
			buf[9] = @intCast(l & 0xFF);
			header = buf[0..];
		}

		if (l == 0) {
			// no body, just write the header
			self.lock.lock();
			defer self.lock.unlock();
			return stream.writeAll(header);
		}

		var vec = [2]std.posix.iovec_const{
			.{ .len = header.len, .base = header.ptr },
			.{ .len = data.len, .base = data.ptr },
		};

		var i: usize = 0;
		const socket = stream.handle;

		self.lock.lock();
		defer self.lock.unlock();

		while (true) {
			var n = try std.posix.writev(socket, vec[i..]);
			while (n >= vec[i].len) {
				n -= vec[i].len;
					i += 1;
					if (i >= vec.len) return;
			}
			vec[i].base += n;
			vec[i].len -= n;
		}
	}

	pub fn writeFramed(self: *Conn, data: []const u8) !void {
		self.lock.lock();
		defer self.lock.unlock();
		try self.stream.writeAll(data);
	}
};


// This is being usexecuted in a thread-pool thread. Access to self has to
// be synchronized.
// Normally access to hc.conn also has to be synchronized, but for doHandshake,
// that's only true after H.init is called (at which point, the application
// has access to &hc.conn and could do things concurrently to it).
fn handleHandshake(comptime H: type, worker: anytype, hc: *HandlerConn(H), ctx: anytype) bool {
	return _handleHandshake(H, worker, hc, ctx) catch |err| {
		log.warn("({}) uncaugh error processing handshake: {}", .{hc.conn.address, err});
		return false;
	};
}

fn _handleHandshake(comptime H: type, worker: anytype, hc: *HandlerConn(H), ctx: anytype) !bool {
	std.debug.assert(hc.handler == null);

	var state = hc.handshake orelse blk: {
		const s = try worker.handshake_pool.acquire();
		hc.handshake = s;
		break :blk s;
	};

	var buf = state.buf;
	var conn = &hc.conn;
	const len = state.len;

	if (len == buf.len) {
		log.warn("({}) handshake request exceeded maximum configured size ({d})", .{conn.address, buf.len});
		return false;
	}

	const n = posix.read(hc.socket, buf[len..]) catch |err| {
		switch (err) {
			error.BrokenPipe, error.ConnectionResetByPeer => log.debug("({}) handshake connection closed: {}", .{conn.address, err}),
			error.WouldBlock => {
				std.debug.assert(blockingMode());
				log.debug("({}) handshake timeout", .{conn.address});
			},
			else => log.warn("({}) handshake error reading from socket: {}", .{conn.address, err}),
		}
		return false;
	};

	if (n == 0) {
		log.debug("({}) handshake connection closed", .{conn.address});
		return false;
	}

	state.len += n;
	const handshake = Handshake.parse(state) catch |err| {
		log.debug("({}) error parsing handshake: {}", .{conn.address, err});
		respondToHandshakeError(conn, err);
		return false;
	} orelse {
		// we need more data
		return true;
	};

	worker.handshake_pool.release(state);
	hc.handshake = null;

	// After this, the app has access to &hc.conn, so any access to the
	// conn has to be synchronized (which the conn does internally).

	const handler = H.init(handshake, conn, ctx) catch |err| {
		if (comptime std.meta.hasFn(H, "handshakeErrorResponse")) {
			preHandOffWrite(H.handshakeErrorResponse(err));
		} else {
			respondToHandshakeError(conn, err);
		}
		log.debug("({}) " ++ @typeName(H) ++ ".init rejected request {}", .{conn.address, err});
		return false;
	};


	hc.handler = handler;
	try conn.writeFramed(&handshake.reply());

	if (comptime std.meta.hasFn(H, "afterInit")) {
		handler.afterInit() catch |err| {
			log.debug("({}) " ++ @typeName(H) ++ ".afterInit error: {}", .{conn.address, err});
			return false;
		};
	}

	hc.reader = Reader.init(worker.config.connection_buffer_size, worker.buffer_provider) catch |err| {
		log.err("({}) error creating reader: {}", .{conn.address, err});
		return false;
	};

	log.debug("({}) connection successfully upgraded", .{conn.address});
	return true;
}

fn handleIncoming(comptime H: type, hc: *HandlerConn(H), allocator: Allocator, fba: *FixedBufferAllocator) bool {
	std.debug.assert(hc.handshake == null);
	return _handleIncoming(H, hc, allocator, fba) catch |err| {
		log.warn("({}) uncaugh error handling incoming data: {}", .{hc.conn.address, err});
		return false;
	};
}

fn _handleIncoming(comptime H: type, hc: *HandlerConn(H), allocator: Allocator, fba: *FixedBufferAllocator) !bool {
	var conn = &hc.conn;
	var reader = &hc.reader.?;
	reader.fill(conn.stream) catch |err| {
		switch (err) {
			error.BrokenPipe, error.Closed, error.ConnectionResetByPeer => log.debug("({}) connection closed: {}", .{conn.address, err}),
			else => log.warn("({}) error reading from connection: {}", .{conn.address, err}),
		}
		return false;
	};

	const handler = &hc.handler.?;
	while (true) {
		const has_more, const message = reader.read() catch |err| {
			switch (err) {
				error.LargeControl => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
				error.ReservedFlags => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
				else => {},
			}
			log.debug("({}) invalid websocket packet: {}", .{conn.address, err});
			return false;
		} orelse {
			// everything is fine, we just need more data
			return true;
		};

		const message_type = message.type;
		defer reader.done(message_type);

		log.debug("({}) received {s} message", .{hc.conn.address, @tagName(message_type)});
		switch (message_type) {
			.text, .binary => {
				const params = @typeInfo(@TypeOf(H.clientMessage)).Fn.params;
				const needs_allocator = comptime params[1].type == Allocator;

				var arena: std.heap.ArenaAllocator = undefined;
				var fallback_allocator: FallbackAllocator = undefined;
				var aa: Allocator = undefined;

				if (comptime needs_allocator) {
					arena = std.heap.ArenaAllocator.init(allocator);
					if (comptime blockingMode()) {
						aa = arena.allocator();
					} else {
						fallback_allocator = FallbackAllocator{
							.fba = fba,
							.fallback = arena.allocator(),
							.fixed = fba.allocator(),
						};
						aa = fallback_allocator.allocator();
					}
				}

				defer if (comptime needs_allocator) {
					arena.deinit();
				};

				switch (comptime params.len) {
					2 => handler.clientMessage(message.data) catch return false,
					3 => if (needs_allocator) {
						handler.clientMessage(aa, message.data) catch return false;
					} else {
						handler.clientMessage(message.data, if (message_type == .text) .text else .binary) catch return false;
					},
					4 => handler.clientMessage(aa, message.data, if (message_type == .text) .text else .binary) catch return false,
					else => @compileError(@typeName(H) ++ ".clientMessage has invalid parameter count"),
				}
			},
			.pong => if (comptime std.meta.hasFn(H, "clientPong")) {
				try handler.clientPong();
			},
			.ping => {
				const data = message.data;
				if (comptime std.meta.hasFn(H, "clientPing")) {
					try handler.clientPing(data);
				} else if (data.len == 0) {
					try hc.conn.writeFramed(EMPTY_PONG);
				} else {
					try hc.conn.writeFrame(.pong, data);
				}
			},
			.close => {
				defer conn.close();
				const data = message.data;
				if (comptime std.meta.hasFn(H, "clientClose")) {
					return handler.clientClose(data);
				}

				const l = data.len;
				if (l == 0) {
					conn.writeClose();
					return false;
				}

				if (l == 1) {
					// close with a payload always has to have at least a 2-byte payload,
					// since a 2-byte code is required
					try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
					return false;
				}

				const code = @as(u16, @intCast(data[1])) | (@as(u16, @intCast(data[0])) << 8);
				if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
					try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
					return false;
				}

				if (l == 2) {
					try conn.writeFramed(CLOSE_NORMAL);
					return false;
				}

				const payload = data[2..];
				if (!std.unicode.utf8ValidateSlice(payload)) {
					// if we have a payload, it must be UTF8 (why?!)
					try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
				} else {
					conn.writeClose();
				}
				return false;
			},
		}

		if (conn.isClosed()) {
			return false;
		}

		if (has_more == false) {
			// we don't have more data ready to be processed in our buffer
			// back to our caller for more data
			return true;
		}
	}
}

fn respondToHandshakeError(conn: *Conn, err: anyerror) void {
	const response = switch (err) {
		error.Close => return,
		error.RequestTooLarge => buildError(400, "too large"),
		error.Timeout, error.WouldBlock => buildError(400, "timeout"),
		error.InvalidProtocol => buildError(400, "invalid protocol"),
		error.InvalidRequestLine => buildError(400, "invalid requestline"),
		error.InvalidHeader => buildError(400, "invalid header"),
		error.InvalidUpgrade => buildError(400, "invalid upgrade"),
		error.InvalidVersion => buildError(400, "invalid version"),
		error.InvalidConnection => buildError(400, "invalid connection"),
		error.MissingHeaders => buildError(400, "missingheaders"),
		error.Empty => buildError(400, "invalid request"),
		else => buildError(400, "unknown"),
	};
	preHandOffWrite(conn, response);
}

fn buildError(comptime status: u16, comptime err: []const u8) []const u8 {
	return std.fmt.comptimePrint("HTTP/1.1 {d} \r\nConnection: Close\r\nError: {s}\r\nContent-Length: 0\r\n\r\n", .{ status, err });
}

fn preHandOffWrite(conn: *Conn, response: []const u8) void {
	// "preHandOff" means we haven't given the applciation handler a reference
	// to *Conn yet. In theory, this means we don't need to worry about thread-safety
	// However, it is possible for the worker to be stopped while we're doing this
	// which causes issues unless we lock
	conn.lock.lock();
	defer conn.lock.unlock();

	if (conn.isClosed()) {
		return;
	}

	const socket = conn.stream.handle;
	const timeout = std.mem.toBytes(posix.timeval{ .tv_sec = 5, .tv_usec = 0 });
	posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch return;

	var pos: usize = 0;
	while (pos < response.len) {
		const n = posix.write(socket, response[pos..]) catch return;
		if (n == 0) {
			// closed
			return;
		}
		pos += n;
	}
}

fn timestamp() u32 {
	if (comptime @hasDecl(std.c, "CLOCK") == false) {
		return @intCast(std.time.timestamp());
	}
	var ts: posix.timespec = undefined;
	posix.clock_gettime(posix.CLOCK.REALTIME, &ts) catch unreachable;
	return @intCast(ts.tv_sec);
}

// intrusive doubly-linked list with count, not thread safe
fn List(comptime T: type) type {
	return struct {
		len: usize = 0,
		head: ?*T = null,
		tail: ?*T = null,

		const Self = @This();

		pub fn insert(self: *Self, node: *T) void {
			if (self.tail) |tail| {
				tail.next = node;
				node.prev = tail;
				self.tail = node;
			} else {
				self.head = node;
				self.tail = node;
			}
			self.len += 1;
			node.next = null;
		}

		pub fn remove(self: *Self, node: *T) void {
			if (node.prev) |prev| {
				prev.next = node.next;
			} else {
				self.head = node.next;
			}

			if (node.next) |next| {
				next.prev = node.prev;
			} else {
				self.tail = node.prev;
			}
			node.prev = null;
			node.next = null;
			self.len -= 1;
		}
	};
}

const t = @import("../t.zig");

var test_thread: Thread = undefined;
var test_server: Server(TestHandler) = undefined;
var global_test_allocator = std.heap.GeneralPurposeAllocator(.{}){};

test "tests:beforeAll" {
	test_server = try Server(TestHandler).init(global_test_allocator.allocator(), .{
		.port = 9292,
		.address = "127.0.0.1",
	});
	test_thread = try test_server.listenInNewThread({});
}

test "tests:afterAll" {
	test_server.stop();
	test_thread.join();
	test_server.deinit();
	try t.expectEqual(false, global_test_allocator.detectLeaks());
}

test "Server: invalid handshake" {
	const stream = try testStream(false);
	defer stream.close();

	try stream.writeAll("GET / HTTP/1.1\r\n\r\n");
	var buf: [1024]u8 = undefined;
	var pos: usize = 0;
	while (pos < buf.len) {
		const n = try stream.read(buf[0..]);
		if (n == 0) {
			break;
		}
		pos += n;
	} else {
		unreachable;
	}

	try t.expectString("HTTP/1.1 400 \r\nConnection: Close\r\nError: missingheaders\r\nContent-Length: 0\r\n\r\n", buf[0..pos]);
}

test "Server: echo" {
	const stream = try testStream(true);
	defer stream.close();

	try stream.writeAll(&proto.frame(.text, "over"));
	var buf: [12]u8 = undefined;
	_ = try stream.readAtLeast(&buf, 6);
	try t.expectSlice(u8, &.{129, 4, '9', '0', '0', '0'}, buf[0..6]);
}

test "Server: handleMessage allocator" {
	const stream = try testStream(true);
	defer stream.close();

	try stream.writeAll(&proto.frame(.text, "dyn"));
	var buf: [12]u8 = undefined;
	_ = try stream.readAtLeast(&buf, 12);
	try t.expectSlice(u8, &.{129, 10, 'o', 'v', 'e', 'r', ' ', '9', '0', '0', '0', '!'}, buf[0..12]);
}

fn testStream(handshake: bool) !net.Stream {
	const timeout = std.mem.toBytes(std.posix.timeval{.tv_sec = 0, .tv_usec = 20_000});
	const address = try std.net.Address.parseIp("127.0.0.1", 9292);
	const stream = try std.net.tcpConnectToAddress(address);
	try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout);
	try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout);

	if (handshake == false) {
		return stream;
	}

	try stream.writeAll("GET / HTTP/1.1\r\ncontent-length: 0\r\nupgrade: websocket\r\nsec-websocket-version: 13\r\nconnection: upgrade\r\nsec-websocket-key: my-key\r\n\r\n");
	var buf: [1024]u8 = undefined;
	var pos: usize = 0;
	while (pos < buf.len) {
		const n = try stream.read(buf[0..]);
		if (n == 0) break;

		pos += n;
		if (std.mem.endsWith(u8, buf[0..pos], "\r\n\r\n")) {
			break;
		}
	} else {
		unreachable;
	}

	try t.expectString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-Websocket-Accept: L8KGBs4w2MNLLzhfzlVoM0scCIE=\r\n\r\n", buf[0..pos]);

	return stream;
}

const TestHandler = struct {
	conn: *Conn,

	pub fn init(_: Handshake, conn: *Conn, _: void) !TestHandler {
		return .{
			.conn = conn,
		};
	}
	pub fn clientMessage(self: *TestHandler, allocator: Allocator, data: []const u8,) !void {
		if (std.mem.eql(u8, data, "over")) {
			return self.conn.writeText("9000");
		}

		if (std.mem.eql(u8, data, "dyn")) {
			return self.conn.writeText(try std.fmt.allocPrint(allocator, "over {d}!", .{9000}));
		}
	}
};

test "List" {
	var list = List(TestNode){};
	try expectList(&.{}, list);

	var n1 = TestNode{ .id = 1 };
	list.insert(&n1);
	try expectList(&.{1}, list);

	list.remove(&n1);
	try expectList(&.{}, list);

	var n2 = TestNode{ .id = 2 };
	list.insert(&n2);
	list.insert(&n1);
	try expectList(&.{ 2, 1 }, list);

	var n3 = TestNode{ .id = 3 };
	list.insert(&n3);
	try expectList(&.{ 2, 1, 3 }, list);

	list.remove(&n1);
	try expectList(&.{ 2, 3 }, list);

	list.insert(&n1);
	try expectList(&.{ 2, 3, 1 }, list);

	list.remove(&n2);
	try expectList(&.{ 3, 1 }, list);

	list.remove(&n1);
	try expectList(&.{3}, list);

	list.remove(&n3);
	try expectList(&.{}, list);
}

const TestNode = struct {
	id: i32,
	next: ?*TestNode = null,
	prev: ?*TestNode = null,
};

fn expectList(expected: []const i32, list: List(TestNode)) !void {
	if (expected.len == 0) {
		try t.expectEqual(null, list.head);
		try t.expectEqual(null, list.tail);
		return;
	}

	var i: usize = 0;
	var next = list.head;
	while (next) |node| {
		try t.expectEqual(expected[i], node.id);
		i += 1;
		next = node.next;
	}
	try t.expectEqual(expected.len, i);

	i = expected.len;
	var prev = list.tail;
	while (prev) |node| {
		i -= 1;
		try t.expectEqual(expected[i], node.id);
		prev = node.prev;
	}
	try t.expectEqual(0, i);
}
