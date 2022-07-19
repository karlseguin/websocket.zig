const std = @import("std");
const t = @import("t.zig");
const builtin = @import("builtin");

const mem = std.mem;
const ascii = std.ascii;
const Allocator = mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const Request = @import("request.zig").Request;
const Handshake = @import("handshake.zig").Handshake;
const Fragmented = @import("fragmented.zig").Fragmented;

pub const TEXT_FRAME = 128 | 1;
pub const BIN_FRAME = 128 | 2;
pub const CLOSE_FRAME = 128 | 8;
pub const PING_FRAME = 128 | 9;
pub const PONG_FRAME = 128 | 10;

const whitespace: []const u8 = ascii.spaces[0..];

pub const MessageType = enum {
    continuation,
    text,
    binary,
    close,
    ping,
    pong,
    invalid,
};

const ParsePhase = enum {
    pre,
    header,
    payload,
};

const ReadFrameResultType = enum {
    message,
    fragment,
};

const ReadFrameResult = union(ReadFrameResultType) {
    message: Message,
    fragment: void,
};

const ReadState = struct {
    // The buffer that we're reading bytes into.
    buf: *Buffer,

    // If we're dealing with a fragmented message (websocket fragment, not tcp
    // fragment), the state of the fragmented message is maintained here.)
    fragment: *Fragmented,
};

pub const Error = error{
    Closed,
    InvalidMessageType,
    FragmentedControl,
    MessageTooLarge,
    NestedFragment,
    UnfragmentedContinuation,
    LargeControl,
    ReservedFlags,
};

// Wrap a std.net.Stream
// we use this so that we can test with a t.Stream
pub const NetStream = struct {
    stream: std.net.Stream,

    pub fn read(self: NetStream, buffer: []u8) !usize {
        return self.stream.read(buffer);
    }

    pub fn close(self: NetStream) void {
        return self.stream.close();
    }

    // Taken from io/Writer.zig (for writeAll) which calls the net.zig's Stream.write
    // function in this loop
    pub fn write(self: NetStream, data: []const u8) !void {
        var index: usize = 0;
        const h = self.stream.handle;
        while (index != data.len) {
            index += try std.event.Loop.instance.?.write(h, data[index..], false);
        }
    }
};

pub const Message = struct {
    type: MessageType,
    data: []const u8,
};

pub const Config = struct {
    max_size: usize,
    path: []const u8,
    buffer_size: usize,
    max_request_size: usize,
};

pub const Client = C(NetStream);

// Only use this internally, for testing, when we want a client that's based
// on our t.Stream instead of a net.Stream
fn C(comptime S: type) type {
    return struct {
        stream: S,
        closed: bool = false,

        const Self = @This();

        pub fn write(self: Self, data: []const u8) !void {
            try writeFrame(S, self.stream, BIN_FRAME, data);
        }

        pub fn writeText(self: Self, data: []const u8) !void {
            try writeFrame(S, self.stream, TEXT_FRAME, data);
        }

        pub fn close(self: *Self) void {
            self.closed = true;
        }
    };
}

pub fn handle(comptime H: type, comptime S: type, context: anytype, stream: S, config: Config, allocator: Allocator) void {
    defer stream.close();
    doHandle(H, S, context, stream, config, allocator) catch {
        return;
    };
}

pub fn doHandle(comptime H: type, comptime S: type, context: anytype, stream: S, config: Config, allocator: Allocator) !void {
    var request_buf = try allocator.alloc(u8, config.max_request_size);
    defer allocator.free(request_buf);
    const request = Request.read(S, stream, request_buf) catch |err| {
        try Request.close(S, stream, err);
        return;
    };

    if (isWebsocketRequest(request, config.path)) {
        try handleWebsocket(H, S, context, stream, request, config, allocator);
    }
}

fn isWebsocketRequest(request: []u8, targetPath: []const u8) bool {
    var index = mem.indexOfScalar(u8, request, ' ') orelse return false;
    const method = request[0..index];
    if (!ascii.eqlIgnoreCase("get", method)) {
        return false;
    }

    var path = mem.trim(u8, request[index..], whitespace);
    index = mem.indexOfScalar(u8, path, ' ') orelse return false;
    path = path[0..index];
    return ascii.eqlIgnoreCase(targetPath, path);
}

