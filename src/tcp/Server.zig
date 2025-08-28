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
const tcp = @import("tcp.zig");

const TcpServer = @This();

const AtomicBool = std.atomic.Value(bool);

const OpenError = tcp.OpenError || posix.BindError || posix.SetSockOptError;
const ListenError = tcp.ListenError || posix.ListenError || error{NotBound};
const AcceptLoopError = std.mem.Allocator.Error || posix.AcceptError || Connection.ConnListenError;

pub const Connection = struct {
    pub const ConnListenError = tcp.ListenError || error{ NotAlive, AlreadyListening };
    pub const ConnAcceptError = posix.AcceptError;

    socket: socket_t,
    client_ip4: Ip4Address,
    alive: bool,
    listening: AtomicBool = .init(false),
    awaits_disposal: AtomicBool = .init(false),
    listen_th: ?Thread = null,
    server: *TcpServer,

    pub fn accept(bound_socket: socket_t, server: *TcpServer) ConnAcceptError!Connection {
        var client_ip4: Ip4Address = undefined;
        var sock_len: posix.socklen_t = @sizeOf(@TypeOf(client_ip4.sa));
        const flags: u32 = if (!server.blocking) posix.SOCK.NONBLOCK else 0;

        const socket = try posix.accept(bound_socket, @ptrCast(&client_ip4.sa), &sock_len, flags);

        return Connection{
            .socket = socket,
            .client_ip4 = client_ip4,
            .alive = true,
            .server = server,
        };
    }

    pub fn close(self: *Connection) void {
        if (self.listen_th) |th| {
            self.listening.store(false, .release);

            if (self.server.blocking) {
                self.alive = false;
                posix.shutdown(self.socket, posix.ShutdownHow.both) catch |err| {
                    std.log.err("tcp server connection socket shutdown error: {s}", .{@errorName(err)});
                    std.log.info("tcp server connection closing socket", .{});
                    posix.close(self.socket);
                };
            }

            th.join();
            self.listen_th = null;
        }

        if (self.alive) {
            self.alive = false;
            posix.close(self.socket);
        }

        std.log.info("tcp connection from {f} closed", .{self.client_ip4});
    }

    pub fn listen(self: *Connection) ConnListenError!void {
        if (!self.alive)
            return ConnListenError.NotAlive;

        if (self.listen_th != null)
            return ConnListenError.AlreadyListening;

        self.listening.store(true, .release);
        errdefer self.listening.store(false, .release);

        self.listen_th = try Thread.spawn(.{}, listenLoop, .{self});

        std.log.info("tcp connection to {f} opened", .{self.client_ip4});
    }

    fn listenLoop(self: *Connection) void {
        if (self.server.dispatch_fn == null)
            return;

        var buffer: [tcp.buffer_size]u8 = undefined;

        while (self.listening.load(.acquire) and self.server.listening.load(.acquire)) {
            const data_len = posix.recv(self.socket, &buffer, 0) catch |err| switch (err) {
                posix.RecvFromError.MessageTooBig => tcp.buffer_size,
                else => continue,
            };
            if (data_len == 0) continue;

            self.server.dispatch_fn.?(self, buffer[0..data_len]) catch continue;
        }
    }

    pub fn send(self: Connection, data: []const u8) tcp.SendError!void {
        const bytes_sent = posix.write(self.socket, data) catch |err| switch (err) {
            posix.WriteError.WouldBlock => if (self.server.blocking) return err else return,
            else => return err,
        };

        if (bytes_sent != data.len)
            std.log.err("tcp server send failed - number of bytes sent: {d} of {d}", .{ bytes_sent, data.len });
    }

    pub inline fn markForDisposal(self: *Connection) void {
        self.awaits_disposal.store(true, .release);
    }
};

const backlog = 128;

socket: socket_t,
ip4: Ip4Address,
blocking: bool,
bound: bool,
/// this callback should be written with care, as it will be called from multiple listening connection threads
dispatch_fn: ?*const fn (connection: *Connection, data: []const u8) anyerror!void = null,
listening: AtomicBool = .init(false),
listen_th: ?Thread = null,
allocator: std.mem.Allocator,
connections: std.array_list.Managed(*Connection),
conn_mutex: Thread.Mutex = .{},

pub fn open(ip: []const u8, port: u16, blocking: bool, allocator: std.mem.Allocator) OpenError!TcpServer {
    const socket: socket_t = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(socket);

    if (!blocking)
        try socket_util.setNonBlocking(socket);

    try socket_util.keepAlive(socket);

    const ip4 = try Ip4Address.parse(ip, port);

    try posix.bind(socket, @ptrCast(&ip4.sa), @sizeOf(addr_in));

    return TcpServer{
        .socket = socket,
        .ip4 = ip4,
        .blocking = blocking,
        .bound = true,
        .allocator = allocator,
        .connections = .init(allocator),
    };
}

pub fn close(self: *TcpServer) void {
    if (self.listen_th) |th| {
        self.listening.store(false, .release);

        if (self.blocking) {
            self.bound = false;
            posix.shutdown(self.socket, posix.ShutdownHow.both) catch |err| {
                std.log.err("tcp server socket shutdown error: {s}", .{@errorName(err)});
                std.log.info("tcp server closing socket", .{});
                posix.close(self.socket);
            };
        }

        th.join();
        self.listen_th = null;

        self.conn_mutex.lock();
        const len = self.connections.items.len;
        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
        self.conn_mutex.unlock();

        std.log.info("all {d} tcp connections closed", .{len});
    }

    if (self.bound) {
        self.bound = false;
        posix.close(self.socket);
    }

    std.log.info("tcp server shut down", .{});
}

pub fn listen(self: *TcpServer) ListenError!void {
    if (!self.bound)
        return ListenError.NotBound;

    if (self.listen_th != null)
        return ListenError.AlreadyListening;

    self.listening.store(true, .release);
    errdefer self.listening.store(false, .release);

    try posix.listen(self.socket, backlog);

    self.listen_th = try Thread.spawn(.{}, acceptLoop, .{self});

    std.log.info("tcp server listening on {f}...", .{self.ip4});
}

fn acceptLoop(self: *TcpServer) void {
    while (self.listening.load(.acquire)) {
        self.acceptLoopErrorNet() catch {};
        self.closeExpiredConnections();
    }
}

fn acceptLoopErrorNet(self: *TcpServer) AcceptLoopError!void {
    var conn = try Connection.accept(self.socket, self);
    errdefer conn.close();

    // destroyed when joining the connection thread
    var conn_alloc = try self.allocator.create(Connection);
    errdefer self.allocator.destroy(conn_alloc);
    conn_alloc.* = conn;

    try conn_alloc.listen();

    self.conn_mutex.lock();
    try self.connections.append(conn_alloc);
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
