const std = @import("std");
const lib = @import("lib.zig");

const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.websocket);

const Reader = lib.Reader;
const buffer = lib.buffer;
const Message = lib.Message;
const Handshake = lib.Handshake;
const OpCode = lib.framing.OpCode;

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
	return false;
	// if (force_blocking) {
	// 	return true;
	// }
	// return switch (builtin.os.tag) {
	// 	.linux, .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => false,
	// 	else => true,
	// };
}

pub const Config = struct {
	port: ?u16 = null,
	address: []const u8 = "127.0.0.1",
	max_size: usize = 65536,
	buffer_size: usize = 4096,
	unix_path: ?[]const u8 = null,

	workers: Workers = .{},
	shutdown: Shutdown = .{},
	handshake: Config.Handshake = .{},
	large_buffers: Config.LargeBuffers = .{},

	const Shutdown = struct {
		close_socket: bool = true,
		notify_client: bool = true,
		notify_handler: bool = true,
	};

	const Workers = struct {
		count: ?u16 = null,
		max_conn: ?u16 = null,
	};

	const Handshake = struct {
		timeout: ?u32 = null,
		max_size: ?u16 = null,
		max_headers: ?u16 = null,
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
		cond: Thread.Condition,
		buffer_provider: buffer.Provider,
		signals: [][2]posix.fd_t,

		const Self = @This();

		pub fn init(allocator: Allocator, config: Config) !Self {
			const signals = try allocator.alloc([2]posix.fd_t, config.workers.count orelse DEFAULT_WORKER_COUNT);
			errdefer allocator.free(signals);

			const buffer_pool = try allocator.create(buffer.Pool);
			errdefer allocator.destroy(buffer_pool);

			const large_buffer_count = config.large_buffers.count orelse 32;
			buffer_pool.* = try buffer.Pool.init(allocator, large_buffer_count, config.large_buffers.size orelse 32768);
			errdefer buffer_pool.deinit();

			const buffer_provider = buffer.Provider.init(allocator, buffer_pool, large_buffer_count);

			return .{
				.cond = .{},
				.config = config,
				.signals = signals,
				.allocator = allocator,
				.buffer_provider = buffer_provider,
			};
		}

		pub fn deinit(self: *Self) void {
			self.buffer_provider.pool.deinit();
			self.allocator.destroy(self.buffer_provider.pool);
			self.allocator.free(self.signals);
		}

		pub fn listenInNewThread(self: *Self, context: anytype) !Thread {
			return try Thread.spawn(.{}, Self.listen, .{self, context});
		}

		pub fn listen(self: *Self, context: anytype) !void {
			const config = &self.config;

			var no_delay = true;
			const address = blk: {
				if (config.unix_path) |unix_path| {
					if (comptime @import("builtin").os.tag == .windows) {
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
				if (lib.blockingMode() == false) sock_flags |= posix.SOCK.NONBLOCK;

				const proto = if (address.any.family == posix.AF.UNIX) @as(u32, 0) else posix.IPPROTO.TCP;
				break :blk try posix.socket(address.any.family, sock_flags, proto);
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
				try posix.listen(socket, 1204); // kernel backlog
			}

			if (comptime lib.blockingMode()) {
				errdefer posix.close(socket);
				var w = try Blocking(H).init(self);
				defer w.deinit();

				const thrd = try std.Thread.spawn(.{}, Blocking(H).listen, .{&w, socket, context});

				// is this really the best way?
				var mutex = Thread.Mutex{};
				mutex.lock();
				self.cond.wait(&mutex);
				mutex.unlock();
				w.stop();
				posix.close(socket);
				thrd.join();
			} else {
				defer posix.close(socket);
				var signals = self.signals;
				const allocator = self.allocator;
				const worker_count = config.workers.count orelse DEFAULT_WORKER_COUNT;
				const workers = try allocator.alloc(NonBlocking(H), worker_count);
				const threads = try allocator.alloc(Thread, worker_count);

				var started: usize = 0;
				defer {
					for (0..started) |i| {
						posix.close(signals[i][1]);
						threads[i].join();
						workers[i].deinit();
					}
					allocator.free(workers);
					allocator.free(threads);
				}

				for (0..workers.len) |i| {
					signals[i] = try posix.pipe2(.{.NONBLOCK = true});
					errdefer posix.close(signals[i][1]);

					workers[i] = try NonBlocking(H).init(self);
					errdefer workers[i].deinit();

					threads[i] = try Thread.spawn(.{}, NonBlocking(H).listen, .{&workers[i], socket, signals[i][0], context});
					started += 1;
				}

				// is this really the best way?
				var mutex = Thread.Mutex{};
				mutex.lock();
				self.cond.wait(&mutex);
				mutex.unlock();
			}
		}

		pub fn stop(self: *Self) void {
			self.cond.signal();
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
		handshake_max_size: u16,
		handshake_max_headers: u16,
		buffer_provider: *buffer.Provider,

		// protects access to the conn_list and conn_pool
		conn_lock: Thread.Mutex,
		conn_list: List(HandlerConn(H)),
		conn_pool: std.heap.MemoryPool(HandlerConn(H)),

		const Timeout = struct {
			sec: u32,
			timeval: [@sizeOf(std.posix.timeval)]u8,

			// if sec is null, it means we want to cancel the timeout.
			fn init(sec: ?u32) Timeout {
				return .{
					.sec = if (sec) |s| s else MAX_TIMEOUT,
					.timeval = std.mem.toBytes(posix.timeval{ .tv_sec = @intCast(sec orelse 0), .tv_usec = 0 }),
				};
			}
		};

		const Self = @This();

		pub fn init(server: *Server(H)) !Self {
			const config = &server.config;
			const allocator = server.allocator;

			const conn_pool = std.heap.MemoryPool(HandlerConn(H)).init(allocator);
			errdefer conn_pool.deinit();

			return .{
				.running = true,
				.config = config,
				.conn_list = .{},
				.conn_lock = .{},
				.conn_pool = conn_pool,
				.allocator = allocator,
				.buffer_provider = &server.buffer_provider,
				.handshake_timeout = Timeout.init(config.handshake.timeout orelse MAX_TIMEOUT),
				.handshake_max_size = config.handshake.max_size orelse DEFAULT_MAX_HANDSHAKE_SIZE,
				.handshake_max_headers = config.handshake.max_headers orelse 0,
			};
		}

		pub fn deinit(self: *Self) void {
			closeAll(H, self.conn_list, &self.conn_pool, self.config.shutdown);
			self.conn_pool.deinit();
		}

		pub fn stop(self: *Self) void {
			@atomicStore(bool, &self.running, false, .monotonic);
		}

		pub fn listen(self: *Self, listener: posix.socket_t, context: anytype) void {
			while (true) {
				if (@atomicLoad(bool, &self.running, .monotonic) == false) {
					return;
				}

				var address: std.net.Address = undefined;
				var address_len: posix.socklen_t = @sizeOf(std.net.Address);
				const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
					log.err("Failed to accept socket: {}", .{err});
					continue;
				};

				const thread = std.Thread.spawn(.{}, Self.handleConnection, .{self, socket, context}) catch |err| {
					posix.close(socket);
					log.err("Failed to spawn connection thread: {}", .{err});
					continue;
				};
				thread.detach();
			}
		}

		// Called in a thread started above in listen.
		// Wrapper around _handleConnection so that we can handle erros
		fn handleConnection(self: *Self, socket: posix.socket_t, context: anytype) void {
			defer posix.close(socket);
			self._handleConnection(socket, context) catch |err| log.err("Connection thread initialization error: {}", .{err});
		}

		fn _handleConnection(self: *Self, socket: posix.socket_t, context: anytype) !void {
			const hc = blk: {
				self.conn_lock.lock();
				defer self.conn_lock.unlock();

				const hc = try self.conn_pool.create();
				hc.* = .{
					.handler = undefined,
					.conn = .{
						._closed = false,
						._rw_mode = .none,
						._io_mode = .blocking,
						._socket_flags = 0, // not needed in the blocking worker
						.stream = .{.handle = socket},
					},
				};

				self.conn_list.insert(hc);
				break :blk hc;
			};

			var conn = &hc.conn;

			defer {
				self.conn_lock.lock();
				self.conn_list.remove(hc);
				self.conn_pool.destroy(hc);
				self.conn_lock.unlock();
			}

			hc.handler = (try self.doHandshake(conn, context)) orelse return;

			var handler = &hc.handler;
			defer if (comptime std.meta.hasFn(H, "close")) {
				handler.close();
			};

			if (comptime std.meta.hasFn(H, "afterInit")) {
				handler.afterInit() catch return;
			}

			const config = self.config;
			var reader = Reader.init(config.buffer_size, config.max_size, self.buffer_provider) catch |err| {
				log.err("Failed to create a Reader, connection is being closed. The error was: {}", .{err});
				return;
			};
			defer reader.deinit();

			while (true) {
				const message = reader.readMessage(conn.stream) catch |err| {
					switch (err) {
						error.LargeControl => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
						error.ReservedFlags => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
						else => {},
					}
					return;
				};

				handleMessage(H, handler, conn, message) catch return;
				// TODO: thread safety
				if (conn._closed) {
					return;
				}

			}
		}

		fn doHandshake(self: *Self, conn: *Conn, context: anytype) !?H {
			var arena = std.heap.ArenaAllocator.init(self.allocator);
			defer arena.deinit();

			const allocator = arena.allocator();

			const buf = try allocator.alloc(u8, self.handshake_max_size);
			const request = self.readRequest(conn, buf) catch |err| {
				respondToHandshakeError(conn, err);
				return null;
			};

			const handshake = Handshake.parse(request, allocator, self.handshake_max_headers) catch |err| {
				respondToHandshakeError(conn, err);
				return null;
			};

			var handler = H.init(handshake, conn, context) catch |err| {
				if (comptime std.meta.hasFn(H, "handshakeErrorResponse")) {
					preHandOffWrite(H.handshakeErrorResponse(err));
				} else {
					respondToHandshakeError(conn, err);
				}
				return null;
			};

			conn.writeFramed(&handshake.reply()) catch |err| {
				if (comptime std.meta.hasFn(H, "close")) {
					handler.close();
				}
				return err;
			};
			return handler;
		}

		fn readRequest(self: *Self, conn: *Conn, buf: []u8) ![]u8 {
			const socket = conn.stream.handle;
			const timeout = self.handshake_timeout;
			const deadline = timestamp() + timeout.sec;

			var pos: usize = 0;
			while (pos < buf.len) {
				const n = try posix.read(socket, buf[pos..]);
				if (n == 0) {
					return error.Close;
				}

				pos += n;
				const request = buf[0..pos];
				if (std.mem.endsWith(u8, request, "\r\n\r\n")) {
					return buf[0..pos];
				}

				if (timestamp() > deadline) {
					return error.Timeout;
				}
			}
			return error.RequestTooLarge;
		}
	};
}

fn NonBlocking(comptime H: type) type {
	return struct {
		// KQueue or Epoll, depending on the platform
		loop: Loop,

		allocator: Allocator,
		config: *const Config,
		buffer_provider: *buffer.Provider,

		max_conn: usize,
		conn_list: List(HandlerConn(H)),
		conn_pool: std.heap.MemoryPool(HandlerConn(H)),

		const Self = @This();

		const Loop = switch (@import("builtin").os.tag) {
			.macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .dragonfly, .openbsd => KQueue,
			.linux => EPoll,
			else => unreachable,
		};

		pub fn init(server: *Server(H)) !Self {
			const config = &server.config;
			const allocator = server.allocator;

			const loop = try Loop.init();
			errdefer loop.deinit();

			const conn_pool = std.heap.MemoryPool(HandlerConn(H)).init(allocator);
			errdefer conn_pool.deinit();

			return .{
				.loop = loop,
				.config = config,
				.conn_list = .{},
				.conn_pool = conn_pool,
				.allocator = allocator,
				.buffer_provider = &server.buffer_provider,
				.max_conn = config.workers.max_conn orelse 8192,
			};
		}

		pub fn deinit(self: *Self) void {
			closeAll(H, self.conn_list, &self.conn_pool, self.config.shutdown);
			self.conn_pool.deinit();
			self.loop.deinit();
		}

		pub fn listen(self: *Self, listener: posix.socket_t, signal: posix.fd_t, context: anytype) void {
			_ = context;
			self.loop.monitorAccept(listener) catch |err| {
				log.err("Failed to add monitor to listening socket: {}", .{err});
				return;
			};

			self.loop.monitorSignal(signal) catch |err| {
				log.err("Failed to add monitor to signal pipe: {}", .{err});
				return;
			};

			while (true) {
				var it = self.loop.wait() catch |err| {
					log.err("Failed to wait on events: {}", .{err});
					std.time.sleep(std.time.ns_per_s);
					continue;
				};

				while (it.next()) |data| {
					if (data == 0) {
						self.accept(listener) catch |err| {
							log.err("Failed to accept connection: {}", .{err});
							std.time.sleep(std.time.ns_per_ms * 10);
						};
						continue;
					}

					if (data == 1) {
						// for now, activity on the signal can only mean shutdown
						return;
					}

					const hc: *HandlerConn(H) = @ptrFromInt(data);
					_ = hc;
					// if (self.handleRequest(hc) == false) {
					// 	self.closeConn(hc);
					// }
				}
			}
		}

		fn accept(self: *Self, listener: posix.fd_t) !void {
			const max_conn = self.max_conn;

			var count = self.conn_list.len;
			while (count < max_conn) {
				var address: std.net.Address = undefined;
				var address_len: posix.socklen_t = @sizeOf(std.net.Address);

				const socket = posix.accept(listener, &address.any, &address_len, posix.SOCK.CLOEXEC) catch |err| {
					// When available, we use SO_REUSEPORT_LB or SO_REUSEPORT, so WouldBlock
					// should not be possible in those cases, but if it isn't available
					// this error should be ignored as it means another thread picked it up.
					return if (err == error.WouldBlock) {} else err;
				};
				errdefer posix.close(socket);

				// set non blocking
				const flags = (try posix.fcntl(socket, posix.F.GETFL, 0)) | @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
				_ = try posix.fcntl(socket, posix.F.SETFL, flags);

				const handle_conn = try self.conn_pool.create();
				handle_conn.* = .{
					.handler = undefined, // DANGEROUS
					.conn = .{
						._closed = false,
						._rw_mode = .none,
						._io_mode = .nonblocking,
						.stream = .{.handle = socket},
						._socket_flags = flags,
					},
				};
				self.conn_list.insert(handle_conn);
				count += 1;
			}
		}


		// pub fn handleRequest(self: *Self, conn: *Conn) bool {
		// 	const stream = conn.stream;

		// 	const done = conn.req_state.parse(stream) catch |err| {
		// 		requestParseError(conn, err) catch {};
		// 		return false;
		// 	};

		// 	if (done == false) {
		// 		// we need to wait for more data
		// 		self.loop.monitorRead(conn, true) catch |err| {
		// 			serverError(conn, "unknown event loop error: {}", err) catch {};
		// 			return false;
		// 		};
		// 		return true;
		// 	}

		// 	metrics.request();
		// 	const server = self.server;
		// 	server._thread_pool.spawn(.{ server, self, conn });
		// 	return true;
		// }

		fn closeConn(self: *Self, hc: *HandlerConn) void {
			posix.close(hc.conn.stream.handle);
			self.conn_list.remove(hc.node);
			self.coon_pool.destroy(hc);
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

	fn monitorRead(self: *KQueue, conn: *Conn, comptime rearm: bool) !void {
		_ = rearm; // used by epoll
		try self.change(conn.stream.handle, @intFromPtr(conn), posix.system.EVFILT_READ, posix.system.EV_ADD | posix.system.EV_ENABLE | posix.system.EV_DISPATCH);
	}

	fn remove(self: *KQueue, conn: *Conn) !void {
		const fd = conn.stream.handle;
		try self.change(fd, 0, posix.system.EVFILT_READ, posix.system.EV_DELETE);
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

	fn wait(self: *KQueue) !Iterator {
		const event_list = &self.event_list;
		const event_count = try posix.kevent(self.q, self.change_buffer[0..self.change_count], event_list, null);
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

	fn monitorRead(self: *EPoll, conn: *Conn, comptime rearm: bool) !void {
		const op = if (rearm) linux.EPOLL.CTL_MOD else linux.EPOLL.CTL_ADD;
		var event = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT, .data = .{ .ptr = @intFromPtr(conn) } };
		return posix.epoll_ctl(self.q, op, conn.stream.handle, &event);
	}

	fn remove(self: *EPoll, conn: *Conn) !void {
		return posix.epoll_ctl(self.q, linux.EPOLL.CTL_DEL, conn.stream.handle, null);
	}

	fn wait(self: *EPoll) !Iterator {
		const event_list = &self.event_list;
		const event_count = blk: while (true) {
			const rc = linux.syscall6(
				.epoll_pwait2,
				@as(usize, @bitCast(@as(isize, self.q))),
				@intFromPtr(event_list.ptr),
				event_list.len,
				0,
				0,
				@sizeOf(linux.sigset_t),
			);

			// taken from std.os.epoll_waits
			switch (posix.errno(rc)) {
				.SUCCESS => break :blk @as(usize, @intCast(rc)),
				.INTR => continue,
				.BADF => unreachable,
				.FAULT => unreachable,
				.INVAL => unreachable,
				else => unreachable,
			}
		};

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


fn HandlerConn(comptime H: type) type {
	return struct {
		conn: Conn,
		handler: H,
		next: ?*HandlerConn(H) = null,
		prev: ?*HandlerConn(H) = null,
	};
}

pub const Conn = struct {
	_closed: bool,
	_io_mode: IOMode,
	_rw_mode: RWMode,
	_socket_flags: usize,
	stream: net.Stream,

	const IOMode = enum {
		blocking,
		nonblocking,
	};

	const RWMode = enum {
		none,
		read,
		write,
	};

	pub fn blocking(self: *Conn) !void {
		// in blockingMode, io_mode is ALWAYS blocking, so we can skip this
		if (comptime lib.blockingMode() == false) {
			if (@atomicRmw(IOMode, &self._io_mode, .Xchg, .blocking, .monotonic) == .nonblock) {
				// we don't care if the above check + this call isn't atomic.
				// at worse, we're doing an unecessary syscall
				_ = try posix.fcntl(self.stream.handle, posix.F.SETFL, self.socket_flags & ~@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
			}
		}
	}

	// TODO: thread safety
	pub fn close(self: *Conn) void {
		self._closed = true;
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

	pub fn writeClose(self: *Conn) !void {
		return self.writeFramed(CLOSE_NORMAL);
	}

	pub fn writeCloseWithCode(self: *Conn, code: u16) !void {
		var buf: [2]u8 = undefined;
		std.mem.writeInt(u16, &buf, code, .Big);
		return self.writeFrame(.close, &buf);
	}

	pub fn writeFrame(self: *Conn, op_code: OpCode, data: []const u8) !void {
		const l = data.len;
		const stream = self.stream;

		// maximum possible prefix length. op_code + length_type + 8byte length
		var buf: [10]u8 = undefined;
		buf[0] = @intFromEnum(op_code);

		if (l <= 125) {
			buf[1] = @intCast(l);
			try stream.writeAll(buf[0..2]);
		} else if (l < 65536) {
			buf[1] = 126;
			buf[2] = @intCast((l >> 8) & 0xFF);
			buf[3] = @intCast(l & 0xFF);
			try stream.writeAll(buf[0..4]);
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
			try stream.writeAll(buf[0..]);
		}
		if (l > 0) {
			try stream.writeAll(data);
		}
	}

	// TODO: SO MUCH
	// (WouldBlock handling, thread safety...)
	pub fn writeFramed(self: Conn, data: []const u8) !void {
		try self.stream.writeAll(data);
	}
};

fn handleMessage(comptime H: type, handler: *H, conn: *Conn, message: Message) !void {
	const message_type = message.type;
	switch (message_type) {
		.text, .binary => {
			switch (comptime @typeInfo(@TypeOf(H.handleMessage)).Fn.params.len) {
				2 => try handler.handleMessage(message.data),
				3 => try handler.handleMessage(message.data, if (message_type == .text) .text else .binary),
				else => @compileError(@typeName(H) ++ ".handleMessage must accept 2 or 3 parameters"),
			}
			// TODO
			// reader.handled();
		},
		.pong => if (comptime std.meta.hasFn(H, "handlePong")) {
			try handler.handlePong();
		},
		.ping => {
			const data = message.data;
			if (comptime std.meta.hasFn(H, "handlePing")) {
				try handler.handlePing(data);
			} else if (data.len == 0) {
				try conn.writeFramed(EMPTY_PONG);
			} else {
				try conn.writeFrame(.pong, data);
			}
		},
		.close => {
			defer conn.close();
			const data = message.data;
			if (comptime std.meta.hasFn(H, "handleClose")) {
				return handler.handleClose(data);
			}

			const l = data.len;
			if (l == 0) {
				return conn.writeClose();
			}

			if (l == 1) {
				// close with a payload always has to have at least a 2-byte payload,
				// since a 2-byte code is required
				return conn.writeFramed(CLOSE_PROTOCOL_ERROR);
			}

			const code = @as(u16, @intCast(data[1])) | (@as(u16, @intCast(data[0])) << 8);
			if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
				return conn.writeFramed(CLOSE_PROTOCOL_ERROR);
			}

			if (l == 2) {
				return try conn.writeFramed(CLOSE_NORMAL);
			}

			const payload = data[2..];
			if (!std.unicode.utf8ValidateSlice(payload)) {
				// if we have a payload, it must be UTF8 (why?!)
				return try conn.writeFramed(CLOSE_PROTOCOL_ERROR);
			}
			return conn.writeClose();
		},
	}
}

fn closeAll(comptime H: type, conn_list: List(HandlerConn(H)), conn_pool: *std.heap.MemoryPool(HandlerConn(H)), shutdown: Config.Shutdown) void {
	var next_node = conn_list.head;
	while (next_node) |hc| {
		if (shutdown.notify_handler) {
			hc.handler.close();
		}

		const conn = &hc.conn;
		if (shutdown.notify_client) {
			conn.writeClose() catch {};
		}

		if (shutdown.close_socket) {
			posix.close(conn.stream.handle);
		}

		defer conn_pool.destroy(hc);
		next_node = hc.next;
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

// Doesn't neeed to worry about Conn's threadsafety since this can only be
// called from the initial thread that accepted the connection, well before
// the conn is handed off to the app.
fn preHandOffWrite(conn: *Conn, response: []const u8) void {
	const socket = conn.stream.handle;
	const timeout = std.mem.toBytes(posix.timeval{ .tv_sec = 5, .tv_usec = 0 });
	posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout) catch return;

	var pos: usize = 0;
	while (pos < response.len) {
		const n = posix.write(socket, response[pos..]) catch |err| switch (err) {
			error.WouldBlock => {
				if (conn._io_mode == .blocking) {
					// We were in blocking mode, which means we reached our timeout
					// We're done trying to send the response.
					return;
				}
				try conn.blocking();
				continue;
			},
			else => return,
		};

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
// Blocking worker has to guard this with a mutex
// NonBlocking worker doesn't have to guard this
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

const t = lib.testing;
test "List: insert & remove" {
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