fn handleWebsocket(comptime H: type, comptime S: type, context: anytype, stream: S, request: []u8, config: Config, allocator: Allocator) !void {
    const h = Handshake.parse(request) catch |err| {
        try Handshake.close(S, stream, err);
        return;
    };
    try h.reply(S, stream);

    var buf = try Buffer.init(config.buffer_size, config.max_size, allocator);
    var state = &ReadState{
        .buf = &buf,
        .fragment = &Fragmented.init(allocator),
    };

    const client = &C(S){ .stream = stream };

    defer {
        buf.deinit();
        state.fragment.deinit();
    }

    var handler = try H.init(h.method, h.url, client, context);
    defer {
        handler.close();
    }

    while (true) {
        buf.next();
        const result = readFrame(S, stream, state) catch |err| {
            switch (err) {
                Error.LargeControl => try stream.write(CLOSE_PROTOCOL_ERROR),
                Error.ReservedFlags => try stream.write(CLOSE_PROTOCOL_ERROR),
                else => {},
            }
            return;
        };

        if (result) |message| {
            switch (message.type) {
                .text, .binary => {
                    try handler.handle(message);
                    state.fragment.reset();
                    if (client.closed) {
                        return;
                    }
                },
                .pong => {
                    // TODO update aliveness?
                },
                .ping => try handlePong(S, stream, message.data),
                .close => {
                    try handleClose(S, stream, message.data);
                    return;
                },
                else => unreachable,
            }
        }
    }
}

fn readFrame(comptime S: type, stream: S, state: *ReadState) !?Message {
    var buf = state.buf;
    var fragment = state.fragment;

    var data_needed: usize = 2; // always need at least the first two bytes to start figuring things out
    var phase = ParsePhase.pre;
    var header_length: usize = 0;
    var length_of_length: usize = 0;

    var masked = true;
    var message_type = MessageType.invalid;

    while (true) {
        if ((try buf.read(S, stream, data_needed)) == false) {
            return Error.Closed;
        }

        switch (phase) {
            ParsePhase.pre => {
                const msg = buf.message();
                var byte1 = msg[0];
                var byte2 = msg[1];
                masked = byte2 & 128 == 128;
                length_of_length = switch (byte2 & 127) {
                    126 => 2,
                    127 => 8,
                    else => 0,
                };
                phase = ParsePhase.header;
                header_length = 2 + length_of_length;
                if (masked) {
                    header_length += 4;
                }
                data_needed = header_length;

                message_type = switch (byte1 & 15) {
                    0 => MessageType.continuation,
                    1 => MessageType.text,
                    2 => MessageType.binary,
                    8 => MessageType.close,
                    9 => MessageType.ping,
                    10 => MessageType.pong,
                    else => return Error.InvalidMessageType,
                };

                // FIN, RSV1, RSV2, RSV3, OP,OP,OP,OP
                // none of the RSV bits should be set
                if (byte1 & 112 != 0) {
                    return Error.ReservedFlags;
                }

                if (length_of_length != 0 and (message_type == .ping or message_type == .close or message_type == .pong)) {
                    return Error.LargeControl;
                }
            },
            ParsePhase.header => {
                const msg = buf.message();
                var payload_length = switch (length_of_length) {
                    2 => @intCast(u16, msg[3]) | @intCast(u16, msg[2]) << 8,
                    8 => @intCast(u64, msg[9]) | @intCast(u64, msg[8]) << 8 | @intCast(u64, msg[7]) << 16 | @intCast(u64, msg[6]) << 24 | @intCast(u64, msg[5]) << 32 | @intCast(u64, msg[4]) << 40 | @intCast(u64, msg[3]) << 48 | @intCast(u64, msg[2]) << 56,
                    else => msg[1] & 127,
                };
                data_needed += payload_length;
                phase = ParsePhase.payload;
            },
            ParsePhase.payload => {
                const msg = buf.message();
                const fin = msg[0] & 128 == 128;
                var payload = msg[header_length..];
                if (masked) {
                    const mask = msg[header_length - 4 .. header_length];
                    applyMask(mask, payload);
                }

                if (fin) {
                    if (message_type == MessageType.continuation) {
                        if (try fragment.add(payload)) {
                            return Message{ .type = fragment.type, .data = fragment.buf };
                        }
                        return Error.UnfragmentedContinuation;
                    }

                    if (fragment.is_fragmented() and (message_type == MessageType.text or message_type == MessageType.binary)) {
                        return Error.NestedFragment;
                    }

                    // just a normal single-fragment message (most common case)
                    return Message{ .type = message_type, .data = payload };
                }

                switch (message_type) {
                    .continuation => {
                        if (try fragment.add(payload)) {
                            return null;
                        }
                        return Error.UnfragmentedContinuation;
                    },
                    .text, .binary => {
                        if (fragment.is_fragmented()) {
                            return Error.NestedFragment;
                        }
                        try fragment.new(message_type, payload);
                        return null;

                        // we're going to get a fragmented message
                        // var frag_buf = ArrayList(u8).init(allocator);
                    },
                    else => return Error.FragmentedControl,
                }
            },
        }
    }
}

