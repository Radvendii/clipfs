const std = @import("std");
const Dev = @import("fuse/Dev.zig");
const EOr = Dev.EOr;
const Clipboard = @import("Clipboard.zig");
const k = @import("fuse/kernel.zig");
const log = std.log.scoped(.@"fuse-callbacks");

// TODO: integrate with clipboard code
const CLIPBOARD = "<the clipboard contents>";

const NodeId = enum(u64) {
    ROOT = k.ROOT_ID,
    COPY,
    PASTE,
    _,
    pub inline fn to(nodeid: NodeId) u64 {
        return @intFromEnum(nodeid);
    }
    pub inline fn from(nodeid: u64) NodeId {
        return @enumFromInt(nodeid);
    }
};

const PrivateData = @This();

generation: u64 = 1,
allocator: std.mem.Allocator,
clipboard: *Clipboard,

pub fn getattr(_: *PrivateData, in: k.InHeader, getattr_in: k.GetattrIn) !EOr(k.AttrOut) {
    _ = getattr_in; // autofix
    // std.debug.assert(getattr_in.getattr_flags.fh == false);

    switch (NodeId.from(in.nodeid)) {
        .ROOT => return .{ .out = k.AttrOut{
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
        } },
        .COPY => return .{ .out = k.AttrOut{
            .attr_valid = 0,
            .attr_valid_nsec = 0,
            .attr = .{
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
        } },
        .PASTE => return .{ .out = k.AttrOut{
            .attr_valid = 0,
            .attr_valid_nsec = 0,
            .attr = .{
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
        } },
        else => {
            log.warn("received GetattrIn for non-existent nodeid {}", .{in.nodeid});
            return .{ .err = .NOENT };
        },
    }
}
pub fn opendir(_: *PrivateData, in: k.InHeader, _: k.OpenIn) !EOr(k.OpenOut) {
    switch (in.nodeid) {
        k.ROOT_ID => {
            return .{ .out = k.OpenOut{
                .fh = 1,
                .open_flags = .{},
            } };
        },
        else => {
            log.warn("received OpenIn for non-existent nodeid {}", .{in.nodeid});
            return .{ .err = .NOENT };
        },
    }
}
pub fn readdirplus(_: *PrivateData, in: k.InHeader, readdirplus_in: k.ReadIn, out: *Dev.OutBuffer) !EOr(void) {
    const Static = struct {
        var done: bool = false;
    };
    if (readdirplus_in.offset != 0) std.debug.panic("TODO: implement dealing with non-zero offset in readdirplus", .{});
    if (in.nodeid != k.ROOT_ID) std.debug.panic("readdirplus not implemented for any nodeid besides ROOT_ID", .{});
    const name = "clipboard";

    // for some reason it calls readdirplus a second time. i don't know how else to signal "we're done" besides sending an empty one after
    if (Static.done) return .{ .out = {} };

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
    return .{ .out = {} };
}
pub fn releasedir(_: *PrivateData, _: k.InHeader, _: k.ReleaseIn) !EOr(void) {
    return .{ .out = {} };
}
pub fn release(_: *PrivateData, _: k.InHeader, _: k.ReleaseIn) !EOr(void) {
    return .{ .out = {} };
}

pub fn lookup(_: *PrivateData, in: k.InHeader, filename: [:0]const u8) !EOr(k.EntryOut) {
    // TODO: in theory the nodeid check can be done before the filename is
    // parsed, which would save a few cycles. in most cases it's probably
    // not worth it but i don't want to prevent optimizations. maybe a
    // `lookup_preparse()` callback could be optionally defined that only
    // takes in the nodeid
    if (in.nodeid != k.ROOT_ID or !std.mem.eql(u8, filename, "clipboard")) {
        return .{ .err = .NOENT };
    }
    return .{
        .out = k.EntryOut{
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
    };
}
pub fn open(_: *PrivateData, in: k.InHeader, _: k.OpenIn) !EOr(k.OpenOut) {
    switch (NodeId.from(in.nodeid)) {
        .COPY => return .{ .out = k.OpenOut{
            .fh = 1,
            .open_flags = .{},
        } },
        else => {
            log.warn("received OpenIn for non-existent nodeid {}", .{in.nodeid});
            return .{ .err = .NOENT };
        },
    }
}
pub fn read(_: *PrivateData, in: k.InHeader, read_in: k.ReadIn) !EOr([]const u8) {
    _ = read_in; // autofix
    switch (NodeId.from(in.nodeid)) {
        .COPY => return .{ .out = CLIPBOARD },
        else => return .{ .err = .NOENT },
    }
}

pub fn flush(_: *PrivateData, _: k.InHeader, _: k.FlushIn) !EOr(void) {
    return .{ .out = {} };
}

pub fn create(this: *PrivateData, _: k.InHeader, create_in: k.CreateIn, _: [:0]const u8) !EOr(k.CreateOut) {
    // TODO: properly return an error
    std.debug.assert(create_in.flags.ACCMODE == .WRONLY);

    defer this.generation += 1;

    return .{ .out = .{
        .entry_out = k.EntryOut{
            .nodeid = NodeId.PASTE.to(),
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
        },
        .open_out = k.OpenOut{
            .fh = 1,
            .open_flags = .{},
        },
    } };
}

pub fn getxattr(_: *PrivateData, _: k.InHeader, _: k.GetxattrIn, attr: [:0]const u8) !EOr(k.GetxattrOut) {
    std.debug.print("{s}", .{attr});
    return .{ .err = .OPNOTSUPP };
    // out.setOutStruct(k.GetxattrOut{
    //     .size = in.size,
    // });
}

pub fn setattr(_: *PrivateData, _: k.InHeader, _: k.SetattrIn) !EOr(k.AttrOut) {
    return .{ .out = k.AttrOut{
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
    } };
}

pub fn write(this: *PrivateData, in: k.InHeader, write_in: k.WriteIn, bytes: []const u8) !EOr(k.WriteOut) {
    std.debug.assert(write_in.offset == 0);

    switch (NodeId.from(in.nodeid)) {
        .PASTE => {
            try this.clipboard.copy(bytes);
        },
        .ROOT, .COPY => {
            return .{ .err = .PERM };
        },
        else => {
            return .{ .err = .NOENT };
        },
    }

    return .{ .out = k.WriteOut{
        .size = @intCast(bytes.len),
    } };
}
