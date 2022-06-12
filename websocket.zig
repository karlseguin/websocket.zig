const std = @import("std");
const client = @import("./websocket/client.zig");

const l = @import("./websocket/listen.zig");

pub const listen = l.listen;
pub const Config = l.Config;
pub const Client = client.Client;
pub const Message = client.Message;

comptime {
    std.testing.refAllDecls(@This());
}