fn applyMask(mask: []const u8, payload: []u8) void {
    @setRuntimeSafety(false);
    const word_size = @sizeOf(usize);

    // not point optimizing this if it's a really short payload
    if (payload.len < word_size * 2) {
        applyMaskSimple(mask, payload);
        return;
    }

    // We're going to xor this 1 word at a time.
    // But, our payload's length probably isn't a perfect multiple of word_size
    // so we'll first xor the bits until we have it aligned.
    var data = payload;
    const over = data.len % word_size;

    if (over > 0) {
        applyMaskSimple(mask, data[0..over]);
        data = data[over..];
    }

    var i: usize = 0;
    var mask_word: [word_size]u8 = undefined;
    while (i < word_size) {
        mask_word[i] = mask[(i + over) & 3];
        i += 1;
    }
    const mask_value = @bitCast(usize, mask_word);

    i = 0;
    while (i < data.len) {
        const slice = data[i .. i + word_size];
        std.mem.bytesAsSlice(usize, slice)[0] ^= mask_value;
        i += word_size;
    }
}

fn applyMaskSimple(mask: []const u8, payload: []u8) void {
    @setRuntimeSafety(false);
    for (payload) |b, i| {
        payload[i] = b ^ mask[i & 3];
    }
}

fn writeFrame(comptime S: type, stream: S, op_code: u8, data: []const u8) !void {
    const l = data.len;

    // maximum possible prefix length. op_code + length_type + 8byte length
    var buf: [10]u8 = undefined;
    buf[0] = op_code;

    if (l <= 125) {
        buf[1] = @intCast(u8, l);
        try stream.write(buf[0..2]);
    } else if (l < 65536) {
        buf[1] = 126;
        buf[2] = @intCast(u8, (l >> 8) & 0xFF);
        buf[3] = @intCast(u8, l & 0xFF);
        try stream.write(buf[0..4]);
    } else {
        buf[1] = 127;
        buf[2] = @intCast(u8, (l >> 56) & 0xFF);
        buf[3] = @intCast(u8, (l >> 48) & 0xFF);
        buf[4] = @intCast(u8, (l >> 40) & 0xFF);
        buf[5] = @intCast(u8, (l >> 32) & 0xFF);
        buf[6] = @intCast(u8, (l >> 24) & 0xFF);
        buf[7] = @intCast(u8, (l >> 16) & 0xFF);
        buf[8] = @intCast(u8, (l >> 8) & 0xFF);
        buf[9] = @intCast(u8, l & 0xFF);
        try stream.write(buf[0..]);
    }
    if (l > 0) {
        try stream.write(data);
    }
}

const EMPTY_PONG = ([2]u8{ PONG_FRAME, 0 })[0..];
fn handlePong(comptime S: type, stream: S, data: []const u8) !void {
    if (data.len == 0) {
        try stream.write(EMPTY_PONG);
    } else {
        try writeFrame(S, stream, PONG_FRAME, data);
    }
}

// CLOSE_FRAME, 2 lenght, code
const CLOSE_NORMAL = ([_]u8{ CLOSE_FRAME, 2, 3, 232 })[0..]; // code: 1000
const CLOSE_PROTOCOL_ERROR = ([_]u8{ CLOSE_FRAME, 2, 3, 234 })[0..]; //code: 1002

