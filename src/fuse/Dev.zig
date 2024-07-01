const Dev = @This();

const std = @import("std");
const log = std.log.scoped(.@"/dev/fuse");

pub const kernel = @import("kernel.zig");
pub const buffered_writer = @import("buffered_writer.zig");

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
_writer: buffered_writer.BufferedWriter(std.fs.File.Writer, WRITER_OPTS),
/// For receiving messages from the kernel. This must be done carefully, as the kernel expects to have a large enough buffer to write in that it never needs to send partial messages.
reader: std.fs.File.Reader,
version: struct { major: u32, minor: u32 },

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

    const writer_unbuffered = fh.writer();
    const _writer = buffered_writer.bufferedWriterOpts(writer_unbuffered, WRITER_OPTS);

    var dev = Dev{
        .fh = fh,
        ._writer = _writer,
        .reader = fh.reader(),
        // Initial version. This will get modified when we exchange Init structs with the kernel
        .version = .{
            .major = kernel.VERSION,
            .minor = kernel.MINOR_VERSION,
        },
    };

    dev.recv1(InitExchange) catch |err| switch (err) {
        error.Unimplemented => {
            log.err("kernel sent us another opcode before initializing.", .{});
            return error.NonCompliantKernel;
        },
        else => return err,
    };

    return dev;
}

