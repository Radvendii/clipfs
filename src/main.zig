const std = @import("std");
const fuse = @import("fuse.zig");
const FuseOps = @import("FuseOps.zig");
const Clipboard = @import("Clipboard.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var clip = try Clipboard.init(alloc);
    defer clip.deinit();
    errdefer clip.errdeinit();

    // Read in the new clipboard contents (the file specified as an argument, or stdin)
    const in = std.io.getStdIn();
    defer in.close();
    // TODO: handle arbitrary lengths
    const clipboard = in.readToEndAlloc(alloc, 1_000_000_000) catch
        std.debug.panic("can't handle file larger than 1GB", .{});
    defer alloc.free(clipboard);

    try clip.copy(clipboard);

    // spawn FUSE main thread, which will handle reads from and writes to our file system and forward them to our FuseOps callbacks
    // From here on out we have to be careful accessing the clipboard only behind the mutex
    const fuse_thread = try std.Thread.spawn(.{}, fuse.main, .{ std.os.argv, FuseOps, &clip });
    try clip.eventLoop();
    // TODO: deal with return value?
    // TODO: It's worse than that. C-c seems to not even kill the fuse thread
    fuse_thread.join();
}
