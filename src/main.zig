const std = @import("std");
const fuse = @import("fuse.zig");

const FILENAME = "hello";
const CONTENT =
    \\ hello, world!
    \\ this is a test file.
    \\
;

const Ops = struct {
    pub fn getattr(path: []const u8) error{ENOENT}!fuse.Stat {
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

    pub fn readdir(
        path: []const u8,
        buf: ?*anyopaque,
        filler: *const fuse.FillDirFn,
        offset: usize,
    ) error{ENOENT}!void {
        _ = offset;

        if (!std.mem.eql(u8, path, "/")) {
            return error.ENOENT;
        }
        _ = filler(buf, ".".ptr, null, 0, .Normal);
        _ = filler(buf, "..".ptr, null, 0, .Normal);
        _ = filler(buf, FILENAME.ptr, null, 0, .Normal);
    }
    pub fn open(
        path: []const u8,
        fi: *fuse.FileInfo,
    ) error{ ENOENT, EACCES }!void {
        if (!std.mem.eql(u8, path[1..], FILENAME)) {
            return error.ENOENT;
        }
        if (fi.flags.ACCMODE != .RDONLY) {
            return error.EACCES;
        }
    }
    pub fn read(
        path: []const u8,
        buf: []u8,
        offset: usize,
        _: *fuse.FileInfo,
    ) error{ENOENT}!usize {
        if (!std.mem.eql(u8, path[1..], FILENAME)) {
            return error.ENOENT;
        }
        if (offset >= CONTENT.len) {
            // already all read
            return 0;
        }
        // how much can we copy in
        const s = if (offset + buf.len > CONTENT.len)
            // all the rest
            CONTENT.len - offset
        else
            // only what fits
            buf.len;

        @memcpy(buf[0..s], CONTENT[offset .. offset + s]);

        return s;
    }
};

pub fn main() !void {
    try fuse.main(std.os.argv, Ops, null);
}
