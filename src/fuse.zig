const std = @import("std");
pub const c = @cImport({
    @cDefine("FUSE_USE_VERSION", 36);
    @cInclude("fuse.h");
});
