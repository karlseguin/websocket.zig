# A zig websocket server.
This project follows Zig master. See available branches if you're targetting a specific version.

# Server
```zig
const ws = @import("websocket");

// Define a struct for "global" data passed into your websocket handler
// This is whatever you want. You pass it to `listen` and the library will
// pass it back to your handler's `init`. For simple cases, this could be empty
const Context = struct {

};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Arbitrary (application-specific) data to pass into each handler
    // Could be Void ({}) if you don't have any data to pass

    var app = App{
        //.db =  a pool of db connections, for example
    };

    var server = try websocket.Server(Handler).init(allocator, .{
        .port = 9224,
        .address = "127.0.0.1",
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            .max_headers = 10,
        },
    });

    // this blocks
    server.listen();
}

// This is your application-specific wrapper around a websocket connection
const Handler = struct {
    app: *App,
    conn: *ws.Conn,

    // You must define a public init function which takes
    pub fn init(h: ws.Handshake, conn: *ws.Conn, app: *App) !Handler {
        // `h` contains the initial websocket "handshake" request
        // It can be used to apply application-specific logic to verify / allow
        // the connection (e.g. valid url, query string parameters, or headers)

        _ = h; // we're not using this in our simple case

        return .{
            .app = app,
            .conn = conn,
        };
    }

    // You must defined a public clientMessage method
    pub fn clientMessage(self: *Handler, data: []u8) !void {
        const data = message.data;
        try self.conn.write(data); // echo the message back
    }
};
```

## Handler
When you create a `websocket.Server(Handler)`, the specified `Handler` is your structure which will receive messages. It must have a public `init` function and `clientMessage` method. Other methods, such as `close` can optionally be defined.

### init
The `init` method is called with a `websocket.Handshake`, a `*websocket.Conn` and whatever app-specific value was passed into `Server(H).init`. 

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

### clientMessage
The `clientMessage` method is called whenever a text or binary message is received.

The `clientMessage` method can take one of four shapes. The simplest, shown in the first example, is:

```zig
// simple clientMessage
clientMessage(h: *Handler, data: []const u8) !void
```

The Websocket specific has a distinct message type for text and binary. Text messages must be valid UTF-8. Websocket.zig does not do this validation (it's expensive and most apps don't care). However, if you do care about the distinction, your `clientMessage` can take another parameter:

```zig
// clientMessage that accepts a tpe to differentiate between messages
// sent as `text` vs those sent as `binary`. Either way, Websocket.zig
// does not validate that text data is valid UTF-8.
clientMessage(h: *Handler, data: []const u8, tpe: ws.Message.TextType) !void
```

Finally, `clientMessage` can take an optional `std.mem.Allocator`. If you need to dynamically allocate memory within `clientMessage`, consider using this allocator. It is a fast thread-local buffer that fallsback to an arena allocator. Allocations made with this allocator are freed after `clientMessage` returns:

```zig
// clientMessage that takes an allocator
clientMessage(h: *Handler, allocator: Allocator, data: []const u8) !void`

// cilentMessage that takes an allocator AND a Message.TextType
clientMessage(h: *Handler, allocator: Allocator, data: []const u8, tpe: ws.Message.TextType) !void`
```

If `clientMessage` returns an error, the connection is closed. You can also call `conn.close()` within the method.

### close
If your handler define `close(handler: *Handler)` method, the method is called whenever the connection is being closed. Guaranteed to be called exactly once, so it is safe to deinitialize the `handler` at this point. This is called no mater the reason for the closure (on shutdown, if the client closed the connection, if your code close the connection, ...)

The socket may or may not still be alive.

### clientClose
If your handler define `clientClose(handler: *Handler, data: []const u8) !void` method, the function will be called whenever a `close` message is received from the client. 

You almost certainly *do not* want to define this method and instead want to use `close()`. When not defined, websocket.zig follows the websocket specific and replies with its own matching close message.

### clientPong
If your handler define `clientPong(handler: *Handler) !void` method, the function will be called whenever a `pong` message is received from the client. When not defined, no action is taken.

### clientPong
If your handler define `clientPing(handler: *Handler, data: []const u8) !void` method, the function will be called whenever `ping` message is received from the client. When not defined, websocket.zig will write a corresponding `pong` reply.

## websocket.Conn
The call to `init` includes a `*websocket.Conn`. It is expected that handlers will keep a reference to it. The main purpose of the `*Conn` is to write data via `conn.write([]const u8)` and `conn.writeBin([]const u8)`. The websocket protocol differentiates between a "text" and "binary" message, with the only difference that "text" must be valid UTF-8. This library does not enforce this. Which you use really depends on what your client expects. For browsers, text messages appear as strings, and binary messages appear as a Blob or ArrayBuffer (depending on how the client is configured).

`conn.close()` can also be called to close the connection. Calling `conn.close()` **will** result in the handler's `close` callback being called. 

