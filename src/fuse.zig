// TODO: a lot of the types in this library are dependent on architecture and OS and other things.
// how much effort do i want to put into making proper bindings?
// an alternative method is to not try for bitcast-ablity, and just bite the bullet of type conversion
// a stop-gap would just be to assert that things are the way i expect them to be
// also bitfields are a mess https://github.com/ziglang/zig/issues/1499
// which is going to be necessary to use fuse_file_info structs
const std = @import("std");
pub const c = @cImport({
    @cDefine("FUSE_USE_VERSION", "35");
    @cInclude("fuse.h");
});
const E = std.os.linux.E;

// TODO: should i make the names more ziggy?
// TODO: figure out what to do with file_info
pub const Operations = struct {
    getattr: ?*const fn (path: []const u8) error{ENOENT}!Stat = null,
    /// Read directory
    ///
    ///The filesystem may choose between two modes of operation:
    ///
    ///1) The readdir implementation ignores the offset parameter, and
    ///passes zero to the filler function's offset.  The filler
    ///function will not return '1' (unless an error happens), so the
    ///whole directory is read in a single readdir operation.
    ///
    ///2) The readdir implementation keeps track of the offsets of the
    ///directory entries.  It uses the offset parameter and always
    ///passes non-zero offset to the filler function.  When the buffer
    ///is full (or an error happens) the filler function will return
    ///'1'.
    ///
    ///When FUSE_READDIR_PLUS is not set, only some parameters of the
    ///fill function (the fuse_fill_dir_t parameter) are actually used:
    ///The file type (which is part of stat::st_mode) is used. And if
    ///fuse_config::use_ino is set, the inode (stat::st_ino) is also
    ///used. The other fields are ignored when FUSE_READDIR_PLUS is not
    ///set.
    ///
    readdir: ?*const fn (
        path: []const u8,
        buf: ?*anyopaque,
        filler: *const FillDirFn,
        offset: Offset,
    ) error{ENOENT}!void = null,
};

fn cErr(err: E) c_int {
    const n: c_int = @intFromEnum(err);
    return -n;
}

// TODO: take in a `type` and compare the decls with the fields of `Operations` to see that it's the right type
fn ExternOperations(comptime zig_ops: Operations) type {
    return struct {
        fn getattr(c_path: [*c]const u8, c_stat: [*c]c.struct_stat, c_fi: ?*c.struct_fuse_file_info) callconv(.C) c_int {
            _ = c_fi;
            const path = std.mem.span(c_path);
            const stat = zig_ops.getattr.?(path) catch |e| switch (e) {
                error.ENOENT => return cErr(E.NOENT),
            };
            c_stat.* = @bitCast(stat);
            return 0;
        }
        fn readdir(
            c_path: [*c]const u8,
            buf: ?*anyopaque,
            c_filler: c.fuse_fill_dir_t,
            // TODO: make offset an optional
            // SEE: https://github.com/ziglang/zig/issues/3806
            offset: c.off_t,
            fi: ?*c.struct_fuse_file_info,
            flags: c.enum_fuse_readdir_flags,
        ) callconv(.C) c_int {
            _ = fi;
            _ = flags; // TODO
            const path = std.mem.span(c_path);
            zig_ops.readdir.?(path, buf, @ptrCast(c_filler), offset) catch |e| switch (e) {
                error.ENOENT => return cErr(E.NOENT),
            };
            return 0;
        }
    };
}

///
///  Function to add an entry in a readdir() operation
///
/// The *off* parameter can be any non-zero value that enables the
/// filesystem to identify the current point in the directory
/// stream. It does not need to be the actual physical position. A
/// value of zero is reserved to indicate that seeking in directories
/// is not supported.
///
/// @param buf the buffer passed to the readdir() operation
/// @param name the file name of the directory entry
/// @param stbuf file attributes, can be NULL
/// @param off offset of the next entry or zero
/// @param flags fill flags
/// @return 1 if buffer is full, zero otherwise
///
// TODO: I can't figure out any way to wrap this nicely, since it's passed *in*
pub const FillDirFn = fn (
    buf: ?*anyopaque,
    name: [*:0]const u8,
    stbuf: ?*const Stat,
    offset: Offset,
    flags: FillDirFlags,
) callconv(.C) c_int;

