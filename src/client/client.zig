const std = @import("std");
const proto = @import("../proto.zig");
const buffer = @import("../buffer.zig");
const compat = @import("../posix_compat.zig");

const ascii = std.ascii;
const posix = std.posix;
const log = std.log.scoped(.websocket);

const Reader = proto.Reader;
const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;
const CompressionOpts = @import("../websocket.zig").Compression;
const ServerHandshake = @import("../server/handshake.zig").Handshake;

fn ReadLoopHandler(comptime T: type) type {
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple)
                @compileError("readLoop: handler does not support tuples.");

            return T;
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .one => return ReadLoopHandler(ptr_info.child),
                else => @compileError("readLoop: handler does not support Slice, C and Many pointers."),
            }
        },
        else => @compileError("readLoop: expected handler to be a struct or pointer to a struct but found '" ++ @tagName(info) ++ "'"),
    }
}

pub const Client = struct {
    io: std.Io,
    stream: Stream,
    _reader: Reader,
    _closed: bool,
    _compression_opts: ?CompressionOpts,
    _compression: ?Client.Compression = null,

    // When creating a client, we can either be given a BufferProvider or create
    // one ourselves. If we create it ourselves (in init), we "own" it and must
    // free it on deinit. (The reference to the buffer provider is already in the
    // reader, no need to hold another reference in the client).
    _own_bp: bool,

    // For advanced cases, a custom masking function can be provided. Masking
    // is a security feature that only really makes sense in the browser. If you
    // aren't running websockets in the browser AND you control both the client
    // and the server, you could get a performance boost by not masking.
    _mask_fn: *const fn (std.Io) [4]u8,

    pub const Config = struct {
        port: u16,
        host: []const u8,
        tls: bool = false,
        max_size: usize = 65536,
        buffer_size: usize = 4096,
        ca_bundle: ?Bundle = null,
        mask_fn: *const fn (std.Io) [4]u8 = generateMask,
        buffer_provider: ?*buffer.Provider = null,
        compression: ?CompressionOpts = null,
    };

    pub const HandshakeOpts = struct {
        timeout_ms: u32 = 10000,
        headers: ?[]const u8 = null,
    };

    const Compression = struct {
        allocator: Allocator,
        retain_writer: bool,
        write_treshold: usize,
        writer: std.Io.Writer.Allocating,
    };

    pub fn init(allocator: Allocator, io: std.Io, config: Config) !Client {
        if (config.compression != null) {
            log.err("Compression is disabled as part of the 0.15 upgrade. I do hope to re-enable it soon.", .{});
            return error.InvalidConfiguraion;
        }

        if (config.tls) {
            // TLS migration is deferred — the 0.16 tls.Client API requires
            // Reader/Writer abstractions and caller-supplied entropy that need
            // a separate pass.  Return a clear error rather than leaving the
            // code in a broken state.
            return error.TlsNotYetMigrated;
        }

        const sock = try tcpConnectToHost(config.host, config.port);
        errdefer compat.close(sock);

        const stream = Stream.init(.{ .handle = sock });

        var own_bp = false;
        var buffer_provider: *buffer.Provider = undefined;

        // If a buffer_provider is provided, we'll use that.
        // If it isn't, we need to create one which also means we now "own" it
        // and we're responsible for cleaning it up
        if (config.buffer_provider) |shared_bp| {
            buffer_provider = shared_bp;
        } else {
            own_bp = true;
            buffer_provider = try allocator.create(buffer.Provider);
            errdefer allocator.destroy(buffer_provider);
            buffer_provider.* = try buffer.Provider.init(allocator, io, .{
                .size = 0,
                .count = 0,
                .max = config.max_size,
            });
        }

        errdefer if (own_bp) {
            buffer_provider.deinit();
            allocator.destroy(buffer_provider);
        };

        const reader_buf = try buffer_provider.allocator.alloc(u8, config.buffer_size);
        errdefer buffer_provider.allocator.free(reader_buf);

        return .{
            .io = io,
            .stream = stream,
            ._closed = false,
            ._own_bp = own_bp,
            ._mask_fn = config.mask_fn,
            ._compression_opts = null, //TODO: ZIG 0.15
            ._reader = Reader.init(reader_buf, buffer_provider, null),
        };
    }

    pub fn deinit(self: *Client) void {
        self.closeStream();

        const larger_buffer_provider = self._reader.large_buffer_provider;
        const allocator = larger_buffer_provider.allocator;
        allocator.free(self._reader.static);

        self._reader.deinit();

        if (self._own_bp) {
            larger_buffer_provider.deinit();
            allocator.destroy(larger_buffer_provider);
        }
    }

    pub fn handshake(self: *Client, path: []const u8, opts: HandshakeOpts) !void {
        const stream = &self.stream;
        errdefer self.closeStream();

        // we've already setup our reader, and the reader has a static buffer
        // we might as well use it!
        const buf = self._reader.static;
        const key = blk: {
            const bin_key = generateKey(self.io);
            var encoded_key: [24]u8 = undefined;
            break :blk std.base64.standard.Encoder.encode(&encoded_key, &bin_key);
        };

        try sendHandshake(path, key, buf, &opts, self._compression_opts != null, stream);

        const res = try HandShakeReply.read(buf, key, &opts, self._compression_opts != null, stream, self.io);
        errdefer self.close(.{ .code = 1001 }) catch unreachable;

        // Set up compression with agreed-on parameters
        if (res.compression) {
            try self.setupCompression();
        }

        // We might have read more than handshake response. If so, readHandshakeReply
        // has positioned the extra data at the start of the buffer, but we need
        // to set the length.
        self._reader.pos = res.over_read;
    }

    fn setupCompression(self: *Client) !void {
        std.debug.assert(self._compression_opts != null);
        self._reader.allow_compressed = true;

        const allocator = self._reader.large_buffer_provider.allocator;
        const config = self._compression_opts.?;
        self._compression = .{
            .allocator = allocator,
            .write_treshold = config.write_threshold.?,
            .retain_writer = config.retain_write_buffer,
            .writer = std.Io.Writer.Allocating.init(allocator),
        };
    }

    pub fn readLoop(self: *Client, handler: anytype) !void {
        const Handler = ReadLoopHandler(@TypeOf(handler));
        var reader = &self._reader;

        defer if (comptime std.meta.hasFn(Handler, "close")) {
            handler.close();
        };

        // block until we have data
        try self.readTimeout(0);

        while (true) {
            const message = self.read() catch |err| switch (err) {
                error.Closed => return,
                else => return err,
            } orelse unreachable;

            const message_type = message.type;
            defer reader.done(message_type);

            switch (message_type) {
                .text, .binary => {
                    switch (comptime @typeInfo(@TypeOf(Handler.serverMessage)).@"fn".param_types.len) {
                        2 => try handler.serverMessage(message.data),
                        3 => try handler.serverMessage(message.data, if (message_type == .text) .text else .binary),
                        else => @compileError(@typeName(Handler) ++ ".serverMessage must accept 2 or 3 parameters"),
                    }
                },
                .ping => if (comptime std.meta.hasFn(Handler, "serverPing")) {
                    try handler.serverPing(message.data);
                } else {
                    // @constCast is safe because we know message.data points to
                    // reader.buffer.buf, which we own and which can be mutated
                    try self.writeFrame(.pong, @constCast(message.data));
                },
                .close => {
                    if (comptime std.meta.hasFn(Handler, "serverClose")) {
                        try handler.serverClose(message.data);
                    } else {
                        self.close(.{}) catch unreachable;
                    }
                    return;
                },
                .pong => if (comptime std.meta.hasFn(Handler, "serverPong")) {
                    try handler.serverPong(message.data);
                },
            }
        }
    }

    pub fn read(self: *Client) !?proto.Message {
        var reader = &self._reader;
        const stream = &self.stream;

        while (true) {
            // try to read a message from our buffer first, before trying to
            // get more data from the socket.
            const has_more, const message = reader.read() catch |err| {
                self.close(.{ .code = 1002 }) catch unreachable;
                return err;
            } orelse {
                reader.fill(stream) catch |err| switch (err) {
                    error.WouldBlock => return null,
                    error.Closed, error.ConnectionResetByPeer, error.BrokenPipe, error.NotOpenForReading => {
                        @atomicStore(bool, &self._closed, true, .monotonic);
                        return error.Closed;
                    },
                    else => {
                        self.close(.{ .code = 1002 }) catch unreachable;
                        return err;
                    },
                };
                continue;
            };

            _ = has_more;
            return message;
        }
    }

    pub fn done(self: *Client, message: proto.Message) void {
        self._reader.done(message.type);
    }

    pub fn readLoopInNewThread(self: *Client, h: anytype) !std.Thread {
        return std.Thread.spawn(.{}, readLoopOwnedThread, .{ self, h });
    }

    fn readLoopOwnedThread(self: *Client, h: anytype) void {
        self.readLoop(h) catch {};
    }

    pub fn writeTimeout(self: *const Client, ms: u32) !void {
        return self.stream.writeTimeout(ms);
    }

    pub fn readTimeout(self: *const Client, ms: u32) !void {
        return self.stream.readTimeout(ms);
    }

    pub fn write(self: *Client, data: []u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writeText(self: *Client, data: []u8) !void {
        return self.writeFrame(.text, data);
    }

    pub fn writeBin(self: *Client, data: []u8) !void {
        return self.writeFrame(.binary, data);
    }

    pub fn writePing(self: *Client, data: []u8) !void {
        return self.writeFrame(.ping, data);
    }

    pub fn writePong(self: *Client, data: []u8) !void {
        return self.writeFrame(.pong, data);
    }

    const CloseOpts = struct {
        code: ?u16 = null,
        reason: []const u8 = "",
    };

    pub fn close(self: *Client, opts: CloseOpts) !void {
        if (@atomicRmw(bool, &self._closed, .Xchg, true, .monotonic) == true) {
            // already closed
            return;
        }

        defer self.stream.close();

        const code = opts.code orelse {
            self.writeFrame(.close, "") catch {};
            return;
        };

        const reason = opts.reason;
        if (reason.len > 123) {
            return error.ReasonTooLong;
        }

        var buf: [125]u8 = undefined;
        buf[0] = @intCast((code >> 8) & 0xFF);
        buf[1] = @intCast(code & 0xFF);

        const end = 2 + reason.len;
        @memcpy(buf[2..end], reason);
        self.writeFrame(.close, buf[0..end]) catch {};
    }

    pub fn writeFrame(self: *Client, op_code: proto.OpCode, data: []u8) !void {
        const payload = data;
        const compressed = false;
        // if (self._compression) |c| {
        //     if (data.len >= c.write_treshold and (op_code == .binary or op_code == .text)) {
        //         compressed = true;

        //         var writer = &c.writer;
        //         var compressor = &c.compressor;
        //         var fbs = std.io.fixedBufferStream(data);
        //         _ = try compressor.compress(fbs.reader());
        //         try compressor.flush();
        //         payload = writer.items[0 .. writer.items.len - 4];

        //         if (c.reset) {
        //             c.compressor = try Compression.Type.init(writer.writer(), .{});
        //         }
        //     }
        // }
        // defer if (compressed) {
        //     const c = self._compression.?;
        //     if (c.retain_writer) {
        //         c.compressor.wrt.context.clearRetainingCapacity();
        //     } else {
        //         c.compressor.wrt.context.clearAndFree();
        //     }
        // };

        // maximum possible prefix length. op_code + length_type + 8byte length + 4 byte mask
        var buf: [14]u8 = undefined;
        const header = proto.writeFrameHeader(&buf, op_code, payload.len, compressed);

        const header_len = header.len;
        const header_end = header.len + 4; // for the mask

        buf[1] |= 128; // indicate that the payload is masked

        const mask = self._mask_fn(self.io);
        @memcpy(buf[header_len..header_end], &mask);
        try self.stream.writeAll(buf[0..header_end]);

        if (payload.len > 0) {
            proto.mask(&mask, payload);
            try self.stream.writeAll(payload);
        }
    }

    fn closeStream(self: *Client) void {
        if (@atomicRmw(bool, &self._closed, .Xchg, true, .monotonic) == false) {
            self.stream.close();
        }
    }
};

// Resolve hostname/IP and connect a TCP socket. Returns the connected socket fd.
// Supports IP address literals (IPv4 and IPv6). Hostname DNS resolution is not
// yet implemented — callers with non-IP hostnames will get error.HostResolveNotImplemented.
fn tcpConnectToHost(host: []const u8, port: u16) !compat.socket_t {
    // Try parsing as an IP address literal first (no Io needed, pure function).
    const ip_addr = std.Io.net.IpAddress.parse(host, port) catch {
        // TODO: implement hostname DNS resolution via std.Io.net.HostName.resolve
        return error.HostResolveNotImplemented;
    };

    const cloexec: u32 = compat.SOCK_CLOEXEC;

    switch (ip_addr) {
        .ip4 => |ip4| {
            const sock = try compat.socket(compat.AF.INET, compat.SOCK.STREAM | cloexec, compat.IPPROTO.TCP);
            errdefer compat.close(sock);

            var addr_in = compat.sockaddr.in{
                .family = compat.AF.INET,
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
                .zero = @splat(0),
            };
            try compat.connect(sock, @ptrCast(&addr_in), @sizeOf(compat.sockaddr.in));
            return sock;
        },
        .ip6 => |ip6| {
            const sock = try compat.socket(compat.AF.INET6, compat.SOCK.STREAM | cloexec, compat.IPPROTO.TCP);
            errdefer compat.close(sock);

            var addr_in6 = compat.sockaddr.in6{
                .family = compat.AF.INET6,
                .port = std.mem.nativeToBig(u16, ip6.port),
                .flowinfo = 0,
                .addr = ip6.bytes,
                .scope_id = 0,
            };
            try compat.connect(sock, @ptrCast(&addr_in6), @sizeOf(compat.sockaddr.in6));
            return sock;
        },
    }
}

// Wraps a compat.Stream and optionally a TLS client.
// TLS support is not yet migrated to 0.16; the tls field is always null.
pub const Stream = struct {
    net_stream: compat.Stream,

    pub fn init(net_stream: compat.Stream) Stream {
        return .{
            .net_stream = net_stream,
        };
    }

    pub fn close(self: *Stream) void {
        const fd = self.net_stream.handle;
        // Shutdown before close so any blocked reads/writes exit.
        compat.shutdown(fd, .both) catch {};
        // std.posix.close panics on EBADF (https://github.com/ziglang/zig/issues/6389)
        // Use the raw syscall to avoid crashing on double close.
        _ = std.posix.system.close(fd);
    }

    pub fn read(self: *Stream, buf: []u8) !usize {
        return self.net_stream.read(buf);
    }

    pub fn writeAll(self: *Stream, data: []const u8) !void {
        return self.net_stream.writeAll(data);
    }

    const zero_timeout = std.mem.toBytes(compat.timeval{ .sec = 0, .usec = 0 });
    pub fn writeTimeout(self: *const Stream, ms: u32) !void {
        return self.setTimeout(compat.SO.SNDTIMEO, ms);
    }

    pub fn readTimeout(self: *const Stream, ms: u32) !void {
        return self.setTimeout(compat.SO.RCVTIMEO, ms);
    }

    fn setTimeout(self: *const Stream, opt_name: u32, ms: u32) !void {
        if (ms == 0) {
            return self.setsockopt(opt_name, &zero_timeout);
        }

        const timeout = std.mem.toBytes(compat.timeval{
            .sec = @intCast(@divTrunc(ms, 1000)),
            .usec = @intCast(@mod(ms, 1000) * 1000),
        });
        return self.setsockopt(opt_name, &timeout);
    }

    pub fn setsockopt(self: *const Stream, opt_name: u32, value: []const u8) !void {
        const rc = std.posix.system.setsockopt(
            self.net_stream.handle,
            std.posix.SOL.SOCKET,
            opt_name,
            value.ptr,
            @intCast(value.len),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => return error.Unexpected,
        }
    }
};

fn generateKey(io: std.Io) [16]u8 {
    if (comptime @import("builtin").is_test) {
        return [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    }
    var key: [16]u8 = undefined;
    io.random(&key);
    return key;
}

fn generateMask(io: std.Io) [4]u8 {
    var m: [4]u8 = undefined;
    io.random(&m);
    return m;
}

fn sendHandshake(path: []const u8, key: []const u8, buf: []u8, opts: *const Client.HandshakeOpts, compression: bool, stream: anytype) !void {
    @memcpy(buf[0..4], "GET ");
    var pos: usize = 4;
    var end = pos + path.len;

    {
        @memcpy(buf[pos..end], path);
        pos = end;
    }

    {
        const headers = " HTTP/1.1\r\ncontent-length: 0\r\nupgrade: websocket\r\nsec-websocket-version: 13\r\nconnection: upgrade\r\nsec-websocket-key: ";
        end = pos + headers.len;
        @memcpy(buf[pos..end], headers);

        pos = end;
        end = pos + key.len;
        @memcpy(buf[pos..end], key);
    }

    if (compression) {
        // NOTE: client_max_window_bits is unsupported
        const permessage_deflate = "\r\nSec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover";
        pos = end;
        end = pos + permessage_deflate.len;
        @memcpy(buf[pos..end], permessage_deflate);
    }

    {
        pos = end;
        end = pos + 2;
        @memcpy(buf[pos..end], "\r\n");
        pos = end;
    }

    if (opts.headers) |extra_headers| {
        end = pos + extra_headers.len;
        @memcpy(buf[pos..end], extra_headers);
        pos = end;
        if (!std.mem.endsWith(u8, extra_headers, "\r\n")) {
            buf[pos] = '\r';
            buf[pos + 1] = '\n';
            pos += 2;
        }
    }
    buf[pos] = '\r';
    buf[pos + 1] = '\n';

    try stream.writeTimeout(opts.timeout_ms);
    try stream.writeAll(buf[0 .. pos + 2]);
    try stream.writeTimeout(0);
}

const HandShakeReply = struct {
    compression: bool,
    over_read: usize,

    fn read(buf: []u8, key: []const u8, opts: *const Client.HandshakeOpts, compression: bool, stream: anytype, io: std.Io) !HandShakeReply {
        const timeout_ms = opts.timeout_ms;
        // Compute a deadline in milliseconds using the realtime clock.
        const start_ts = std.Io.Timestamp.now(io, .real);
        const deadline_ns = start_ts.nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms;
        try stream.readTimeout(timeout_ms);

        var pos: usize = 0;
        var line_start: usize = 0;
        var complete_response: u8 = 0;
        var server_compression: bool = false;

        while (true) {
            const n = stream.read(buf[pos..]) catch |err| switch (err) {
                error.WouldBlock => return error.Timeout,
                else => return err,
            };
            if (n == 0) {
                return error.ConnectionClosed;
            }

            pos += n;
            while (std.mem.indexOfScalar(u8, buf[line_start..pos], '\r')) |relative_end| {
                if (relative_end == 0) {
                    if (complete_response != 15) {
                        return error.InvalidHandshakeResponse;
                    }
                    const over_read = pos - (line_start + 2);
                    std.mem.copyForwards(u8, buf[0..over_read], buf[line_start + 2 .. pos]);
                    try stream.readTimeout(0);
                    return .{
                        .over_read = over_read,
                        .compression = server_compression,
                    };
                }

                const line_end = line_start + relative_end;
                const line = buf[line_start..line_end];

                // the next line starts where this line ends, skip over the \r\n
                line_start = line_end + 2;

                if (complete_response == 0) {
                    if (!ascii.startsWithIgnoreCase(line, "HTTP/1.1 101 ")) {
                        return error.InvalidHandshakeResponse;
                    }
                    complete_response |= 1;
                    continue;
                }

                for (line, 0..) |b, i| {
                    // find the colon and lowercase the header while we're iterating
                    if ('A' <= b and b <= 'Z') {
                        line[i] = b + 32;
                        continue;
                    }

                    if (b != ':') {
                        continue;
                    }

                    switch (i) {
                        7 => if (std.mem.eql(u8, line[0..i], "upgrade")) {
                            if (!ascii.eqlIgnoreCase(std.mem.trim(u8, line[i + 1 ..], &ascii.whitespace), "websocket")) {
                                return error.InvalidUpgradeHeader;
                            }
                            complete_response |= 2;
                        },
                        10 => if (std.mem.eql(u8, line[0..i], "connection")) {
                            if (!ascii.eqlIgnoreCase(std.mem.trim(u8, line[i + 1 ..], &ascii.whitespace), "upgrade")) {
                                return error.InvalidConnectionHeader;
                            }
                            complete_response |= 4;
                        },
                        20 => if (std.mem.eql(u8, line[0..i], "sec-websocket-accept")) {
                            var h: [20]u8 = undefined;
                            {
                                var hasher = std.crypto.hash.Sha1.init(.{});
                                hasher.update(key);
                                hasher.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
                                hasher.final(&h);
                            }

                            var encoded_buf: [28]u8 = undefined;
                            const sec_hash = std.base64.standard.Encoder.encode(&encoded_buf, &h);
                            const header_value = std.mem.trim(u8, line[i + 1 ..], &ascii.whitespace);

                            if (!std.mem.eql(u8, header_value, sec_hash)) {
                                return error.InvalidWebsocketAcceptHeader;
                            }
                            complete_response |= 8;
                        },
                        24 => if (std.mem.eql(u8, line[0..i], "sec-websocket-extensions")) {
                            if (try parseExtension(line[i + 1 ..])) |sc| {
                                if (!compression) {
                                    // server is saying compression, but we didn't ask for it.
                                    return error.InvalidExtensionHeader;
                                }
                                if (!sc.client_no_context_takeover or !sc.server_no_context_takeover) {
                                    // as of Zig 0.15, we no longer support context takeover
                                    // We told the server this, it should have respected it.
                                    return error.InvalidExtensionHeader;
                                }

                                server_compression = true;
                            }
                        },
                        else => {}, // some other header we don't care about
                    }
                }
            }

            if (std.Io.Timestamp.now(io, .real).nanoseconds > deadline_ns) {
                return error.Timeout;
            }

            if (pos == buf.len) {
                return error.ResponseTooLarge;
            }
        }
    }

    pub fn parseExtension(value: []const u8) !?ServerHandshake.Compression {
        var deflate = false;
        var client_max_bits: u8 = 15;
        var client_no_context_takeover = false;
        var server_no_context_takeover = false;

        var it = std.mem.splitScalar(u8, value, ';');
        while (it.next()) |param_| {
            const param = std.mem.trim(u8, param_, &ascii.whitespace);
            if (std.mem.eql(u8, param, "permessage-deflate")) {
                deflate = true;
                continue;
            }
            if (std.mem.eql(u8, param, "client_no_context_takeover")) {
                client_no_context_takeover = true;
                continue;
            }
            if (std.mem.eql(u8, param, "server_no_context_takeover")) {
                server_no_context_takeover = true;
                continue;
            }
            const client_max_window_bits = "client_max_window_bits=";
            if (std.mem.startsWith(u8, param, client_max_window_bits)) {
                client_max_bits = std.fmt.parseInt(u8, param[client_max_window_bits.len..], 10) catch {
                    return error.InvalidCompressionServerMaxBits;
                };
            }
        }
        if (deflate == false) {
            return null;
        }

        if (client_max_bits != 15) {
            // We don't offer client window, so if the server asks for one, that's an error
            return error.InvalidExtensionHeader;
        }

        return .{
            .client_no_context_takeover = client_no_context_takeover,
            .server_no_context_takeover = server_no_context_takeover,
        };
    }
};

const t = @import("../t.zig");
test "Client: handshake" {
    {
        // empty response
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // invalid websocket response
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 200 OK\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // missing upgrade header
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // wrong upgrade header
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: nope\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try t.expectError(error.InvalidUpgradeHeader, client.handshake("/", .{}));
    }

    {
        // missing connection header
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: websocket\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // wrong connection header
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: something\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try t.expectError(error.InvalidConnectionHeader, client.handshake("/", .{}));
    }

    {
        // missing Sec-Websocket-Accept header
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nUpgrade: websocket\r\nConnection: upgrade\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try t.expectError(error.InvalidHandshakeResponse, client.handshake("/", .{}));
    }

    {
        // wrong Sec-Websocket-Accept header
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: hack\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try t.expectError(error.InvalidWebsocketAcceptHeader, client.handshake("/", .{}));
    }

    {
        // ok for successful
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: C/0nmHhBztSRGR1CwL6Tf4ZjwpY=\r\n\r\n");

        var client = testClient(pair.server);
        defer client.deinit();
        try client.handshake("/", .{});
        try t.expectEqual(0, client._reader.pos);
    }

    {
        // ok for successful, with overread
        var pair = t.SocketPair.init(.{});
        defer pair.deinit();
        try pair.client.writeAll("HTTP/1.1 101 Switching Protocol\r\nupgrade: WebSocket\r\nConnection: UPGRADE\r\nSec-Websocket-Accept: C/0nmHhBztSRGR1CwL6Tf4ZjwpY=\r\n\r\nSome Random Data Which is Part Of the Next Message");

        var client = testClient(pair.server);
        defer client.deinit();
        try client.handshake("/", .{});
        try t.expectEqual(50, client._reader.pos);
    }
}

test "Client: write/read" {
    var client = try Client.init(t.allocator, t.getIo(), .{
        .port = 9292,
        .host = "127.0.0.1",
    });
    defer client.deinit();

    try client.handshake("/", .{
        .timeout_ms = 1000,
    });

    var buf = [_]u8{ 'o', 'v', 'e', 'r' };
    try client.write(&buf);
    try client.readTimeout(1000);

    const message = (try client.read()) orelse unreachable;
    try t.expectEqual(.text, message.type);
    try t.expectString("9000", message.data);

    client.close(.{}) catch unreachable;
}

test "Client: close with code" {
    var client = try Client.init(t.allocator, t.getIo(), .{
        .port = 9292,
        .host = "127.0.0.1",
    });
    defer client.deinit();

    try client.handshake("/", .{
        .timeout_ms = 1000,
    });

    client.close(.{ .code = 4002 }) catch unreachable;
}

test "Client: with code and reason" {
    var client = try Client.init(t.allocator, t.getIo(), .{
        .port = 9292,
        .host = "127.0.0.1",
    });
    defer client.deinit();

    try client.handshake("/", .{
        .timeout_ms = 1000,
    });

    client.close(.{ .code = 4002, .reason = "goodbye" }) catch unreachable;
}

test "Client: Handler" {
    var h = try ClientHandler.init(t.allocator);
    defer h.deinit();

    var buf: [6]u8 = undefined;
    {
        @memcpy(buf[0..3], "dyn");
        try h.client.write(buf[0..3]);
    }

    {
        @memcpy(buf[0..4], "ping");
        try h.client.write(buf[0..4]);
    }

    {
        @memcpy(buf[0..4], "pong");
        try h.client.write(buf[0..4]);
    }

    {
        @memcpy(buf[0..6], "close1");
        try h.client.write(buf[0..6]);
    }

    try h.client.readLoop(&h);

    // if pong is true then ping and message have to be true
    // because each asserts the previous
    try t.expectEqual(true, h.pong);
    try t.expectEqual(true, h.closed);
}

fn testClient(stream: compat.Stream) Client {
    const io = t.getIo();
    const bp = t.allocator.create(buffer.Provider) catch unreachable;
    bp.* = buffer.Provider.init(t.allocator, io, .{ .count = 0, .size = 0, .max = 4096 }) catch unreachable;

    const reader_buf = bp.allocator.alloc(u8, 1024) catch unreachable;

    return .{
        .io = io,
        ._closed = false,
        ._own_bp = true,
        ._mask_fn = generateMask,
        ._compression_opts = null,
        .stream = .{ .net_stream = stream },
        ._reader = Reader.init(reader_buf, bp, null),
    };
}

const ClientHandler = struct {
    ping: bool = false,
    pong: bool = false,
    closed: bool = false,
    message: bool = false,
    client: Client,

    fn init(allocator: Allocator) !ClientHandler {
        var client = try Client.init(allocator, t.getIo(), .{
            .port = 9292,
            .host = "127.0.0.1",
        });
        errdefer client.deinit();

        try client.handshake("/", .{
            .timeout_ms = 1000,
        });

        return .{
            .client = client,
        };
    }

    fn deinit(self: *ClientHandler) void {
        self.client.deinit();
    }

    pub fn serverMessage(self: *ClientHandler, data: []u8, tpe: proto.Message.TextType) !void {
        try t.expectEqual(.text, tpe);
        try t.expectString("over 9000!", data);
        self.message = true;
    }

    pub fn serverPing(self: *ClientHandler, data: []u8) !void {
        try t.expectEqual(true, self.message);
        try t.expectString("a-ping", data);
        self.ping = true;
    }

    pub fn serverPong(self: *ClientHandler, data: []u8) !void {
        try t.expectEqual(true, self.ping);
        try t.expectString("a-pong", data);
        self.pong = true;
    }

    pub fn close(self: *ClientHandler) void {
        self.client.close(.{}) catch unreachable;
        self.closed = true;
    }
};
