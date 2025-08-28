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

pub const ConnectError = tcp.OpenError || posix.ConnectError;
pub const ListenError = tcp.ListenError || error{NotConnected};
pub const SendError = tcp.SendError || error{NotConnected};

socket: socket_t,
ip4: net.Ip4Address,
blocking: bool,
connected: bool,
/// this callback should be written with care, as it will be called from the listen thread
dispatch_fn: ?*const fn (self: *const TcpClient, data: []const u8) anyerror!void = null,
listening: AtomicBool = .init(false),
listen_th: ?Thread = null,
buffer_size: usize,

/// Creates a TCP client and connects to the specified IP and port. Uses a blocking or non-blocking socket
pub fn connect(ip: []const u8, port: u16, blocking: bool, buffer_size: ?usize) ConnectError!TcpClient {
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
        .buffer_size = buffer_size orelse tcp.buffer_size,
    };
}

/// closes the TCP client socket and stops the listen thread if running.
///
/// It is safe to call this function more than once.
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

/// starts listening on a dedicated thread for incoming data.
///
/// Returns
/// `NotConnected` if the client is not connected
/// `AlreadyListening` if the listen thread is already running.
pub fn listen(self: *TcpClient, allocator: std.mem.Allocator) ListenError!void {
    if (!self.connected)
        return ListenError.NotConnected;

    if (self.listen_th != null)
        return ListenError.AlreadyListening;

    self.listening.store(true, .release);
    errdefer self.listening.store(false, .release);

    self.listen_th = try Thread.spawn(.{}, listenLoop, .{ self, allocator });

    std.log.info("tcp client running...", .{});
}

fn listenLoop(self: *const TcpClient, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
    if (self.dispatch_fn == null) {
        std.log.warn("tcp client dispatch function is not set", .{});
        return;
    }

    const buffer = try allocator.alloc(u8, self.buffer_size);
    defer allocator.free(buffer);

    while (self.listening.load(.acquire)) {
        const data_len = posix.recv(self.socket, buffer, 0) catch |err| switch (err) {
            posix.RecvFromError.MessageTooBig => tcp.buffer_size,
            else => continue,
        };
        if (data_len == 0) continue;

        self.dispatch_fn.?(self, buffer[0..data_len]) catch continue;
    }
}

/// sends data through client's connected socket
///
/// Returns `NotConnected` if the client is not connected
pub fn send(self: TcpClient, data: []const u8) SendError!void {
    if (!self.connected)
        return SendError.NotConnected;

    const bytes_sent = posix.write(self.socket, data) catch |err| switch (err) {
        posix.WriteError.WouldBlock => if (self.blocking) return err else return,
        else => return err,
    };

    if (bytes_sent != data.len)
        std.log.err("tcp client send failed - number of bytes sent: {d} of {d}", .{ bytes_sent, data.len });
}
