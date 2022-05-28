const client = @import("./websocket/client.zig");

pub const listen = @import("./websocket/listen.zig").listen;
pub const Client = client.Client;
pub const Message = client.Message;

test "test all" {
    _ = @import("websocket/client.zig");
    _ = @import("websocket/handshake.zig");
    _ = @import("websocket/fragmented.zig");
}
