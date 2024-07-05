const std = @import("std");
const Dev = @import("Dev.zig");
const k = @import("kernel.zig");
const log = std.log.scoped(.@"fuse-low-level");

// TODO: integrate with clipboard code
const CLIPBOARD = "<the clipboard contents>";
pub const Callbacks = struct {
    pub fn getattr(_: *Dev, in: k.InHeader, getattr_in: k.GetattrIn, out: *Dev.OutBuffer) !void {
        _ = getattr_in; // autofix
        // std.debug.assert(getattr_in.getattr_flags.fh == false);

        switch (in.nodeid) {
            k.ROOT_ID => {
                out.setOutStruct(k.AttrOut{
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
                out.setOutStruct(k.AttrOut{
                    // can i send an "invalidate" signal to the kernel?
                    .attr_valid = 0,
                    .attr_valid_nsec = 0,
                    .attr = .{
                        // no relation to nodeid. so what is it?
                        .ino = 2,
                        .size = CLIPBOARD.len,
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
                log.warn("received GetattrIn for non-existent nodeid {}", .{in.nodeid});
                out.setErr(.NOENT);
                return;
            },
        }
    }
    pub fn opendir(_: *Dev, in: k.InHeader, _: k.OpenIn, out: *Dev.OutBuffer) !void {
        switch (in.nodeid) {
            k.ROOT_ID => {
                out.setOutStruct(k.OpenOut{
                    .fh = 1,
                    .open_flags = .{},
                });
            },
            else => {
                log.warn("received OpenIn for non-existent nodeid {}", .{in.nodeid});
                out.setErr(.NOENT);
                return;
            },
        }
    }
    pub fn readdirplus(_: *Dev, in: k.InHeader, readdirplus_in: k.ReadIn, out: *Dev.OutBuffer) !void {
        const Static = struct {
            var done: bool = false;
        };
        if (readdirplus_in.offset != 0) std.debug.panic("TODO: implement dealing with non-zero offset in readdirplus", .{});
        if (in.nodeid != k.ROOT_ID) std.debug.panic("readdirplus not implemented for any nodeid besides ROOT_ID", .{});
        const name = "clipboard";
        // TODO: for more than one entry, we will need to implement sendOut for []EntryOut
        // FAM means we probably need to just send a []u8 here
        if (Static.done) {
            return;
        }
        out.appendDirentAndString(
            k.DirentPlus{
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
                        .size = CLIPBOARD.len,
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
            },
            name,
        ) catch @panic("clipboard file name wayyy too long.");
        Static.done = true;
    }
    pub fn releasedir(_: *Dev, _: k.InHeader, _: k.ReleaseIn, _: *Dev.OutBuffer) !void {
        return;
    }
    pub fn release(_: *Dev, _: k.InHeader, _: k.ReleaseIn, _: *Dev.OutBuffer) !void {
        return;
    }

    pub fn lookup(_: *Dev, in: k.InHeader, filename: [:0]const u8, out: *Dev.OutBuffer) !void {
        // TODO: in theory the nodeid check can be done before the filename is
        // parsed, which would save a few cycles. in most cases it's probably
        // not worth it but i don't want to prevent optimizations. maybe a
        // `lookup_preparse()` callback could be optionally defined that only
        // takes in the nodeid
        if (in.nodeid != k.ROOT_ID or !std.mem.eql(u8, filename, "clipboard")) {
            out.setErr(.NOENT);
            return;
        }
        out.setOutStruct(k.EntryOut{
            .nodeid = 2,
            .generation = 0,
            .entry_valid = 0,
            .entry_valid_nsec = 0,
            .attr_valid = 0,
            .attr_valid_nsec = 0,
            .attr = .{
                .ino = 1,
                // XXX: this needs to be the actual clipboard contents
                .size = CLIPBOARD.len,
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
    }
    pub fn open(_: *Dev, in: k.InHeader, _: k.OpenIn, out: *Dev.OutBuffer) !void {
        switch (in.nodeid) {
            2 => {
                out.setOutStruct(k.OpenOut{
                    .fh = 1,
                    .open_flags = .{},
                });
            },
            else => {
                log.warn("received OpenIn for non-existent nodeid {}", .{in.nodeid});
                out.setErr(.NOENT);
                return;
            },
        }
    }
    pub fn read(_: *Dev, in: k.InHeader, read_in: k.ReadIn, out: *Dev.OutBuffer) !void {
        _ = read_in; // autofix
        switch (in.nodeid) {
            2 => out.appendString(CLIPBOARD) catch @panic("clipboard too long"),
            else => {
                out.setErr(.NOENT);
                return;
            },
        }
    }
    pub fn flush(_: *Dev, _: k.InHeader, _: k.FlushIn, _: *Dev.OutBuffer) !void {
        return;
    }
};

pub const OpTypes = {};

pub fn recv1(dev: *Dev, comptime Ops: type) !void {
    _ = Ops;
    try dev.recv1(Callbacks);
}
