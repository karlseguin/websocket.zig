//! Backfill for syscall wrappers removed from `std.posix` in Zig 0.16.
//!
//! 0.16 hollowed out `std.posix` — `socket`, `bind`, `listen`, `accept`,
//! `close`, `send`, `recv`, `shutdown`, `fcntl`, `connect`, `epoll_*`, `kqueue`,
//! `clock_gettime`, `pipe2`, `write`, `writev`, `getsockname` are all gone as
//! direct wrappers. They moved to `std.Io.net.*` (which requires an `Io`
//! instance and presumes its event loop drives accept/recv) or must be
//! accessed via `std.posix.system.*` (raw libc/syscall layer, errno-style).
//!
//! This module exposes a minimal, library-local set of thin wrappers over
//! `std.posix.system.*` so the existing custom epoll/kqueue event loop in
//! `src/server/server.zig` can keep working. Callers replace
//! `const posix = std.posix;` with `const posix = @import("posix_compat.zig");`
//! and get the pre-0.16 surface plus re-exports of constants/types that
//! survived.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const system = std.posix.system;
const errno = std.posix.errno;
const E = std.posix.E;

// Windows-only: WSAGetLastError() for translating Winsock errors.
// Declared here instead of relying on std.os.windows.ws2_32 which doesn't export it.
const WSAError = if (native_os == .windows) enum(c_int) {
    WSAEINTR = 10004,
    WSAEINVAL = 10022,
    WSAEMFILE = 10024,
    WSAEWOULDBLOCK = 10035,
    WSAENOTSOCK = 10038,
    WSAECONNABORTED = 10053,
    WSAECONNRESET = 10054,
    WSAEPIPE = 10058, // WSAESHUTDOWN (similar to EPIPE)
    WSAETIMEDOUT = 10060,
    _,
} else void;

extern "ws2_32" fn WSAGetLastError() if (native_os == .windows) c_int else void;
// On Windows, sockets must be closed with closesocket(), not CRT close().
extern "ws2_32" fn closesocket(s: if (native_os == .windows) fd_t else void) if (native_os == .windows) c_int else void;
// WSAStartup must be called before any Winsock functions.
// WSADATA is opaque to us; 408 bytes covers the struct on both 32-bit and 64-bit Windows.
const WsaData = if (native_os == .windows) [408]u8 else void;
extern "ws2_32" fn WSAStartup(
    wVersionRequired: if (native_os == .windows) u16 else void,
    lpWSAData: if (native_os == .windows) *WsaData else void,
) if (native_os == .windows) c_int else void;

var winsock_initialized: std.atomic.Value(bool) = .init(false);
fn ensureWinsockInit() void {
    if (comptime native_os != .windows) return;
    // Fast path: already initialized.
    if (winsock_initialized.load(.acquire)) return;
    var data: WsaData = undefined;
    const result = WSAStartup(0x0202, &data); // Request Winsock 2.2
    if (result != 0) @panic("WSAStartup failed");
    winsock_initialized.store(true, .release);
}

// --- Re-exports: constants, types, and wrappers still in std.posix ---

pub const AF = std.posix.AF;
pub const F = std.posix.F;
pub const IPPROTO = std.posix.IPPROTO;
pub const Kevent = std.posix.Kevent;
pub const O = std.posix.O;
pub const SO = std.posix.SO;
pub const SOCK = std.posix.SOCK;
pub const SOL = std.posix.SOL;
pub const CLOCK = std.posix.CLOCK;
pub const SHUT = std.posix.SHUT;

/// SOCK_CLOEXEC flag for socket()/accept4() where it is both declared AND
/// accepted by the syscall. On macOS the symbol exists in std.posix.SOCK
/// but the socket() syscall rejects the flag with EPROTOTYPE, so we must
/// gate to Linux only. (Linux is the only target that also provides
/// accept4, so CLOEXEC can be set atomically on both socket and accept.)
pub const SOCK_CLOEXEC: u32 = if (native_os == .linux and @hasDecl(SOCK, "CLOEXEC")) SOCK.CLOEXEC else 0;

