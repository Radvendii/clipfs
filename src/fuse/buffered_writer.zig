// TODO: upstream some of this

const std = @import("std");

const io = std.io;
const mem = std.mem;

pub const BufferedWriterOptions = struct {
    buffer_size: usize = 4096,
    buffer_align: usize = 1,
    automatic_flush: bool = true,
};

pub fn BufferedWriter(comptime WriterType: type, comptime opts: BufferedWriterOptions) type {
    return struct {
        unbuffered_writer: WriterType,
        buf: [opts.buffer_size]u8 align(opts.buffer_align) = undefined,
        end: usize = 0,

        pub const Error = if (opts.automatic_flush)
            WriterType.Error
        else
            WriterType.Error || error{ NeedsFlush, BufferTooSmall };
        pub const Writer = io.Writer(*Self, Error, write);

        const Self = @This();

        pub fn flush(self: *Self) !void {
            try self.unbuffered_writer.writeAll(self.buf[0..self.end]);
            self.end = 0;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            if (self.end + bytes.len > self.buf.len) {
                if (opts.automatic_flush) {
                    try self.flush();
                    if (bytes.len > self.buf.len)
                        return self.unbuffered_writer.write(bytes);
                } else {
                    if (self.end == 0) {
                        return error.BufferTooSmall;
                    } else {
                        return error.NeedsFlush;
                    }
                }
                if (bytes.len > self.buf.len)
                    return self.unbuffered_writer.write(bytes);
            }

            const new_end = self.end + bytes.len;
            @memcpy(self.buf[self.end..new_end], bytes);
            self.end = new_end;
            return bytes.len;
        }
    };
}

pub fn bufferedWriter(underlying_stream: anytype) BufferedWriter(@TypeOf(underlying_stream), .{}) {
    return .{ .unbuffered_writer = underlying_stream };
}

pub fn bufferedWriterOpts(unbuffered_writer: anytype, comptime opts: BufferedWriterOptions) BufferedWriter(@TypeOf(unbuffered_writer), opts) {
    return .{ .unbuffered_writer = unbuffered_writer };
}
