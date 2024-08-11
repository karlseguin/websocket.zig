const std = @import("std");
const websocket = @import("websocket");

const Conn = websocket.Conn;
const Message = websocket.Message;
const Handshake = websocket.Handshake;
const Allocator = std.mem.Allocator;

pub const std_options = .{ .log_scope_levels = &[_]std.log.ScopeLevel{
    .{ .scope = .websocket, .level = .warn },
} };

var nonblocking_server: websocket.Server(Handler) = undefined;
var nonblocking_bp_server: websocket.Server(Handler) = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    if (@import("builtin").os.tag != .windows) {
        defer _ = gpa.detectLeaks();

        std.posix.sigaction(std.posix.SIG.TERM, &.{
            .handler = .{ .handler = shutdown },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        }, null);
    }

    const t1 = try startNonBlocking(allocator);
    const t2 = try startNonBlockingBufferPool(allocator);

    t1.join();
    t2.join();

    nonblocking_server.deinit();
    nonblocking_bp_server.deinit();
}

fn startNonBlocking(allocator: Allocator) !std.Thread {
    nonblocking_server = try websocket.Server(Handler).init(allocator, .{
        .port = 9224,
        .address = "127.0.0.1",
        .buffers = .{
            .small_pool = 0,
            .small_size = 8192,
        },
        // autobahn tests with large messages (16MB).
        // You almost certainly want to use a small value here.
        .max_message_size = 20_000_000,
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            .max_headers = 10,
        },
    });
    return try nonblocking_server.listenInNewThread({});
}

fn startNonBlockingBufferPool(allocator: Allocator) !std.Thread {
    nonblocking_bp_server = try websocket.Server(Handler).init(allocator, .{
        .port = 9225,
        .address = "127.0.0.1",
        .buffers = .{
            .small_pool = 3,
            .small_size = 8192,
        },
        // autobahn tests with large messages (16MB).
        // You almost certainly want to use a small value here.
        .max_message_size = 20_000_000,
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            .max_headers = 10,
        },
    });
    return try nonblocking_bp_server.listenInNewThread({});
}

const Context = struct {};

const Handler = struct {
    conn: *Conn,

    pub fn init(_: Handshake, conn: *Conn, ctx: void) !Handler {
        _ = ctx;
        return .{ .conn = conn };
    }

    pub fn clientMessage(self: *Handler, data: []const u8, tpe: websocket.Message.TextType) !void {
        switch (tpe) {
            .binary => try self.conn.writeBin(data),
            .text => {
                if (std.unicode.utf8ValidateSlice(data)) {
                    try self.conn.writeText(data);
                } else {
                    self.conn.close(.{.code = 1007}) catch {};
                }
            },
        }
    }
};

fn shutdown(_: c_int) callconv(.C) void {
    nonblocking_server.stop();
    nonblocking_bp_server.stop();
}
