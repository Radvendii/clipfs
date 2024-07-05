/// takes care of opening, mounting, reading and writing to /dev/fuse. provides a slightly more convenient interface.
/// THREAD_SAFETY: a single Dev should **not** be shared between threads. in the future, there will be an interface for duplicating a Dev to be used in another thread, but this is not yet implemented.
const Dev = @This();

const std = @import("std");
const log = std.log.scoped(.@"/dev/fuse");

pub const k = @import("kernel.zig");
pub const buffered_writer = @import("buffered_writer.zig");

/// Must be > MIN_READ_BUFFER. The kernel wants to read/write in discrete units
/// of an entire message (header + body). Otherwise it will return EINVAL.
pub const READ_BUF_SIZE = 2 * k.MIN_READ_BUFFER;
/// Must be > MIN_READ_BUFFER. The kernel wants to read/write in discrete units
/// of an entire message (header + body). Otherwise it will return EINVAL.
pub const WRITE_BUF_SIZE = 2 * k.MIN_READ_BUFFER;

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
mnt: [:0]const u8,

pub inline fn writer(dev: *Dev) @TypeOf(dev._writer).Writer {
    return dev._writer.writer();
}

/// buffer for outgoing messages to the kernel
pub const OutBuffer = struct {
    buf: [WRITE_BUF_SIZE]u8 align(8) = undefined,
    /// we need to know the minor version so we know the expected lengths of output structs
    minor_version: u32,

    pub fn init(minor_version: u32, unique: k.Unique) OutBuffer {
        var this = OutBuffer{ .minor_version = minor_version };
        this.header().* = .{
            .@"error" = .SUCCESS,
            .unique = unique,
            .len = @sizeOf(k.OutHeader),
        };
        return this;
    }

    pub inline fn header(this: *OutBuffer) *k.OutHeader {
        return @ptrCast(&this.buf);
    }

    pub inline fn pos(this: *OutBuffer) *u32 {
        return &this.header().len;
    }

    pub inline fn len(this: OutBuffer) u32 {
        return @constCast(&this).header().len;
    }

    pub fn message(this: OutBuffer) []align(8) const u8 {
        return this.buf[0..this.len()];
    }

    pub fn setErr(this: *OutBuffer, err: k.@"-E") void {
        this.header().@"error" = err;
        this.pos().* = @sizeOf(k.OutHeader);
    }

    pub fn isErr(this: OutBuffer) bool {
        return this.header().@"error" != .SUCCESS;
    }

    pub fn appendOutStruct(this: *OutBuffer, data: anytype) error{OutOfMemory}!void {
        const Data = @TypeOf(data);
        std.debug.assert(this.pos().* % @alignOf(Data) == 0);
        const new_pos = this.pos().* + @sizeOf(Data);
        if (new_pos > this.buf.len)
            return error.OutOfMemory;

        const ptr: *Data = @alignCast(@ptrCast(&this.buf[this.pos().*]));
        ptr.* = data;
        // const out_bytes = outBytes(data, this.minor_version);
        // @memcpy(this.buf[this.pos().*..][0..out_bytes.len], out_bytes);
        this.pos().* = new_pos;
    }

    pub fn appendInt(this: *OutBuffer, int: anytype) error{OutOfMemory}!void {
        const Int = @TypeOf(int);
        std.debug.assert(@typeInfo(Int) == .Int);
        std.debug.assert(this.pos().* & @alignOf(Int) == 0);
        const new_pos = this.pos().* + @sizeOf(Int);
        if (new_pos > this.buf.len)
            return error.OutOfMemory;
        const ptr: *Int = @alignCast(@ptrCast(&this.buf[this.pos().*]));
        ptr.* = int;
        this.pos().* = new_pos;
    }

    pub inline fn align64(this: *OutBuffer) void {
        Align64.@"align"(this.pos());
    }

    pub fn appendString(this: *OutBuffer, str: [:0]const u8) error{OutOfMemory}!void {
        const new_pos = Align64.next(this.pos().* + str.len + 1);
        if (new_pos > this.buf.len)
            return error.OutOfMemory;
        @memcpy(this.buf[this.pos().*..][0 .. str.len + 1], str[0 .. str.len + 1]);
        this.pos().* = @intCast(new_pos);
    }
};

pub fn send(dev: *Dev, out: OutBuffer) !void {
    try dev.fh.writeAll(out.message());
}