fn handleClose(comptime S: type, stream: S, data: []const u8) !void {
    const l = data.len;

    if (l == 0) {
        return try stream.write(CLOSE_NORMAL);
    }
    if (l == 1) {
        // close with a payload always has to have at least a 2-byte payload,
        // since a 2-byte code is required
        return try stream.write(CLOSE_PROTOCOL_ERROR);
    }
    const code = @intCast(u16, data[1]) | @intCast(u16, data[0]) << 8;
    if (code < 1000 or code == 1004 or code == 1005 or code == 1006 or (code > 1013 and code < 3000)) {
        return try stream.write(CLOSE_PROTOCOL_ERROR);
    }

    if (l == 2) {
        return try stream.write(CLOSE_NORMAL);
    }

    const payload = data[2..];
    if (!std.unicode.utf8ValidateSlice(payload)) {
        // if we have a payload, it must be UTF8 (why?!)
        return try stream.write(CLOSE_PROTOCOL_ERROR);
    }
    return try stream.write(CLOSE_NORMAL);
}

const TEST_BUFFER_SIZE = 512;
const TestContext = struct {};
const TestHandler = struct {
    client: *C(*t.Stream),

    pub fn init(_: []const u8, _: []const u8, client: *C(*t.Stream), _: TestContext) !TestHandler {
        return TestHandler{
            .client = client,
        };
    }

    // echo it back, so that it gets written back into our t.Stream
    pub fn handle(self: TestHandler, message: Message) !void {
        const data = message.data;
        switch (message.type) {
            .binary => try self.client.write(data),
            .text => try self.client.writeText(data),
            else => unreachable,
        }
    }

    pub fn close(_: TestHandler) void {}
};

test "mask" {
    const random = t.getRandom().random();
    const mask = [4]u8{ 10, 20, 55, 200 };

    var original = try t.allocator.alloc(u8, 10000);
    var payload = try t.allocator.alloc(u8, 10000);

    var size: usize = 0;
    while (size < 10000) {
        var slice = original[0..size];
        random.bytes(slice);
        std.mem.copy(u8, payload, slice);
        applyMask(mask[0..], payload[0..size]);

        for (slice) |b, i| {
            try t.expectEqual(b ^ mask[i & 3], payload[i]);
        }

        size += 1;
    }
    t.allocator.free(original);
    t.allocator.free(payload);
}

