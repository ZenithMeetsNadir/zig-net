const std = @import("std");
const posix = std.posix;
const Ip4Address = std.net.Ip4Address;

const UdpServer = @import("UdpServer.zig");
const UdpClient = @import("UdpClient.zig");
const DataPacker = @import("DataPacker.zig");

const UdpS = struct {
    ip4: Ip4Address,
    name: []const u8,
    tick: usize,
};

const server_port = 6969;

var allocator: std.mem.Allocator = undefined;

var udp_servers: std.ArrayList(UdpS) = undefined;

var udp_search: UdpServer = undefined;
var search_running: std.atomic.Value(bool) = .init(true);

var dp: DataPacker = blk: {
    var dp_blk: DataPacker = .init("nejtajnejsiheslouwu", "uwu", null);
    dp_blk.keyValueMode(null);

    break :blk dp_blk;
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    allocator = gpa.allocator();
    defer _ = gpa.deinit();

    udp_servers = .init(allocator);
    defer udp_servers.deinit();

    const std_in = std.io.getStdIn().reader();

    {
        udp_search = try .open("0.0.0.0", 0);
        defer udp_search.close();

        try udp_search.enableBroadcast();

        udp_search.dispatch_fn = dispatchSearchResponse;

        try udp_search.listen();

        const search_th = try std.Thread.spawn(.{}, broadcastSearchLoop, .{});

        std.log.info("press ENTER to stop the search...", .{});
        while (try std_in.readByte() != '\n') {}

        search_running.store(false, .release);
        search_th.join();

        std.log.info("search interrupted", .{});
        std.log.info("found {} active server(s)", .{udp_servers.items.len});
    }
}

fn dispatchSearchResponse(self: *const UdpServer, sender_addr: Ip4Address, data: []const u8) anyerror!void {
    _ = self;

    const decoded = try dp.whichevercrypt(data, allocator);
    defer allocator.free(decoded);

    if (!dp.verify(decoded))
        return;

    var iter = dp.iteratorOver(decoded);
    if (dp.valueOfContinue(&iter, "sname")) |s_name| {
        const tick = try std.fmt.parseUnsigned(usize, dp.valueOfContinue(&iter, "t") orelse return, 0);

        var log_servers = false;
        var i: usize = 0;
        while (i < udp_servers.items.len) {
            if (tick >= 4 and udp_servers.items[i].tick < tick - 4) {
                _ = udp_servers.swapRemove(i);
                log_servers = true;
                continue;
            }

            i += 1;
        }

        const append = for (udp_servers.items) |*server| {
            if (std.meta.eql(server.ip4, sender_addr)) {
                server.tick = tick;
                break false;
            }
        } else true;

        if (append) {
            try udp_servers.append(.{
                .ip4 = sender_addr,
                .name = s_name,
                .tick = tick,
            });
            log_servers = true;
        }

        if (log_servers) {
            for (udp_servers.items) |server| {
                std.debug.print("{s}: {}; ", .{ server.name, server.ip4 });
            }
            std.debug.print("\n", .{});
        }
    }
}

var tick_c: usize = 0;
fn broadcastSearchLoop() anyerror!void {
    const ip4 = try Ip4Address.parse("255.255.255.255", server_port);

    std.log.info("broadcasting server search trigger...", .{});
    while (search_running.load(.acquire)) {
        std.time.sleep(std.time.ns_per_s);

        var msg = try dp.message(allocator);
        defer msg.deinit();

        try dp.msgAppend(&msg, "", "s");

        const tick_str = try std.fmt.allocPrint(allocator, "{d}", .{tick_c});
        defer allocator.free(tick_str);
        try dp.msgAppend(&msg, tick_str, "t");

        const question_existence = try dp.whichevercrypt(msg.items, allocator);
        defer allocator.free(question_existence);

        udp_search.sendTo(ip4, question_existence) catch continue;

        tick_c += 1;
    }

    std.log.info("search broadcast ended", .{});
}
