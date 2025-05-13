const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const in = posix.sockaddr.in;
const socket_t = posix.socket_t;
const Ip4Address = net.Ip4Address;
const Thread = std.Thread;
const windows = std.os.windows;

const UdpServer = @This();

const AtomicBool = std.atomic.Value(bool);

pub const buffer_size = 1048;

socket: socket_t,
ip4: net.Ip4Address,
dispatch_fn: ?*const fn (self: *const UdpServer, sender_addr: Ip4Address, data: []const u8) anyerror!void = null,
running: AtomicBool = .init(false),
serve_th: Thread = undefined,

pub fn getNonBlockingDGram() (posix.FcntlError || posix.SocketError)!socket_t {
    const socket: socket_t = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    errdefer posix.close(socket);

    switch (builtin.os.tag) {
        .windows => {
            var nonblocking: u32 = 1;
            const result = windows.ws2_32.ioctlsocket(socket, windows.ws2_32.FIONBIO, &nonblocking);

            if (result == windows.ws2_32.SOCKET_ERROR)
                return posix.SocketError.Unexpected;
        },
        else => {
            // wouldn't work for some reason when cross-compiling for linux
            // const O_NONBLOCK = posix.O.NONBLOCK;
            const O_NONBLOCK = 0o400;
            const flags = try posix.fcntl(socket, posix.F.GETFL, 0);
            _ = try posix.fcntl(socket, posix.F.SETFL, flags | O_NONBLOCK);
        },
    }

    return socket;
}

pub fn open(ip: []const u8, port: u16) (posix.SocketError || posix.FcntlError || net.IPv4ParseError || posix.BindError)!UdpServer {
    const socket: socket_t = try getNonBlockingDGram();
    errdefer posix.close(socket);

    const ip4 = try Ip4Address.parse(ip, port);

    try posix.bind(socket, @ptrCast(&ip4.sa), @sizeOf(in));

    return UdpServer{
        .socket = socket,
        .ip4 = ip4,
    };
}

pub fn listen(self: *UdpServer) Thread.SpawnError!void {
    if (!self.running.load(.acquire)) {
        self.running.store(true, .release);

        self.serve_th = try Thread.spawn(.{}, listenLoop, .{self});

        std.log.info("server running...", .{});
    }
}

pub inline fn close(self: *UdpServer) void {
    if (self.running.load(.acquire)) {
        self.running.store(false, .release);
        self.serve_th.join();
        std.log.info("server shut down", .{});
    }

    posix.close(self.socket);
}

pub inline fn sendTo(self: UdpServer, ip4: Ip4Address, data: []const u8) posix.SendToError!void {
    const bytes_sent = try posix.sendto(self.socket, data, 0, @ptrCast(&ip4.sa), @sizeOf(in));
    std.debug.assert(bytes_sent == data.len);
}

pub fn enableBroadcast(self: UdpServer) posix.SetSockOptError!void {
    const enable: c_int = 1;
    try posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&enable));
}

fn listenLoop(self: *UdpServer) void {
    var buffer: [buffer_size]u8 = undefined;

    while (self.running.load(.acquire) and self.dispatch_fn != null) {
        var sender_addr: in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(in);

        const data_len = posix.recvfrom(self.socket, &buffer, 0, @ptrCast(&sender_addr), &addr_len) catch |err| switch (err) {
            posix.RecvFromError.MessageTooBig => buffer_size,
            else => continue,
        };
        if (data_len == 0) continue;

        const ip4 = Ip4Address{
            .sa = sender_addr,
        };

        self.dispatch_fn.?(self, ip4, buffer[0..data_len]) catch continue;
    }
}
