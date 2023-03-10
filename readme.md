A zig websocket server.

Zig 0.11-dev is rapidly changing and constantly breaking features. I'll try to keep this up to date as much as possible. Note that 0.11-dev currently does not support async, so I've reverted to threads.

See the [v0.10.1-compat](https://github.com/karlseguin/websocket.zig/tree/v0.10.1-compat) tag for a release that's compatible with Zig 0.10.1.

Right now, this is just a fun side project. But every mandatory [Autobahn Testsuite](https://github.com/crossbario/autobahn-testsuite) case is passing. (Three fragmented UTF-8 are flagged as non-strict and as compression is not implemented, these are all flagged as "Unimplemented").

Look at autobahn.zig for example usage. This is the code that starts the server and responds to autobahn tests request. It's essentially an echo server but should be straightforward to adapt.

Note that the `handle` function takes a `message` which has a `type` and `data`field. The `type` will either be `text` or `binary`, but in 99% of cases, you can ignore it and just use `data`. This is an unfortunate part of the spec which differentiates between arbitrary byte data (binary) and valid UTF-8 (text). This library _does not_ reject text messages with invalid UTF-8. Again, in most cases, it doesn't matter and just wastes cycles. If you care about this, do like the autobahn test does and validate it in your handler.

When starting the server, a `buffer_size` and `max_size` must be specified. Each connection will have `buffer_size` bytes allocated. However, up to `max_size` will be allocated as needed for messages larger than `buffer_size`. Setting `max_size` == `buffer_size` is valid and will ensure that only the initial `buffer_size` bytes will be allocated.

Websockets have their own fragmentation "feature" (not the same as TCP fragmentation) which is not handled efficiently at this time (but, I don't think this websocket fragmentation is being used at all).

(There will be addition changes to how buffers behave)
