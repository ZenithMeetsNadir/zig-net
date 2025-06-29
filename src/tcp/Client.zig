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
const TcpServer = @import("Server.zig");

const TcpClient = @This();

const AtomicBool = std.atomic.Value(bool);

socket: socket_t,
ip4: net.Ip4Address,
dispatch_fn: ?*const fn (self: *const TcpClient, data: []const u8) anyerror!void = null,
running: AtomicBool = .init(false),
serve_th: Thread = undefined,

pub fn connect(ip: []const u8, port: u16) (posix.SocketError || posix.FcntlError || net.IPv4ParseError || posix.ConnectError)!TcpClient {
    const socket: socket_t = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(socket);

    try socket_util.setNonBlocking(socket);

    const ip4 = try Ip4Address.parse(ip, port);

    posix.connect(socket, @ptrCast(&ip4.sa), @sizeOf(addr_in)) catch |err| switch (err) {
        posix.ConnectError.WouldBlock => {},
        else => return err,
    };

    return TcpClient{
        .socket = socket,
        .ip4 = ip4,
    };
}

pub fn listen(self: *TcpClient) Thread.SpawnError!void {
    if (!self.running.load(.acquire)) {
        self.running.store(true, .release);

        self.serve_th = try Thread.spawn(.{}, listenLoop, .{self});

        std.log.info("tcp client running...", .{});
    }
}

pub fn close(self: *TcpClient) void {
    if (self.running.load(.acquire)) {
        self.running.store(false, .release);
        self.serve_th.join();
    }

    posix.close(self.socket);
    std.log.info("tcp client shut down", .{});
}

pub fn send(self: TcpClient, data: []const u8) posix.WriteError!void {
    const bytes_sent = posix.write(self.socket, data) catch |err| switch (err) {
        posix.WriteError.WouldBlock => return,
        else => return err,
    };
    std.debug.assert(bytes_sent == data.len);
}

// self param has to be a pointer in order to determine when the loop should break
fn listenLoop(self: *const TcpClient) void {
    var buffer: [TcpServer.buffer_size]u8 = undefined;

    while (self.running.load(.acquire) and self.dispatch_fn != null) {
        const data_len = posix.recv(self.socket, &buffer, 0) catch |err| switch (err) {
            posix.RecvFromError.MessageTooBig => TcpServer.buffer_size,
            else => continue,
        };
        if (data_len == 0) continue;

        self.dispatch_fn.?(self, buffer[0..data_len]) catch continue;
    }
}