/// SOCK_NONBLOCK flag for socket()/accept4(). Same story as SOCK_CLOEXEC:
/// macOS declares the symbol but the socket() syscall rejects it with
/// EPROTOTYPE. On non-Linux targets use 0 here and apply O_NONBLOCK via
/// fcntl(F_SETFL) after the socket is created.
pub const SOCK_NONBLOCK: u32 = if (native_os == .linux and @hasDecl(SOCK, "NONBLOCK")) SOCK.NONBLOCK else 0;

pub const fd_t = std.posix.fd_t;
pub const socket_t = std.posix.socket_t;
pub const socklen_t = std.posix.socklen_t;
pub const sockaddr = std.posix.sockaddr;
pub const timeval = std.posix.timeval;
pub const timespec = std.posix.timespec;
pub const iovec = std.posix.iovec;
pub const iovec_const = std.posix.iovec_const;
pub const sigset_t = std.posix.sigset_t;
pub const Sigaction = std.posix.Sigaction;
pub const SIG = std.posix.SIG;

// setsockopt: provide our own to avoid std.posix's Windows @compileError.
// Uses system.setsockopt directly (ws2_32 on Windows, libc on POSIX).
pub const SetSockOptError = std.posix.SetSockOptError;
pub fn setsockopt(fd: socket_t, level: i32, optname: u32, opt: []const u8) SetSockOptError!void {
    switch (errno(system.setsockopt(fd, level, optname, opt.ptr, @intCast(opt.len)))) {
        .SUCCESS => {},
        .BADF => unreachable,
        .NOTSOCK => unreachable,
        .INVAL => unreachable,
        .FAULT => unreachable,
        .DOM => return error.TimeoutTooBig,
        .ISCONN => return error.AlreadyConnected,
        .NOPROTOOPT => return error.InvalidProtocolOption,
        .NOMEM => return error.SystemResources,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}
// read: delegate to readFd (our thin wrapper) so Windows doesn't see
// std.posix.read's @compileError. Server doesn't run on Windows anyway.
pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    return readFd(fd, buf);
}
pub const sigaction = std.posix.sigaction;
pub const poll = std.posix.poll;

// --- Error-translation helpers ---

fn unexpectedErrno(err: E) error{Unexpected} {
    _ = err;
    return error.Unexpected;
}

// --- Thin syscall wrappers ---

