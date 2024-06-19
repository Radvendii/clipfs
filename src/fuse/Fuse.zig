const std = @import("std");
const log = std.log.scoped(.fuse);

pub const kernel = @import("kernel_api.zig");

const Self = @This();

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

dev: std.fs.File,
// TODO: is this the right use of AnyReader? Should I be more specific here?
_reader: std.io.BufferedReader(READ_BUF_SIZE, std.fs.File.Reader),
_writer: std.io.BufferedWriter(WRITE_BUF_SIZE, std.fs.File.Writer),
version: struct { major: u32, minor: u32 },

pub inline fn reader(self: *Self) @TypeOf(self._reader).Reader {
    return self._reader.reader();
}
pub inline fn writer(self: *Self) @TypeOf(self._writer).Writer {
    return self._writer.writer();
}
pub inline fn flush_writer(self: *Self) !void {
    return self._writer.flush();
}

pub fn init() !Self {
    const dev = try std.fs.openFileAbsolute("/dev/fuse", .{ .mode = .read_write });
    errdefer dev.close();

    var buf: [256]u8 = undefined;
    const mount_args: [:0]u8 = try std.fmt.bufPrintZ(&buf, "fd={d},rootmode={o},user_id={d},group_id={d}", .{
        dev.handle,
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

    const reader_unbuffered = dev.reader();
    const _reader = std.io.bufferedReaderSize(READ_BUF_SIZE, reader_unbuffered);

    const writer_unbuffered = dev.writer();
    const _writer = bufferedWriterSize(WRITE_BUF_SIZE, writer_unbuffered);

    var self = Self{
        .dev = dev,
        ._reader = _reader,
        ._writer = _writer,
        // Initial version. This will get modified when we exchange Init structs with the kernel
        .version = .{
            .major = kernel.VERSION,
            .minor = kernel.MINOR_VERSION,
        },
    };

    // init exchange

    var in_header = try self.reader().readStruct(kernel.InHeader);
    std.debug.assert(in_header.opcode == .init);

    const extraneous = in_header.len - (@sizeOf(kernel.InHeader) + @sizeOf(kernel.InitIn));
    if (extraneous < 0) {
        log.err("Kernel's init message is to small by {} bytes. There is no known reason for this to happen, and we don't know how to proceed.", .{-extraneous});
        return error.InitTooSmall;
    } else if (extraneous > 0) {
        log.warn("Kernel's init message is too big by {} bytes. This may be a newer version of the kernel. Will attempt to plow ahead and treat the first bytes as the InitIn we understand and then ignore subsequent bytes.", .{extraneous});
    }

    var init_in = try self.reader().readStruct(kernel.InitIn);
    log.debug("received init from kernel: {}", .{std.json.fmt(init_in, .{ .whitespace = .indent_2 })});

    if (extraneous > 0) {
        _ = try self.reader().skipBytes(extraneous, .{});
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
    if (init_in.major > self.version.major) {
        try self.writer().writeStruct(kernel.OutHeader{
            .unique = in_header.unique,
            .@"error" = 0,
            .len = @sizeOf(kernel.OutHeader) + @sizeOf(u32),
        });
        try self.writer().writeInt(u32, kernel.VERSION, @import("builtin").target.cpu.arch.endian());
        try self.flush_writer();

        in_header = try self.reader().readStruct(kernel.InHeader);
        std.debug.assert(in_header.opcode == .init);
        // at this point the kernel shouldn't send us incompatible structs
        std.debug.assert(in_header.len == @sizeOf(kernel.InHeader) + @sizeOf(kernel.InitIn));
        init_in = try self.reader().readStruct(kernel.InitIn);
        // TODO: will this ever be <=?
        std.debug.assert(init_in.major == self.version.major);
    }

    // the kernel is on an old version, we'll cede to it.
    if (init_in.major < self.version.major) {
        self.version = .{
            .major = init_in.major,
            .minor = init_in.minor,
        };
    } else if (init_in.minor < self.version.minor) {
        self.version.minor = init_in.minor;
    }

    try self.sendOut(in_header.unique, kernel.InitOut{
        .major = self.version.major,
        .minor = self.version.minor,
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
    return self;
}

// TODO: if we put the version number of the change into the COMPAT_SIZE name, we can comptime automate this whole thing
// TODO: we could allow for sending ints here. i'm a little wary of that because it's such an unusual thing to do that i don't want to bog down the "normal" function with it or give the impression it's a normal thing
pub fn outSize(self: *const Self, comptime Data: type) usize {
    switch (Data) {
        kernel.InitOut => {
            return switch (self.version.minor) {
                0...4 => kernel.InitOut.COMPAT_SIZE,
                5...22 => kernel.InitOut.COMPAT_22_SIZE,
                else => @sizeOf(Data),
            };
        },

        kernel.EntryOut,
        kernel.AttrOut,
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

        // => {
        //     try self.writer.writeStruct(header);
        //     try self.writer.writeStruct(data);
        // },

        else => @compileError("Unsupported send operation on type " ++ @typeName(Data)),
    }
}

pub fn outBytes(self: *const Self, data_ptr: anytype) ![]const u8 {
    const Data = @typeInfo(@TypeOf(data_ptr)).Pointer.child;
    const size = self.outSize(Data);
    if (size == @sizeOf(Data)) {
        return std.mem.asBytes(data_ptr);
    }
    if (size < @sizeOf(Data)) {
        log.debug("Truncating {s} to {} bytes due to old protocol version {}.{}", .{ @typeName(Data), size, self.version.major, self.version.minor });
        return std.mem.asBytes(data_ptr)[0..size];
    }
    if (size > @sizeOf(Data)) {
        log.debug("Expanding {s} to {} bytes, probably due to FAM", .{ @typeName(Data), size });
        return @as([*]const u8, @ptrCast(data_ptr))[0..size];
    }
    unreachable;
}

pub fn sendOut(self: *Self, unique: u64, data: anytype) !void {
    log.info("Sending to kernel: {}", .{data});
    // Normally, we just send the struct.
    // Two things make the size unpredictable:
    // 1. compatibilty with older protocol versions means we might have to truncate it
    // 2. flexible array members are not of compile-time known size
    const out_bytes = try self.outBytes(&data);

    const header = kernel.OutHeader{
        .@"error" = 0,
        .unique = unique,
        .len = @intCast(@sizeOf(kernel.OutHeader) + out_bytes.len),
    };
    try self.writer().writeStruct(header);
    try self.writer().writeAll(out_bytes);
    try self.flush_writer();
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

pub fn deinit(self: Self) !void {
    try unmount();
    self.dev.close();
}
