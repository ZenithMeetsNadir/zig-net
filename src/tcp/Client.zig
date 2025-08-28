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
const tcp = @import("tcp.zig");

const TcpClient = @This();

const AtomicBool = std.atomic.Value(bool);

const ConnectError = tcp.OpenError || posix.ConnectError;
const ListenError = tcp.ListenError || error{NotConnected};

socket: socket_t,
ip4: net.Ip4Address,
blocking: bool,
connected: bool,
/// this callback should be written with care, as it will be called from the listen thread
dispatch_fn: ?*const fn (self: *const TcpClient, data: []const u8) anyerror!void = null,
listening: AtomicBool = .init(false),
listen_th: ?Thread = null,

pub fn connect(ip: []const u8, port: u16, blocking: bool) ConnectError!TcpClient {
    const socket: socket_t = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(socket);

    if (!blocking)
        try socket_util.setNonBlocking(socket);

    const ip4 = try Ip4Address.parse(ip, port);

    posix.connect(socket, @ptrCast(&ip4.sa), @sizeOf(addr_in)) catch |err| switch (err) {
        posix.ConnectError.WouldBlock => if (blocking) return err,
        else => return err,
    };

    return TcpClient{
        .socket = socket,
        .ip4 = ip4,
        .blocking = blocking,
        .connected = true,
    };
}

pub fn listen(self: *TcpClient) ListenError!void {
    if (!self.connected)
        return ListenError.NotConnected;

    if (self.listen_th != null)
        return ListenError.AlreadyListening;

    self.listening.store(true, .release);
    errdefer self.listening.store(false, .release);

    self.listen_th = try Thread.spawn(.{}, listenLoop, .{self});

    std.log.info("tcp client running...", .{});
}

pub fn close(self: *TcpClient) void {
    if (self.listen_th) |th| {
        self.listening.store(false, .release);

        if (self.blocking) {
            self.connected = false;
            posix.shutdown(self.socket, posix.ShutdownHow.both) catch |err| {
                std.log.err("tcp client socket shutdown error: {s}", .{@errorName(err)});
                std.log.info("tcp client closing socket", .{});
                posix.close(self.socket);
            };
        }

        th.join();
        self.listen_th = null;
    }

    if (self.connected) {
        self.connected = false;
        posix.close(self.socket);
    }

    std.log.info("tcp client shut down", .{});
}

pub fn send(self: TcpClient, data: []const u8) tcp.SendError!void {
    const bytes_sent = posix.write(self.socket, data) catch |err| switch (err) {
        posix.WriteError.WouldBlock => if (self.blocking) return err else return,
        else => return err,
    };

    if (bytes_sent != data.len)
        std.log.err("tcp client send failed - number of bytes sent: {d} of {d}", .{ bytes_sent, data.len });
}

fn listenLoop(self: *const TcpClient) void {
    var buffer: [tcp.buffer_size]u8 = undefined;

    while (self.listening.load(.acquire) and self.dispatch_fn != null) {
        const data_len = posix.recv(self.socket, &buffer, 0) catch |err| switch (err) {
            posix.RecvFromError.MessageTooBig => tcp.buffer_size,
            else => continue,
        };
        if (data_len == 0) continue;

        self.dispatch_fn.?(self, buffer[0..data_len]) catch continue;
    }
}