test "read messages" {
    {
        // simple small message
        var expected = .{Expect.text("over 9000!")};
        try testReadFrames(t.Stream.handshake().textFrame(true, "over 9000!"), &expected);
    }

    {
        // single message exactly TEST_BUFFER_SIZE
        // header will be 8 bytes, so we make the messae TEST_BUFFER_SIZE - 8 bytes
        const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 8);
        var expected = .{Expect.text(msg[0..])};
        try testReadFrames(t.Stream.handshake().textFrame(true, msg[0..]), &expected);
    }

    {
        // single message that is bigger than TEST_BUFFER_SIZE
        // header is 8 bytes, so if we make our message TEST_BUFFER_SIZE - 7, we'll
        // end up with a message which is exactly 1 byte larger than TEST_BUFFER_SIZE
        const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 7);
        var expected = .{Expect.text(msg[0..])};
        try testReadFrames(t.Stream.handshake().textFrame(true, msg[0..]), &expected);
    }

    {
        // single message that is much bigger than TEST_BUFFER_SIZE
        const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE * 2);
        var expected = .{Expect.text(msg[0..])};
        try testReadFrames(t.Stream.handshake().textFrame(true, msg[0..]), &expected);
    }

    {
        // multiple small messages
        var expected = .{ Expect.text("over"), Expect.text(" "), Expect.pong(""), Expect.text("9000"), Expect.text("!") };
        try testReadFrames(t.Stream.handshake()
            .textFrame(true, "over")
            .textFrame(true, " ")
            .ping()
            .textFrame(true, "9000")
            .textFrame(true, "!"), &expected);
    }

    {
        // two messages, individually smaller than TEST_BUFFER_SIZE, but
        // their total length is greater than TEST_BUFFER_SIZE (this is an important
        // test as it requires special handling since the two messages are valid
        // but don't fit in a single buffer)
        const msg1 = [_]u8{'a'} ** (TEST_BUFFER_SIZE - 100);
        const msg2 = [_]u8{'b'} ** 200;
        var expected = .{ Expect.text(msg1[0..]), Expect.text(msg2[0..]) };
        try testReadFrames(t.Stream.handshake()
            .textFrame(true, msg1[0..])
            .textFrame(true, msg2[0..]), &expected);
    }

    {
        // two messages, the first bigger than TEST_BUFFER_SIZE, the second smaller
        const msg1 = [_]u8{'a'} ** (TEST_BUFFER_SIZE + 100);
        const msg2 = [_]u8{'b'} ** 200;
        var expected = .{ Expect.text(msg1[0..]), Expect.text(msg2[0..]) };
        try testReadFrames(t.Stream.handshake()
            .textFrame(true, msg1[0..])
            .textFrame(true, msg2[0..]), &expected);
    }

    {
        // Simple fragmented (websocket fragementation)
        var expected = .{Expect.text("over 9000!")};
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, "over")
            .cont(true, " 9000!"), &expected);
    }

    {
        // large fragmented (websocket fragementation)
        const msg = [_]u8{'a'} ** (TEST_BUFFER_SIZE * 2 + 600);
        var expected = .{Expect.text(msg[0..])};
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, msg[0 .. TEST_BUFFER_SIZE + 100])
            .cont(true, msg[TEST_BUFFER_SIZE + 100 ..]), &expected);
    }

    {
        // Fragmented with control in between
        var expected = .{ Expect.pong(""), Expect.pong(""), Expect.text("over 9000!") };
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, "over")
            .ping()
            .cont(false, " ")
            .ping()
            .cont(true, "9000!"), &expected);
    }

    {
        // Large Fragmented with control in between
        const msg = [_]u8{'b'} ** (TEST_BUFFER_SIZE * 2 + 600);
        var expected = .{ Expect.pong(""), Expect.pong(""), Expect.text(msg[0..]) };
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, msg[0 .. TEST_BUFFER_SIZE + 100])
            .ping()
            .cont(false, msg[TEST_BUFFER_SIZE + 100 .. TEST_BUFFER_SIZE + 110])
            .ping()
            .cont(true, msg[TEST_BUFFER_SIZE + 110 ..]), &expected);
    }

    {
        // Empty fragmented messages
        var expected = .{Expect.text("")};
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, "")
            .cont(false, "")
            .cont(true, ""), &expected);
    }

    {
        // max-size control
        const msg = [_]u8{'z'} ** 125;
        var expected = .{Expect.pong(msg[0..])};
        try testReadFrames(t.Stream.handshake()
            .pingPayload(msg[0..]), &expected);
    }
}

test "readFrame erros" {
    {
        // Nested non-control fragmented (websocket fragementation)
        var expected = .{};
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, "over")
            .textFrame(false, " 9000!"), &expected);
    }

    {
        // Nested non-control fragmented FIN (websocket fragementation)
        var expected = .{};
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, "over")
            .textFrame(true, " 9000!"), &expected);
    }

    {
        // control too big
        const msg = [_]u8{'z'} ** 126;
        var expected = .{Expect.close(CLOSE_PROTOCOL_ERROR)};
        try testReadFrames(t.Stream.handshake()
            .pingPayload(msg[0..]), &expected);
    }

    {
        // reserved bit1
        var expected = .{Expect.close(CLOSE_PROTOCOL_ERROR)};
        var s = t.Stream.handshake().textFrameReserved(true, "over9000", 64);
        try testReadFrames(s, &expected);
    }

    {
        // reserved bit2
        var expected = .{Expect.close(CLOSE_PROTOCOL_ERROR)};
        var s = t.Stream.handshake().textFrameReserved(true, "over9000", 32);
        try testReadFrames(s, &expected);
    }

    {
        // reserved bit3
        var expected = .{Expect.close(CLOSE_PROTOCOL_ERROR)};
        var s = t.Stream.handshake().textFrameReserved(true, "over9000", 16);
        try testReadFrames(s, &expected);
    }
}

