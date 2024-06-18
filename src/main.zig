const std = @import("std");
// const fuse = @import("fuse.zig");
// const FuseOps = @import("FuseOps.zig");
// const Clipboard = @import("Clipboard.zig");
const fuse = @import("fuse/kernel_api.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    // const fuse_fd = try std.posix.open("/dev/fuse", .{ .ACCMODE = .RDWR }, 0);
    // std.debug.assert(fuse_fd > 0);
    // defer std.posix.close(fuse_fd);

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

    // try std.posix.chdir("/");

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

    std.log.debug("/dev/fuse fd: {}", .{fuse_fd});
    std.log.debug("stdin fd: {}", .{std.io.getStdIn().handle});

    var buf: [fuse.MIN_READ_BUFFER]u8 = [_]u8{0} ** fuse.MIN_READ_BUFFER;
    {
        const valid = std.os.linux.fcntl(fuse_fd, std.os.linux.F.GETFL, 0);
        std.log.debug("status of the fd: {x}", .{valid});
    }
    const amt = amt: {
        const ret = std.os.linux.read(fuse_fd, &buf, buf.len);
        switch (std.posix.errno(ret)) {
            .SUCCESS => break :amt ret,
            else => |err| {
                std.log.err("reading: {}", .{err});
                return error.ReadingError;
            },
        }
    };
    // const amt = try std.posix.read(fuse_fd, &buf);
    std.debug.assert(amt == buf.len);
    const header = std.mem.bytesAsValue(fuse.InHeader, &buf);

    // const fuse_reader = fuse_fh.reader();
    // const header = try fuse_reader.readStruct(fuse.InHeader);
    std.debug.print("kernel: header: {}", .{header.*});

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