pub const FillDirFlags = enum(c_int) {
    ///
    /// "Plus" mode: all file attributes are valid
    /// The attributes are used by the kernel to prefill the inode cache
    /// during a readdir.
    /// It is okay to set FUSE_FILL_DIR_PLUS if FUSE_READDIR_PLUS is not set
    /// and vice versa.
    ///
    Normal = 0,
    Plus = (1 << 1),
};

pub const ReadDirFlags = enum(c_int) {
    ///
    /// "Plus" mode.
    ///
    /// The kernel wants to prefill the inode cache during readdir.  The
    /// filesystem may honour this by filling in the attributes and setting
    /// FUSE_FILL_DIR_FLAGS for the filler function.  The filesystem may also
    /// just ignore this flag completely.
    ///
    Normal = 0,
    Plus = (1 << 0),
};
fn externOperations(comptime zig_opts: Operations) c.struct_fuse_operations {
    const ExternOps = ExternOperations(zig_opts);
    return .{
        .getattr = if (zig_opts.getattr) |_| ExternOps.getattr else null,
        .readdir = if (zig_opts.readdir) |_| ExternOps.readdir else null,
        .readlink = null,
        .mknod = null,
        .mkdir = null,
        .unlink = null,
        .rmdir = null,
        .symlink = null,
        .rename = null,
        .link = null,
        .chmod = null,
        .chown = null,
        .truncate = null,
        .open = null,
        .read = null,
        .write = null,
        .statfs = null,
        .flush = null,
        .release = null,
        .fsync = null,
        .setxattr = null,
        .getxattr = null,
        .listxattr = null,
        .removexattr = null,
        .opendir = null,
        .releasedir = null,
        .fsyncdir = null,
        .init = null,
        .destroy = null,
        .access = null,
        .create = null,
        .lock = null,
        .utimens = null,
        .bmap = null,
        .ioctl = null,
        .poll = null,
        .write_buf = null,
        .read_buf = null,
        .flock = null,
        .fallocate = null,
        .copy_file_range = null,
        .lseek = null,
        // .readlink = if (zig_opts.readlink) |_| ExternOps.readlink else null,
        // .mknod = if (zig_opts.mknod) |_| ExternOps.mknod else null,
        // .mkdir = if (zig_opts.mkdir) |_| ExternOps.mkdir else null,
        // .unlink = if (zig_opts.unlink) |_| ExternOps.unlink else null,
        // .rmdir = if (zig_opts.rmdir) |_| ExternOps.rmdir else null,
        // .symlink = if (zig_opts.symlink) |_| ExternOps.symlink else null,
        // .rename = if (zig_opts.rename) |_| ExternOps.rename else null,
        // .link = if (zig_opts.link) |_| ExternOps.link else null,
        // .chmod = if (zig_opts.chmod) |_| ExternOps.chmod else null,
        // .chown = if (zig_opts.chown) |_| ExternOps.chown else null,
        // .truncate = if (zig_opts.truncate) |_| ExternOps.truncate else null,
        // .open = if (zig_opts.open) |_| ExternOps.open else null,
        // .read = if (zig_opts.read) |_| ExternOps.read else null,
        // .write = if (zig_opts.write) |_| ExternOps.write else null,
        // .statfs = if (zig_opts.statfs) |_| ExternOps.statfs else null,
        // .flush = if (zig_opts.flush) |_| ExternOps.flush else null,
        // .release = if (zig_opts.release) |_| ExternOps.release else null,
        // .fsync = if (zig_opts.fsync) |_| ExternOps.fsync else null,
        // .setxattr = if (zig_opts.setxattr) |_| ExternOps.setxattr else null,
        // .getxattr = if (zig_opts.getxattr) |_| ExternOps.getxattr else null,
        // .listxattr = if (zig_opts.listxattr) |_| ExternOps.listxattr else null,
        // .removexattr = if (zig_opts.removexattr) |_| ExternOps.removexattr else null,
        // .opendir = if (zig_opts.opendir) |_| ExternOps.opendir else null,
        // .releasedir = if (zig_opts.releasedir) |_| ExternOps.releasedir else null,
        // .fsyncdir = if (zig_opts.fsyncdir) |_| ExternOps.fsyncdir else null,
        // .init = if (zig_opts.init) |_| ExternOps.init else null,
        // .destroy = if (zig_opts.destroy) |_| ExternOps.destroy else null,
        // .access = if (zig_opts.access) |_| ExternOps.access else null,
        // .create = if (zig_opts.create) |_| ExternOps.create else null,
        // .lock = if (zig_opts.lock) |_| ExternOps.lock else null,
        // .utimens = if (zig_opts.utimens) |_| ExternOps.utimens else null,
        // .bmap = if (zig_opts.bmap) |_| ExternOps.bmap else null,
        // .ioctl = if (zig_opts.ioctl) |_| ExternOps.ioctl else null,
        // .poll = if (zig_opts.poll) |_| ExternOps.poll else null,
        // .write_buf = if (zig_opts.write_buf) |_| ExternOps.write_buf else null,
        // .read_buf = if (zig_opts.read_buf) |_| ExternOps.read_buf else null,
        // .flock = if (zig_opts.flock) |_| ExternOps.flock else null,
        // .fallocate = if (zig_opts.fallocate) |_| ExternOps.fallocate else null,
        // .copy_file_range = if (zig_opts.copy_file_range) |_| ExternOps.copy_file_range else null,
        // .lseek = if (zig_opts.lseek) |_| ExternOps.lseek else null,
    };
}