pub const Align64 = struct {
    /// round up to the nearest 60-bit aligned value
    pub const next = k.align64;
    /// how many bits need to be added to reach the nearest 64-bit aligned number
    pub fn fill(x: anytype) @TypeOf(x) {
        const Int = @TypeOf(x);
        std.debug.assert(@typeInfo(Int) == .Int);
        const lower_bits: Int = @alignOf(u64) - 1;

        return (~x +% 1) & lower_bits;
    }
    /// is this value already 64-bit aligned
    pub fn aligned(x: anytype) bool {
        const Int = @TypeOf(x);
        std.debug.assert(@typeInfo(Int) == .Int);
        const lower_bits: Int = @alignOf(u64) - 1;

        return (x & lower_bits) == 0;
    }
    /// Take a mutable pointer to a
    pub fn @"align"(ptr: anytype) void {
        const Int = @TypeOf(ptr).Pointer.child;
        std.debug.assert(@typeInfo(Int) == .Int);
        const lower_bits: Int = @alignOf(u64) - 1;
        const upper_bits: Int = ~lower_bits;

        ptr.* += lower_bits;
        ptr.* &= upper_bits;
    }
};

pub fn init(mnt: [:0]const u8) !Dev {
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
        mnt,
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
    errdefer unmount(mnt) catch @panic("failed to unmount");

    const writer_unbuffered = fh.writer();
    const _writer = buffered_writer.bufferedWriterOpts(writer_unbuffered, WRITER_OPTS);

    var dev = Dev{
        .mnt = mnt,
        .fh = fh,
        ._writer = _writer,
        .reader = fh.reader(),
        // Initial version. This will get modified when we exchange Init structs with the kernel
        .version = .{
            .major = k.VERSION,
            .minor = k.MINOR_VERSION,
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
        pub fn init(dev: *Dev, _: k.InHeader, init_in: k.InitIn, out: *OutBuffer) !void {
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
                out.appendInt(@as(u32, k.VERSION)) catch unreachable;

                return dev.recv1(InitExchange.@"2");
            }

            initKnownValid(dev, init_in, out);
        }
    };
    pub const @"2" = struct {
        // The kernel will then issue a new FUSE_INIT request conforming to the
        // older version.
        pub fn init(dev: *Dev, _: k.InHeader, init_in: k.InitIn, out: *OutBuffer) !void {
            if (init_in.major != dev.version.major) {
                log.err("kernel refusing to conform to major version {}. Sending {} instead.", .{ dev.version.major, init_in.major });
                return error.NonCompliantKernel;
            }
            initKnownValid(dev, init_in, out);
        }
    };
    pub fn initKnownValid(dev: *Dev, init_in: k.InitIn, out: *OutBuffer) void {
        // the kernel is on an old version, we'll cede to it.
        if (init_in.major < dev.version.major) {
            dev.version = .{
                .major = init_in.major,
                .minor = init_in.minor,
            };
        } else if (init_in.minor < dev.version.minor) {
            dev.version.minor = init_in.minor;
        }

        out.appendOutStruct(k.InitOut{
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
        }) catch unreachable;
    }
};

