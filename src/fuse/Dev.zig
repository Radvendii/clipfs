const std = @import("std");
const log = std.log.scoped(.fuse);

pub const kernel = @import("kernel.zig");

const Dev = @This();

// really belongs in std.io
// TODO: upstream
fn bufferedWriterSize(comptime size: usize, unbuffered_writer: anytype) std.io.BufferedWriter(size, @TypeOf(unbuffered_writer)) {
    return .{ .unbuffered_writer = unbuffered_writer };
}

/// Must be > MIN_READ_BUFFER. The kernel wants to read/write in discrete units
/// of an entire message (header + body). Otherwise it will return EINVAL.
pub const READ_BUF_SIZE = 2 * kernel.MIN_READ_BUFFER;
/// Must be > MIN_READ_BUFFER. The kernel wants to read/write in discrete units
/// of an entire message (header + body). Otherwise it will return EINVAL.
pub const WRITE_BUF_SIZE = 2 * kernel.MIN_READ_BUFFER;

fh: std.fs.File,
_reader: std.io.BufferedReader(READ_BUF_SIZE, std.fs.File.Reader),
_writer: std.io.BufferedWriter(WRITE_BUF_SIZE, std.fs.File.Writer),
version: struct { major: u32, minor: u32 },

pub inline fn reader(dev: *Dev) @TypeOf(dev._reader).Reader {
    return dev._reader.reader();
}
pub inline fn writer(dev: *Dev) @TypeOf(dev._writer).Writer {
    return dev._writer.writer();
}
pub inline fn flush_writer(dev: *Dev) !void {
    return dev._writer.flush();
}

