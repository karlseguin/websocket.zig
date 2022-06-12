const std = @import("std");
const t = @import("t.zig");

const Allocator = std.mem.Allocator;

pub const BufferError = error{
    TooLarge,
};

// Somewhat generic wrapper around a re-usable "static" buffer which can switch
// to a larger dynamically allocated buffer as needed. Specifically designed
// to read data from a socket witha known length (e.g. length-prefixed).
pub const Buffer = struct {
    // Start position in buf of active data
    start: usize,

    // Length of active data. Can span more than one message
    // buf[start..start + len]
    len: usize,

    // Length of active message. message_len is always <= read_len
    // buf[start..start + message_len]
    message_len: usize,

    // Maximum size that we'll dynamically allocate
    max_size: usize,

    // The current buffer, will reference either static or dynamic
    buf: []u8,

    // Our static buffer. Initialized upfront.
    static: []u8,

    // Dynamic buffer, Initialized for messages larger than static.len
    dynamic: ?[]u8,

    allocator: Allocator,

    pub fn init(static_size: usize, max_size: usize, allocator: Allocator) !Buffer {
        const static = try allocator.alloc(u8, static_size);
        return Buffer{
            .start = 0,
            .len = 0,
            .message_len = 0,
            .buf = static,
            .static = static,
            .dynamic = null,
            .max_size = max_size,
            .allocator = allocator,
        };
    }

    // Reads at least to_read bytes and returns true
    // When read fails, returns false
    pub fn read(self: *Buffer, comptime S: type, stream: S, to_read: usize) !bool {
        var len = self.len;

        if (to_read < len) {
            // we already have to_read bytes available
            self.message_len = to_read;
            return true;
        }
        const missing = to_read - len;

        var buf = self.buf;
        const message_len = self.message_len;
        var read_start = self.start + len;

        if (missing > buf.len - read_start) {
            if (to_read <= buf.len) {
                // We have enough space to read this message in our
                // current buffer, but we need to recompact it.
                std.mem.copy(u8, buf[0..], buf[self.start..read_start]);
                self.start = 0;
                read_start = len;
            } else if (to_read <= self.max_size) {
                std.debug.assert(self.dynamic == null);

                var dyn = try self.allocator.alloc(u8, to_read);
                if (len > 0) {
                    std.mem.copy(u8, dyn, buf[self.start .. self.start + len]);
                }

                buf = dyn;
                read_start = len;

                self.start = 0;
                self.buf = dyn;
                self.dynamic = dyn;
                self.len = message_len;
            } else {
                return BufferError.TooLarge;
            }
        }

        var total_read: usize = 0;
        while (total_read < missing) {
            const n = try stream.read(buf[(read_start + total_read)..]);
            if (n == 0) {
                return false;
            }
            total_read += n;
        }

        self.len += total_read;
        self.message_len = to_read;
        return true;
    }

    // Returns a message, the length of which is based the sum
    // of `to_read` passed to `read` since the last next (or
    // since first use)
    pub fn message(self: Buffer) []u8 {
        const start = self.start;
        return self.buf[start .. start + self.message_len];
    }

    pub fn next(self: *Buffer) void {
        if (self.dynamic) |dynamic| {
            self.allocator.free(dynamic);
            self.dynamic = null;
            self.buf = self.static;
            self.len = 0;
            self.start = 0;
        } else {
            const message_len = self.message_len;
            if (message_len == self.len) {
                self.len = 0;
                self.start = 0;
            } else {
                self.len -= message_len;
                self.start += message_len;
            }
        }
        self.message_len = 0;
    }

    pub fn deinit(self: *Buffer) void {
        const allocator = self.allocator;
        allocator.free(self.static);
        if (self.dynamic) |dynamic| {
            allocator.free(dynamic);
        }
        self.* = undefined;
    }
};

test "exact read into static with no overflow" {
    // exact read into static with no overflow
    var s = t.Stream.init().add("hello1");
    defer s.deinit();

    var b = try Buffer.init(20, 20, t.allocator);
    defer b.deinit();

    try t.expectEqual(true, try b.read(*t.Stream, s, 6));
    try t.expectString("hello1", b.message());
    try t.expectString("hello1", b.message());
}

test "overread into static with no overflow" {
    var s = t.Stream.init().add("hello1world");
    defer s.deinit();

    var b = try Buffer.init(20, 20, t.allocator);
    defer b.deinit();

    try t.expectEqual(true, try b.read(*t.Stream, s, 6));
    try t.expectString("hello1", b.message());
    try t.expectString("hello1", b.message());
    b.next();
    try t.expectEqual(true, try b.read(*t.Stream, s, 5));
    try t.expectString("world", b.message());
}

test "incremental read of message" {
    var s = t.Stream.init().add("12345");
    defer s.deinit();

    var b = try Buffer.init(20, 20, t.allocator);
    defer b.deinit();

    try t.expectEqual(true, try b.read(*t.Stream, s, 2));
    try t.expectString("12", b.message());

    try t.expectEqual(true, try b.read(*t.Stream, s, 5));
    try t.expectString("12345", b.message());
}

test "reads with overflow" {
    var s = t.Stream.init().add("hellow").add("orld!");
    defer s.deinit();

    var b = try Buffer.init(6, 5, t.allocator);
    defer b.deinit();

    try t.expectEqual(true, try b.read(*t.Stream, s, 5));
    try t.expectString("hello", b.message());
    try t.expectString("hello", b.message());
    b.next();
    try t.expectEqual(true, try b.read(*t.Stream, s, 6));
    try t.expectString("world!", b.message());
}

