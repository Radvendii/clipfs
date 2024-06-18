const std = @import("std");
const log = std.log.scoped(.fuse);

pub const kernel = @import("kernel_api.zig");

const Self = @This();

dev: std.fs.File,
// TODO: is this the right use of AnyReader? Should I be more specific here?
reader: std.io.AnyReader,

pub fn init() !Self {
    const dev = try std.fs.openFileAbsolute("/dev/fuse", .{ .mode = .read_write });
    errdefer dev.close();

    var buf: [256]u8 = undefined;
    const mount_args: [:0]u8 = try std.fmt.bufPrintZ(&buf, "fd={d},rootmode={o},user_id={d},group_id={d}", .{
        dev.handle,
        std.posix.S.IFDIR,
        std.os.linux.geteuid(),
        std.os.linux.getegid(),
    });
    log.debug("mount args: \"{s}\"", .{mount_args});

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
            log.err("mounting: {}", .{err});
            return error.Mount;
        },
    }
    errdefer unmount() catch @panic("failed to unmount");

    const reader_unbuffered = dev.reader();
    var _reader = std.io.bufferedReaderSize(kernel.MIN_READ_BUFFER * 2, reader_unbuffered);
    const reader = _reader.reader();

    const self = Self{
        .dev = dev,
        .reader = reader.any(),
    };

    // init exchange

    const header = try reader.readStruct(kernel.InHeader);
    std.debug.print("kernel: header: {}", .{header});

    return self;
}

pub fn unmount() !void {
    switch (std.posix.errno(std.os.linux.umount("/mnt"))) {
        .SUCCESS => {},
        else => |err| {
            log.err("unmounting: {}", .{err});
            return error.Unmount;
        },
    }
}

pub fn deinit(self: Self) !void {
    try unmount();
    self.dev.close();
}
