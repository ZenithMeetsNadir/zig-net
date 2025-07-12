const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const mem = std.mem;
const posix = std.posix;
const addr_in = posix.sockaddr.in;
const socket_t = posix.socket_t;
const Ip4Address = net.Ip4Address;
const Thread = std.Thread;
const windows = std.os.windows;
const socket_util = @import("../socket.zig");

const UdpServer = @This();

const AtomicBool = std.atomic.Value(bool);

pub const buffer_size = 1024;

socket: socket_t,
ip4: net.Ip4Address,
dispatch_fn: ?*const fn (server: *const UdpServer, sender_addr: Ip4Address, data: []const u8) anyerror!void = null,
running: AtomicBool = .init(false),
serve_th: Thread = undefined,

pub fn open(ip: []const u8, port: u16) (posix.SocketError || posix.FcntlError || net.IPv4ParseError || posix.BindError)!UdpServer {
    const socket: socket_t = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    errdefer posix.close(socket);

    try socket_util.setNonBlocking(socket);

    const ip4 = try Ip4Address.parse(ip, port);

    try posix.bind(socket, @ptrCast(&ip4.sa), @sizeOf(addr_in));

    return UdpServer{
        .socket = socket,
        .ip4 = ip4,
    };
}

pub fn listen(self: *UdpServer) Thread.SpawnError!void {
    if (!self.running.load(.acquire)) {
        self.running.store(true, .release);

        self.serve_th = try Thread.spawn(.{}, listenLoop, .{self});

        std.log.info("udp server running on {}...", .{self.ip4});
    }
}

pub inline fn close(self: *UdpServer) void {
    if (self.running.load(.acquire)) {
        self.running.store(false, .release);
        self.serve_th.join();
    }

    posix.close(self.socket);
    std.log.info("udp server shut down", .{});
}

pub inline fn sendTo(self: UdpServer, ip4: Ip4Address, data: []const u8) posix.SendToError!void {
    const bytes_sent = posix.sendto(self.socket, data, 0, @ptrCast(&ip4.sa), @sizeOf(addr_in)) catch |err| switch (err) {
        posix.SendToError.WouldBlock => return,
        else => return err,
    };
    std.debug.assert(bytes_sent == data.len);
}

pub fn enableBroadcast(self: UdpServer) posix.SetSockOptError!void {
    const enable: c_int = 1;
    try posix.setsockopt(self.socket, posix.SOL.SOCKET, posix.SO.BROADCAST, std.mem.asBytes(&enable));
}

fn listenLoop(self: *UdpServer) void {
    var buffer: [buffer_size]u8 = undefined;

    while (self.running.load(.acquire) and self.dispatch_fn != null) {
        var sender_ip4: Ip4Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(addr_in);

        const data_len = posix.recvfrom(self.socket, &buffer, 0, @ptrCast(&sender_ip4.sa), &addr_len) catch |err| switch (err) {
            posix.RecvFromError.MessageTooBig => buffer_size,
            else => continue,
        };
        if (data_len == 0) continue;

        self.dispatch_fn.?(self, sender_ip4, buffer[0..data_len]) catch continue;
    }
}