pub const Device = c.__dev_t;
pub const Ino = c.__ino_t;
pub const NLink = c.__nlink_t;
// TODO: this could look more ziggy.
// .{ .dir = true, .owner_read = true, }
// but that also becomes super verbose. is there a better way to combine bitstructs?
pub const Mode = c.__mode_t;
pub const UID = c.__uid_t;
pub const GID = c.__gid_t;
pub const Offset = c.__off_t;
pub const BlockSize = c.__blksize_t;
pub const BlockCount = c.__blkcnt_t;
pub const Time = c.__time_t;
pub const TimeSpec = extern struct {
    sec: Time,
    // TODO: figure out a better type name
    nsec: c.__syscall_slong_t,
};

// TODO: do i name these fields more nicely, or leave them?
// TODO: does the user ever generate these structs? if not, we don't need to initialize the fields.
pub const Stat = extern struct {
    dev: Device = 0,
    ino: Ino = 0,
    nlink: NLink = 0,
    mode: Mode = 0,
    uid: UID = 0,
    gid: GID = 0,
    __pad0: c_int = 0,
    rdev: Device = 0,
    size: Offset = 0,
    blksize: BlockSize = 0,
    blocks: BlockCount = 0,
    atim: TimeSpec = std.mem.zeroes(TimeSpec),
    mtim: TimeSpec = std.mem.zeroes(TimeSpec),
    ctim: TimeSpec = std.mem.zeroes(TimeSpec),
    __glibc_reserved: [3]c.__syscall_slong_t = std.mem.zeroes([3]c.__syscall_slong_t),
};

pub fn main(argv: [][*:0]u8, comptime ops: Operations, private_data: ?*anyopaque) !void {
    const c_ops = externOperations(ops);
    const ret = c.fuse_main_real(@intCast(argv.len), @ptrCast(argv.ptr), &c_ops, @sizeOf(@TypeOf(c_ops)), private_data);
    switch (ret) {
        0 => return,
        1 => return error.FuseParseArgs, // Invalid option arguments
        2 => return error.FuseNoMountPoint, // No mount point specified
        3 => return error.FuseSetup, // FUSE setup failed
        4 => return error.FuseMount, // Mounting failed
        5 => return error.FuseDaemonize, // Failed to daemonize (detach from session)
        6 => return error.FuseSignalHandlers, // Failed to set up signal handlers
        7 => return error.FuseEventLoop, // An error occurred during the life of the file system
        else => return error.FuseUnknown,
    }
}
