const std = @import("std");

const DataPacker = @This();

const Message = std.ArrayList(u8);

pw: []const u8,
prefix: []const u8,
delim: u8 = '&',
key_value: bool = false,
key_value_delim: u8 = '=',

pub fn init(pw: []const u8, prefix: []const u8, delim: ?u8) DataPacker {
    var dp = DataPacker{
        .pw = pw,
        .prefix = prefix,
    };
    if (delim) |d|
        dp.delim = d;

    return dp;
}

pub fn keyValueMode(self: *DataPacker, key_value_delim: ?u8) void {
    self.key_value = true;
    if (key_value_delim) |kvd|
        self.key_value_delim = kvd;
}

/// DISCLAIMER:
/// the following encryption and decryption is merely a xor obfuscation and guarantees less than no security
pub fn whichevercrypt(self: DataPacker, data: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    const encrypted = try allocator.alloc(u8, data.len);

    for (data, 0..) |byte, i| {
        encrypted[i] = byte ^ self.pw[i % self.pw.len];
    }

    return encrypted;
}

pub inline fn verify(self: DataPacker, data: []const u8) bool {
    return std.mem.startsWith(u8, data, self.prefix);
}

pub inline fn iteratorOver(self: DataPacker, data: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, data, self.delim);
}

pub fn valueOfContinue(self: DataPacker, iter: *std.mem.SplitIterator(u8, .scalar), key: []const u8) ?[]const u8 {
    if (!self.key_value)
        return null;

    return while (iter.next()) |pair| {
        if (pair.len > key.len and std.mem.startsWith(u8, pair, key) and pair[key.len] == self.key_value_delim)
            break pair[key.len + 1 ..];
    } else null;
}

pub fn valueOf(self: DataPacker, data: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, data, self.delim);
    return self.valueOfContinue(&iter, key);
}

pub fn message(self: DataPacker, allocator: std.mem.Allocator) std.mem.Allocator.Error!Message {
    var buffer: Message = .init(allocator);
    try buffer.appendSlice(self.prefix);

    return buffer;
}

pub fn msgAppend(self: DataPacker, buffer: *Message, value: []const u8, key: ?[]const u8) std.mem.Allocator.Error!void {
    try buffer.append(self.delim);

    if (key) |k| {
        try buffer.appendSlice(k);
        try buffer.append(self.key_value_delim);
    }

    try buffer.appendSlice(value);
}
