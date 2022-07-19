const std = @import("std");
const websocket = @import("./websocket.zig");

const Allocator = std.mem.Allocator;

const Client = websocket.Client;
const Message = websocket.Message;
const Handshake = websocket.Handshake;

// THIS MUST BE PRESENT
pub const io_mode = .evented;

pub fn main() !void {
    const config = websocket.Config{
        .port = 9223,

        .address = "127.0.0.1",

        .path = "/",

        // Maximum allowed request sizes. Allocated to parse the request.
        // Only max_request_size will be allocated for non-websocket requests.
        .max_request_size = 1024,

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

    // abitrary context object that will get passed to your handler
    const context = Context{};
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    // Start websocket listening on the given port,
    // speficying the handler struct that will servi
    try websocket.listen(Handler, context, allocator, config);
}

const Context = struct {};

const Handler = struct {
    client: *Client,
    context: Context,

    pub fn init(_: []const u8, _: []const u8, client: *Client, context: Context) !Handler {
        return Handler{
            .client = client,
            .context = context,
        };
    }

    pub fn handle(self: *Handler, message: Message) !void {
        const data = message.data;
        switch (message.type) {
            .binary => try self.client.write(data),
            .text => {
                if (std.unicode.utf8ValidateSlice(data)) {
                    try self.client.writeText(data);
                } else {
                    self.client.close();
                }
            },
            else => unreachable,
        }
    }

    pub fn close(_: *Handler) void {}
};
