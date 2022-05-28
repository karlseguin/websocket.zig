const std = @import("std");
const websocket = @import("./websocket.zig");

const Allocator = std.mem.Allocator;

const Client = websocket.Client;
const Message = websocket.Message;
const Handshake = websocket.Handshake;

// THIS MUST BE PRESENT
pub const io_mode = .evented;

pub fn main() !void {
    // abitrary context object that will get passed to your handler
    const context = Context{};
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    // Start websocket listening on the given port,
    // speficying the handler struct that will servi
    try websocket.listen(Handler, context, allocator, 9223);
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
