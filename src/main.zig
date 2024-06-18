const std = @import("std");
// const fuse = @import("fuse.zig");
// const FuseOps = @import("FuseOps.zig");
// const Clipboard = @import("Clipboard.zig");
const fuse = @import("fuse/kernel_api.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    const fuse_fh = try std.fs.openFileAbsolute("/dev/fuse", .{ .mode = .read_write });
    defer fuse_fh.close();
    const fuse_fd = fuse_fh.handle;

    const mount_args: [:0]u8 = try std.fmt.allocPrintZ(alloc, "fd={d},rootmode={o},user_id={d},group_id={d}", .{
        fuse_fd,
        std.posix.S.IFDIR,
        std.os.linux.geteuid(),
        std.os.linux.getegid(),
    });
    defer alloc.free(mount_args);
    std.log.debug("mount args: \"{s}\"", .{mount_args});

    // TODO: mount was returning the error code -22, but when we're using libc, errno() expects -1 and errno set
    switch (std.posix.errno(std.os.linux.mount(
        "fuse",
        "/mnt",
        "fuse.clipfs",
        std.os.linux.MS.NODEV | std.os.linux.MS.NOSUID,
        @intFromPtr(mount_args.ptr),
    ))) {
        .SUCCESS => {},
        else => |err| {
            std.log.err("mounting: {}", .{err});
            return error.MountingError;
        },
    }
    defer {
        switch (std.posix.errno(std.os.linux.umount("/mnt"))) {
            .SUCCESS => {},
            else => |err| {
                std.log.err("unmounting: {}", .{err});
            },
        }
    }

    var fuse_reader = blk: {
        const fuse_reader_unbuffered = fuse_fh.reader();
        var _fuse_reader = std.io.bufferedReaderSize(fuse.MIN_READ_BUFFER * 2, fuse_reader_unbuffered);
        break :blk _fuse_reader.reader();
    };

    const header = try fuse_reader.readStruct(fuse.InHeader);
    std.debug.print("kernel: header: {}", .{header});

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
