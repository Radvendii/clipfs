const std = @import("std");
const Clipboard = @import("Clipboard.zig");
const Dev = @import("fuse/Dev.zig");
const FuseCallbacks = @import("FuseCallbacks.zig");
const x = @import("x11.zig");

// TODO: obviously shouldn't be hard-coded
// needs to be root-owned for now
const MNT = "/home/qolen/personal/clipfs/mnt";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var dev = dev: {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        break :dev try Dev.init(arena.allocator(), MNT);
    };

    defer dev.deinit() catch |err| std.debug.panic("Fuse failed to deinit: {}", .{err});

    var clip = try Clipboard.init(alloc);
    defer clip.deinit();
    errdefer clip.errdeinit();

    var callbacks = FuseCallbacks{
        .allocator = alloc,
        .clipboard = &clip,
    };

    var pfds = [_]std.posix.pollfd{
        .{
            .fd = dev.fh.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
        .{
            .fd = x.connectionNumber(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    while (true) {
        x.flush();
        // TODO: heard good things about epoll.
        // select?
        // ppoll?
        // is there some higher-level zig stdlib interface?
        for (&pfds) |*pfd| pfd.revents = 0;
        _ = try std.posix.poll(&pfds, -1);

        std.log.info("got something", .{});

        if (pfds[0].revents != 0) try dev.recv1(&callbacks);
        if (pfds[1].revents != 0) try clip.processEvent();
    }
}
