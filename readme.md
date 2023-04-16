A zig websocket server.

Zig 0.11-dev is rapidly changing and constantly breaking features. I'll try to keep this up to date as much as possible. Note that 0.11-dev currently does not support async, so I've reverted to threads.

See the [v0.10.1-compat](https://github.com/karlseguin/websocket.zig/tree/v0.10.1-compat) tag for a release that's compatible with Zig 0.10.1.

## Example
```zig
const websocket = @import("websocket");

// Define a struct for "global" data passed into your websocket handler
const Context = struct {

};

pub fn main() !void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = general_purpose_allocator.allocator();

    // this is the instance of your "global" struct to pass into your handlers
    var context = Context{}; 

    try websocket.listen(Handler, allocator,  &context, .{
        .path = "/",
        .port = 9223,
        .address = "127.0.0.1",
    });
}

const Handler = struct {
    client: *Client,
    context: *Context,

    pub fn init(method: []const u8, url: []const u8, client: *Client, context: *Context) !Handler {
        return Handler{
            .client = client,
            .context = context,
        };
    }

    pub fn handle(self: *Handler, message: Message) !void {
        const data = message.data;
        try self.client.write(data); // echo the messge back
    }

    // called whenever the connection is closed, can do some cleanup in ehre
    pub fn close(_: *Handler) void {}
};
```

The `handle` function takes a `message` which has a `type` and `data`field. The `type` will either be `text` or `binary`, but in 99% of cases, you can ignore it and just use `data`. This is an unfortunate part of the spec which differentiates between arbitrary byte data (binary) and valid UTF-8 (text). This library _does not_ reject text messages with invalid UTF-8. Again, in most cases, it doesn't matter and just wastes cycles. If you care about this, do like the autobahn test does and validate it in your handler.

## Autobahn
Every mandatory [Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite) case is passing. (Three fragmented UTF-8 are flagged as non-strict and as compression is not implemented, these are all flagged as "Unimplemented").

You can see `autobahn.zig` in the root of the project for the handler that's used for the autobahn tests.


## Config
The 4th parameter to `websocket.listen` is a configuration object. 

* `port` - Port to listen to. Default: `9223`,
* `path` - Path to accept the initial websocket handshake request on. Default: `"/"`
* `max_size` - Maximum incoming message size to allow. The server will dynamically allocate up to this much space per request. Default: `65536`,
* `buffer_size` - Size of the static buffer that's available per connection for incoming messages. While there's other overhead, the minimal memory usage of the server will be `# of active connections * buffer_size`. Default: 4096,
* `address` - Address to bind to. Default: `"127.0.0.1"``,
* `max_handshake_size` - The maximum size of the initial handshake to allow. Default: `1024`.

Setting `max_size == buffer_size` is valid and will ensure that only the initial `buffer_size` bytes will be allocated.

The reason for the separate configuration values of `max_handshake_size` and `buffer_size` is to reduce the cost of invalid handshakes. When the connection is first established, only `max_handshake_size` is allocated. Unless you're expecting a large url/querystring value or large headers, this value can be relatively small and thus limits the amount of resources committed. Only once the handshake is accepted is `buffer_size` allocated. However, keep in mind that the websocket handshake contains a number of mandatory headers, so `max_handshake_size` cannot be set super small either.

Websockets have their own fragmentation "feature" (not the same as TCP fragmentation) which this library could handle more efficiently. However, I'm not aware of any client (e.g. browsers) which use this feature at all.

## Testing
The library comes with some helpers for testing:

```zig
cosnt wt = @import("websocket").testing;

test "handler invalid message" {
    var wtt = wt.init();
    defer wtt.deinit();

    var handler = MyAppHandler{
        .client = &wtt.client,
    }

    handler.handle(wtt.textMessage("hack"));
    try wtt.expectText("invalid message");
}
```

For testing websockets, you usually care about two things: emulating incoming messages and asserting the messages sent to the client.

`wtt.client` is an instance of a `websocket.Client` which is usually passed to your handler's `init` function. For testing purposes, you can inject thing directly into your handler. The `wtt.expectText` asserts that the expected message was sent to the client. 

The `wtt.textMessage` generates a message that you can pass into your handle's `handle` function.

## http.zig
I'm also working on an HTTP 1.1 server for zig: [https://github.com/karlseguin/http.zig](https://github.com/karlseguin/http.zig).
