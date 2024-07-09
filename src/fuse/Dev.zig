/// takes care of opening, mounting, reading and writing to /dev/fuse. provides a slightly more convenient interface.
/// THREAD_SAFETY: a single Dev should **not** be shared between threads. in the future, there will be an interface for duplicating a Dev to be used in another thread, but this is not yet implemented.
// TODO: this should be async though... you don't want to stop up all processing because one operation is taking a while
// when that happens, we will need to not have just one write buffer. maybe there's a method to get one, or maybe it's passed into the callbacks
const Dev = @This();

const std = @import("std");
const log = std.log.scoped(.@"/dev/fuse");

const k = @import("kernel.zig");

/// Must be > MIN_READ_BUFFER. The kernel wants to read/write in discrete units
/// of an entire message (header + body). Otherwise it will return EINVAL.
pub const READ_BUF_SIZE = 2 * k.MIN_READ_BUFFER;
/// Must be > MIN_READ_BUFFER. The kernel wants to read/write in discrete units
/// of an entire message (header + body). Otherwise it will return EINVAL.
pub const WRITE_BUF_SIZE = 2 * k.MIN_READ_BUFFER;

fh: std.fs.File,
version: struct { major: u32, minor: u32 },
mnt: [:0]const u8,

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

    pub inline fn remaining(this: OutBuffer) u32 {
        return WRITE_BUF_SIZE - this.len();
    }

    pub inline fn isEmpty(this: OutBuffer) bool {
        return this.len() == @sizeOf(k.OutHeader);
    }

    pub fn isErr(this: OutBuffer) bool {
        return @constCast(&this).header().@"error" != .SUCCESS;
    }

    pub fn message(this: OutBuffer) []align(8) const u8 {
        return this.buf[0..this.len()];
    }

    pub fn reset(this: *OutBuffer) void {
        this.header().* = .{
            .@"error" = .SUCCESS,
            .unique = this.unique,
            .len = @sizeOf(k.OutHeader),
        };
    }

    pub fn setErr(this: *OutBuffer, err: k.@"-E") void {
        std.debug.assert(this.isEmpty());
        this.header().@"error" = err;
        this.pos().* = @sizeOf(k.OutHeader);
    }

    pub fn setOutStruct(this: *OutBuffer, data: anytype) void {
        std.debug.assert(this.isEmpty());
        this.appendOutStruct(data) catch unreachable;
    }

    pub fn setInt(this: *OutBuffer, int: anytype) void {
        std.debug.assert(this.isEmpty());
        this.appendInt(int) catch unreachable;
    }

    pub fn appendDirentAndString(this: *OutBuffer, dirent: anytype, str: [:0]const u8) error{OutOfMemory}!void {
        const Dirent = @TypeOf(dirent);
        std.debug.assert(Dirent == k.Dirent or Dirent == k.DirentPlus);
        // TODO: a re-implementation would be more efficient
        const saved_pos = this.len();
        errdefer this.pos().* = saved_pos;
        try this.appendOutStruct(dirent);
        try this.appendString(str);
    }

    pub fn appendDirentWithString(this: *OutBuffer, dirent: anytype) error{OutOfMemory}!void {
        const Dirent = @TypeOf(dirent).Pointer.child;
        std.debug.assert(Dirent == k.Dirent or Dirent == k.DirentPlus);
        std.debug.assert(this.len() % @alignOf(Dirent) == 0);
        const new_pos = this.len() + dirent.size();
        if (new_pos > this.buf.len)
            return error.OutOfMemory;
        const bytes: [*]u8 = @ptrCast(dirent);
        @memcpy(this.buf[this.len()..][0..dirent.size()], bytes[0..dirent.size()]);
        this.pos().* = new_pos;
    }

    pub fn appendOutStruct(this: *OutBuffer, data: anytype) error{OutOfMemory}!void {
        const Data = @TypeOf(data);
        std.debug.assert(this.len() % @alignOf(Data) == 0);
        if (this.len() + @sizeOf(Data) > this.buf.len)
            return error.OutOfMemory;

        const ptr: *Data = @alignCast(@ptrCast(&this.buf[this.len()]));
        ptr.* = data;
        this.pos().* += @intCast(outStructSize(Data, this.minor_version));
    }

    pub fn appendInt(this: *OutBuffer, int: anytype) error{OutOfMemory}!void {
        const Int = @TypeOf(int);
        std.debug.assert(@typeInfo(Int) == .Int);
        std.debug.assert(this.len() & @alignOf(Int) == 0);
        const new_pos = this.len() + @sizeOf(Int);
        if (new_pos > this.buf.len)
            return error.OutOfMemory;
        const ptr: *Int = @alignCast(@ptrCast(&this.buf[this.len()]));
        ptr.* = int;
        this.pos().* = new_pos;
    }

    pub inline fn align64(this: *OutBuffer) void {
        Align64.@"align"(this.pos());
    }

    pub fn appendString(this: *OutBuffer, str: [:0]const u8) error{OutOfMemory}!void {
        return this.appendBytes(str[0 .. str.len + 1]);
    }

    pub fn appendBytes(this: *OutBuffer, bytes: []const u8) error{OutOfMemory}!void {
        const new_pos = Align64.next(this.len() + bytes.len);
        if (new_pos > this.buf.len)
            return error.OutOfMemory;
        @memcpy(this.buf[this.len()..][0..bytes.len], bytes);
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

pub fn init(allocator: std.mem.Allocator, mnt: [:0]const u8) !Dev {
    const fh = try fusermount(allocator, mnt);
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

    var dev = Dev{
        .mnt = mnt,
        .fh = fh,
        // Initial version. This will get modified when we exchange Init structs with the kernel
        .version = .{
            .major = k.VERSION,
            .minor = k.MINOR_VERSION,
        },
    };

    var init_exchange = InitExchange{ .dev = &dev };

    try init_exchange.go();

    return dev;
}

const InitExchange = struct {
    dev: *Dev,
    kernel_major_larger: bool = false,

    // TODO: handle errors so we can just return this
    // pub const Error = error{ NonCompliantKernel, UnsupportedVersion };

    pub fn go(this: *InitExchange) !void {
        try this.recv1();
        if (this.kernel_major_larger)
            try this.recv1();
    }

    pub fn recv1(this: *InitExchange) !void {
        this.dev.recv1(this) catch |err| switch (err) {
            error.Unimplemented => {
                log.err("kernel sent us another opcode before initializing.", .{});
                return error.NonCompliantKernel;
            },
            else => return err,
        };
    }

    pub fn init(this: *InitExchange, _: k.InHeader, init_in: k.InitIn) !EOr(k.InitOut) {
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
        if (init_in.major > this.dev.version.major) {
            if (this.kernel_major_larger) {
                // we've already been through this
                log.err("kernel refusing to conform to major version {}. Sending {} instead.", .{ this.dev.version.major, init_in.major });
                return error.NonCompliantKernel;
            }

            this.kernel_major_larger = true;
            var out = std.mem.zeroes(k.InitOut);
            out.major = k.VERSION;
            return .{ .out = out };
        }
        // the kernel is on an old version, we'll cede to it.
        if (init_in.major < this.dev.version.major) {
            this.dev.version = .{
                .major = init_in.major,
                .minor = init_in.minor,
            };
        } else if (init_in.minor < this.dev.version.minor) {
            this.dev.version.minor = init_in.minor;
        }

        return .{
            .out = k.InitOut{
                .major = this.dev.version.major,
                .minor = this.dev.version.minor,
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
            },
        };
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
    setArgType(&arg_types, k.InHeader);

    if (opcode.InStruct()) |InStruct|
        setArgType(&arg_types, InStruct);

    for (0..opcode.nFiles()) |_|
        setArgType(&arg_types, [:0]const u8);

    if (opcode.bytesIn())
        setArgType(&arg_types, []const u8);

    if (opcode.OutStruct() == []k.Dirent or opcode.OutStruct() == []k.DirentPlus)
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

fn ConcatTuples(comptime T1: type, comptime T2: type) type {
    const t1: T1 = undefined;
    const t2: T2 = undefined;
    return @TypeOf(t1 ++ t2);
}

pub fn EOr(Out: type) type {
    return union(enum) {
        out: Out,
        // TODO: annoyingly, this can represent the state .{ .err = .SUCESS }
        err: k.@"-E",
    };
}

/// callbacks: *Callbacks
pub fn recv1(dev: *Dev, callbacks: anytype) !void {
    const Callbacks = @typeInfo(@TypeOf(callbacks)).Pointer.child;
    // everything in fuse is 8-byte-aligned
    var message_buf: [READ_BUF_SIZE]u8 align(8) = undefined;
    log.info("waiting for kernel message...", .{});
    const message_len = try dev.fh.reader().readAtLeast(&message_buf, @sizeOf(k.InHeader));
    log.info("got it!", .{});
    const message: []align(8) const u8 = message_buf[0..message_len];

    var pos: usize = 0;
    const header: *const k.InHeader = @alignCast(@ptrCast(&message[pos]));
    pos += @sizeOf(k.InHeader);
    std.debug.assert(header.len == message.len);
    log.info("received: {}", .{header});

    switch (header.opcode) {
        inline else => |opcode| {
            var bytes_arg_size: u32 = undefined;
            if (!@hasDecl(Callbacks, @tagName(opcode))) {
                log.err("Callback not provided for {s}", .{@tagName(opcode)});
                return error.Unimplemented;
            }
            const callback = @field(Callbacks, @tagName(opcode));
            var args: ConcatTuples(
                std.meta.Tuple(&[_]type{*Callbacks}),
                CallbackArgsT(opcode),
            ) = undefined;
            comptime var arg_n = 0;
            // pass the private data in as the first argument (this will look like a method to implement)
            setArg(&args, &arg_n, callbacks);
            setArg(&args, &arg_n, header.*);

            const MaybeInStruct = comptime opcode.InStruct();
            if (MaybeInStruct) |InStruct| {
                const size = inStructSize(InStruct, dev.version.minor);
                std.debug.assert(pos + size <= message.len);
                // TODO: this will give us garbage for the rest of the struct. what we want is 0s for sure.
                const in_struct: *const InStruct = @alignCast(@ptrCast(&message[pos]));
                if (comptime opcode.bytesIn())
                    // this field better exist for those opcodes
                    bytes_arg_size = in_struct.size;

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
                    //    probably not a problem since it just needs to be u8 aligned
                    // 2. how does it deal with offsets?
                    //    what does this even mean?
                    // SEE: https://github.com/hanwen/go-fuse/blob/master/fuse/request.go#L206
                    log.err("TODO: implement code for handling operations that send multiple filenames", .{});
                }
            }

            if (comptime opcode.bytesIn()) {
                const bytes = message[pos..][0..bytes_arg_size];
                log.info("received bytes", .{});
                setArg(&args, &arg_n, bytes);
                pos += bytes_arg_size;
                log.info("skipping {} extra bytes", .{message.len - pos});
                pos = message.len;
            }

            std.debug.assert(pos == message.len);

            var out = OutBuffer.init(dev.version.minor, header.unique);
            const ReturnPayload = @typeInfo(@typeInfo(@TypeOf(callback)).Fn.return_type.?).ErrorUnion.payload;
            comptime var OutStruct = opcode.OutStruct() orelse {
                // kernel not expecting response
                std.debug.assert(ReturnPayload == void);
                try @call(.auto, callback, args);
                return;
            };

            switch (OutStruct) {
                []k.Dirent, []k.DirentPlus => {
                    setArg(&args, &arg_n, &out);
                    OutStruct = void;
                },
                else => {},
            }

            // typecheck
            comptime std.debug.assert(ReturnPayload == EOr(OutStruct));

            switch (try @call(.auto, callback, args)) {
                .err => |err| {
                    std.debug.assert(err != .SUCCESS);
                    out.setErr(err);
                },
                .out => |ret| {
                    // XXX: ugh horrible hack.
                    switch (OutStruct) {
                        []const u8 => out.appendBytes(ret) catch @panic("bytes too long"),
                        k.CreateOut => {
                            // these have independent compat sizes
                            out.appendOutStruct(ret.entry_out) catch unreachable;
                            out.appendOutStruct(ret.open_out) catch unreachable;
                        },
                        else => out.appendOutStruct(ret) catch unreachable,
                    }
                },
            }

            if (out.isErr()) log.warn("responding to kernel with error: {s}", .{@tagName(out.header().@"error")});

            if (opcode.OutStruct() != null)
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
        k.OpenOut,
        k.Dirent,
        k.DirentPlus,
        k.GetxattrOut,
        k.WriteOut,
        void,
        => return @sizeOf(Data),

        k.CreateOut => @compileError(@typeName(Data) ++ " does not have an independent compat size. You must add it's components separately"),

        k.StatxOut,
        k.StatfsOut,
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

pub fn inStructSize(comptime Data: type, minor_version: u32) usize {
    return switch (Data) {
        k.GetattrIn,
        k.OpenIn,
        k.ReleaseIn,
        k.ReadIn,
        k.InitIn,
        k.FlushIn,
        k.GetxattrIn,
        k.SetattrIn,
        k.CreateIn,
        => @sizeOf(Data),

        k.WriteIn,
        => switch (minor_version) {
            0...8 => Data.COMPAT_SIZE,
            else => @sizeOf(Data),
        },

        k.IoctlIn,
        k.MknodIn,
        k.AccessIn,
        k.ForgetIn,
        k.BatchForgetIn,
        k.LinkIn,
        k.MkdirIn,
        k.FallocateIn,
        k.RenameIn,
        k.Rename2In,
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
    // TODO: use fusermount
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

// TODO: all this should go upstream in stdlib
const Cmsg = extern struct {
    len: usize,
    level: i32,
    type: SCM,
    _data: [0]u8,

    pub const SCM = enum(i32) {
        RIGHTS = 0x01,
        // TODO: These only exist if __USE_GNU is defined
        CREDENTIALS = 0x02,
        SECURITY = 0x03,
        PIDFD = 0x04,
        _,
    };

    pub inline fn data(cmsg: *const Cmsg) []const u8 {
        return @ptrCast(&cmsg._data);
    }
    pub inline fn next(msg: *const std.posix.msghdr, cmsg: *const Cmsg) ?*const Cmsg {

        // the current header is malformed. too small to be a full header
        // this is a weird check to do here. surely we're already screwed?
        if (Cmsg.len < @sizeOf(Cmsg)) return null;

        const msg_control_end = @intFromPtr(msg) + msg.controllen;
        const cmsg_end = @intFromPtr(cmsg) + cmsg.len;
        const space_left = msg_control_end - cmsg_end;
        const space_needed = @sizeOf(Cmsg) + Cmsg.padding(cmsg.len);
        if (space_left < space_needed) return null;

        const cmsg_ptr: [*]const u8 = @ptrCast(cmsg);

        return @ptrCast(cmsg_ptr[Cmsg.@"align"(cmsg.len)]);
    }
    pub inline fn first(msg: *const std.posix.msghdr) ?*const Cmsg {
        return if (msg.controllen < @sizeOf(Cmsg))
            null
        else
            @alignCast(@ptrCast(msg.control));
    }
    // TODO: combine this with the Align64 stuff above and generalize
    pub inline fn @"align"(len_: usize) usize {
        const lower_bits: usize = @sizeOf(usize) - 1;
        const upper_bits: usize = ~lower_bits;
        return len_ + lower_bits & upper_bits;
    }
    pub inline fn space(len_: usize) usize {
        return Cmsg.@"align"(len_) + Cmsg.@"align"(@sizeOf(Cmsg));
    }
    pub inline fn len(len_: usize) usize {
        return Cmsg.@"align"(@sizeOf(Cmsg)) + len_;
    }
    pub inline fn padding(len_: usize) usize {
        const lower_bits: usize = @sizeOf(usize) - 1;
        // return len - Cmsg.@"align"(len);
        return (@sizeOf(usize) - (len_ & lower_bits)) & lower_bits;
    }
};

// I resent needing an allocator at all, since everything is nicely bounded. And needing to construct an EnvMap with 1 item just to turn it into an array of strings is silly.
// but this isn't in a hotloop :sigh:
// TODO: look into (undocumented) --auto-unmount
// when we do, we'll need to figure out closing the file handles on the child process
pub fn fusermount(arena: std.mem.Allocator, mnt: [:0]const u8) !std.fs.File {
    const l = std.os.linux;
    var fds: [2]std.posix.fd_t = undefined;
    switch (std.posix.errno(l.socketpair(l.AF.UNIX, l.SOCK.SEQPACKET, 0, &fds))) {
        .SUCCESS => {},
        else => |err| {
            log.err("socketpair(): {}", .{err});
            return error.SocketPair;
        },
    }
    const local = std.fs.File{ .handle = fds[0] };
    defer local.close();
    const remote = std.fs.File{ .handle = fds[1] };
    defer remote.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    const exe =
        which("fusermount3", &path_buf) orelse
        which("fusermount", &path_buf) orelse
        @panic("no fusermount executable found");

    var env_map = std.process.EnvMap.init(arena);
    // var env_map = try std.process.getEnvMap(allocator);
    // defer env_map.deinit();
    try env_map.put("_FUSE_COMMFD", try std.fmt.allocPrint(arena, "{d}", .{remote.handle}));

    var proc = std.process.Child.init(&.{ exe, "--", mnt }, arena);
    proc.env_map = &env_map;
    proc.stdin_behavior = .Close;
    proc.stdout_behavior = .Inherit;
    proc.stderr_behavior = .Inherit;

    switch (try proc.spawnAndWait()) {
        .Exited => |rc| if (rc == 0) {} else {
            return error.FusermountFailed;
        },
        else => return error.FusermountFailed,
    }

    /////////////////////////////////////
    // Here Be Dragons
    // most of this is copied from libfuse/lib/mount.c
    // this appears to be a super arcane kernel interface, so there's no nice wrapping in zig (even some of the macros are missing)
    /////////////////////////////////////

    var buf: [1]u8 = undefined;

    var iovs: [1]std.posix.iovec = .{.{
        .base = &buf,
        .len = buf.len,
    }};

    var ccmsg: [Cmsg.space(@sizeOf(u32))]u8 = undefined;

    var msg: std.posix.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = &iovs,
        .iovlen = iovs.len,
        .control = @ptrCast(&ccmsg),
        .controllen = ccmsg.len,
        .flags = 0,
    };

    while (true) {
        switch (std.posix.errno(l.recvmsg(local.handle, &msg, 0))) {
            .SUCCESS => break,
            .INTR => continue,
            else => |err| {
                log.err("recvmsg(): {}", .{err});
                return error.RecvmsgFailed;
            },
        }
    }
    const cmsg = Cmsg.first(&msg) orelse return error.CmsgBroken;
    if (cmsg.type != .RIGHTS)
        log.err("got control message of wrong type {d}", .{cmsg.type});

    const fd_ptr: *const std.posix.fd_t = @ptrCast(&cmsg._data);

    return .{ .handle = fd_ptr.* };
}

pub fn which(file: []const u8, out_buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const PATH = std.posix.getenvZ("PATH") orelse return null;
    return lookup(file, PATH, out_buffer);
}

pub fn lookup(file: []const u8, path: []const u8, out_buffer: *[std.fs.max_path_bytes]u8) ?[]u8 {
    // TODO: check whether it is faster to first open the directory and call std.fs.Dir.access() before concatenating the paths
    var path_it = std.mem.tokenizeScalar(u8, path, ':');
    while (path_it.next()) |a_path| {
        const resolved_path = std.fmt.bufPrintZ(out_buffer, "{s}/{s}", .{
            a_path,
            file,
        }) catch continue;

        if (std.fs.accessAbsolute(resolved_path, .{})) |_| {
            return resolved_path;
        } else |_| {}
    }
    return null;
}

pub fn deinit(dev: Dev) !void {
    try unmount(dev.mnt);
    dev.fh.close();
}