You can also use `conn.closeWithCode(code: u16)` and `conn.closeWithReason(code: u16, reason: []const u8)`. Refer to [RFC6455](https://datatracker.ietf.org/doc/html/rfc6455#section-7.4.1) for valid codes. The `reason` must be <= 123 bytes.

### Writer
It's possible to get a `std.io.Writer` from a `*Conn`. Because websocket messages are framed, the writter will buffer the message in memory and requires an explicit "flush". Buffering will use the global buffer pool (described in the Config section), but can still result in dynamic allocations if the pool is empty or the message being written is larger than the configured max size.

```zig
// .text or .binary
var wb = try conn.writeBuffer(.text);
defer wb.deinit();

try std.fmt.format(wb.writer(), "it's over {d}!!!", .{9000});

try wb.flush();
```

## Thread Safety
Websocket.zig ensures that only 1 message per connection/handler is processed at a time. Therefore, you will never have concurrent calls to `clientMessage`, `clientPing`, `clientPong` or `clientClose`. Conversely, concurrent calls to methods of `*websocket.Conn` are allowed (i.e. `conn.write` and `conn.close`). 

## Config
The 2nd parameter to `Server(H).init` is a configuration object. 

```zig
pub const Config = struct {
    port: u16 = 9882,

    // Ignored if unix_path is set
    address: []const u8 = "127.0.0.1",

    // Not valid on windows
    unix_path: ?[]const u8 = null,

    // In nonblocking mode (Linux/Mac/BSD), sets the number of
    // listening threads. Defaults to 1.
    // In blocking mode, this is ignored and always set to 1.
    worker_count: ?u8 = null,

    // The maximum number of connections, per worker.
    max_conn: usize = 16_384,

    // The maximium allows message size. 
    // A websocket message can have up to 14 bytes of overhead/header
    max_message_size: usize = 65_536,

    handshake: Config.Handshake = .{},
    thread_pool: ThreadPool = .{},
    buffers: Config.Buffers = .{},

    // In blocking mode the thread pool isn't used 
    pub const ThreadPool = struct {
        // Number of threads to process messages.
        // These threads are where your `clientXYZ` method will execute.
        // Default: 4.
        count: ?u16 = null,

        // The maximum number of pending requests that the thread pool will accept
        // This applies back pressure to worker and ensures that, under load
        // pending requests get precedence over processing new requests.
        // Default: 500.
        backlog: ?u32 = null,

        // Size of the static buffer to give each thread. Memory usage will be 
        // `count * buffer_size`.
        // If clientMessage isn't defined with an Allocator, this defaults to 0.
        // Else it default to 32768
        buffer_size: ?usize = null,
    };

    const Handshake = struct {
        // time, in seconds, to timeout the initial handshake request
        timeout: u32 = 10,

        // Max size, in bytes, allowed for the initial handshake request.
        // If you're expected a large handshake (many headers, large cookies, etc)
        // you'll need to set this larger.
        // Default: 1024
        max_size: ?u16 = null,

        // Max number of headers to capture. These become available as
        // handshake.headers.get(...).
        // Default: 0
        max_headers: ?u16 = null,

        // Count of handshake objects to keep in a pool. More are created
        // as needed.
        // Default: 32
        count: ?u16 = null,
    };

    const Buffers = struct {
        // The number of "small" buffers to keep pooled.
        //
        // When `null`, the small buffer pool is disabled and each connection
        // gets its own dedicated small buffer (of `size`). This is reasonable
        // when you expect most clients to be sending a steady stream of data.
        
        // When set > 0, a pool is created (of `size` buffers) and buffers are 
        // assigned as messages are received. This is reasonable when you expect
        // sporadic and messages from clients.
        //
        // Default: `null`
        pool: ?usize = null,

        // The size of each "small" buffer. Depending on the value of `pool`
        // this is either a per-connection buffer, or the size of pool buffers
        // shared between all connections
        // Default: 2048
        size: ?usize = null,

        // The number of large buffers to have in the pool.
        // Messages larger than `buffers.size` but smaller than `max_message_size`
        // will attempt to use a large buffer from the pool.
        // If the pool is empty, a dynamic buffer is created.
        // Default: 8
        large_count: ?u16 = null,

        // The size of each large buffer.
        // Default: smallest of  `2 * buffers.size` or `max_message_size`
        large_size: ?usize = null,
    };
}
```
The handshake pool/buffer is separate from the main `buffer` to reduce the memory cost of invalid handshakes. Unless you're expecting a very large handshake request (a large URL, querystring or headers), the initial handshake is usually < 1KB. This data is also short-lived. Once the websocket is established however, you may want a larger buffer for handling incoming requests (and this buffer is generally much longer lived). By using a small pooled buffer for the initial handshake, invalid connections don't use up [as much] memory and thus the server may be more resilient to basic DOS attacks. Keep in mind that the websocket protocol requires a number of mandatory headers, so `handshake_max_size` can't be set to a super small value. Also keep in mind that the current pool implementation does not block when empty, but rather creates dynamic buffers of `handshake_max_size`.

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

### Blocking Mode
kqueue (BSD, MacOS) or epoll (Linux) are used on supported platforms. On all other platforms (most notably Windows), a more naive thread-per-connection with blocking sockets is used.

The comptime-safe, `websocket.blockingMode() bool` function can be called to determine which mode websocket is running in (when it returns `true`, then you're running the simpler blocking mode).

It is possible to force blocking mode by adding the <code>websocket_blocking = true</code> build option in your build.zig (it is **not** possible to force non blocking mode)

```zig
var websocket_module =  b.dependency("websocket", dep_opts);
const options = b.addOptions();
options.addOption(bool, "websocket_blocking", true);
websocket_module.addOptions("build", options);
```

### Per-Connection Buffers
In non-blocking mode, the `buffers.pool` and `buffers.size` should be set for your particular use case. When `buffers.pool == null`, each connection gets its own buffer of `buffers.size` bytes. This is a good option if you expect most of your clients to be sending a steady stream of data. While it might take more memory (# of connections * buffers.size), its faster and minimizes multi-threading overhead.

However, if you expect clients to only send messages sporadically, such as a chat application, enabling the pool can reduce memory usage at the cost of a bit of overhead.

In blocking mode, these settings are ignored and each connection always gets its own buffer (though there is still a shared large buffer pool).

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
        try self.client.handshake(path, .{
            .timeout_ms = 5000,
            .headers = "Host: 127.0.0.1:9223",
        });
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

The above is an example of how you might want to use `websocket.Client`. The link between the library's `websocket.Client` and your application's `Handler` is very thin. Your handler will hold the client in order to write to the server and close the connection. But it is only the call to `client.readLoopInNewThread(HANDLER)` or `client.readLoop(HANDLER)` which connects the client to your handler.

The above example could be rewritten to more cleanly separate the application's Handler and the library's Client:

```zig
var client = try websocket.connect(allocator, "localhost", 9001, .{});
defer client.deinit();

const path = "/";
try client.handshake(path, .{
    .timeout_ms = 5000
    .headers = "Host: localhost:9001",
});

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

Setting `max_size == buffer_size` is valid and will ensure that no dynamic memory allocation occurs once the connection is established.

Zig only supports TLS 1.3, so this library can only connect to hosts using TLS 1.3. If no `ca_bundle` is provided, the library will create a default bundle per connection.

### Performance Optimization 1 - CA Bundle
For a high number of connections, it might be beneficial to manage our own CA bundle:

```zig
// some global data
var ca_bundle = std.crypto.Certificate.Bundle{}
try ca_bundle.rescan(allocator);
defer ca_bundle.deinit(allocator);
```

And then assign this `ca_bundle` into the the configuration's `ca_bundle` field. This way the library does not have to create and scan the installed CA certificates for each client connection.

### Performance Optimization 2 - Buffer Provider
For a high nummber of connections, or code that is especially sensitive to memory allocations, a large buffer pool can be created and provided to each client:

```zig
// Create a buffer pool of 10 buffers, each being 32K
const buffer_provider = try websocket.bufferProvider(allocator, 10, 32768);
defer buffer_provider.deinit();


// create your client(s) using the above created buffer_provider
var client = try websocket.connect(allocator, "localhost", 9001, .{
    ...
    .buffer_provider = buffer_provider,
});
```

This allows each client to have a reasonable `buffer_size` that can accomodate most messages, while having an efficient fallback for the occasional large message. When `max_size` is greater than the large buffer pool size (32K in the above example) or when all pooled buffers are used, a dynamic buffer is created.
 
## Handshake
The handshake sends the initial HTTP-like request to the server. A `timeout` in milliseconds can be specified. You can pass arbitrary headers to the backend via the `headers` option. However, the full handshake request must fit within the configured `buffer_size`. By default, the request size is about 150 bytes (plus the length of the URL).

## Handler and Read Loop
A websocket client typically listens for messages from the server, within a blocking loop. The `readLoop` function begins such a loop and will block until the connection is closed (either by the server, or by calling `close`). As an alternative, `readLoopInNewThread` can be called which will start the `readLoop` in a new thread and return a `std.thread.Thread`. Typically one would call `detach` on this thread. Both `readLoop` and `readLoopInNewThread` take an arbitrary handler which will be called with any received messages. This handler must implement the `handle` and `close` methods as shown in the above example.

`close` will always be called when the read loop exits.

It is safe to call `client.write`, `client.writeBin` and `client.close` from a thread other than the read loop thread.

# Autobahn
Every mandatory [Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite) case is passing. (Three fragmented UTF-8 are flagged as non-strict and as compression is not implemented, these are all flagged as "Unimplemented").

You can see `support/autobahn/server/main.zig` and `support/autobahn/client/main.zig` for the handler that's used for the autobahn tests.

## http.zig
I'm also working on an HTTP 1.1 server for zig: [https://github.com/karlseguin/http.zig](https://github.com/karlseguin/http.zig).
