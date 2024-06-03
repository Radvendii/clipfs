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
const E = std.c.E;

// TODO: should i make the names more ziggy?
// problem is this is hidden from user, so they just have to run into type errors to figure out what types things should be.
const ZigOpTypes = struct {
    pub const getattr = fn (path: []const u8) error{ENOENT}!Stat;
    pub const readdir = fn (path: []const u8, buf: ?*anyopaque, filler: *const FillDirFn, offset: usize) error{ENOENT}!void;
    pub const open = fn (path: []const u8, fi: *FileInfo) error{ ENOENT, EACCES }!void;
    pub const read = fn (path: []const u8, buf: []u8, offset: usize, fi: *FileInfo) error{ENOENT}!usize;
};

// TODO: operate on error values
fn cErr(err: E) c_int {
    const n: c_int = @intFromEnum(err);
    return -n;
}

// TODO: better error messages and tests
fn ExternOperations(comptime ZigOps: type) type {
    // typecheck
    comptime {
        for (@typeInfo(ZigOps).Struct.decls) |decl| {
            const got = @TypeOf(@field(ZigOps, decl.name));
            const expected = @field(ZigOpTypes, decl.name);
            if (got != expected) {
                @compileError("FUSE operation " ++ decl.name ++ " has the wrong type. Got: `" ++ got ++ "`. Expected: `" ++ expected ++ "`.");
            }
        }
    }
    // We take advantage of laziness. We can freely call `ZigOps.foo()` inside `ExternOps(ZigOps).foo()` because if the former isn't defined, the latter will never be called.
    return struct {
        pub fn getattr(c_path: [*c]const u8, c_stat: [*c]c.struct_stat, c_fi: ?*c.struct_fuse_file_info) callconv(.C) c_int {
            _ = c_fi;
            const path = std.mem.span(c_path);
            const stat = ZigOps.getattr(path) catch |e| switch (e) {
                error.ENOENT => return cErr(E.NOENT),
            };
            c_stat.* = @bitCast(stat);
            return 0;
        }
        pub fn readdir(
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
            ZigOps.readdir(path, buf, @ptrCast(c_filler), @intCast(offset)) catch |e| switch (e) {
                error.ENOENT => return cErr(E.NOENT),
            };
            return 0;
        }
        pub fn open(c_path: [*c]const u8, fi: ?*c.struct_fuse_file_info) callconv(.C) c_int {
            const path = std.mem.span(c_path);
            ZigOps.open(path, @ptrCast(@alignCast(fi.?))) catch |e| switch (e) {
                error.ENOENT => return cErr(E.NOENT),
                error.EACCES => return cErr(E.ACCES),
            };
            return 0;
        }
        pub fn read(c_path: [*c]const u8, buf: [*c]u8, size: usize, offset: c.off_t, fi: ?*c.struct_fuse_file_info) callconv(.C) c_int {
            const path = std.mem.span(c_path);
            const ret = ZigOps.read(path, buf[0..size], @intCast(offset), @ptrCast(@alignCast(fi.?))) catch |e| switch (e) {
                error.ENOENT => return cErr(E.NOENT),
            };
            return @intCast(ret);
        }
    };
}

fn externOperations(comptime ZigOps: type) c.struct_fuse_operations {
    const ExternOps = ExternOperations(ZigOps);
    comptime var ops = c.struct_fuse_operations{};
    comptime {
        for (@typeInfo(ZigOps).Struct.decls) |decl| {
            @field(ops, decl.name) = @field(ExternOps, decl.name);
        }
    }
    return ops;
}

pub const FileInfo = extern struct {
    flags: std.c.O,
    // TODO: figure out c bitfields
    // SEE: https://github.com/ziglang/zig/issues/1499
    bitfield: u32,
    padding2: u32,
    fh: u64,
    lock_owner: u64,
    poll_events: u32,
};

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

pub fn main(argv: [][*:0]u8, comptime Ops: type, private_data: ?*anyopaque) !void {
    const c_ops = externOperations(Ops);
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
        // TODO: this triggers on ^C. What common exit conditions am i missing?
        else => return error.FuseUnknown,
    }
}
