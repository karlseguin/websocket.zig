const std = @import("std");
const websocket = @import("./src/websocket.zig");

const Conn = websocket.Conn;
const Message = websocket.Message;
const Handshake = websocket.Handshake;

pub const std_options = .{
	.log_scope_levels = &[_]std.log.ScopeLevel{
		.{.scope = .websocket, .level = .warn},
	}
};

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.detectLeaks();

	const allocator = gpa.allocator();

	var server = try websocket.Server(Handler).init(allocator, .{
		.port = 9223,

		.address = "127.0.0.1",

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

		.handshake = .{
			.timeout = 3,
			.max_size = 1024,
			.max_headers = 10,
		},
	});
	defer server.deinit();

	// abitrary context object that will get passed to your handler
	var context = Context{};

	// Start websocket listening on the given port,
	// speficying the handler struct that will servi
	try server.listen(&context);
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

	pub fn handleMessage(self: *Handler, data: []const u8, tpe: websocket.Message.TextType) !void {
		switch (tpe) {
			.binary => try self.conn.writeBin(data),
			.text => {
				if (std.unicode.utf8ValidateSlice(data)) {
					try self.conn.writeText(data);
				} else {
					self.conn.close();
				}
			},
		}
	}

	pub fn close(_: *Handler) void {}
};
