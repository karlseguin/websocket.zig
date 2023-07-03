const std = @import("std");
const builtin = @import("builtin");
const t = @import("t.zig");

const os = std.os;
const mem = std.mem;
const Stream = if (builtin.is_test) *t.Stream else std.net.Stream;

const RequestError = error{
	Invalid,
	TooLarge,
	Timeout,
};

pub const Request = struct {
	pub fn read(stream: Stream, buf: []u8, timeout: ?u32) ![]u8 {
		@setRuntimeSafety(builtin.is_test);

		var poll_fd = [_]os.pollfd{os.pollfd{
			.fd = stream.handle,
			.events = os.POLL.IN,
			.revents = undefined,
		}};
		var deadline: ?i64 = null;
		var read_timeout: i32 = 0;
		if (timeout) |ms| {
			// our timeout for each individual read
			read_timeout = @intCast(ms);
			// our absolute deadline for reading the header
			deadline = std.time.milliTimestamp() + ms;
		}

		var total: usize = 0;
		while (true) {
			if (total == buf.len) {
				return RequestError.TooLarge;
			}

			if (read_timeout != 0) {
				if (try os.poll(&poll_fd, read_timeout) == 0) {
					return RequestError.Timeout;
				}
			}

			var n = try stream.read(buf[total..]);
			if (n == 0) {
				return RequestError.Invalid;
			}
			total += n;
			const request = buf[0..total];
			if (mem.endsWith(u8, request, "\r\n\r\n")) {
				return request;
			}

			if (deadline) |dl| {
				if (std.time.milliTimestamp() > dl) {
					return RequestError.Timeout;
				}
			}
		}
	}

	pub fn close(stream: Stream, err: anyerror) !void {
		try stream.writeAll("HTTP/1.1 400 Invalid\r\nerror: ");
		const s = switch (err) {
			error.Invalid => "invalid",
			error.TooLarge => "toolarge",
			error.Timeout => "timeout",
			else => "unknown",
		};
		try stream.writeAll(s);
		try stream.writeAll("\r\n\r\n");
	}
};
