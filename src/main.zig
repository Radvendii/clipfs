const std = @import("std");
const fuse = @import("fuse.zig");
const FuseOps = @import("FuseOps.zig").FuseOps(Shared);

const Shared = struct {
    pub const mutex: std.Thread.Mutex = .{};
    pub var clipboard: []u8 = undefined;
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    // Read in the new clipboard contents (the file specified as an argument, or stdin)
    const in = std.io.getStdIn();
    defer in.close();
    // TODO: handle arbitrary lengths
    Shared.clipboard = in.readToEndAlloc(alloc, 1_000_000_000) catch
        std.debug.panic("can't handle file larger than 1GB", .{});
    defer alloc.free(Shared.clipboard);

    // spawn FUSE main thread, which will handle reads from and writes to our file system.
    const t = try std.Thread.spawn(.{}, fuse.main, .{ std.os.argv, FuseOps, null });
    // TODO: deal with return value?
    t.join();
}
