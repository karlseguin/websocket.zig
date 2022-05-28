const std = @import("std");
const t = @import("t.zig");

const Allocator = std.mem.Allocator;
const Handshake = @import("handshake.zig").Handshake;
const Fragmented = @import("fragmented.zig").Fragmented;

// Every client will get a [BUFFER_SIZE]u8 which we'll try to use as much
// as possible. However, for messages larger than BUFFER_SIZE, we'll need
// to allocate memory.
pub const BUFFER_SIZE = 8192;

pub const TEXT_FRAME = 128 | 1;
pub const BIN_FRAME = 128 | 2;
pub const CLOSE_FRAME = 128 | 8;
pub const PING_FRAME = 128 | 9;
pub const PONG_FRAME = 128 | 10;

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
    // Static of size BUFFER_SIZE, used for any message that will fit
    buf: []u8,

    // Dynamically allocated for messages larger than BUFFER_SIZE
    // Note that our dynamic buffer is always precisely sized for a specific
    // message, so we'll never read part of the next message into it, which
    // makes our life easier.
    dyn: ?[]u8,

    // How much we've read of the current message, could reference
    // the end of either buf of dyn
    read: usize,

    // Where in buf the message starts. For dyn, the start is always 0
    // since we allocate dyn for a specific message.
    start: usize,

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

pub const Client = C(NetStream);

// Only use this internally, for testing, when we want a client that's based
// on our t.Stream instead of a net.Stream
fn C(comptime S: type) type {
    return struct {
        closed: bool,
        stream: S,

        const Self = @This();

        pub fn write(self: Self, data: []const u8) !void {
            try writeFrame(S, self.stream, BIN_FRAME, data);
        }

        pub fn writeText(self: Self, data: []const u8) !void {
            try writeFrame(S, self.stream, TEXT_FRAME, data);
        }

        pub fn close(self: *Self) void {
            if (self.closed) {
                return;
            }
            self.closed = true;
            self.stream.close();
        }
    };
}
pub fn handle(comptime H: type, comptime S: type, context: anytype, stream: S, allocator: Allocator) void {
    // wrap this in case we want to do something fancy with error handling,
    // but as is, it's difficult, since a lot of these would just be normal things,
    // like the client disconnecting.
    do_handle(H, S, context, stream, allocator) catch {
        return;
    };
}

fn do_handle(comptime H: type, comptime S: type, context: anytype, stream: S, allocator: Allocator) !void {
    var buffer: [BUFFER_SIZE]u8 = undefined;
    var buf = buffer[0..];
    var state = &ReadState{ .read = 0, .start = 0, .buf = buf, .dyn = null, .fragment = &Fragmented.init(allocator) };

    const client = &C(S){ .stream = stream, .closed = false };

    defer {
        client.close();
        if (state.dyn) |dyn| {
            allocator.free(dyn);
        }
        state.fragment.deinit();
    }

    const h = Handshake.parse(S, stream, buf) catch |err| {
        try Handshake.close(S, stream, err);
        return;
    };
    try h.reply(S, stream);

    var handler = try H.init(h.method, h.url, client, context);
    defer {
        handler.close();
    }

    while (true) {
        const result = readFrame(S, stream, state, allocator) catch |err| {
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

                    if (state.dyn) |dyn| {
                        allocator.free(dyn);
                        state.dyn = null;
                    }
                    state.fragment.reset();
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
        } else if (state.dyn) |dyn| {
            allocator.free(dyn);
            state.dyn = null;
        }
    }
}

