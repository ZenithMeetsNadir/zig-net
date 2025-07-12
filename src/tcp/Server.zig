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

const TcpServer = @This();

const AtomicBool = std.atomic.Value(bool);

pub const Connection = struct {
    socket: socket_t,
    client_ip4: Ip4Address,
    running: AtomicBool = .init(false),
    awaits_disposal: AtomicBool = .init(false),
    thread: Thread = undefined,

    pub fn close(self: *Connection) void {
        if (self.running.load(.acquire)) {
            self.running.store(false, .release);

            self.thread.join();

            posix.close(self.socket);
            std.log.info("tcp connection from {} closed", .{self.client_ip4});
        }
    }

    pub fn send(self: Connection, data: []const u8) posix.WriteError!void {
        const bytes_sent = posix.write(self.socket, data) catch |err| switch (err) {
            posix.WriteError.WouldBlock => return,
            else => return err,
        };
        std.debug.assert(bytes_sent == data.len);
    }

    pub fn listen(self: *Connection, server: *TcpServer) Thread.SpawnError!void {
        if (!self.running.load(.acquire)) {
            self.running.store(true, .release);

            self.thread = try Thread.spawn(.{}, dispatchLoop, .{ self, server });

            std.log.info("tcp connection to {} opened", .{self.client_ip4});
        }
    }

    fn dispatchLoop(self: *Connection, server: *TcpServer) void {
        var buffer: [buffer_size]u8 = undefined;

        while (self.running.load(.acquire) and server.running.load(.acquire) and server.dispatch_fn != null) {
            const data_len = posix.recv(self.socket, &buffer, 0) catch |err| switch (err) {
                posix.RecvFromError.MessageTooBig => buffer_size,
                else => continue,
            };
            if (data_len == 0) continue;

            server.dispatch_fn.?(server, self, buffer[0..data_len]) catch continue;
        }
    }
};

pub const buffer_size = 1024;
const backlog = 128;

socket: socket_t,
ip4: net.Ip4Address,
dispatch_fn: ?*const fn (server: *TcpServer, connection: *Connection, data: []const u8) anyerror!void = null,
running: AtomicBool = .init(false),
serve_th: Thread = undefined,
allocator: std.mem.Allocator,
connections: std.ArrayList(*Connection),
conn_mutex: Thread.Mutex = .{},

pub fn open(ip: []const u8, port: u16, allocator: std.mem.Allocator) (posix.SocketError || posix.FcntlError || net.IPv4ParseError || posix.BindError || posix.SetSockOptError)!TcpServer {
    const socket: socket_t = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(socket);

    try socket_util.setNonBlocking(socket);
    try socket_util.keepAlive(socket);

    const ip4 = try Ip4Address.parse(ip, port);

    try posix.bind(socket, @ptrCast(&ip4.sa), @sizeOf(addr_in));

    return TcpServer{
        .socket = socket,
        .ip4 = ip4,
        .allocator = allocator,
        .connections = .init(allocator),
    };
}

pub fn listen(self: *TcpServer) (Thread.SpawnError || posix.ListenError)!void {
    if (!self.running.load(.acquire)) {
        self.running.store(true, .release);

        try posix.listen(self.socket, backlog);

        self.serve_th = try Thread.spawn(.{}, acceptLoop, .{self});

        std.log.info("tcp server running on {}...", .{self.ip4});
    }
}

pub fn close(self: *TcpServer) void {
    if (self.running.load(.acquire)) {
        self.running.store(false, .release);
        self.serve_th.join();

        self.conn_mutex.lock();
        const len = self.connections.items.len;
        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
        // no need to unlock on close

        std.log.info("all {} tcp connections closed", .{len});
    }

    posix.close(self.socket);
    std.log.info("tcp server shut down", .{});
}

fn acceptLoop(self: *TcpServer) void {
    while (self.running.load(.acquire)) {
        self.acceptLoopErrorNet() catch Thread.yield() catch {};
        self.closeExpiredConnections();
    }
}

fn acceptLoopErrorNet(self: *TcpServer) !void {
    var client_ip4: Ip4Address = undefined;

    var sock_len: posix.socklen_t = @sizeOf(@TypeOf(client_ip4.sa));
    const accepted_socket: socket_t = try posix.accept(self.socket, @ptrCast(&client_ip4.sa), &sock_len, posix.SOCK.NONBLOCK);

    // destroyed when joining the connection thread
    var connection = self.allocator.create(Connection) catch |err| {
        posix.close(accepted_socket);
        return err;
    };
    errdefer self.allocator.destroy(connection);
    connection.socket = accepted_socket;
    errdefer connection.close();
    connection.client_ip4 = client_ip4;

    try connection.listen(self);

    self.conn_mutex.lock();
    try self.connections.append(connection);
    self.conn_mutex.unlock();
}

fn closeExpiredConnections(self: *TcpServer) void {
    var i: usize = 0;
    self.conn_mutex.lock();
    while (i < self.connections.items.len) {
        if (self.connections.items[i].awaits_disposal.load(.acquire)) {
            var exp_conn = self.connections.swapRemove(i);
            exp_conn.close();
            self.allocator.destroy(exp_conn);
        } else i += 1;
    }
    self.conn_mutex.unlock();
}