// TODO: I don't like that this has to exist. this is replicating the logic in recv1, but pared down. I don't like that it could get out of sync.
// an arraylist would be ideal, but that appears impossible at comptime
inline fn setArgType(arg_types: *[]type, next: type) void {
    arg_types.*.len += 1;
    arg_types.*[arg_types.len - 1] = next;
}
pub fn CallbackArgsT(opcode: k.OpCode) type {
    const MAX_ARGS = 10;
    var arg_types_buf = [1]type{undefined} ** MAX_ARGS;
    var arg_types: []type = arg_types_buf[0..0];
    setArgType(&arg_types, *Dev);
    setArgType(&arg_types, k.InHeader);

    if (opcode.InStruct()) |InStruct|
        setArgType(&arg_types, InStruct);

    for (0..opcode.nFiles()) |_|
        setArgType(&arg_types, [:0]const u8);

    setArgType(&arg_types, *OutBuffer);

    return std.meta.Tuple(arg_types);
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
    const message_len = try dev.reader.readAtLeast(&message_buf, @sizeOf(k.InHeader));
    log.info("got it!", .{});
    const message: []align(8) const u8 = message_buf[0..message_len];

    var pos: usize = 0;
    const header: *const k.InHeader = @alignCast(@ptrCast(&message[pos]));
    pos += @sizeOf(k.InHeader);
    std.debug.assert(header.len == message.len);
    log.info("received: {}", .{header});

    switch (header.opcode) {
        inline else => |opcode| {
            if (!@hasDecl(Callbacks, @tagName(opcode))) {
                log.err("Callback not provided for {s}", .{@tagName(opcode)});
                return error.Unimplemented;
            }
            const callback = @field(Callbacks, @tagName(opcode));
            var args: CallbackArgsT(opcode) = undefined;
            comptime var arg_n = 0;
            setArg(&args, &arg_n, dev);
            setArg(&args, &arg_n, header.*);

            const MaybeInStruct = opcode.InStruct();
            if (MaybeInStruct) |InStruct| {
                const size = dev.inStructSize(InStruct);
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

            var out = OutBuffer.init(dev.version.minor, header.unique);
            setArg(&args, &arg_n, &out);

            @call(.auto, callback, args) catch |err_| {
                switch (err_) {
                    inline else => |err| {
                        const maybeE: ?k.ErrorE = comptime e: {
                            for (@typeInfo(k.ErrorE).ErrorSet.?) |err_e| {
                                if (std.mem.eql(u8, err_e.name, @errorName(err)))
                                    break :e @field(k.ErrorE, @errorName(err));
                            } else {
                                break :e null;
                            }
                        };
                        if (maybeE) |e| {
                            out.setErr(k.errorToE(e));
                        } else {
                            return err;
                        }
                    },
                }
            };

            try dev.send(out);
        },
    }
}

// TODO: if we put the version number of the change into the COMPAT_SIZE name, we can comptime automate this whole thing
// TODO: we could allow for sending ints here. i'm a little wary of that because it's such an unusual thing to do that i don't want to bog down the "normal" function with it or give the impression it's a normal thing
pub fn outStructSize(comptime Data: type, minor_version: u32) usize {
    switch (Data) {
        k.InitOut => return switch (minor_version) {
            0...4 => k.InitOut.COMPAT_SIZE,
            5...22 => k.InitOut.COMPAT_22_SIZE,
            else => @sizeOf(Data),
        },
        k.AttrOut => return switch (minor_version) {
            0...8 => k.AttrOut.COMPAT_SIZE,
            else => @sizeOf(Data),
        },
        k.EntryOut => return switch (minor_version) {
            0...8 => k.EntryOut.COMPAT_SIZE,
            else => @sizeOf(Data),
        },
        k.OpenOut, void => return @sizeOf(Data),

        k.Dirent, k.DirentPlus => @compileError(@typeName(Data) ++ " output size must be handled manually"),

        k.StatxOut,
        k.WriteOut,
        k.StatfsOut,
        k.GetxattrOut,
        k.LkOut,
        k.BmapOut,
        k.IoctlOut,
        k.PollOut,
        k.NotifyPollWakeupOut,
        k.NotifyInvalInodeOut,
        k.NotifyInvalEntryOut,
        k.NotifyDeleteOut,
        k.NotifyRetrieveOut,
        k.LseekOut,
        => @compileError("TODO: check what the compat sizes are for " ++ @typeName(Data)),

        else => @compileError(@typeName(Data) ++ " is not a fuse output struct"),
    }
}

pub fn inStructSize(dev: *const Dev, comptime Data: type) usize {
    _ = dev;
    return switch (Data) {
        k.GetattrIn,
        k.OpenIn,
        k.ReleaseIn,
        k.ReadIn,
        k.InitIn,
        k.FlushIn,
        => @sizeOf(Data),

        k.GetxattrIn,
        k.SetattrIn,
        k.IoctlIn,
        k.MknodIn,
        k.CreateIn,
        k.AccessIn,
        k.ForgetIn,
        k.BatchForgetIn,
        k.LinkIn,
        k.MkdirIn,
        k.FallocateIn,
        k.RenameIn,
        k.Rename2In,
        k.WriteIn,
        k.FsyncIn,
        k.SetxattrIn,
        k.LkIn,
        k.InterruptIn,
        k.BmapIn,
        k.PollIn,
        k.LseekIn,
        k.CopyFileRangeIn,
        k.SetupmappingIn,
        k.RemovemappingIn,
        k.SyncfsIn,
        k.StatxIn,
        k.Cuse.InitIn,
        k.NotifyRetrieveIn,
        => @compileError("TODO: check what the compat sizes are for " ++ @typeName(Data)),

        else => @compileError(@typeName(Data) ++ " is not a fuse input struct"),
    };
}

pub fn unmount(mnt: [:0]const u8) !void {
    if (false) {
        switch (std.posix.errno(std.os.linux.umount(mnt))) {
            .SUCCESS => {},
            else => |err| {
                log.err("unmounting: {}", .{err});
                return error.Unmount;
            },
        }
    }
}

pub fn deinit(dev: Dev) !void {
    try unmount(dev.mnt);
    dev.fh.close();
}
