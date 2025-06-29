const std = @import("std");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const in = posix.sockaddr.in;
const socket_t = posix.socket_t;
const Ip4Address = net.Ip4Address;
const Thread = std.Thread;
const socket_util = @import("../socket.zig");

const UdpServer = @import("Server.zig");
const UdpClient = @This();

udp_core: UdpServer,
dispatch_fn: ?*const fn (self: *const UdpClient, data: []const u8) anyerror!void = null,

pub fn connect(ip: []const u8, port: u16) (posix.SocketError || posix.FcntlError || net.IPv4ParseError || posix.ConnectError)!UdpClient {
    const socket: socket_t = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    errdefer posix.close(socket);

    try socket_util.setNonBlocking(socket);

    const ip4 = try Ip4Address.parse(ip, port);

    posix.connect(socket, @ptrCast(&ip4.sa), @sizeOf(in)) catch |err| switch (err) {
        posix.ConnectError.WouldBlock => {},
        else => return err,
    };

    return UdpClient{ .udp_core = UdpServer{
        .socket = socket,
        .ip4 = ip4,
    } };
}

pub fn listen(self: *UdpClient) Thread.SpawnError!void {
    if (!self.udp_core.running.load(.acquire)) {
        self.udp_core.running.store(true, .release);

        self.udp_core.serve_th = try Thread.spawn(.{}, listenLoop, .{self});

        std.log.info("udp client running...", .{});
    }
}

pub inline fn close(self: *UdpClient) void {
    self.udp_core.close();
}

pub fn send(self: UdpClient, data: []const u8) posix.WriteError!void {
    const bytes_sent = posix.write(self.udp_core.socket, data) catch |err| switch (err) {
        posix.WriteError.WouldBlock => return,
        else => return err,
    };
    std.debug.assert(bytes_sent == data.len);
}

// self param has to be a pointer in order to determine when the loop should break
fn listenLoop(self: *const UdpClient) void {
    var buffer: [UdpServer.buffer_size]u8 = undefined;

    while (self.udp_core.running.load(.acquire) and self.dispatch_fn != null) {
        const data_len = posix.recv(self.udp_core.socket, &buffer, 0) catch |err| switch (err) {
            posix.RecvFromError.MessageTooBig => UdpServer.buffer_size,
            else => continue,
        };
        if (data_len == 0) continue;

        self.dispatch_fn.?(self, buffer[0..data_len]) catch continue;
    }
}
