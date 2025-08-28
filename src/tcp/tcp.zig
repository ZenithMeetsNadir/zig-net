const std = @import("std");
const posix = std.posix;
const net = std.net;

pub const OpenError = posix.SocketError || posix.FcntlError || net.IPv4ParseError;
pub const ListenError = std.Thread.SpawnError || error{AlreadyListening};
pub const SendError = posix.WriteError;

pub const buffer_size = 1024;
