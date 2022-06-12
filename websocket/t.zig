const std = @import("std");

const mem = std.mem;
const ArrayList = std.ArrayList;

pub const expect = std.testing.expect;
pub const allocator = std.testing.allocator;

pub const expectEqual = std.testing.expectEqual;
pub const expectError = std.testing.expectError;
pub const expectString = std.testing.expectEqualStrings;

pub fn getRandom() std.rand.DefaultPrng {
    var seed: u64 = undefined;
    std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
    return std.rand.DefaultPrng.init(seed);
}

pub const Stream = struct {
    closed: bool,
    buf_index: usize,
    read_index: usize,
    frames: ArrayList([]u8),
    to_read: ArrayList([]const u8),
    random: std.rand.DefaultPrng,
    received: ArrayList([]const u8),

    pub fn init() Stream {
        return .{
            .closed = false,
            .buf_index = 0,
            .read_index = 0,
            .random = getRandom(),
            .frames = ArrayList([]u8).init(allocator),
            .to_read = ArrayList([]const u8).init(allocator),
            .received = ArrayList([]const u8).init(allocator),
        };
    }

    // init's the stream + sets up a valid handshake
    const h = "GET / HTTP/1.1\r\n" ++
        "Connection: upgrade\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Sec-websocket-version: 13\r\n" ++
        "Sec-websocket-key: leto\r\n\r\n";

    pub fn handshake() Stream {
        var s = init();

        // is all this really necessary?
        // I think so since everything else in s.frames is dynamically allocated
        // and owned by s.frames

        var buf = allocator.alloc(u8, h.len) catch unreachable;
        mem.copy(u8, buf, h);
        s.frames.append(buf) catch unreachable;
        return s;
    }

    // When bytes are added via add, the call to read will return the
    // bytes exactly as they were added, provided the destination has
    // enough space. This is different than adding the bytes via a frame
    // method which will cause random fragmentation (those framing methods
    // ultimate end up calling add).
    pub fn add(self: *Stream, value: []const u8) *Stream {
        // Take ownership of this data so that we can consistently free each
        // (necessary because we need to allocate data for frames)
        var copy = allocator.alloc(u8, value.len) catch unreachable;
        mem.copy(u8, copy, value);
        self.to_read.append(copy) catch unreachable;
        return self;
    }

    pub fn fragmentedAdd(self: *Stream, value: []const u8) *Stream {
        // Take ownership of this data so that we can consistently free each
        // (necessary because we need to allocate data for frames)
        var copy = allocator.alloc(u8, value.len) catch unreachable;
        mem.copy(u8, copy, value);

        // Adding this to frames, instead of to_read, means that, when we
        // first call read, we'll randomly fragment these. A bit messy, but
        // this dummy stream has grown up oddly.
        self.frames.append(copy) catch unreachable;
        return self;
    }

    pub fn ping(self: *Stream) *Stream {
        return self.pingPayload("");
    }

    pub fn pingPayload(self: *Stream, payload: []const u8) *Stream {
        return self.frame(true, 9, payload);
    }

    pub fn textFrame(self: *Stream, fin: bool, payload: []const u8) *Stream {
        return self.frame(fin, 1, payload);
    }

    pub fn cont(self: *Stream, fin: bool, payload: []const u8) *Stream {
        return self.frame(fin, 0, payload);
    }

    pub fn frame(self: *Stream, fin: bool, op_code: u8, payload: []const u8) *Stream {
        const l = payload.len;

        var buf: []u8 = undefined;

        var mask_start: usize = 2;
        if (l <= 125) {
            buf = allocator.alloc(u8, l + 6) catch unreachable;
            buf[1] = 128 | @intCast(u8, l);
        } else if (l < 65536) {
            buf = allocator.alloc(u8, l + 8) catch unreachable;
            buf[1] = 128 | 126;
            buf[2] = @intCast(u8, (l >> 8) & 0xFF);
            buf[3] = @intCast(u8, l & 0xFF);
            mask_start = 4;
        } else {
            buf = allocator.alloc(u8, l + 14) catch unreachable;
            buf[1] = 128 | 127;
            buf[2] = @intCast(u8, (l >> 56) & 0xFF);
            buf[3] = @intCast(u8, (l >> 48) & 0xFF);
            buf[4] = @intCast(u8, (l >> 40) & 0xFF);
            buf[5] = @intCast(u8, (l >> 32) & 0xFF);
            buf[6] = @intCast(u8, (l >> 24) & 0xFF);
            buf[7] = @intCast(u8, (l >> 16) & 0xFF);
            buf[8] = @intCast(u8, (l >> 8) & 0xFF);
            buf[9] = @intCast(u8, l & 0xFF);
            mask_start = 10;
        }

        // now that we've allocated buf (since we didn't know the size before)
        // we can set our first bit
        if (fin) {
            buf[0] = 128 | op_code;
        } else {
            buf[0] = op_code;
        }

        const payload_start = mask_start + 4;
        const mask = buf[mask_start..payload_start];

        // self.random.random().bytes(mask);
        mask[0] = 0;
        mask[1] = 0;
        mask[2] = 0;
        mask[3] = 0;
        for (payload) |b, i| {
            buf[payload_start + i] = b ^ mask[i & 3];
        }

        self.frames.append(buf) catch unreachable;
        return self;
    }

    pub fn read(self: *Stream, buf: []u8) !usize {
        std.debug.assert(!self.closed);

        // The first time we call read with frames we will fragment the messages.
        // So if we have 2 frames, we could end up with 2 or more to_read.
        if (self.frames.items.len > 0) {
            var random = self.random.random();
            for (self.frames.items) |f| {
                var data = f;
                while (data.len > 0) {
                    const l = random.uintAtMost(usize, data.len - 1) + 1;
                    _ = self.add(data[0..l]);
                    data = data[l..];
                }
                allocator.free(f);
            }
            self.frames.deinit();
            self.frames.items.len = 0;
        }

        const items = self.to_read.items;
        if (self.read_index == items.len) {
            return 0;
        }

        var data = items[self.read_index][self.buf_index..];
        if (data.len > buf.len) {
            // we have more data than we have space in buf (our target)
            // we'll fill the target buffer, and keep track of where
            // we our in our source buffer, so that that on the next read
            // we'll use the same source buffer, but at the offset
            self.buf_index += buf.len;
            data = data[0..buf.len];
        } else {
            // ok, fully read this one, next time we can move on
            self.buf_index = 0;
            self.read_index += 1;
        }

        for (data) |b, i| {
            buf[i] = b;
        }

        return data.len;
    }

    // store messages that are written to the stream
    pub fn write(self: *Stream, data: []const u8) !void {
        std.debug.assert(!self.closed);
        var copy = allocator.alloc(u8, data.len) catch unreachable;
        mem.copy(u8, copy, data);
        self.received.append(copy) catch unreachable;
    }

    pub fn close(self: *Stream) void {
        self.closed = true;
    }

    // self should continue to be valid after this call (since we can clone
    // it multiple times)
    pub fn clone(self: *Stream) Stream {
        var c = Stream.init();
        for (self.frames.items) |f| {
            var copy = allocator.alloc(u8, f.len) catch unreachable;
            mem.copy(u8, copy, f);
            c.frames.append(copy) catch unreachable;
        }
        return c;
    }

    pub fn deinit(self: *Stream) void {
        for (self.to_read.items) |buf| {
            allocator.free(buf);
        }
        self.to_read.deinit();

        if (self.frames.items.len > 0) {
            for (self.frames.items) |buf| {
                allocator.free(buf);
            }
            self.frames.deinit();
        }

        if (self.received.items.len > 0) {
            for (self.received.items) |buf| {
                allocator.free(buf);
            }
            self.received.deinit();
        }

        self.* = undefined;
    }
};