const InitExchange = struct {
    // start at stage 1
    pub usingnamespace @"1";
    pub const @"1" = struct {
        pub fn init(dev: *Dev, header: kernel.InHeader, init_in: kernel.InitIn) !void {
            if (init_in.major < 7) {
                // libfuse doesn't support it, so at least to begin with i'll follow suit
                log.err("unsupported protocol version: {d}.{d}", .{ init_in.major, init_in.minor });
                return error.UnsupportedVersion;
            }

            // man fuse.4 (section FUSE_INIT)
            // If the major version supported by the kernel is larger than that
            // supported by the daemon, the reply shall consist of only uint32_t major
            // (following the usual header), indicating the largest major version
            // supported by the daemon.
            if (init_in.major > dev.version.major) {
                try dev.writer().writeStruct(kernel.OutHeader{
                    .unique = header.unique,
                    .@"error" = .SUCCESS,
                    .len = @sizeOf(kernel.OutHeader) + @sizeOf(u32),
                });
                try dev.writer().writeInt(u32, kernel.VERSION, @import("builtin").target.cpu.arch.endian());
                try dev.flush_writer();

                return dev.recv1(InitExchange.@"2");
            }

            return initKnownValid(dev, header, init_in);
        }
    };
    pub const @"2" = struct {
        // The kernel will then issue a new FUSE_INIT request conforming to the
        // older version.
        pub fn init(dev: *Dev, header: kernel.InHeader, init_in: kernel.InitIn) !void {
            if (init_in.major != dev.version.major) {
                log.err("kernel refusing to conform to major version {}. Sending {} instead.", .{ dev.version.major, init_in.major });
                return error.NonCompliantKernel;
            }
            return initKnownValid(dev, header, init_in);
        }
    };
    pub fn initKnownValid(dev: *Dev, header: kernel.InHeader, init_in: kernel.InitIn) !void {
        // the kernel is on an old version, we'll cede to it.
        if (init_in.major < dev.version.major) {
            dev.version = .{
                .major = init_in.major,
                .minor = init_in.minor,
            };
        } else if (init_in.minor < dev.version.minor) {
            dev.version.minor = init_in.minor;
        }

        try dev.sendOut(header.unique, kernel.InitOut{
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
    }
};

// TODO: I don't like that this has to exist. this is replicating the logic in recv1, but pared down. I don't like that it could get out of sync.
// an arraylist would be ideal, but that appears impossible at comptime
inline fn setArgType(arg_types: *[]type, next: type) void {
    arg_types.*.len += 1;
    arg_types.*[arg_types.len - 1] = next;
}
pub fn CallbackArgsT(opcode: kernel.OpCode) type {
    const MAX_ARGS = 10;
    var arg_types_buf = [1]type{undefined} ** MAX_ARGS;
    var arg_types: []type = arg_types_buf[0..0];
    setArgType(&arg_types, *Dev);
    setArgType(&arg_types, kernel.InHeader);
    if (opcode.InStruct()) |InStruct|
        setArgType(&arg_types, InStruct);
    for (0..opcode.nFiles()) |_|
        setArgType(&arg_types, [:0]const u8);

    return std.meta.Tuple(arg_types);
}

/// equivalent to
/// args.@"n" = value;
/// n += 1;
inline fn setArg(args: anytype, comptime n: *comptime_int, value: anytype) void {
    const n_str = comptime std.fmt.comptimePrint("{d}", .{n.*});
    if (@TypeOf(@field(args, n_str)) != @TypeOf(value)) {
        @compileError(std.fmt.comptimePrint("Failed to set argument {} of tuple {s}. Expected type {s} got {s}", .{
            n.*,
            @typeName(@TypeOf(args)),
            @typeName(@TypeOf(@field(args, n_str))),
            @typeName(@TypeOf(value)),
        }));
    }
    @field(args, n_str) = value;
    n.* += 1;
}

test "setArg" {
    var args: std.meta.Tuple(&.{ u32, []const u8 }) = undefined;
    comptime var arg_n = 0;
    setArg(&args, &arg_n, 0);
    setArg(&args, &arg_n, "hello");
    std.testing.expectEqual(args, .{ 0, "hello" });
}
// TODO: i can make a recv1Alloc version too that allocates a buffer rather than putting them on the stack
// this would allow the values to outlive the recv1 call
// but do we really want that? any particular data you should copy out, you shouldn't be holding onto an API struct
// QUESTION: are we guaranteed the kernel will never send us more than one message at the same time?
// QUESTION: what if the kernel sends us messages in two writes, but we just read after both have been sent?
// I'm thinking about this as a FIFO, but it's not. our read request gets sent directly to the kernel, so probably we only get one message at a time
// TODO: we could define the types needed in CallbackArgsT(), and then here just loop over that and do the obvious thing for each one
/// @Callbacks has a function for each opcode. see low_level.DevCallbacks for an example and to see what types are expected
pub fn recv1(dev: *Dev, Callbacks: type) !void {
    // everything in fuse is 8-byte-aligned
    var message_buf: [READ_BUF_SIZE]u8 align(8) = undefined;
    log.info("waiting for kernel message...", .{});
    const message_len = try dev.reader.readAtLeast(&message_buf, @sizeOf(kernel.InHeader));
    log.info("got it!", .{});
    const message: []align(8) const u8 = message_buf[0..message_len];

    var pos: usize = 0;
    const header: *const kernel.InHeader = @alignCast(@ptrCast(&message[pos]));
    pos += @sizeOf(kernel.InHeader);
    std.debug.assert(header.len == message.len);
    log.info("received: {}", .{header});

    switch (header.opcode) {
        inline else => |opcode| {
            if (!@hasDecl(Callbacks, @tagName(opcode))) {
                log.err("Callback not provided for {s}", .{@tagName(opcode)});
                return error.Unimplemented;
            }
            var args: CallbackArgsT(opcode) = undefined;
            comptime var arg_n = 0;
            setArg(&args, &arg_n, dev);
            // TODO: don't pass the whole header, just the `unique` and what each op actually needs
            setArg(&args, &arg_n, header.*);

            const MaybeInStruct = opcode.InStruct();
            if (MaybeInStruct) |InStruct| {
                const size = dev.inSize(InStruct);
                std.debug.assert(pos + size <= message.len);
                const in_struct: *const InStruct = @alignCast(@ptrCast(&message[pos]));
                pos += size;
                log.info("received: {}", .{in_struct});
                setArg(&args, &arg_n, in_struct.*);
            } else {
                log.info("no body expected", .{});
            }

            const count = comptime opcode.nFiles();

            if (count > 0) {
                // TODO: setxattr works differently
                // TODO: do i have to deal with offset parameters?
                if (count == 1) {
                    const filename = std.mem.span(@as([*:0]const u8, message[pos .. message.len - 1 :0]));
                    log.info("received filename: \"{s}\"", .{filename});
                    setArg(&args, &arg_n, filename);
                    pos += filename.len + 1;
                    log.info("skipping {} extra bytes", .{message.len - pos});
                    pos = message.len;
                } else {
                    // TODO: the go code seems to split on 0-bytes, which makes sense except
                    // 1. how does it deal with alignment
                    // 2. how does it deal with offsets?
                    // SEE: https://github.com/hanwen/go-fuse/blob/master/fuse/request.go#L206
                    log.err("TODO: implement code for handling operations that send multiple filenames", .{});
                }
            }

            std.debug.assert(pos == message.len);

            try @call(.auto, @field(Callbacks, @tagName(opcode)), args);
        },
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
        kernel.OpenOut, void => return @sizeOf(Data),

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

        else => @compileError(@typeName(Data) ++ " is not a fuse output struct"),
    }
}

pub fn inSize(dev: *const Dev, comptime Data: type) usize {
    _ = dev;
    return switch (Data) {
        kernel.GetattrIn,
        kernel.OpenIn,
        kernel.ReleaseIn,
        kernel.ReadIn,
        kernel.InitIn,
        => @sizeOf(Data),

        kernel.FlushIn,
        kernel.GetxattrIn,
        kernel.SetattrIn,
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

pub fn outBytes(dev: *const Dev, data_ptr: anytype) []const u8 {
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
    const out_bytes = dev.outBytes(&data);

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