fn testReadFrames(s: *t.Stream, expected: []Expect) !void {
    defer s.deinit();
    errdefer s.deinit();

    var count: usize = 0;

    // we don't currently use this
    var context = TestContext{};

    // test with various random  TCP fragmentations
    // our t.Stream automatically fragments the frames on the first
    // call to read. Note this is TCP fragmentation, not websocket fragmentation
    const config = Config{
        .path = "/",
        .max_request_size = 512,
        .buffer_size = TEST_BUFFER_SIZE,
        .max_size = TEST_BUFFER_SIZE * 10,
    };
    while (count < 100) : (count += 1) {
        var stream = &s.clone();
        handle(TestHandler, *t.Stream, context, stream, config, t.allocator);
        try t.expectEqual(stream.closed, true);

        const r = Received.init(stream.received.items);
        const messages = r.messages;
        errdefer r.deinit();
        errdefer stream.deinit();

        try t.expectEqual(expected.len, messages.len);

        var i: usize = 0;
        while (i < expected.len) : (i += 1) {
            const e = expected[i];
            const actual = messages[i];
            try t.expectEqual(e.type, actual.type);
            try t.expectString(e.data, actual.data);
        }
        r.deinit();
        stream.deinit();
    }
}

const Expect = struct {
    type: MessageType,
    data: []const u8,

    fn text(data: []const u8) Expect {
        return .{
            .data = data,
            .type = .text,
        };
    }

    fn pong(data: []const u8) Expect {
        return .{
            .data = data,
            .type = .pong,
        };
    }

    fn close(data: []const u8) Expect {
        return .{
            // strip out the op_code + length
            .data = data[2..],
            .type = .close,
        };
    }
};

const Received = struct {
    messages: []Message,

    // We make some big assumptions about these messages.
    // Namely, we know that there's no websocket fragmentation, there's no
    // continuation and we know that there's only two ways a single message
    // will be fragmented:
    //  either 1 received message == 1 full frame (such as when we write a
    //       pre-generated message, like CLOSE_NORMAL)
    //  or when writeFrame is used, in which case we'd expect 2 messages:
    //       the first is the op_code + length, and the 2nd is the payload.
    //
    // There's a cleaner world where we'd let our real readFrame parse this.
    fn init(all: [][]const u8) Received {
        var i: usize = 0;
        // skip the handshake reply (at least for now)
        while (i < all.len) : (i += 1) {
            if (std.ascii.endsWithIgnoreCase(all[i], "\r\n\r\n")) {
                break;
            }
        }

        // move past the last received data, which was the end of our handshake
        var frames = all[i + 1 ..];

        var frame_index: usize = 0;
        var message_index: usize = 0;

        var messages = t.allocator.alloc(Message, frames.len) catch unreachable;
        while (frame_index < frames.len) : (frame_index += 1) {
            var f = frames[frame_index];
            const message_type = switch (f[0] & 15) {
                1 => MessageType.text,
                2 => MessageType.binary,
                8 => MessageType.close,
                10 => MessageType.pong,
                else => unreachable,
            };

            // Let's figure out if this message is all within this single frame
            // or if it's split between this frame and the next.
            // If it is split, then this frame will contain OP + LENGTH_PREFIX + LENGTH
            // and the next one will be the full payload (and nothing else)
            const length_of_length: u8 = switch (f[1] & 127) {
                126 => 2,
                127 => 8,
                else => 0,
            };

            const payload_length = switch (length_of_length) {
                2 => @intCast(u16, f[3]) | @intCast(u16, f[2]) << 8,
                8 => @intCast(u64, f[9]) | @intCast(u64, f[8]) << 8 | @intCast(u64, f[7]) << 16 | @intCast(u64, f[6]) << 24 | @intCast(u64, f[5]) << 32 | @intCast(u64, f[4]) << 40 | @intCast(u64, f[3]) << 48 | @intCast(u64, f[2]) << 56,
                else => f[1],
            };

            var payload: []const u8 = undefined;
            if (f.len >= 2 + length_of_length + payload_length) {
                payload = f[2 + length_of_length ..];
            } else {
                frame_index += 1;
                f = frames[frame_index];
                payload = f;
            }

            messages[message_index] = Message{
                .data = payload,
                .type = message_type,
            };
            message_index += 1;
        }
        return Received{ .messages = messages[0..message_index] };
    }

    fn deinit(self: Received) void {
        t.allocator.free(self.messages);
    }
};
