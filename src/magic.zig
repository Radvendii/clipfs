// can't use a toplevel opaque. have to @import("magic.zig").Magic
// SEE: https://github.com/ziglang/zig/issues/6617
// SEE: https://github.com/ziglang/zig/issues/7881
// SEE: https://github.com/ziglang/zig/issues/19448
pub const Magic = opaque {
    const std = @import("std");
    pub const c = @cImport({
        @cInclude("magic.h");
    });
    const log = std.log.scoped(.libmagic);

    inline fn raw(mgc: *Magic) c.magic_t {
        return @ptrCast(mgc);
    }

    // TODO: is there some way to remove the no_ and change the default to `true`?
    // just doing that flips the bit in the resulting bitmask
    pub const OpenFlags = packed struct(c_int) {
        debug: bool = false,
        symlink: bool = false,
        compress: bool = false,
        devices: bool = false,
        mime_type: bool = false,
        @"continue": bool = false,
        check: bool = false,
        preserve_atime: bool = false,
        raw: bool = false,
        @"error": bool = false,
        mime_encoding: bool = false,
        apple: bool = false,
        no_check_compress: bool = false,
        no_check_tar: bool = false,
        no_check_soft: bool = false,
        no_check_apptype: bool = false,
        no_check_elf: bool = false,
        no_check_text: bool = false,
        no_check_cdf: bool = false,
        no_check_csv: bool = false,
        no_check_tokens: bool = false,
        no_check_encoding: bool = false,
        no_check_json: bool = false,
        no_check_simh: bool = false,
        extension: bool = false,
        compress_transp: bool = false,
        no_compress_fork: bool = false,

        _padding2: u5 = 0,
    };

    pub fn open(flags: OpenFlags) *Magic {
        if (c.magic_open(@bitCast(flags))) |_raw| {
            return @ptrCast(_raw);
        } else {
            // this should only happen if MagicFlags is an invalid bit pattern
            unreachable;
        }
    }

    pub fn close(mgc: *Magic) void {
        c.magic_close(mgc.raw());
    }

    pub fn load(mgc: *Magic, db_files: ?[:0]const u8) !void {
        const err = c.magic_load(mgc.raw(), @ptrCast(db_files));
        if (err == -1) {
            // TODO: put in error handling with magic_errno()
            return error.MagicLoad;
        }
    }

    pub fn file(mgc: *Magic, file_path: ?[:0]const u8) ![:0]const u8 {
        const c_str = c.magic_file(mgc.raw(), @ptrCast(file_path)) orelse
            return error.MagicFailed;
        return std.mem.span(c_str);
    }

    pub fn buffer(mgc: *Magic, buf: []const u8) ![:0]const u8 {
        const c_str = c.magic_buffer(mgc.raw(), @ptrCast(buf), buf.len) orelse
            return error.MagicFailed;
        return std.mem.span(c_str);
    }

    pub fn logIfError(mgc: *Magic) void {
        if (c.magic_error(mgc.raw())) |err| {
            log.err("{s}", .{err});
        }
    }
};