pub const SocketError = error{
    AddressFamilyNotSupported,
    PermissionDenied,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
    Unexpected,
};

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    if (comptime native_os == .windows) ensureWinsockInit();
    const rc = system.socket(domain, socket_type, protocol);
    switch (errno(rc)) {
        // On Windows, fd_t = HANDLE = *anyopaque; the raw socket fd is a c_int
        // that we need to convert to a pointer-sized handle.
        .SUCCESS => return if (comptime native_os == .windows)
            @as(socket_t, @ptrFromInt(@as(usize, @as(c_uint, @bitCast(rc)))))
        else
            @intCast(rc),
        .ACCES => return error.PermissionDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub const BindError = error{
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    FileDescriptorNotASocket,
    AddressFamilyNotSupported,
    Unexpected,
};

pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) BindError!void {
    const rc = system.bind(sock, addr, len);
    switch (errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .BADF, .NOTSOCK => return error.FileDescriptorNotASocket,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
    SystemResources,
    Unexpected,
};

pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    const rc = system.listen(sock, backlog);
    switch (errno(rc)) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .BADF, .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const AcceptError = error{
    ConnectionAborted,
    FileDescriptorNotASocket,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    WouldBlock,
    OperationNotSupported,
    ProtocolFailure,
    BlockedByFirewall,
    Unexpected,
};

pub fn accept(sock: socket_t, addr: ?*sockaddr, addr_size: ?*socklen_t, flags: u32) AcceptError!socket_t {
    // accept4 is a Linux extension; not available on Windows or macOS.
    const have_accept4 = comptime native_os == .linux and @hasDecl(system, "accept4");
    _ = if (!have_accept4) flags; // flags only used with accept4

    while (true) {
        const rc = if (have_accept4)
            system.accept4(sock, addr, addr_size, flags)
        else
            system.accept(sock, addr, addr_size);

        if (comptime native_os == .windows) {
            const rc_signed: isize = @intCast(rc);
            if (rc_signed < 0) {
                const wsa_err = WSAGetLastError();
                return switch (@as(WSAError, @fromBackingInt(@intCast(wsa_err)))) {
                    .WSAEINTR => continue, // interrupted; retry
                    .WSAEWOULDBLOCK => error.WouldBlock,
                    .WSAECONNABORTED, .WSAECONNRESET => error.ConnectionAborted,
                    .WSAEINVAL => error.SocketNotListening,
                    .WSAEMFILE => error.ProcessFdQuotaExceeded,
                    .WSAENOTSOCK => error.FileDescriptorNotASocket,
                    else => return error.Unexpected,
                };
            }
            return @as(socket_t, @ptrFromInt(@as(usize, @bitCast(rc_signed))));
        }

        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF, .NOTSOCK, .OPNOTSUPP => return error.FileDescriptorNotASocket,
            .CONNABORTED => return error.ConnectionAborted,
            .INVAL => return error.SocketNotListening,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn close(fd: fd_t) void {
    // Intentionally swallow errors — matches the old std.posix.close behavior.
    // On Windows, use closesocket() from ws2_32 instead of CRT close().
    if (comptime native_os == .windows) {
        _ = closesocket(fd);
    } else {
        _ = system.close(fd);
    }
}

pub const ConnectError = error{
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    WouldBlock,
    OpenAlreadyInProgress,
    FileDescriptorNotASocket,
    ConnectionRefused,
    ConnectionResetByPeer,
    NetworkUnreachable,
    ConnectionTimedOut,
    SystemResources,
    FileNotFound,
    Unexpected,
};

pub fn connect(sock: socket_t, addr: *const sockaddr, len: socklen_t) ConnectError!void {
    const rc = system.connect(sock, addr, len);
    switch (errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.PermissionDenied,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .AGAIN, .INPROGRESS => return error.WouldBlock,
        .ALREADY => return error.OpenAlreadyInProgress,
        .BADF, .NOTSOCK => return error.FileDescriptorNotASocket,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .NETUNREACH => return error.NetworkUnreachable,
        .TIMEDOUT => return error.ConnectionTimedOut,
        .NOENT => return error.FileNotFound,
        else => |err| return unexpectedErrno(err),
    }
}

pub const ShutdownError = error{
    ConnectionAborted,
    ConnectionResetByPeer,
    BlockingOperationInProgress,
    FileDescriptorNotASocket,
    SocketNotConnected,
    SystemResources,
    Unexpected,
};

pub const ShutdownHow = enum(c_int) {
    recv,
    send,
    both,
};

pub fn shutdown(sock: socket_t, how: ShutdownHow) ShutdownError!void {
    const rc = system.shutdown(sock, @backingInt(how));
    switch (errno(rc)) {
        .SUCCESS => return,
        .BADF, .NOTSOCK => return error.FileDescriptorNotASocket,
        .INVAL => return error.BlockingOperationInProgress,
        .NOTCONN => return error.SocketNotConnected,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const WriteError = error{
    WouldBlock,
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
    BrokenPipe,
    ConnectionResetByPeer,
    Unexpected,
};

pub fn write(fd: fd_t, buf: []const u8) WriteError!usize {
    if (comptime native_os == .windows) {
        // On Windows, sockets must be written with send(). Winsock errors do not
        // set POSIX errno — translate WSA errors directly.
        const rc = system.send(fd, buf.ptr, buf.len, 0);
        if (rc >= 0) return @intCast(rc);
        return switch (@as(WSAError, @fromBackingInt(@intCast(WSAGetLastError())))) {
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAECONNRESET => error.ConnectionResetByPeer,
            .WSAEPIPE => error.BrokenPipe,
            else => error.Unexpected,
        };
    }
    const rc = system.write(fd, buf.ptr, buf.len);
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .BADF, .INVAL => return error.AccessDenied,
        .CONNRESET => return error.ConnectionResetByPeer,
        .DQUOT => return error.DiskQuota,
        .FBIG => return error.FileTooBig,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .PERM => return error.AccessDenied,
        .PIPE => return error.BrokenPipe,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn writev(fd: fd_t, iov: []const iovec_const) WriteError!usize {
    if (comptime native_os == .windows) {
        // Windows has no writev syscall. Emulate by writing each segment sequentially.
        // The caller (Conn.writeAllIOVec) tracks partial writes and calls writev in a
        // loop, so returning a single-segment count on each call is correct.
        if (iov.len == 0) return 0;
        const seg = iov[0];
        if (seg.len == 0) return 0;
        return write(fd, seg.base[0..seg.len]);
    }
    const rc = system.writev(fd, iov.ptr, @intCast(iov.len));
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .BADF, .INVAL => return error.AccessDenied,
        .CONNRESET => return error.ConnectionResetByPeer,
        .DQUOT => return error.DiskQuota,
        .FBIG => return error.FileTooBig,
        .IO => return error.InputOutput,
        .NOSPC => return error.NoSpaceLeft,
        .PERM => return error.AccessDenied,
        .PIPE => return error.BrokenPipe,
        else => |err| return unexpectedErrno(err),
    }
}

pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    Unexpected,
};

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    while (true) {
        const rc = system.fcntl(fd, cmd, arg);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .ACCES => return error.PermissionDenied,
            .AGAIN => return error.Locked,
            .BADF => return error.FileBusy,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const GetSockNameError = error{
    FileDescriptorNotASocket,
    SystemResources,
    Unexpected,
};

pub fn getsockname(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) GetSockNameError!void {
    const rc = system.getsockname(sock, addr, addrlen);
    switch (errno(rc)) {
        .SUCCESS => return,
        .BADF, .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

// --- Linux-only: epoll, pipe2 ---

pub const EpollCreateError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    Unexpected,
};

pub fn epoll_create1(flags: u32) EpollCreateError!fd_t {
    if (native_os != .linux) @compileError("epoll_create1 is linux-only");
    const rc = system.epoll_create1(flags);
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INVAL => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const EpollCtlError = error{
    FileDescriptorAlreadyPresentInSet,
    OperationCausesCircularLoop,
    FileDescriptorNotRegistered,
    SystemResources,
    UserResourceLimitReached,
    FileDescriptorIncompatibleWithEpoll,
    Unexpected,
};

pub fn epoll_ctl(epfd: fd_t, op: u32, fd: fd_t, event: ?*system.epoll_event) EpollCtlError!void {
    if (native_os != .linux) @compileError("epoll_ctl is linux-only");
    const rc = system.epoll_ctl(epfd, op, fd, event);
    switch (errno(rc)) {
        .SUCCESS => return,
        .BADF => unreachable,
        .EXIST => return error.FileDescriptorAlreadyPresentInSet,
        .INVAL => unreachable,
        .LOOP => return error.OperationCausesCircularLoop,
        .NOENT => return error.FileDescriptorNotRegistered,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.UserResourceLimitReached,
        .PERM => return error.FileDescriptorIncompatibleWithEpoll,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn epoll_wait(epfd: fd_t, events: []system.epoll_event, timeout: i32) usize {
    if (native_os != .linux) @compileError("epoll_wait is linux-only");
    while (true) {
        const rc = system.epoll_wait(epfd, events.ptr, @intCast(events.len), timeout);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF, .FAULT, .INVAL => unreachable,
            else => unreachable,
        }
    }
}

pub const PipeError = error{
    SystemFdQuotaExceeded,
    ProcessFdQuotaExceeded,
    Unexpected,
};

pub fn pipe2(flags: O) PipeError![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (comptime native_os == .linux) {
        const rc = system.pipe2(&fds, @bitCast(flags));
        switch (errno(rc)) {
            .SUCCESS => return fds,
            .INVAL => unreachable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => |err| return unexpectedErrno(err),
        }
    } else {
        // macOS/BSD: no pipe2 syscall. Emulate with pipe() + fcntl(F_SETFL).
        const rc = system.pipe(&fds);
        switch (errno(rc)) {
            .SUCCESS => {},
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            else => |err| return unexpectedErrno(err),
        }
        // Caller always passes .{ .NONBLOCK = true } in webzocket — apply it.
        if (flags.NONBLOCK) {
            const o_nonblock: usize = @as(u32, @bitCast(O{ .NONBLOCK = true }));
            inline for (0..2) |i| {
                const cur = fcntl(fds[i], F.GETFL, 0) catch 0;
                _ = fcntl(fds[i], F.SETFL, cur | o_nonblock) catch {};
            }
        }
        return fds;
    }
}

// --- BSD/macOS-only: kqueue, kevent ---

pub const KQueueError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    Unexpected,
};

pub fn kqueue() KQueueError!fd_t {
    const is_bsd = switch (native_os) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
    if (!is_bsd) @compileError("kqueue is bsd/macos-only");
    const rc = system.kqueue();
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return unexpectedErrno(err),
    }
}

pub const KEventError = error{
    EventNotFound,
    SystemResources,
    ProcessNotFound,
    AccessDenied,
    Unexpected,
};

pub fn kevent(
    kq: fd_t,
    changelist: []const Kevent,
    eventlist: []Kevent,
    timeout: ?*const timespec,
) KEventError!usize {
    const is_bsd = switch (native_os) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
        else => false,
    };
    if (!is_bsd) @compileError("kevent is bsd/macos-only");
    while (true) {
        const rc = system.kevent(
            kq,
            changelist.ptr,
            @intCast(changelist.len),
            eventlist.ptr,
            @intCast(eventlist.len),
            timeout,
        );
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .ACCES => return error.AccessDenied,
            .INTR => continue,
            .NOENT => return error.EventNotFound,
            .NOMEM => return error.SystemResources,
            .SRCH => return error.ProcessNotFound,
            .BADF, .FAULT, .INVAL => unreachable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

// --- Clock ---

pub const ClockGetTimeError = error{
    UnsupportedClock,
    Unexpected,
};

pub fn clock_gettime(clk: CLOCK) ClockGetTimeError!timespec {
    var ts: timespec = undefined;
    const rc = system.clock_gettime(clk, &ts);
    switch (errno(rc)) {
        .SUCCESS => return ts,
        .INVAL => return error.UnsupportedClock,
        else => |err| return unexpectedErrno(err),
    }
}

// --- Stream: replacement for std.net.Stream ---
//
// Thin wrapper over a file descriptor exposing the same surface the library
// relied on (read / writeAll / close). Used by the server's Conn, the client,
// and test SocketPair so proto.Reader.fill (`stream: anytype`) still works
// with duck-typed stream objects.

pub const Stream = struct {
    handle: socket_t,

    pub fn read(self: Stream, buf: []u8) ReadError!usize {
        return readFd(self.handle, buf);
    }

    pub fn writeAll(self: Stream, buf: []const u8) WriteError!void {
        var i: usize = 0;
        while (i < buf.len) {
            i += try write(self.handle, buf[i..]);
        }
    }

    pub fn readAtLeast(self: Stream, buf: []u8, len: usize) ReadError!usize {
        var total: usize = 0;
        while (total < len) {
            const n = try readFd(self.handle, buf[total..]);
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    pub fn close(self: Stream) void {
        close_fd(self.handle);
    }
};

pub const ReadError = error{
    WouldBlock,
    InputOutput,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    IsDir,
    Unexpected,
};

pub fn readFd(fd: fd_t, buf: []u8) ReadError!usize {
    if (comptime native_os == .windows) {
        // On Windows, sockets must be read with recv(). Winsock errors do not
        // set POSIX errno — use WSAGetLastError() via windows.ws2_32.
        const rc = system.recv(fd, buf.ptr, buf.len, 0);
        if (rc >= 0) return @intCast(rc);
        // rc == -1 (SOCKET_ERROR): translate WSA error to our error set.
        const wsa_err = WSAGetLastError();
        return switch (@as(WSAError, @fromBackingInt(@intCast(wsa_err)))) {
            .WSAEINTR => error.WouldBlock, // treat interrupt as retryable
            .WSAEWOULDBLOCK => error.WouldBlock,
            .WSAECONNRESET, .WSAECONNABORTED => error.ConnectionResetByPeer,
            .WSAETIMEDOUT => error.ConnectionTimedOut,
            .WSAEPIPE => error.BrokenPipe,
            .WSAENOTSOCK => error.NotOpenForReading,
            else => error.Unexpected,
        };
    }
    const rc = system.read(fd, buf.ptr, buf.len);
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.WouldBlock,
        .BADF => return error.NotOpenForReading,
        .CONNRESET => return error.ConnectionResetByPeer,
        .IO => return error.InputOutput,
        .ISDIR => return error.IsDir,
        .PIPE => return error.BrokenPipe,
        .TIMEDOUT => return error.ConnectionTimedOut,
        else => |err| return unexpectedErrno(err),
    }
}

// Internal alias so Stream.close avoids name collision with the module-level `close`.
fn close_fd(fd: fd_t) void {
    if (comptime native_os == .windows) {
        _ = closesocket(fd);
        return;
    }
    _ = system.close(fd);
}