pub fn init() !Dev {
    const fh = try std.fs.openFileAbsolute("/dev/fuse", .{ .mode = .read_write });
    errdefer fh.close();

    var buf: [256]u8 = undefined;
    const mount_args: [:0]u8 = try std.fmt.bufPrintZ(&buf, "fd={d},rootmode={o},user_id={d},group_id={d}", .{
        fh.handle,
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

    const reader_unbuffered = fh.reader();
    const _reader = std.io.bufferedReaderSize(READ_BUF_SIZE, reader_unbuffered);

    const writer_unbuffered = fh.writer();
    const _writer = bufferedWriterSize(WRITE_BUF_SIZE, writer_unbuffered);

    var dev = Dev{
        .fh = fh,
        ._reader = _reader,
        ._writer = _writer,
        // Initial version. This will get modified when we exchange Init structs with the kernel
        .version = .{
            .major = kernel.VERSION,
            .minor = kernel.MINOR_VERSION,
        },
    };

    // init exchange

    var in_header = try dev.reader().readStruct(kernel.InHeader);
    std.debug.assert(in_header.opcode == .init);

    const extraneous = in_header.len - (@sizeOf(kernel.InHeader) + @sizeOf(kernel.InitIn));
    if (extraneous < 0) {
        log.err("Kernel's init message is to small by {} bytes. There is no known reason for this to happen, and we don't know how to proceed.", .{-extraneous});
        return error.InitTooSmall;
    } else if (extraneous > 0) {
        log.warn("Kernel's init message is too big by {} bytes. This may be a newer version of the kernel. Will attempt to plow ahead and treat the first bytes as the InitIn we understand and then ignore subsequent bytes.", .{extraneous});
    }

    var init_in = try dev.reader().readStruct(kernel.InitIn);
    log.debug("received init from kernel: {}", .{std.json.fmt(init_in, .{ .whitespace = .indent_2 })});

    if (extraneous > 0) {
        _ = try dev.reader().skipBytes(extraneous, .{});
        log.warn("skipped {} bytes from kernel (InitIn struct was too big)", .{extraneous});
    }

    if (init_in.major < 7) {
        // libfuse doesn't support it, so at least to begin with i'll follow suit
        log.err("unsupported protocol version: {d}.{d}", .{ init_in.major, init_in.minor });
        return error.UnsupportedVersion;
    }

    // man fuse.4 (section FUSE_INIT)
    // If the major version supported by the kernel is larger than that
    // supported by the daemon, the reply shall consist of only uint32_t major
    // (following the usual header), indicating the largest major version
    // supported by the daemon.  The kernel will then issue a new FUSE_INIT
    // request conforming to the older version.  In the reverse case, the daemon
    // should quietly fall back to the kernel's major version.
    if (init_in.major > dev.version.major) {
        try dev.writer().writeStruct(kernel.OutHeader{
            .unique = in_header.unique,
            .@"error" = .SUCCESS,
            .len = @sizeOf(kernel.OutHeader) + @sizeOf(u32),
        });
        try dev.writer().writeInt(u32, kernel.VERSION, @import("builtin").target.cpu.arch.endian());
        try dev.flush_writer();

        in_header = try dev.reader().readStruct(kernel.InHeader);
        std.debug.assert(in_header.opcode == .init);
        // at this point the kernel shouldn't send us incompatible structs
        std.debug.assert(in_header.len == @sizeOf(kernel.InHeader) + @sizeOf(kernel.InitIn));
        init_in = try dev.reader().readStruct(kernel.InitIn);
        // TODO: will this ever be <=?
        std.debug.assert(init_in.major == dev.version.major);
    }

    // the kernel is on an old version, we'll cede to it.
    if (init_in.major < dev.version.major) {
        dev.version = .{
            .major = init_in.major,
            .minor = init_in.minor,
        };
    } else if (init_in.minor < dev.version.minor) {
        dev.version.minor = init_in.minor;
    }

    try dev.sendOut(in_header.unique, kernel.InitOut{
        .major = dev.version.major,
        .minor = dev.version.minor,
        .max_readahead = init_in.max_readahead,

        // TODO: presumably we should only set the flags we actually want to support
        .flags = init_in.flags,
        .flags2 = init_in.flags2,

        // not sure what these are
        // values taken from https://github.com/richiejp/m/blob/main/src/fuse.zig#L360-L365
        .max_background = 0,
        .congestion_threshold = 0,
        .max_write = 4096,
        .time_gran = 0,
        .max_pages = 1,
        .map_alignment = 1,
    });
    return dev;
}

pub fn recv1(dev: *Dev) !void {
    const header = try dev.reader().readStruct(kernel.InHeader);
    log.info("received header from kernel: {}", .{header});
    var rest = header.len - @sizeOf(kernel.InHeader);
    switch (header.opcode) {
        // inline else => |opcode| {
        //     const MaybeInStruct = opcode.InStruct();
        //     if (MaybeInStruct) |InStruct| {
        //         const body = try dev.reader().readStruct(InStruct);
        //         rest -= @sizeOf(InStruct);
        //         log.info("received body: {}", .{body});
        //     } else {
        //         log.info("no body expected", .{});
        //     }

        //     const count = comptime opcode.nFiles();

        //     // How does this work?
        //     // is the rest of the `len` a filename?
        //     // is it zero-terminated?
        //     // what if there are two filenames?
        //     // it seems like it might divide the remaining bytes evenly between the two.
        //     // does that mean it's zero-terminated?
        //     // SEE: https://github.com/hanwen/go-fuse/blob/master/fuse/request.go#L206
        //     if (count > 0) {
        //         log.err("TODO: implement code for handling operations that send filenames", .{});
        //     }
        //     std.debug.assert(rest == 0);
        // },
        .getattr => {
            const getattr_in = try dev.reader().readStruct(kernel.GetattrIn);
            log.info("received GetattrIn from the kernel: {}", .{getattr_in});
            rest -= @sizeOf(kernel.GetattrIn);
            std.debug.assert(rest == 0);
            std.debug.assert(header.nodeid == kernel.ROOT_ID);
            // don't know how to deal with this yet
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
                else => try dev.sendErr(header.unique, .NOENT),
            }
        },
        .lookup,
        .forget,
        .setattr,
        .readlink,
        .symlink,
        .mknod,
        .mkdir,
        .unlink,
        .rmdir,
        .rename,
        .link,
        .open,
        .read,
        .write,
        .statfs,
        .release,
        .fsync,
        .setxattr,
        .getxattr,
        .listxattr,
        .removexattr,
        .flush,
        .init,
        .opendir,
        .readdir,
        .releasedir,
        .fsyncdir,
        .getlk,
        .setlk,
        .setlkw,
        .access,
        .create,
        .interrupt,
        .bmap,
        .destroy,
        .ioctl,
        .poll,
        .notify_reply,
        .batch_forget,
        .fallocate,
        .readdirplus,
        .rename2,
        .lseek,
        .copy_file_range,
        .setupmapping,
        .removemapping,
        .syncfs,
        .tmpfile,
        .statx,
        .cuse_init,
        .cuse_init_bswap_reserved,
        .init_bswap_reserved,
        => std.debug.panic("TODO: implement Dev.recv1() for {s}", .{@tagName(header.opcode)}),
    }
}

// TODO: if we put the version number of the change into the COMPAT_SIZE name, we can comptime automate this whole thing
// TODO: we could allow for sending ints here. i'm a little wary of that because it's such an unusual thing to do that i don't want to bog down the "normal" function with it or give the impression it's a normal thing
pub fn outSize(dev: *const Dev, comptime Data: type) usize {
    switch (Data) {
        kernel.InitOut => return switch (dev.version.minor) {
            0...4 => kernel.InitOut.COMPAT_SIZE,
            5...22 => kernel.InitOut.COMPAT_22_SIZE,
            else => @sizeOf(Data),
        },
        kernel.AttrOut => return switch (dev.version.minor) {
            0...8 => kernel.AttrOut.COMPAT_SIZE,
            else => @sizeOf(Data),
        },

        kernel.EntryOut,
        kernel.StatxOut,
        kernel.OpenOut,
        kernel.WriteOut,
        kernel.StatfsOut,
        kernel.GetxattrOut,
        kernel.LkOut,
        kernel.BmapOut,
        kernel.IoctlOut,
        kernel.PollOut,
        kernel.NotifyPollWakeupOut,
        kernel.NotifyInvalInodeOut,
        kernel.NotifyInvalEntryOut,
        kernel.NotifyDeleteOut,
        kernel.NotifyRetrieveOut,
        kernel.LseekOut,
        => @compileError("TODO: check what the compat sizes are for " ++ @typeName(Data)),

        else => @compileError("Unsupported send operation on type " ++ @typeName(Data)),
    }
}

pub fn outBytes(dev: *const Dev, data_ptr: anytype) ![]const u8 {
    const Data = @typeInfo(@TypeOf(data_ptr)).Pointer.child;
    const size = dev.outSize(Data);
    if (size == @sizeOf(Data)) {
        return std.mem.asBytes(data_ptr);
    }
    if (size < @sizeOf(Data)) {
        log.debug("Truncating {s} to {} bytes due to old protocol version {}.{}", .{ @typeName(Data), size, dev.version.major, dev.version.minor });
        return std.mem.asBytes(data_ptr)[0..size];
    }
    if (size > @sizeOf(Data)) {
        log.debug("Expanding {s} to {} bytes, probably due to FAM", .{ @typeName(Data), size });
        return @as([*]const u8, @ptrCast(data_ptr))[0..size];
    }
    unreachable;
}

pub fn sendOut(dev: *Dev, unique: u64, data: anytype) !void {
    log.info("Sending to kernel: {}", .{data});
    // Normally, we just send the struct.
    // Two things make the size unpredictable:
    // 1. compatibilty with older protocol versions means we might have to truncate it
    // 2. flexible array members are not of compile-time known size
    const out_bytes = try dev.outBytes(&data);

    const header = kernel.OutHeader{
        .@"error" = .SUCCESS,
        .unique = unique,
        .len = @intCast(@sizeOf(kernel.OutHeader) + out_bytes.len),
    };
    try dev.writer().writeStruct(header);
    try dev.writer().writeAll(out_bytes);
    try dev.flush_writer();
}

pub fn sendErr(dev: *Dev, unique: u64, err: kernel.@"-E") !void {
    log.info("Sending error to kernel: E{s}", .{@tagName(err)});
    try dev.writer().writeStruct(kernel.OutHeader{
        .unique = unique,
        .@"error" = err,
        .len = @sizeOf(kernel.OutHeader),
    });
    try dev.flush_writer();
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

pub fn deinit(dev: Dev) !void {
    try unmount();
    dev.fh.close();
}
