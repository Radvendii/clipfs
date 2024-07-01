const std = @import("std");
const Dev = @import("Dev.zig");
const kernel = @import("kernel.zig");
const log = std.log.scoped(.@"fuse-low-level");

pub const Callbacks = struct {
    pub fn getattr(dev: *Dev, header: kernel.InHeader, getattr_in: kernel.GetattrIn) !void {
        std.debug.assert(getattr_in.getattr_flags.fh == false);

        switch (header.nodeid) {
            kernel.ROOT_ID => {
                try dev.sendOut(header.unique, kernel.AttrOut{
                    // can i send an "invalidate" signal to the kernel?
                    .attr_valid = 0,
                    .attr_valid_nsec = 0,
                    .attr = .{
                        // no relation to nodeid. so what is it?
                        .ino = 1,
                        .size = 0,
                        .blocks = 0,
                        .atime = 0,
                        .atimensec = 0,
                        .mtime = 0,
                        .mtimensec = 0,
                        .ctime = 0,
                        .ctimensec = 0,
                        .mode = std.posix.S.IFDIR | 0o0755,
                        .nlink = 1,
                        .uid = 0,
                        .gid = 0,
                        .rdev = 0,
                        .blksize = 0,
                        .flags = .{
                            .submount = false,
                            .dax = false,
                        },
                    },
                });
            },
            // clipboard
            2 => {
                try dev.sendOut(header.unique, kernel.AttrOut{
                    // can i send an "invalidate" signal to the kernel?
                    .attr_valid = 0,
                    .attr_valid_nsec = 0,
                    .attr = .{
                        // no relation to nodeid. so what is it?
                        .ino = 2,
                        .size = "<the clipboard contents>".len,
                        .blocks = 0,
                        .atime = 0,
                        .atimensec = 0,
                        .mtime = 0,
                        .mtimensec = 0,
                        .ctime = 0,
                        .ctimensec = 0,
                        .mode = std.posix.S.IFREG | 0o0755,
                        .nlink = 1,
                        .uid = 0,
                        .gid = 0,
                        .rdev = 0,
                        .blksize = 0,
                        .flags = .{
                            .submount = false,
                            .dax = false,
                        },
                    },
                });
            },
            else => {
                log.warn("received GetattrIn for non-existent nodeid {}", .{header.nodeid});
                try dev.sendErr(header.unique, .NOENT);
            },
        }
    }
    pub fn opendir(dev: *Dev, header: kernel.InHeader, _: kernel.OpenIn) !void {
        switch (header.nodeid) {
            kernel.ROOT_ID => {
                try dev.sendOut(header.unique, kernel.OpenOut{
                    .fh = 1,
                    .open_flags = .{},
                });
            },
            else => {
                log.warn("received OpenIn for non-existent nodeid {}", .{header.nodeid});
            },
        }
    }
    pub fn readdirplus(dev: *Dev, header: kernel.InHeader, readdirplus_in: kernel.ReadIn) !void {
        const Static = struct {
            var done: bool = false;
        };
        if (readdirplus_in.offset != 0) std.debug.panic("TODO: implement dealing with non-zero offset in readdirplus", .{});
        if (header.nodeid != kernel.ROOT_ID) std.debug.panic("readdirplus not implemented for any nodeid besides ROOT_ID", .{});
        const name = "clipboard";
        // TODO: for more than one entry, we will need to implement sendOut for []EntryOut
        // FAM means we probably need to just send a []u8 here

        try dev.writer().writeStruct(kernel.OutHeader{
            .@"error" = .SUCCESS,
            .len = @sizeOf(kernel.OutHeader),
            .unique = header.unique,
        });
        var out_header: *kernel.OutHeader = @ptrCast(&dev._writer.buf);
        if (Static.done) {
            try dev.flush_writer();
            return;
        }
        try dev.writer().writeStruct(kernel.DirentPlus{
            .entryOut = .{
                .nodeid = 2,
                .generation = 0,
                .entry_valid = 0,
                .entry_valid_nsec = 0,
                .attr_valid = 0,
                .attr_valid_nsec = 0,
                .attr = .{
                    .ino = 1,
                    // XXX: this needs to be the actual clipboard contents
                    .size = "<the clipboard contents>".len,
                    .blocks = 0,
                    .atime = 0,
                    .atimensec = 0,
                    .mtime = 0,
                    .mtimensec = 0,
                    .ctime = 0,
                    .ctimensec = 0,
                    .mode = std.posix.S.IFREG | 0o0755,
                    .nlink = 1,
                    .uid = 0,
                    .gid = 0,
                    .rdev = 0,
                    .blksize = 0,
                    .flags = .{
                        .submount = false,
                        .dax = false,
                    },
                },
            },
            .dirent = .{
                .ino = 5,
                .off = 0,
                .type = .REG,
                .namelen = name.len,
            },
        });
        const dirent_plus: *kernel.DirentPlus = @alignCast(@ptrCast(&dev._writer.buf[out_header.len]));
        out_header.len += @sizeOf(kernel.DirentPlus);

        // TODO: writeAllSentinel() would be nice
        // or maybe fn std.mem.withSentinel([:0]const T) []const T
        try dev.writer().writeAll(name[0 .. name.len + 1]);
        out_header.len += @intCast(name.len + 1);

        std.debug.assert(std.mem.eql(u8, dirent_plus.dirent.name(), name));
        out_header.len += @intCast(try dev.padWrite());

        try dev.flush_writer();
        Static.done = true;
    }
    pub fn releasedir(dev: *Dev, header: kernel.InHeader, _: kernel.ReleaseIn) !void {
        try dev.sendOut(header.unique, {});
    }

    pub fn lookup(dev: *Dev, header: kernel.InHeader, filename: [:0]const u8) !void {
        // TODO: in theory the nodeid check can be done before the filename is
        // parsed, which would save a few cycles. in most cases it's probably
        // not worth it but i don't want to prevent optimizations. maybe a
        // `lookup_preparse()` callback could be optionally defined that only
        // takes in the nodeid
        if (header.nodeid != kernel.ROOT_ID or !std.mem.eql(u8, filename, "clipboard"))
            try dev.sendErr(header.unique, .NOENT);
        try dev.sendOut(
            header.unique,
            kernel.EntryOut{
                .nodeid = 2,
                .generation = 0,
                .entry_valid = 0,
                .entry_valid_nsec = 0,
                .attr_valid = 0,
                .attr_valid_nsec = 0,
                .attr = .{
                    .ino = 1,
                    // XXX: this needs to be the actual clipboard contents
                    .size = "<the clipboard contents>".len,
                    .blocks = 0,
                    .atime = 0,
                    .atimensec = 0,
                    .mtime = 0,
                    .mtimensec = 0,
                    .ctime = 0,
                    .ctimensec = 0,
                    .mode = std.posix.S.IFREG | 0o0755,
                    .nlink = 1,
                    .uid = 0,
                    .gid = 0,
                    .rdev = 0,
                    .blksize = 0,
                    .flags = .{
                        .submount = false,
                        .dax = false,
                    },
                },
            },
        );
    }
};

pub const OpTypes = {};

pub fn recv1(dev: *Dev, comptime Ops: type) !void {
    _ = Ops;
    try dev.recv1(Callbacks);
}
