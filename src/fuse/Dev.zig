const std = @import("std");
const log = std.log.scoped(.@"/dev/fuse");

pub const kernel = @import("kernel.zig");
pub const buffered_writer = @import("buffered_writer.zig");

const Dev = @This();

/// Must be > MIN_READ_BUFFER. The kernel wants to read/write in discrete units
/// of an entire message (header + body). Otherwise it will return EINVAL.
pub const READ_BUF_SIZE = 2 * kernel.MIN_READ_BUFFER;
/// Must be > MIN_READ_BUFFER. The kernel wants to read/write in discrete units
/// of an entire message (header + body). Otherwise it will return EINVAL.
pub const WRITE_BUF_SIZE = 2 * kernel.MIN_READ_BUFFER;

const WRITER_OPTS = buffered_writer.BufferedWriterOptions{
    .buffer_size = WRITE_BUF_SIZE,
    // everything here is at most align(@sizeOf(u64)), and it will be convenient to be able to @ptrCast() the buffer
    .buffer_align = @alignOf(u64),
    // The point of the buffer is to ensure we don't send partial packets to the kernel. If we write past the end of the buffer, that's an error.
    .automatic_flush = false,
};

fh: std.fs.File,
_reader: std.io.BufferedReader(READ_BUF_SIZE, std.fs.File.Reader),
_writer: buffered_writer.BufferedWriter(std.fs.File.Writer, WRITER_OPTS),
version: struct { major: u32, minor: u32 },

pub inline fn reader(dev: *Dev) @TypeOf(dev._reader).Reader {
    return dev._reader.reader();
}
pub inline fn writer(dev: *Dev) @TypeOf(dev._writer).Writer {
    return dev._writer.writer();
}

pub const Align64 = struct {
    /// round up to the nearest 60-bit aligned value
    pub const next = kernel.align64;
    /// how many bits need to be added to reach the nearest 64-bit aligned number
    pub fn fill(x: anytype) @TypeOf(x) {
        const lower_bits: @TypeOf(x) = @alignOf(u64) - 1;
        return (~x +% 1) & lower_bits;
    }
    /// is this value laready 64-bit aligned
    pub fn aligned(x: anytype) bool {
        const lower_bits: @TypeOf(x) = @alignOf(u64) - 1;
        return (x & lower_bits) == 0;
    }
};

