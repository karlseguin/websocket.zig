A zig websocket server.

Zig 0.12-dev is rapidly changing and constantly breaking features. I'll try to keep this up to date as much as possible. Note that 0.12-dev currently does not support async, so I've reverted to threads.

See the [v0.10.1-compat](https://github.com/karlseguin/websocket.zig/tree/v0.10.1-compat) tag for a release that's compatible with Zig 0.10.1.

# Server
The server is meant to be flexible and easy to use. Until async is re-added to zig, every connection spawns a thread. We try to limit the creation of resources until after a successful handshake (this can be fine-tuned via the configuration).

## Example
```zig
const websocket = @import("websocket");
const Conn = websocket.Conn;
const Message = websocket.Message;
const Handshake = websocket.Handshake;

// Define a struct for "global" data passed into your websocket handler
// This is whatever you want. You pass it to `listen` and the library will
// pass it back to your handler's `init`. For simple cases, this could be empty
const Context = struct {

};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    // this is the instance of your "global" struct to pass into your handlers
    var context = Context{}; 

    try websocket.listen(Handler, allocator, &context, .{
        .port = 9223,
        .max_headers = 10,
        .address = "127.0.0.1",
    });
}

const Handler = struct {
    conn: *Conn,
    context: *Context,

    pub fn init(h: Handshake, conn: *Conn, context: *Context) !Handler {
        // `h` contains the initial websocket "handshake" request
        // It can be used to apply application-specific logic to verify / allow
        // the connection (e.g. valid url, query string parameters, or headers)

        _ = h; // we're not using this in our simple case

        return Handler{
            .conn = conn,
            .context = context,
        };
    }

    // optional hook that, if present, will be called after initialization is complete
    pub fn afterInit(self: *Handler) !void {}

    pub fn handle(self: *Handler, message: Message) !void {
        const data = message.data;
        try self.conn.write(data); // echo the message back
    }

    // called whenever the connection is closed, can do some cleanup in here
    pub fn close(_: *Handler) void {}
};
```

### init
The `init` method is called with a `websocket.Handshake`, a `*websocket.Conn` and whatever `context` value was passed as the 3rd parameter to `websocket.listen`. If you were building a chat application, you might have a ChannelManager that you want your handler to interact with. You would create a context with your `channel_manager`, pass that context to `listen`, and get that context back in `init`, where you can do with it what you want (e.g. store it as a field of your handler and use it in the `handle` function).

The websocket specification requires the initial "handshake" to contain certain headers and values. The library validates these headers. However applications may have additional requirements before allowing the connection to be "upgraded" to a websocket connection. For example, a one-time-use token could be required in the querystring. Applications should use the provided `websocket.Handshake` to apply any application-specific verification and optionally return an error to terminate the connection.

The `websocket.Handshake` exposes the following fields:

* `url: []const u8` - URL of the request in its original casing
* `method: []const u8` - Method of the request in its original casing
* `raw_headers: []const u8` - The raw "key1: value1\r\nkey2: value2\r\n" headers. Keys are lowercase.

If you set the `max_headers` configuration value to > 0, then you can use `req.headers.get("HEADER_NAME")` to extract a header value from the given name:

```zig
// get returns a ?[]const u8
// the name is lowercase
// the value is in its original case
const token = handshake.headers.get("authorization") orelse {
    return error.NotAuthorized;
}
...
```

Memory referenced by the `websocket.Handshake`, including headers from `handshake.headers` will be freed after the call to `init` completes. Application that need these values to exist beyond the call to `init` must make a copy.

### handle
The `handle` function takes a `message` which has a `type` and `data` field. The `type` will either be `text` or `binary`, but in 99% of cases, you can ignore it and just use `data`. This is an unfortunate part of the spec which differentiates between arbitrary byte data (binary) and valid UTF-8 (text). This library _does not_ reject text messages with invalid UTF-8. Again, in most cases, it doesn't matter and just wastes cycles. If you care about this, do like the autobahn test does and validate it in your handler.

If `handle` returns an error, the connection is closed.

### close
Called whenever the connection terminates. By the time `close` is called, there is no guarantee about the state of the underlying TCP connection (it may or may not be closed).

## websocket.Conn
The call to `init` includes a `*websocket.Conn`. It is expected that handlers will keep a reference to it. The main purpose of the `*Conn` is to write data via `conn.write([]const u8)` and `conn.writeBin([]const u8)`. The websocket protocol differentiates between a "text" and "binary" message, with the only difference that "text" must be valid UTF-8. This library does not enforce this. Which you use really depends on what your client expects. For browsers, text messages appear as strings, and binary messages appear as a Blob or ArrayBuffer (depending on how the client is configured).

`conn.close()` can also be called to close the connection. Calling `conn.close()` **will** result in the handler's `close` callback being called.

### Pings, Pongs and Close
By default, the library answers incoming `ping` messages with a corresponging `pong`. Similarly, when a `close` message is received, a `close` reply is sent (as per the spec).

When configured with `handle_ping` and/or `handle_pong` and/or `handle_close`, the messages are passed to the `handle` method and no automatic handling is done. 

This is an advanced feature. 

```zig
pub fn handle(self: Handler, message: Message) !void {
    switch (message.type) {
        .binary, .text => try self.conn.write(message.data),
        .ping => try self.conn.writeFrame(websocket.OpCode.pong, message.data),
        .pong => {}, 
        .close => try self.conn.writeFrame(websocket.OpCode.close, [_]u8{3, 232});
    }
}

```

## Config
The 4th parameter to `websocket.listen` is a configuration object. 

* `port` - Port to listen to. Default: `9223`.
* `max_size` - Maximum incoming message size to allow. The server will dynamically allocate up to this much space per request. Default: `65536`.
* `buffer_size` - Size of the static buffer that's available per connection for incoming messages. While there's other overhead, the minimal memory usage of the server will be `# of active connections * buffer_size`. Default: `4096`.
* `address` - Address to bind to. Default: `"127.0.0.1"`.
* `handshake_pool_count` - The number of buffers to create and keep for reading the initial handshake. Default: `50`
* `handshake_max_size` - The maximum size of the initial handshake to allow. Default: `1024`.
* `max_headers` - The maximum size of headers to store in `handshake.headers`. Requests with more headers will still be processed, but `handshake.headers` will only contain the first `max_headers` headers. Default: `0`.
* `handshake_timeout_ms` - The time, in milliseconds, to wait for the handshake to complete. This essentially prevents a client from opening a connection and "hanging" the thread while it waits for data. If a client slowly sends a few bytes at a time, the actual timeout might happen up to 2x longer than specified. Generally speaking, it might be better to let a proxy (e.g. nginx) handle this. Default 10_000;
 `handle_ping` - Whether ping messages should be sent to the handler. When true, the libray will not automatically answer with a pong. Default: `false`.
* `handle_pong` - Whether pong messages should be sent to the handler. 
* `handle_close` - Whether close messages should be sent to the handler.  When true, the library will not automatically answer with a corresponding `close` However, the readLoop will exists and the connection will be closed.

Setting `max_size == buffer_size` is valid and will ensure that no dynamic memory allocation occurs once the connection is established.

The server allocates and keep around `handshake_pool_size * handshake_max_size` bytes at all times. If the handshake buffer pool is empty, new buffers of `handshake_max_size` are dynamically created.

The handshake pool/buffer is separate from the main `buffer_size` to reduce the memory cost of invalid handshakes. Unless you're expecting a very large handshake request (a large URL, querystring or headers), the initial handshake is usually < 1KB. This data is also short-lived. Once the websocket is established however, you may want a larger buffer for handling incoming requests (and this buffer is generally much longer lived). By using a small pooled buffer for the initial handshake, invalid connections don't use up [as much] memory and thus the server may be more resilient to basic DOS attacks. Keep in mind that the websocket protocol requires a number of mandatory headers, so `handshake_max_size` can't be set to a super small value. Also keep in mind that the current pool implementation does not block when empty, but rather creates dynamic buffers of `handshake_max_size`.

Websockets have their own fragmentation "feature" (not the same as TCP fragmentation) which this library could handle more efficiently. However, I'm not aware of any client (e.g. browsers) which use this feature at all.

## Advanced

### Pre-Framed Comptime Message
Websocket message have their own special framing. When you use `conn.write` or `conn.writeBin` the data you provide is "framed" into a correct websocket message. Framing is fast and cheap (e.g., it DOES NOT require an O(N) loop through the data). Nonetheless, there may be be cases where pre-framing messages at compile-time is desired. The `websocket.frameText` and `websocket.frameBin` can be used for this purpose:

```zig
const UNKNOWN_COMMAND = websocket.frameText("unknown command");
...

pub fn handle(self: *Handler, message: Message) !void {
    const data = message.data;
    if (std.mem.startsWith(u8, data, "join: ")) {
        self.handleJoin(data)
    } else if (std.mem.startsWith(u8, data, "leave: ")) {
        self.handleLead(data)
    } else {
        try self.conn.writeFramed(UNKNOWN_COMMAND);
    }
}
```

## Testing
The library comes with some helpers for testing:

```zig
cosnt wt = @import("websocket").testing;

test "handler invalid message" {
    var wtt = wt.init();
    defer wtt.deinit();

    var handler = MyAppHandler{
        .conn = &wtt.conn,
    }

    handler.handle(wtt.textMessage("hack"));
    try wtt.expectText("invalid message");
}
```

For testing websockets, you usually care about two things: emulating incoming messages and asserting the messages sent to the client.

`wtt.conn` is an instance of a `websocket.Conn` which is usually passed to your handler's `init` function. For testing purposes, you can inject it directly into your handler. The `wtt.expectText` asserts that the expected message was sent to the conn. 

The `wtt.textMessage` generates a message that you can pass into your handle's `handle` function.

# Client
The websocket client implementation is currently a work in progress. Feedback on the API is welcome.

## Example
```zig
const std = @import("std");
const websocket = @import("websocket");

const Handler = struct {
    client: websocket.Client,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !Handler {
        return .{
            .client = try websocket.connect(allocator, host, port, .{}),
        };
    }

    pub fn deinit(self: *Handler) void {
        self.client.deinit();
    }

    pub fn connect(self: *Handler, path: []const u8) !void {
        try self.client.handshake(path, .{.timeout_ms = 5000});
        const thread = try self.client.readLoopInNewThread(self);
        thread.detach();
    }

    pub fn handle(_: Handler, message: websocket.Message) !void {
        const data = message.data;
        std.debug.print("CLIENT GOT: {any}\n", .{data});
    }

    pub fn write(self: *Handler, data: []u8) !void {
        return self.client.write(data);
    }

    pub fn close(_: Handler) void {}
};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    var handler = try Handler.init(allocator, "127.0.0.1", 9223);
    defer handler.deinit();

    // spins up a thread to listen to new messages
    try handler.connect("/");

    var data = try allocator.dupe(u8, "hello world");
    try handler.write(data);

    // without this, we'll exit immediately without having time to receive a
    // message from the server
    std.time.sleep(std.time.ns_per_s);
}
```

The above is an example of how you might want to use `websocket.Client`. The link between the library's `websocket.Client` and your application's` `Handler` is very thin. Your handler will hold the client in order to write to the server and close the connection. But it is only the call to `client.readLoopInNewThread(HANDLER)` or `client.readLoop(HANDLER)` which connects the client to your handler.

The above example could be rewritten to more cleanly separate the application's Handler and the library's Client:

```zig
var client = try websocket.connect(allocator, "localhost", 9001, .{});
defer client.deinit();

const path = "/";
try client.handshake(path, .{.timeout_ms = 5000});

const handler = Handler{.client = &client};
const thread = try client.readLoopInNewThread(handler);
thread.detach();

...
const Handler = struct {
    client: *websocket.Client,

    pub fn handle(self: Handler, message: websocket.Message) !void {
        const data = message.data;
        try self.client.write(data); // echo the message back
    }

    pub fn close(_: Handler) void {
    }
};
```

### Client
The main methods of `*websocket.Client` are:

* `writeBin([]u8)` - To write binary data
* `writeText([]u8)` - To write text data
* `write([]u8)` - Alias to `writeText`
* `close()` - Sends a close message and closes the connection

As you can see, these methods take a `[]u8`, not a `[]const u8` as they **will** mutate the data (websocket payloads are always masked). If you don't want the data mutated, pass a dupe. (By not just automatically duping the data, the library allows the application to decide if whether the data can be mutated or not, and thus whether to pay the dupe performance cost or not).

More advanced methods are:
* `closeWithCode(u16)` - Sends a close message with the specified code and closes the connection
* `writePing([]u8)` - Writes a ping frame
* `writePong([]u8)` - Writes a pong frame
* `writeFrame(websocket.OpCode, []u8) - Writes an arbitrary frame`. `OpCode` is an enum with possible values of: `text`, `binary`, `close`, `ping`, `pong`

### Pings, Pongs and Close
By default, the client answers incoming `ping` messages with a corresponging `pong`. By default, when the client receives a `close` message, it calls `client.close() which replies with a `close` frame and closes the underlying socket.

When configured with `handle_ping` and/or `handle_pong` and/or `handle_close`, the messages are passed to the `handle` method and no automatic handling is done. 

This is an advanced feature. Handlers are strongly encourages to call `client.writePong` in response to a `ping` and to call `client.close` in response to a `close`.

```zig
pub fn handle(self: Handler, message: websocket.Message) !void {
    switch (message.type) {
        .binary, text => try self.client.write(message.data); // echo the message back
        .ping => try self.client.writePong(@constCast(message.data)), // @constCast is safe
        .pong => {}, // noop
        .close => client.close(),
    }
}
```

## Config
The 3rd parameter to `connect` is a configuration object. 

* `max_size` - Maximum incoming message size to allow. The library will dynamically allocate up to this much space per request. Default: `65536`.
* `buffer_size` - Size of the static buffer that's available for the client to process incoming messages. While there's other overhead, the minimal memory usage of the server will be `# of active clients * buffer_size`. Default: `4096`.
* `tls` - Whether or not to connect over TLS. Only TLS 1.3 is supported. Default: `false`.
* `ca_bundle` - Provide a custom `std.crypto.Certificate.Bundle`. Only meaningful when `tls = true`. Default: `null`.
* `handle_ping` - Whether ping messages should be sent to the handler. When true, the client will not automatically answer with a pong. Default: `false`.
* `handle_pong` - Whether pong messages should be sent to the handler. 
* `handle_close` - Whether close messages should be sent to the handler.  When true, the client will not automatically answer with a corresponding `close` and will not close the underlying socket. However, the readLoop will still exists. If `true`, handlers are strongly encouraged to call `client.close()` when receiving a close message.
* `write_timeout_ms` - u32 - Timeout for writes. Default: `0` (writes won't timeout)

Setting `max_size == buffer_size` is valid and will ensure that no dynamic memory allocation occurs once the connection is established.

Zig only supports TLS 1.3, so this library can only connect to hosts using TLS 1.3. If no `ca_bundle` is provided, the library will create a default bundle per connection. For a high number of connections, it might be beneficial to manage our own CA bundle:

```zig
// some global data
var ca_bundle = std.crypto.Certificate.Bundle{}
try ca_bundle.rescan(allocator);
defer ca_bundle.deinit(allocator);
```

And then assign this `ca_bundle` into the the configuration's `ca_bundle`field.
 
## Handshake
The handshake sends the initial HTTP-like request to the server. A `timeout` in milliseconds can be specified. You can pass arbitrary headers to the backend via the `headers` option. However, the full handshake request must fit within the configured `buffer_size`. By default, the request size is about 150 bytes (plus the length of the URL).

## Handler and Read Loop
A websocket client typically listens for messages from the server, within a blocking loop. The `readLoop` function begins such a loop and will block until the connection is closed (either by the server, or by calling `close`). As an alternative, `readLoopInNewThread` can be called which will start the `readLoop` in a new thread and return a `std.thread.Thread`. Typically one would call `detach` on this thread. Both `readLoop` and `readLoopInNewThread` take an arbitrary handler which will be called with any received messages. This handler must implement the `handle` and `close` methods as shown in the above example.

`close` will always be called when the read loop exits.

It is safe to call `client.write`, `client.writeBin` and `client.close` from a thread other than the read loop thread.

# Autobahn
Every mandatory [Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite) case is passing. (Three fragmented UTF-8 are flagged as non-strict and as compression is not implemented, these are all flagged as "Unimplemented").

You can see `autobahn_server.zig` and `autobahn_client.zig` in the root of the project for the handler that's used for the autobahn tests.

## http.zig
I'm also working on an HTTP 1.1 server for zig: [https://github.com/karlseguin/http.zig](https://github.com/karlseguin/http.zig).
