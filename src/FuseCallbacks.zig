const std = @import("std");
const Dev = @import("fuse/Dev.zig");
const k = @import("fuse/kernel.zig");
const log = std.log.scoped(.@"fuse-callbacks");

// TODO: integrate with clipboard code
const CLIPBOARD = "<the clipboard contents>";

const NodeID = enum(u64) {
    ROOT = k.ROOT_ID,
    COPY,
    PASTE,
    _,
};

const PrivateData = @This();

generation: u64 = 1,
allocator: std.mem.Allocator,
clipboard: []u8,

pub fn getattr(_: *PrivateData, in: k.InHeader, getattr_in: k.GetattrIn, out: *Dev.OutBuffer) !void {
    _ = getattr_in; // autofix
    // std.debug.assert(getattr_in.getattr_flags.fh == false);

    switch (@as(NodeID, @enumFromInt(in.nodeid))) {
        .ROOT => out.setOutStruct(k.AttrOut{
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
        }),
        .COPY => out.setOutStruct(k.AttrOut{
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
        }),
        .PASTE => out.setOutStruct(k.AttrOut{
            // can i send an "invalidate" signal to the kernel?
            .attr_valid = 0,
            .attr_valid_nsec = 0,
            .attr = .{
                // no relation to nodeid. so what is it?
                .ino = 3,
                .size = 0,
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
        }),
        else => {
            log.warn("received GetattrIn for non-existent nodeid {}", .{in.nodeid});
            out.setErr(.NOENT);
            return;
        },
    }
}
pub fn opendir(_: *PrivateData, in: k.InHeader, _: k.OpenIn, out: *Dev.OutBuffer) !void {
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
pub fn readdirplus(_: *PrivateData, in: k.InHeader, readdirplus_in: k.ReadIn, out: *Dev.OutBuffer) !void {
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
pub fn releasedir(_: *PrivateData, _: k.InHeader, _: k.ReleaseIn, _: *Dev.OutBuffer) !void {
    return;
}
pub fn release(_: *PrivateData, _: k.InHeader, _: k.ReleaseIn, _: *Dev.OutBuffer) !void {
    return;
}

pub fn lookup(_: *PrivateData, in: k.InHeader, filename: [:0]const u8, out: *Dev.OutBuffer) !void {
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
pub fn open(_: *PrivateData, in: k.InHeader, _: k.OpenIn, out: *Dev.OutBuffer) !void {
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
pub fn read(_: *PrivateData, in: k.InHeader, read_in: k.ReadIn, out: *Dev.OutBuffer) !void {
    _ = read_in; // autofix
    switch (@as(NodeID, @enumFromInt(in.nodeid))) {
        .COPY => out.appendString(CLIPBOARD) catch @panic("clipboard too long"),
        else => {
            out.setErr(.NOENT);
            return;
        },
    }
}

pub fn flush(_: *PrivateData, _: k.InHeader, _: k.FlushIn, _: *Dev.OutBuffer) !void {
    return;
}

pub fn create(this: *PrivateData, _: k.InHeader, create_in: k.CreateIn, _: [:0]const u8, out: *Dev.OutBuffer) !void {
    // TODO: properly return an error
    std.debug.assert(create_in.flags.ACCMODE == .WRONLY);
    // TODO: have a single `CreateOut` struct or something
    out.appendOutStruct(k.EntryOut{
        .nodeid = @intFromEnum(NodeID.PASTE),
        .generation = this.generation,
        .entry_valid = 0,
        .entry_valid_nsec = 0,
        .attr_valid = 0,
        .attr_valid_nsec = 0,
        .attr = .{
            .ino = 1,
            .size = 0,
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
    }) catch unreachable;
    out.appendOutStruct(k.OpenOut{
        .fh = 1,
        .open_flags = .{},
    }) catch unreachable;

    this.generation += 1;
}

pub fn getxattr(_: *PrivateData, _: k.InHeader, _: k.GetxattrIn, attr: [:0]const u8, out: *Dev.OutBuffer) !void {
    std.debug.print("{s}", .{attr});
    out.setErr(.OPNOTSUPP);
    // out.setOutStruct(k.GetxattrOut{
    //     .size = in.size,
    // });
}

pub fn write(this: *PrivateData, in: k.InHeader, write_in: k.WriteIn, bytes: []const u8, out: *Dev.OutBuffer) !void {
    std.debug.assert(write_in.offset == 0);

    switch (@as(NodeID, @enumFromInt(in.nodeid))) {
        .PASTE => {
            this.clipboard = try this.allocator.realloc(this.clipboard, bytes.len);
            @memcpy(this.clipboard, bytes);
        },
        .ROOT, .COPY => {
            out.setErr(.PERM);
            return;
        },
        else => {
            out.setErr(.NOENT);
            return;
        },
    }

    out.setOutStruct(k.WriteOut{
        .size = @intCast(bytes.len),
    });
}
