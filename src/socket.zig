const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket_t = posix.socket_t;
const windows = std.os.windows;
const fcntl = @import("root.zig").fnctl;

pub fn setNonBlocking(socket: socket_t) (posix.FcntlError || posix.SocketError)!void {
    switch (builtin.os.tag) {
        .windows => {
            var nonblocking: u32 = 1;
            const result = windows.ws2_32.ioctlsocket(socket, windows.ws2_32.FIONBIO, &nonblocking);

            if (result == windows.ws2_32.SOCKET_ERROR)
                return posix.SocketError.Unexpected;
        },
        else => {
            const O_NONBLOCK = fcntl.O_NONBLOCK;
            //const O_NONBLOCK = 0o400;
            const flags = try posix.fcntl(socket, posix.F.GETFL, 0);
            _ = try posix.fcntl(socket, posix.F.SETFL, flags | O_NONBLOCK);
        },
    }
}

const idle: c_int = 10;
const interval: c_int = 5;
const count: c_int = 4;

const keep_idle = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.TCP.MAXRT,
    else => posix.TCP.KEEPIDLE,
};

pub fn keepAlive(socket: socket_t) (posix.FcntlError || posix.SocketError || posix.SetSockOptError)!void {
    var keepalive: c_int = 1;
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&keepalive));
    try posix.setsockopt(socket, posix.IPPROTO.TCP, keep_idle, std.mem.asBytes(&idle));
    try posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, std.mem.asBytes(&interval));
    try posix.setsockopt(socket, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, std.mem.asBytes(&count));
}
