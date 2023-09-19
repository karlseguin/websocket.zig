const std = @import("std");
const websocket = @import("./src/websocket.zig");

const Allocator = std.mem.Allocator;

const Conn = websocket.Conn;
const Message = websocket.Message;
const Handshake = websocket.Handshake;

// THIS MUST BE PRESENT
pub const io_mode = .evented;

pub fn main() !void {
	var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = general_purpose_allocator.detectLeaks();

	const allocator = general_purpose_allocator.allocator();


	// abitrary context object that will get passed to your handler
	var context = Context{};

	const config = websocket.Config.Server{
		.port = 9223,

		.address = "127.0.0.1",
		.handshake_timeout_ms = 3000,

		// We initialize and keep in memory `handshake_pool_size` buffers, each of
		// `handshake_max_size` at all time. This is used to parse the initial
		// handshake request. If the pool is empty and new connections come in,
		// then buffers of `handshake_max_size` are dynamically allocated as needed.
		.handshake_pool_size = 10,

		// See handshake_pool_size
		.handshake_max_size = 1024,

		// On connection, each client will get buffer_size bytes allocated
		// to process messages. This will be a single allocation and will only
		// be allocated after the request has been successfully parsed and
		// identified as a websocket request.
		.buffer_size = 8192,

		// Maximum allowed message size. If max_size == buffer_size, then the
		// system will never allocate more than the initial buffer_size.
		// The system will dynamically allocate up to max_size bytes to deal
		// with messages large than buffer_size. There is no guarantee around
		// how long (or short) this memory will remain allocated.
		// Messages larger than max_size will be rejected.

		// IMPORTANT NOTE: autobahn tests with large messages (16MB).
		// You almost certainly want to use a small value here.
		.max_size = 20_000_000,
	};

	// Start websocket listening on the given port,
	// speficying the handler struct that will servi
	try websocket.listen(Handler, allocator, &context, config);
}

const Context = struct {};

const Handler = struct {
	conn: *Conn,
	context: *Context,

	pub fn init(_: Handshake, conn: *Conn, context: *Context) !Handler {
		return Handler{
			.conn = conn,
			.context = context,
		};
	}

	pub fn handle(self: *Handler, message: Message) !void {
		const data = message.data;
		switch (message.type) {
			.binary => try self.conn.writeBin(data),
			.text => {
				if (std.unicode.utf8ValidateSlice(data)) {
					try self.conn.write(data);
				} else {
					self.conn.close();
				}
			},
			else => unreachable,
		}
	}

	pub fn close(_: *Handler) void {}
};
