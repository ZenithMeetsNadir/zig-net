const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const in = posix.sockaddr.in;
const socket_t = posix.socket_t;
const Ip4Address = net.Ip4Address;
const Thread = std.Thread;

const UdpServer = @import("UdpServer.zig");
const UdpClient = @This();

udp_core: UdpServer,
dispatch_fn: ?*const fn (self: *const UdpClient, data: []const u8) anyerror!void = null,

pub fn connect(ip: []const u8, port: u16) (posix.SocketError || posix.FcntlError || net.IPv4ParseError || posix.BindError)!UdpClient {
    const socket: socket_t = try UdpServer.getNonBlockingDGram();
    const ip4 = try Ip4Address.parse(ip, port);

    try posix.connect(socket, @ptrCast(&ip4.sa), @sizeOf(in));

    return UdpClient{UdpServer{
        .socket = socket,
        .ip4 = ip4,
    }};
}

pub fn listen(self: *UdpClient) Thread.SpawnError!void {
    if (!self.udp_core.running.load(.acquire)) {
        self.udp_core.running.store(true, .release);

        self.udp_core.serve_th = try Thread.spawn(.{}, listenLoop, .{self.*});

        std.log.info("server running...", .{});
    }
}

pub inline fn close(self: UdpClient) void {
    self.udp_core.close();
}

pub fn send(self: UdpClient, data: []const u8) posix.WriteError!void {
    try posix.write(self.udp_core.socket, data);
}

fn listenLoop(self: UdpClient) void {
    var buffer: [UdpServer.buffer_size]u8 = undefined;

    while (self.udp_core.running.load(.acquire) and self.dispatch_fn != null) {
        const data_len = posix.recv(self.udp_core.socket, &buffer, 0) catch continue;
        if (data_len == 0) continue;

        self.dispatch_fn(&self, buffer[0..data_len]) catch continue;
    }
}