test "reads too learge" {
    var s = t.Stream.init().add("12356");
    defer s.deinit();

    var b1 = try Buffer.init(5, 5, t.allocator);
    defer b1.deinit();
    try t.expectError(BufferError.TooLarge, b1.read(*t.Stream, s, 6));

    var b2 = try Buffer.init(5, 10, t.allocator);
    defer b2.deinit();
    try t.expectError(BufferError.TooLarge, b2.read(*t.Stream, s, 11));
}

test "reads message larger than static" {
    var s = t.Stream.init().add("hello world");
    defer s.deinit();

    var b = try Buffer.init(5, 20, t.allocator);
    defer b.deinit();
    try t.expectEqual(true, try b.read(*t.Stream, s, 11));
    try t.expectString("hello world", b.message());
}

test "reads fragmented message larger than static" {
    var s = t.Stream.init().add("hello").add(" ").add("world!").add("nice");
    defer s.deinit();

    var b = try Buffer.init(5, 20, t.allocator);
    defer b.deinit();
    try t.expectEqual(true, try b.read(*t.Stream, s, 12));
    try t.expectString("hello world!", b.message());
    try t.expectString("hello world!", b.message());
    b.next();
    try t.expectEqual(true, try b.read(*t.Stream, s, 4));
    try t.expectString("nice", b.message());
}

test "reads large fragmented message after small message" {
    var s = t.Stream.init().add("nice").add("hello").add(" ").add("world!");
    defer s.deinit();

    var b = try Buffer.init(5, 20, t.allocator);
    defer b.deinit();
    try t.expectEqual(true, try b.read(*t.Stream, s, 4));
    try t.expectString("nice", b.message());
    b.next();
    try t.expectEqual(true, try b.read(*t.Stream, s, 12));
    try t.expectString("hello world!", b.message());
    try t.expectString("hello world!", b.message());
}

test "reads large fragmented message fragmented with small message" {
    var s = t.Stream.init().add("nicehel").add("lo").add(" ").add("world!");
    defer s.deinit();

    var b = try Buffer.init(7, 20, t.allocator);
    defer b.deinit();
    try t.expectEqual(true, try b.read(*t.Stream, s, 4));
    try t.expectString("nice", b.message());
    b.next();
    try t.expectEqual(true, try b.read(*t.Stream, s, 12));
    try t.expectString("hello world!", b.message());
    try t.expectString("hello world!", b.message());
}

test "reads large fragmented message fragmented with small message" {
    var s = t.Stream.init().add("nicehel").add("lo").add(" ").add("world!");
    defer s.deinit();

    var b = try Buffer.init(7, 20, t.allocator);
    defer b.deinit();
    try t.expectEqual(true, try b.read(*t.Stream, s, 4));
    try t.expectString("nice", b.message());
    b.next();
    try t.expectEqual(true, try b.read(*t.Stream, s, 12));
    try t.expectString("hello world!", b.message());
    try t.expectString("hello world!", b.message());
}

test "reads large fragmented message with a small message when static buffer is smaller than read size" {
    var s = t.Stream.init().add("nicehel").add("lo").add(" ").add("world!");
    defer s.deinit();

    var b = try Buffer.init(5, 20, t.allocator);
    defer b.deinit();
    try t.expectEqual(true, try b.read(*t.Stream, s, 4));
    try t.expectString("nice", b.message());
    b.next();
    try t.expectEqual(true, try b.read(*t.Stream, s, 12));
    try t.expectString("hello world!", b.message());
    try t.expectString("hello world!", b.message());
}

test "reads large fragmented message" {
    var s = t.Stream.init().add("0").add("123456").add("789ABCabc").add("defghijklmn");
    defer s.deinit();

    var b = try Buffer.init(5, 20, t.allocator);
    defer b.deinit();
    try t.expectEqual(true, try b.read(*t.Stream, s, 1));
    try t.expectString("0", b.message());

    try t.expectEqual(true, try b.read(*t.Stream, s, 13));
    try t.expectString("0123456789ABC", b.message());
    b.next();
    try t.expectEqual(true, try b.read(*t.Stream, s, 14));
    try t.expectString("abcdefghijklmn", b.message());
}

test "fuzz" {
    const allocator = t.allocator;
    const random = t.getRandom().random();

    // NOTE: there's an inner fuzzing loop also.
    // This loop generates 1 set of messages/expectations. The inner loop
    // generates random fragmentation over those messages.

    var outer: usize = 0;
    while (outer < 100) : (outer += 1) {
        // The number of message this iteration will be setting up/expecting
        const message_count = random.uintAtMost(usize, 10) + 1;
        var messages = allocator.alloc([]u8, message_count) catch unreachable;
        defer {
            for (messages) |m| {
                allocator.free(m);
            }
            allocator.free(messages);
        }

        var j: usize = 0;
        while (j < message_count) : (j += 1) {
            const len = random.uintAtMost(usize, 100) + 1;
            messages[j] = allocator.alloc(u8, len) catch unreachable;
            random.bytes(messages[j]);
        }

        // Now we have all ouf our expectations setup, let's setup our mock stream
        var stream = t.Stream.init();
        for (messages) |m| {
            _ = stream.fragmentedAdd(m);
        }

        // This is the inner fuzzing loop which takes a set of messages
        // and tries multiple time with random fragmentation
        var inner: usize = 0;
        while (inner < 10) : (inner += 1) {
            var s = &stream.clone();
            var b = try Buffer.init(40, 101, t.allocator);

            for (messages) |m| {
                try t.expectEqual(true, try b.read(*t.Stream, s, m.len));
                try t.expectString(m, b.message());
                b.next();
            }

            b.deinit();
            s.deinit();
        }
        stream.deinit();
    }
}