fn readFrame(comptime S: type, stream: S, state: *ReadState, allocator: Allocator) !?Message {
    var buf = state.buf;
    var read = state.read;
    var start = state.start;
    var fragment = state.fragment;

    var data_needed: usize = 2; // always need at least the first two bytes to start figuring things out
    var phase = ParsePhase.pre;
    var header_length: usize = 0;
    var length_of_length: usize = 0;

    // buf might switch from being our static buffer into a dynamic buffer. This
    // would only happen after we've parsed the header, in whic case the header
    // is in our static buffer, but our payload is in our dynamic buffer. We could
    // copy our header into our dynamic buffer, and then it wouldn't matter if
    // we switch. Instead, we'll capture the header data that we need in these
    // variables. It's safe to reference the static buffer here since it isn't
    // going to be used/changed for this message once we switch to dynamic buffer.
    var byte1: u8 = 0;
    var masked = true;
    var mask: [4]u8 = undefined;
    var message_type = MessageType.invalid;

    while (true) {
        if (read < data_needed) {
            var buf_start = start + read;
            if (data_needed > (buf.len - buf_start)) {
                std.mem.copy(u8, buf[0..], buf[start..buf_start]);
                start = 0;
                buf_start = start + read;
            }
            const n = try stream.read(buf[buf_start..]);
            if (n == 0) {
                return Error.Closed;
            }
            read += n;
            continue;
        }

        switch (phase) {
            ParsePhase.pre => {
                byte1 = buf[start];
                var byte2 = buf[start + 1];
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
                var payload_length = switch (length_of_length) {
                    2 => @intCast(u16, buf[start + 3]) | @intCast(u16, buf[start + 2]) << 8,
                    8 => @intCast(u64, buf[start + 9]) | @intCast(u64, buf[start + 8]) << 8 | @intCast(u64, buf[start + 7]) << 16 | @intCast(u64, buf[start + 6]) << 24 | @intCast(u64, buf[start + 5]) << 32 | @intCast(u64, buf[start + 4]) << 40 | @intCast(u64, buf[start + 3]) << 48 | @intCast(u64, buf[start + 2]) << 56,
                    else => buf[start + 1] & 127,
                };

                data_needed += payload_length;

                // buf data might move around (if our static buffer is at the end
                // we wrap around). We could move the buffer around too, but let's
                // just snapshot the 4 bytes, so much easier.
                const mask_end = start + header_length;
                std.mem.copy(u8, mask[0..], buf[mask_end - 4 .. mask_end]);

                if (data_needed > BUFFER_SIZE) {
                    // We require more data than will fit into our static buffer.
                    // It's time to allocate as much memory as we're going to need.

                    // TODO, we probably want a configurable max_message_size
                    // and to reject any payload which is larger
                    const dyn = try allocator.alloc(u8, payload_length);

                    // The header data is already in our static buffer, but that's
                    // ok because we already captured the important data (see the
                    // byte1, masked and mask variables).

                    // We've already read some of the payload, we need to copy
                    // this data into our new dynamic buffer
                    if (read > header_length) {
                        const payload_end = start + read;
                        const payload_start = start + header_length;
                        std.mem.copy(u8, dyn, buf[payload_start..payload_end]);
                        read = payload_end - payload_start;
                    } else {
                        read = 0;
                    }

                    start = 0;
                    header_length = 0;
                    buf = dyn;
                    state.dyn = dyn;
                    data_needed = payload_length;
                }
                phase = ParsePhase.payload;
            },
            ParsePhase.payload => {
                const fin = byte1 & 128 == 128;
                const payload_end = start + data_needed;
                const payload_start = start + header_length;
                var payload = buf[payload_start..payload_end];

                if (masked) {
                    applyMask(mask, payload);
                }

                if (state.dyn != null) {
                    state.start = 0;
                    state.read = 0;
                } else {
                    state.start = payload_end;
                    state.read = read - data_needed;
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

fn applyMask(mask: [4]u8, payload: []u8) void {
    // TODO: this can be partially unrolled
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

test "read messages" {
    {
        // simple small message
        var expected = .{Expect.text("over 9000!")};
        try testReadFrames(t.Stream.handshake().textFrame(true, "over 9000!"), &expected);
    }

    {
        // single message exactly BUFFER_SIZE
        // header will be 8 bytes, so we make the messae BUFFER_SIZE - 8 bytes
        const msg = [_]u8{'a'} ** (BUFFER_SIZE - 8);
        var expected = .{Expect.text(msg[0..])};
        try testReadFrames(t.Stream.handshake().textFrame(true, msg[0..]), &expected);
    }

    {
        // single message that is bigger than BUFFER_SIZE
        // header is 8 bytes, so if we make our message BUFFER_SIZE - 7, we'll
        // end up with a message which is exactly 1 byte larger than BUFFER_SIZE
        const msg = [_]u8{'a'} ** (BUFFER_SIZE - 7);
        var expected = .{Expect.text(msg[0..])};
        try testReadFrames(t.Stream.handshake().textFrame(true, msg[0..]), &expected);
    }

    {
        // single message that is much bigger than BUFFER_SIZE
        const msg = [_]u8{'a'} ** (BUFFER_SIZE * 2);
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
        // two messages, individually smaller than BUFFER_SIZE, but
        // their total length is greater than BUFFER_SIZE (this is an important
        // test as it requires special handling since the two messages are valid
        // but don't fit in a single buffer)
        const msg1 = [_]u8{'a'} ** (BUFFER_SIZE - 100);
        const msg2 = [_]u8{'b'} ** 200;
        var expected = .{ Expect.text(msg1[0..]), Expect.text(msg2[0..]) };
        try testReadFrames(t.Stream.handshake()
            .textFrame(true, msg1[0..])
            .textFrame(true, msg2[0..]), &expected);
    }

    {
        // two messages, the first bigger than BUFFER_SIZE, the second smaller
        const msg1 = [_]u8{'a'} ** (BUFFER_SIZE + 100);
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
        const msg = [_]u8{'a'} ** (BUFFER_SIZE * 2 + 600);
        var expected = .{Expect.text(msg[0..])};
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, msg[0 .. BUFFER_SIZE + 100])
            .cont(true, msg[BUFFER_SIZE + 100 ..]), &expected);
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
        const msg = [_]u8{'b'} ** (BUFFER_SIZE * 2 + 600);
        var expected = .{ Expect.pong(""), Expect.pong(""), Expect.text(msg[0..]) };
        try testReadFrames(t.Stream.handshake()
            .textFrame(false, msg[0 .. BUFFER_SIZE + 100])
            .ping()
            .cont(false, msg[BUFFER_SIZE + 100 .. BUFFER_SIZE + 110])
            .ping()
            .cont(true, msg[BUFFER_SIZE + 110 ..]), &expected);
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
        var s = t.Stream.handshake().textFrame(true, "over9000");
        s.frames.items[1][0] |= 64; // index 0 is the handshake
        try testReadFrames(s, &expected);
    }

    {
        // reserved bit2
        var expected = .{Expect.close(CLOSE_PROTOCOL_ERROR)};
        var s = t.Stream.handshake().textFrame(true, "over9000");
        s.frames.items[1][0] |= 32; // index 0 is the handshake
        try testReadFrames(s, &expected);
    }

    {
        // reserved bit3
        var expected = .{Expect.close(CLOSE_PROTOCOL_ERROR)};
        var s = t.Stream.handshake().textFrame(true, "over9000");
        s.frames.items[1][0] |= 16; // index 0 is the handshake
        try testReadFrames(s, &expected);
    }
}

fn testReadFrames(s: *t.Stream, expected: []Expect) !void {
    defer s.deinit();

    var count: usize = 0;

    // we don't currently use this
    var context = TestContext{};

    // test with various random  TCP fragmentations
    // our t.Stream automatically fragments the frames on the first
    // call to read. Note this is TCP fragmentation, not websocket fragmentation
    while (count < 100) : (count += 1) {
        var stream = &s.clone();
        handle(TestHandler, *t.Stream, context, stream, t.allocator);
        try t.expectEqual(stream.closed, true);

        const r = Received.init(stream.received.items);
        const messages = r.messages;

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
