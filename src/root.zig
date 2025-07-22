pub const UdpClient = @import("udp/Client.zig");
pub const UdpServer = @import("udp/Server.zig");
pub const TcpClient = @import("tcp/Client.zig");
pub const TcpServer = @import("tcp/Server.zig");
pub const DataPacker = @import("DataPacker.zig");

const builtin = @import("builtin");

pub const fnctl = if (builtin.os.tag == .linux) @cImport(@cInclude("fcntl.h")) else void;
