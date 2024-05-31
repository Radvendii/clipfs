const std = @import("std");
const fuse = @import("fuse.zig");

const FILENAME = "hello";
const CONTENT =
    \\ hello, world!
    \\ this is a test file.
;

fn getattr(path: []const u8) error{ENOENT}!fuse.Stat {
    var ret: fuse.Stat = .{};
    if (std.mem.eql(u8, path, "/")) {
        ret.mode = fuse.c.S_IFDIR | 0o0755;
        ret.nlink = 2;
    } else if (std.mem.eql(u8, path[1..], "hello")) {
        ret.mode = fuse.c.S_IFREG | 0o0444;
        ret.nlink = 1;
        ret.size = CONTENT.len;
    } else {
        return error.ENOENT;
    }
    return ret;
}

fn readdir(
    path: []const u8,
    buf: ?*anyopaque,
    filler: *const fuse.FillDirFn,
    _: fuse.Offset,
) error{ENOENT}!void {
    if (!std.mem.eql(u8, path, "/")) {
        return error.ENOENT;
    }
    _ = filler(buf, ".".ptr, null, 0, .Normal);
    _ = filler(buf, "..".ptr, null, 0, .Normal);
    _ = filler(buf, FILENAME.ptr, null, 0, .Normal);
}

// TODO: this feels redundant
const OPS = fuse.Operations{
    .getattr = &getattr,
    .readdir = &readdir,
};

pub fn main() !void {
    try fuse.main(std.os.argv, OPS, null);
}
