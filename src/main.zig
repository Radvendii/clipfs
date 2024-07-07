const std = @import("std");
// const fuse = @import("fuse.zig");
// const FuseOps = @import("FuseOps.zig");
// const Clipboard = @import("Clipboard.zig");
const Dev = @import("fuse/Dev.zig");
const FuseCallbacks = @import("FuseCallbacks.zig");

// TODO: obviously shouldn't be hard-coded
// needs to be root-owned for now
const MNT = "/home/qolen/personal/clipfs/mnt";

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const alloc = gpa.allocator();

    var dev = try Dev.init(MNT);
    defer dev.deinit() catch |err| std.debug.panic("Fuse failed to deinit: {}", .{err});
    var callbacks = FuseCallbacks{};
    while (true) {
        try dev.recv1(&callbacks);
    }

    // var clip = try Clipboard.init(alloc);
    // defer clip.deinit();
    // errdefer clip.errdeinit();

    // // Read in the new clipboard contents (the file specified as an argument, or stdin)
    // const in = std.io.getStdIn();
    // defer in.close();
    // // TODO: handle arbitrary lengths
    // const clipboard = in.readToEndAlloc(alloc, 1_000_000_000) catch
    //     std.debug.panic("can't handle file larger than 1GB", .{});
    // defer alloc.free(clipboard);

    // try clip.copy(clipboard);

    // // spawn FUSE main thread, which will handle reads from and writes to our file system and forward them to our FuseOps callbacks
    // // From here on out we have to be careful accessing the clipboard only behind the mutex
    // // TODO: fuse_main() daemonizes and shit. let's not call it.
    // const fuse_thread = try std.Thread.spawn(.{}, fuse.main, .{ std.os.argv, FuseOps, &clip });
    // try clip.eventLoop();
    // // TODO: deal with return value?
    // // TODO: It's worse than that. C-c seems to not even kill the fuse thread
    // fuse_thread.join();
}