/// Write out bytes until we're 64bit aligned
pub inline fn padWrite(dev: *Dev) !usize {
    const fill = Align64.fill(dev._writer.end);
    try dev.writer().writeByteNTimes('\x00', fill);
    return fill;
}
pub inline fn flush_writer(dev: *Dev) !void {
    if (!Align64.aligned(dev._writer.end))
        return error.UnalignedSend;
    return dev._writer.flush() catch |err| {
        log.err("problem writing to kernel: {}", .{err});
        return err;
    };
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
    const _writer = buffered_writer.bufferedWriterOpts(writer_unbuffered, WRITER_OPTS);

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

// TODO: I don't like that this has to exist. this is replicating the logic in recv1, but pared down. I don't like that it could get out of sync.
// TODO: if we can't do away with it, it's still ugly. clean it up.
pub fn CallbackArgsT(opcode: kernel.OpCode) type {
    const MAX_ARGS = 8;
    comptime var n_args = 0;
    comptime var arg_types: [MAX_ARGS]type = undefined;
    arg_types[n_args] = *Dev;
    n_args += 1;
    arg_types[n_args] = kernel.InHeader;
    n_args += 1;
    if (opcode.InStruct()) |InStruct| {
        arg_types[n_args] = InStruct;
        n_args += 1;
    }
    for (0..opcode.nFiles()) |_| {
        arg_types[n_args] = [:0]u8;
        n_args += 1;
    }
    return std.meta.Tuple(arg_types[0..n_args]);
}

/// equivalent to
/// args.@"n" = value;
/// n += 1;
inline fn setArg(args: anytype, comptime n: *comptime_int, value: anytype) void {
    const n_str = comptime std.fmt.comptimePrint("{d}", .{n.*});
    if (@TypeOf(@field(args, n_str)) != @TypeOf(value)) {
        @compileError(std.fmt.comptimePrint("Failed to set argument {} of tuple {}. Expected type {} got {}", .{
            n.*,
            @TypeOf(args),
            @TypeOf(@field(args, n_str)),
            @TypeOf(value),
        }));
    }
    @field(args, n_str) = value;
    n.* += 1;
}

// TODO: if i just make a 64-bit aligned buffer, I can just cast pointers to different parts of it...
// I'm already doing this with the BufferedReader, it's just not aligned so we have to memcpy the bytes out
// TODO: i can make a recv1Alloc version too that allocates a buffer rather than putting them on the stack
// this would allow the values to outlive the recv1 call
// but do we really want that? any particular data you should copy out, you shouldn't be holding onto an API struct
// QUESTION: are we guaranteed the kernel will never send us more than one message at the same time?
// QUESTION: what if the kernel sends us messages in two writes, but we just read after both have been sent?
// I'm thinking about this as a FIFO, but it's not. our read request gets sent directly to the kernel, so probably we only get one message at a time
/// @Callbacks has a function for each opcode. see low_level.DevCallbacks for an example and to see what types are expected
pub fn recv1(dev: *Dev) !void {
    const header = try dev.reader().readStruct(kernel.InHeader);
    log.info("received: {}", .{header});
    var rest = header.len - @sizeOf(kernel.InHeader);
    switch (header.opcode) {
        inline else => |opcode| {
            if (!@hasDecl(Callbacks, @tagName(opcode))) {
                log.err("Callback not provided for {}", .{opcode});
                return error.Unimplemented;
            }
            var args: CallbackArgsT(opcode) = undefined;
            comptime var arg_n = 0;
            setArg(&args, &arg_n, dev);
            // TODO: don't pass the whole header, just the `unique` and what each op actually needs
            setArg(&args, &arg_n, header);

            const MaybeInStruct = opcode.InStruct();
            if (MaybeInStruct) |InStruct| {
                const size = dev.inSize(InStruct);
                std.debug.assert(rest >= size);
                std.debug.assert(size >= @sizeOf(InStruct));
                var in_struct: InStruct = std.mem.zeroes(InStruct);
                try dev.reader().readNoEof(std.mem.asBytes(&in_struct)[0..size]);
                rest -= @intCast(size);
                log.info("received: {}", .{in_struct});
                setArg(&args, &arg_n, in_struct);
                arg_n += 1;
            } else {
                log.info("no body expected", .{});
            }

            const count = comptime opcode.nFiles();

            if (count > 0) {
                // TODO: setxattr works differently
                // TODO: do i have to deal with offset parameters?
                if (count == 1) {
                    // XXX: shhhhhh this is a terrible hack to get things working
                    // i'm more and more thinking the right way to do this is to
                    // allocate a top-level buffer for the whole kernel message
                    // and then pass around pointers to parts of it. I want
                    // to test things out before making that big change but I
                    // don't want to bother doing allocations right for those .5
                    // seconds of testing
                    const alloc = std.heap.page_allocator;
                    const buf = try alloc.alloc(u8, rest);
                    try dev.reader().readNoEof(buf);
                    log.info("received filename: \"{}\"", .{buf});
                    setArg(&args, &arg_n, buf[0 .. buf.len - 1 :0]);
                } else {
                    // TODO: the go code seems to split on 0-bytes, which makes sense except
                    // 1. how does it deal with alignment
                    // 2. how does it deal with offsets?
                    // SEE: https://github.com/hanwen/go-fuse/blob/master/fuse/request.go#L206
                    log.err("TODO: implement code for handling operations that send multiple filenames", .{});
                }
            }

            std.debug.assert(rest == 0);

            try @call(.auto, @field(Callbacks, @tagName(opcode)), args);
        },
    }
}

const Callbacks = struct {
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
        const name = "hello";
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
                .nodeid = 0,
                .generation = 0,
                .entry_valid = 0,
                .entry_valid_nsec = 0,
                .attr_valid = 0,
                .attr_valid_nsec = 0,
                .attr = .{
                    .ino = 1,
                    .size = "hello".len,
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
        try dev.sendOut(header.unique, void);
    }
};

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
        kernel.OpenOut => return @sizeOf(Data),

        kernel.Dirent, kernel.DirentPlus => @compileError(@typeName(Data) ++ " output size must be handled manually"),

        kernel.EntryOut,
        kernel.StatxOut,
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

pub fn inSize(dev: *const Dev, comptime Data: type) usize {
    _ = dev;
    return switch (Data) {
        kernel.GetattrIn,
        kernel.OpenIn,
        kernel.ReleaseIn,
        kernel.ReadIn,
        => @sizeOf(Data),

        kernel.FlushIn,
        kernel.GetxattrIn,
        kernel.SetattrIn,
        kernel.InitIn,
        kernel.IoctlIn,
        kernel.MknodIn,
        kernel.CreateIn,
        kernel.AccessIn,
        kernel.ForgetIn,
        kernel.BatchForgetIn,
        kernel.LinkIn,
        kernel.MkdirIn,
        kernel.FallocateIn,
        kernel.RenameIn,
        kernel.Rename2In,
        kernel.WriteIn,
        kernel.FsyncIn,
        kernel.SetxattrIn,
        kernel.LkIn,
        kernel.InterruptIn,
        kernel.BmapIn,
        kernel.PollIn,
        kernel.LseekIn,
        kernel.CopyFileRangeIn,
        kernel.SetupmappingIn,
        kernel.RemovemappingIn,
        kernel.SyncfsIn,
        kernel.StatxIn,
        kernel.Cuse.InitIn,
        kernel.NotifyRetrieveIn,
        => @compileError("TODO: check what the compat sizes are for " ++ @typeName(Data)),

        else => @compileError(@typeName(Data) ++ " is not a fuse input struct"),
    };
}

pub fn outBytes(dev: *const Dev, data_ptr: anytype) ![]const u8 {
    const Data = @typeInfo(@TypeOf(data_ptr)).Pointer.child;
    // special case for sendOut(void);
    if (Data == type)
        if (data_ptr.* == void)
            return &[0]u8{};
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
