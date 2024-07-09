const std = @import("std");
const lib = @import("lib.zig");

const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.websocket);

const Conn = lib.Conn;
const Reader = lib.Reader;
const buffer = lib.buffer;
const Message = lib.Message;
const Handshake = lib.Handshake;
const OpCode = lib.framing.OpCode;

const MAX_TIMEOUT = 2_147_483_647;
const DEFAULT_MAX_HANDSHAKE_SIZE = 1024;

const EMPTY_PONG = ([2]u8{ @intFromEnum(OpCode.pong), 0 })[0..];
// CLOSE, 2 length, code
const CLOSE_NORMAL = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ @intFromEnum(OpCode.close), 2, 3, 234 })[0..]; //code: 1002

pub const Config = struct {
	port: ?u16 = null,
	address: []const u8 = "127.0.0.1",
	max_size: usize = 65536,
	buffer_size: usize = 4096,
	unix_path: ?[]const u8 = null,

	handshake: Config.Handshake = .{},
	large_buffers: Config.LargeBuffers = .{},

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

		const Self = @This();

		pub fn init(allocator: Allocator, config: Config) !Self {
			const buffer_pool = try allocator.create(buffer.Pool);
			errdefer allocator.destroy(buffer_pool);

			const large_buffer_count = config.large_buffers.count orelse 32;
			buffer_pool.* = try buffer.Pool.init(allocator, large_buffer_count, config.large_buffers.size orelse 32768);
			errdefer buffer_pool.deinit();

			const buffer_provider = buffer.Provider.init(allocator, buffer_pool, large_buffer_count);

			return .{
				.cond = .{},
				.config = config,
				.allocator = allocator,
				.buffer_provider = buffer_provider,
			};
		}

		pub fn deinit(self: *Self) void {
			self.buffer_provider.pool.deinit();
			self.allocator.destroy(self.buffer_provider.pool);
		}

		pub fn listenInNewThread(self: *Self) !Thread {
			return try Thread.spawn(.{}, Server.listen, .{self});
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

			defer posix.close(socket);

			if (comptime lib.blockingMode()) {
				var w = Blocking(H).init(self);
				const thrd = try std.Thread.spawn(.{}, Blocking(H).listen, .{&w, socket, context});

				// is this really the best way?
				var mutex = Thread.Mutex{};
				mutex.lock();
				self.cond.wait(&mutex);
				mutex.unlock();
				w.stop();
				thrd.join();
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

		pub fn init(server: *Server(H)) Self {
			const config = &server.config;
			return .{
				.running = true,
				.config = config,
				.allocator = server.allocator,
				.buffer_provider = &server.buffer_provider,
				.handshake_timeout = Timeout.init(config.handshake.timeout orelse MAX_TIMEOUT),
				.handshake_max_size = config.handshake.max_size orelse DEFAULT_MAX_HANDSHAKE_SIZE,
				.handshake_max_headers = config.handshake.max_headers orelse 0,
			};
		}

		pub fn deinit(self: *const Self) void {
			_ = self;
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
			var conn = Conn{
				._closed = false,
				._rw_mode = .none,
				._io_mode = .blocking,
				.stream = .{.handle = socket},
			};

			const config = self.config;
			var handler = (try self.doHandshake(&conn, context)) orelse return;

			defer if (comptime std.meta.hasFn(H, "close")) {
				handler.close();
			};

			var reader = Reader.init(config.buffer_size, config.max_size, self.buffer_provider) catch |err| {
				log.err("Failed to create a Reader, connection is being closed. The error was: {}", .{err});
				return;
			};
			defer reader.deinit();

			if (comptime std.meta.hasFn(H, "afterInit")) {
				handler.afterInit() catch return;
			}

			while (true) {
				const message = reader.readMessage(conn.stream) catch |err| {
					switch (err) {
						error.LargeControl => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
						error.ReservedFlags => conn.writeFramed(CLOSE_PROTOCOL_ERROR) catch {},
						else => {},
					}
					return;
				};
				handleMessage(H, &handler, &conn, message) catch return;
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
