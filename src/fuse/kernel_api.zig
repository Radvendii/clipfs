const std = @import("std");
const zeroes = std.mem.zeroes;

// TODO: there are a bunch of flags struct members that are unclear what flags are supported

pub const VERSION = 7;
pub const MINOR_VERSION = 39;
pub const ROOT_ID = 1;

/// errno values are technically defined to be positive. However, as return
/// values their negations are typically used. This convention is followed
/// in the OutHeader struct. To provide a convenient, legible enum interface
/// without incurring the runtime cost and visual noise of conversions, we
/// define here a negative version of std.posix.E, where each of the fields is
/// the negative version.
//
// Unfortunately, comptime means:
// - no lsp completion.
// - we can't have any decls, such as `init()`
// I tried spelling out all the options explicitly, but different architectures
// have different sets of error codes (e.g. E.PORCLIM only defined on sparc*
// variants)
//
// Using @"-E" is a choice. Not sure if I like it. @"" is ugly, and used very
// little, but it is the most obvious identifier that explains what it is. NE
// could be a lot of things. Another option would be to just use E, but I do
// sort of respect that error codes *are* defined to be positive.
pub const @"-E" = @"-E": {
    const Type = std.builtin.Type;
    const E = std.posix.E;
    const fields = @typeInfo(E).Enum.fields;
    var @"-fields": [fields.len]Type.EnumField = undefined;
    for (fields, &@"-fields") |src, *dst| {
        dst.* = .{
            .name = src.name,
            .value = -src.value,
        };
    }
    break :@"-E" @Type(.{ .Enum = .{
        .tag_type = i32,
        .fields = &@"-fields",
        .decls = &.{},
        .is_exhaustive = false,
    } });
};

// Make sure all structures are padded to 64bit boundary, so 32bit userspace works under 64bit kernels
// TODO: is there a more ziggy way to do this?

pub const Attr = extern struct {
    ino: u64,
    size: u64,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u32,
    blksize: u32,
    flags: Flags,
    pub const Flags = packed struct(u32) {
        /// object is a submount root
        submount: bool = false,
        /// enable DAX for this file in per inode DAX mode
        dax: bool = false,

        _padding: std.meta.Int(.unsigned, 32 - 25) = 0,
    };
};
/// The following structures are bit-for-bit compatible with the statx(2) ABI in Linux
pub const Statx = extern struct {
    pub const Time = extern struct {
        tv_sec: i64,
        tv_nsec: u32,
        __reserved: i32,
    };
    mask: u32,
    blksize: u32,
    attributes: u64,
    nlink: u32,
    uid: u32,
    gid: u32,
    mode: u16,
    __spare0: [1]u16 = zeroes([1]u16),
    ino: u64,
    size: u64,
    blocks: u64,
    attributes_mask: u64,
    atime: Time,
    btime: Time,
    ctime: Time,
    mtime: Time,
    rdev_major: u32,
    rdev_minor: u32,
    dev_major: u32,
    dev_minor: u32,
    __spare2: [14]u64 = zeroes([14]u64),
};
pub const Kstatfs = extern struct {
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    bsize: u32,
    namelen: u32,
    frsize: u32,
    padding: u32 = zeroes(u32),
    spare: [6]u32 = zeroes([6]u32),
};
pub const FileLock = extern struct {
    start: u64,
    end: u64,
    type: u32,
    /// tgid
    pid: u32,
};
pub const ExtType = enum(c_uint) {
    max_nr_secctx = 31,
    ext_groups = 32,
};
pub const OpCode = enum(c_uint) {
    lookup = 1,
    forget = 2, // no reply
    getattr = 3,
    setattr = 4,
    readlink = 5,
    symlink = 6,
    mknod = 8,
    mkdir = 9,
    unlink = 10,
    rmdir = 11,
    rename = 12,
    link = 13,
    open = 14,
    read = 15,
    write = 16,
    statfs = 17,
    release = 18,
    fsync = 20,
    setxattr = 21,
    getxattr = 22,
    listxattr = 23,
    removexattr = 24,
    flush = 25,
    init = 26,
    opendir = 27,
    readdir = 28,
    releasedir = 29,
    fsyncdir = 30,
    getlk = 31,
    setlk = 32,
    setlkw = 33,
    access = 34,
    create = 35,
    interrupt = 36,
    bmap = 37,
    destroy = 38,
    ioctl = 39,
    poll = 40,
    notify_reply = 41,
    batch_forget = 42,
    fallocate = 43,
    readdirplus = 44,
    rename2 = 45,
    lseek = 46,
    copy_file_range = 47,
    setupmapping = 48,
    removemapping = 49,
    syncfs = 50,
    tmpfile = 51,
    statx = 52,

    // CUSE specific operations
    cuse_init = 4096,

    // Reserved opcodes: helpful to detect structure endian-ness
    // TODO: should be able to directly refer to the other values here.
    // SEE: https://github.com/ziglang/zig/issues/20339
    cuse_init_bswap_reserved = 1048576, // @intFromEnum(OpCode.cuse_init) << 8,
    init_bswap_reserved = 436207616, // @intFromEnum(OpCode.init) << 24,
};
pub const NotifyCode = enum(c_uint) {
    poll = 1,
    inval_inode = 2,
    inval_entry = 3,
    store = 4,
    retrieve = 5,
    delete = 6,
    // TODO: is there no way to get this information out of an enum in zig?
    max,
};
pub const EntryOut = extern struct {
    /// Inode ID
    nodeid: u64,
    /// Inode generation: nodeid: gen must be unique for the fs's lifetime
    generation: u64,
    /// Cache timeout for the name
    entry_valid: u64,
    /// Cache timeout for the attributes
    attr_valid: u64,
    entry_valid_nsec: u32,
    attr_valid_nsec: u32,
    attr: Attr,
    pub const COMPAT_SIZE = 120;
};
pub const ForgetIn = extern struct {
    nlookup: u64,
};
pub const ForgetOne = extern struct {
    nodeid: u64,
    nlookup: u64,
};
pub const BatchForgetIn = extern struct {
    count: u32,
    dummy: u32 = zeroes(u32),
};
pub const GetattrFlags = packed struct(u32) {
    fh: bool = false,
    _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
};
pub const GetattrIn = extern struct {
    getattr_flags: GetattrFlags,
    dummy: u32 = zeroes(u32),
    fh: u64,
};
pub const AttrOut = extern struct {
    attr_valid: u64,
    attr_valid_nsec: u32,
    dummy: u32 = zeroes(u32),
    attr: Attr,
    pub const COMPAT_SIZE = 96;
};
pub const StatxIn = extern struct {
    getattr_flags: GetattrFlags,
    reserved: u32 = zeroes(u32),
    fh: u64,
    sx_flags: u32,
    sx_mask: u32,
};
pub const StatxOut = extern struct {
    attr_valid: u64, // Cache timeout for the attributes
    attr_valid_nsec: u32,
    flags: u32,
    spare: [2]u64 = zeroes([2]u64),
    stat: Statx,
};
pub const MknodIn = extern struct {
    mode: u32,
    rdev: u32,
    umask: u32,
    padding: u32 = zeroes(u32),
    pub const COMPAT_SIZE = 8;
};
pub const MkdirIn = extern struct {
    mode: u32,
    umask: u32,
};
pub const RenameIn = extern struct {
    newdir: u64,
};
pub const Rename2In = extern struct {
    newdir: u64,
    flags: u32,
    padding: u32 = zeroes(u32),
};
pub const LinkIn = extern struct {
    oldnodeid: u64,
};
pub const SetattrIn = extern struct {
    valid: Valid,
    padding: u32 = zeroes(u32),
    fh: u64,
    size: u64,
    lock_owner: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    unused4: u32,
    uid: u32,
    gid: u32,
    unused5: u32 = zeroes(u32),

    // FATTR_* in linux/fuse.h source
    // says "bitmasks for fuse_seettattr_in.valid"
    pub const Valid = packed struct(u32) {
        mode: bool = false,
        uid: bool = false,
        gid: bool = false,
        size: bool = false,
        atime: bool = false,
        mtime: bool = false,
        fh: bool = false,
        atime_now: bool = false,
        mtime_now: bool = false,
        lockowner: bool = false,
        ctime: bool = false,
        kill_suidgid: bool = false,

        _padding: std.meta.Int(.unsigned, 32 - 12) = 0,
    };
};

pub const OpenInFlags = packed struct(u32) {
    //// kill suid and sgid if executable
    kill_suidgid: bool = false,
    _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
};
pub const OpenIn = extern struct {
    // TODO: are both of these the same set of Flags?
    flags: OpenInFlags,
    open_flags: OpenInFlags,
};
pub const CreateIn = extern struct {
    flags: u32,
    mode: u32,
    umask: u32,
    open_flags: OpenInFlags,
};
// FOPEN_* in linux/fuse.h source
// says "flags returned by the OPEN request"
pub const OpenOutFlags = packed struct(u32) {
    /// bypass page cache for this open file
    direct_io: bool = false,
    /// don't invalidate the data cache on open
    keep_cache: bool = false,
    /// the file is not seekable
    nonseekable: bool = false,
    /// allow caching this directory
    cache_dir: bool = false,
    /// the file is stream-like (no file position at all)
    stream: bool = false,
    /// don't flush data cache on close (unless FUSE_WRITEBACK_CACHE)
    noflush: bool = false,
    /// allow concurrent direct writes on the same inode
    parallel_direct_writes: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 7) = 0,
};
pub const OpenOut = extern struct {
    fh: u64,
    open_flags: OpenOutFlags,
    padding: u32 = zeroes(u32),
};
pub const ReleaseFlags = packed struct(u32) {
    flush: bool = false,
    flock_unlock: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 2) = 0,
};

pub const ReleaseIn = extern struct {
    fh: u64,
    flags: u32,
    release_flags: ReleaseFlags,
    lock_owner: u64,
};
pub const FlushIn = extern struct {
    fh: u64,
    unused: u32 = zeroes(u32),
    padding: u32 = zeroes(u32),
    lock_owner: u64,
};
pub const ReadFlags = packed struct(u32) {
    lockowner: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
};

/// the read buffer is required to be at least 8k, but may be much larger
// TODO: what does this represent? Does it make sense to move it into ReadIn struct?
pub const MIN_READ_BUFFER = 8192;

pub const ReadIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    read_flags: ReadFlags,
    lock_owner: u64,
    flags: u32,
    padding: u32 = zeroes(u32),
};
pub const WriteFlags = packed struct(u32) {
    /// delayed write from page cache, file handle is guessed
    cache: bool = false,
    /// lock_owner field is valid
    lockowner: bool = false,
    /// kill suid and sgid bits
    kill_suidgid: bool = false,
    // obsolete alias: this flag implies killing suid/sgid only
    // kill_priv == kill_suidgid

    _padding: std.meta.Int(.unsigned, 32 - 3) = 0,
};
pub const WriteIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    write_flags: WriteFlags,
    lock_owner: u64,
    flags: u32,
    padding: u32 = zeroes(u32),
    pub const COMPAT_SIZE = 24;
};
pub const WriteOut = extern struct {
    size: u32,
    padding: u32 = zeroes(u32),
};
pub const StatfsOut = extern struct {
    st: Kstatfs,
    pub const COMPAT_SIZE = 48;
};
pub const FsyncFlags = packed struct(u32) {
    /// sync data only, not metadata
    fdatasync: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
};
pub const FsyncIn = extern struct {
    fh: u64,
    fsync_flags: u32,
    padding: u32 = zeroes(u32),
};
pub const SetxattrFlags = packed struct(u32) {
    /// clear sgid when system.posix_acl_access is set
    acl_kill_sgid: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
};
pub const SetxattrIn = extern struct {
    size: u32,
    flags: SetxattrFlags,
    setxattr_flags: u32,
    padding: u32 = zeroes(u32),
    pub const COMPAT_SIZE = 8;
};
pub const GetxattrIn = extern struct {
    size: u32,
    padding: u32 = zeroes(u32),
};
pub const GetxattrOut = extern struct {
    size: u32,
    padding: u32 = zeroes(u32),
};
pub const LkFlags = packed struct(u32) {
    flock: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
};

pub const LkIn = extern struct {
    fh: u64,
    owner: u64,
    lk: FileLock,
    lk_flags: LkFlags,
    padding: u32 = zeroes(u32),
};
pub const LkOut = extern struct {
    lk: FileLock,
};
pub const AccessIn = extern struct {
    mask: u32,
    padding: u32 = zeroes(u32),
};

pub const InitFlags = packed struct(u32) {
    /// asynchronous read requests
    async_read: bool = false,
    /// remote lockign for POSIX file locks
    posix_locks: bool = false,
    /// kernel sends file handle for fstat, etc... (not yet supported)
    file_ops: bool = false,
    /// handles the O_TRUNC open flag in the filesystem
    atomic_o_trunc: bool = false,
    /// filesystem handles lookups of "." and ".."
    export_support: bool = false,
    /// filesystem can handle write sizes larger than 4kB
    big_writes: bool = false,
    /// don't apply umask to file mode on create operations
    dont_mask: bool = false,
    /// kernel supports splice write on the device
    splice_write: bool = false,
    /// kernel supports splice move on the device
    splice_move: bool = false,
    /// kernel supports splice read on the device
    splice_read: bool = false,
    /// remote locking for BSD style file locks
    flock_locks: bool = false,
    /// kernel supports ioctl on directories
    has_ioctl_dir: bool = false,
    /// automatically invalidate cached pages
    auto_inval_data: bool = false,
    /// do READDIRPLUS (READDIR+LOOKUP in one)
    do_readdirplus: bool = false,
    /// adaptive readdirplus
    readdirplus_auto: bool = false,
    /// asynchronous direct I/O submission
    async_dio: bool = false,
    /// use writeback cache for buffered writes
    writeback_cache: bool = false,
    /// kernel supports zero-message opens
    no_open_support: bool = false,
    /// allow parallel lookups and readdir
    parallel_dirops: bool = false,
    /// fs handles killing suid/sgid/cap on write/chown/trunc
    handle_killpriv: bool = false,
    /// filesystem supports posix acls
    posix_acl: bool = false,
    /// reading the device after abort returns ECONNABORTED
    abort_error: bool = false,
    /// init_out.max_pages contains the max number of req pages
    max_pages: bool = false,
    /// cache READLINK responses
    cache_symlinks: bool = false,
    /// kernel supports zero-message opendir
    no_opendir_support: bool = false,
    /// only invalidate cached pages on explicit request
    explicit_inval_data: bool = false,
    /// InitOut.map_alignment contains log2(byte alignment) for
    /// foffset and moffset fields in struct
    /// SetupmappingOut and RemovemappingOne.
    map_alignment: bool = false,
    /// kernel supports auto-mounting directory submounts
    submounts: bool = false,
    /// fs kills suid/sgid/cap on write/chown/trunc
    /// Upon write/truncate suid/sgid is only killed if caller
    /// does not have CAP_FSETID. Additionally upon
    /// write/truncate sgid is killed only if file has group
    /// execute permission. (Same as Linux VFS behavior).
    handle_killpriv_v2: bool = false,
    /// Server supports extended struct fuse_setxattr_in
    setxattr_ext: bool = false,
    /// extended fuse_init_in request
    init_ext: bool = false,
    /// reserved, do not use
    init_reserved: bool = false,
};
// bits 32..63 get shifted down 32 bits into the flags2 field
pub const InitFlags2 = packed struct(u32) {
    /// add security context to create, mkdir, symlink, and mknod
    security_ctx: bool = false,
    /// use per inode DAX
    has_inode_dax: bool = false,
    /// add supplementary group info to create, mkdir,
    /// symlink and mknod (single group that matches parent)
    create_supp_group: bool = false,
    /// kernel supports expiry-only entry invalidation
    has_expire_only: bool = false,
    /// relax restrictions in FOPEN_DIRECT_IO mode, for now
    /// allow shared mmap
    direct_io_relax: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 5) = 0,
};
pub const InitIn = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: InitFlags,
    flags2: InitFlags2,
    unused: [11]u32 = zeroes([11]u32),
};
pub const InitOut = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: InitFlags,
    max_background: u16,
    congestion_threshold: u16,
    max_write: u32,
    time_gran: u32,
    max_pages: u16,
    map_alignment: u16,
    flags2: InitFlags2,
    unused: [7]u32 = zeroes([7]u32),
    pub const COMPAT_SIZE = 8;
    // TODO: why don't all the COMPAT_SIZEs say what version they're for?
    pub const COMPAT_22_SIZE = 24;
};
pub const InterruptIn = extern struct {
    unique: u64,
};
pub const BmapIn = extern struct {
    block: u64,
    blocksize: u32,
    padding: u32 = zeroes(u32),
};
pub const BmapOut = extern struct {
    block: u64,
};

pub const IoctlFlags = packed struct(u32) {
    /// 32bit compat ioctl on 64bit machine
    compat: bool = false,
    /// not restricted to well-formed ioctls, retry allowed
    unrestricted: bool = false,
    /// retry with new iovecs
    retry: bool = false,
    /// 32bit ioctl
    @"32bit": bool = false,
    /// is a directory
    dir: bool = false,
    /// x32 compat ioctl on 64bit machine (64bit time_t)
    compat_x32: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 6) = 0,
};
/// maximum of in_iovecs + out_iovecs
pub const MAX_IOVEC = 256;

pub const IoctlIn = extern struct {
    fh: u64,
    flags: IoctlFlags,
    cmd: u32,
    arg: u64,
    in_size: u32,
    out_size: u32,
};
pub const IoctlIovec = extern struct {
    base: u64,
    len: u64,
};
pub const IoctlOut = extern struct {
    result: i32,
    flags: IoctlFlags,
    in_iovs: u32,
    out_iovs: u32,
};

pub const PollFlags = packed struct(u32) {
    /// request poll notify
    schedule_notify: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
};

pub const PollIn = extern struct {
    fh: u64,
    kh: u64,
    flags: u32,
    events: u32,
};
pub const PollOut = extern struct {
    revents: u32,
    padding: u32 = zeroes(u32),
};
pub const NotifyPollWakeupOut = extern struct {
    kh: u64,
};
pub const FallocateIn = extern struct {
    fh: u64,
    offset: u64,
    length: u64,
    mode: u32,
    padding: u32 = zeroes(u32),
};
pub const InHeader = extern struct {
    len: u32,
    opcode: OpCode,
    unique: u64,
    nodeid: u64,
    uid: std.os.linux.uid_t,
    gid: std.os.linux.gid_t,
    pid: std.os.linux.pid_t,
    total_extlen: u16,
    padding: u16 = zeroes(u16),
};
pub const OutHeader = extern struct {
    len: u32,
    // TODO: does this have a more defined error type? totally unclear from the docs
    // TODO: look in the kernel
    @"error": @"-E",
    unique: u64,
};

/// align up (ceil) to the nearest u64
/// this is FUSE_REC_ALIGN / FUSE_DIRENT_ALIGN in the C header
pub fn alignU64(x: usize) usize {
    return x + @sizeOf(u64) - 1 & ~(@sizeOf(u64) - 1);
}
// TODO: consider using std.mem.CopyPtrAttrs
fn TransferConstVolatile(BasePtr: type, ConstVolatilePtr: type) !type {
    switch (@typeInfo(BasePtr)) {
        .Pointer => |base_ptr| {
            switch (@typeInfo(ConstVolatilePtr)) {
                .Pointer => |const_volatile_ptr| {
                    return @Type(.{ .Pointer = .{
                        .size = base_ptr.size,
                        .alignment = base_ptr.alignment,
                        .address_space = base_ptr.address_space,
                        .child = base_ptr.child,
                        .is_allowzero = base_ptr.is_allowzero,
                        .sentinel = base_ptr.sentinel,

                        .is_const = const_volatile_ptr.is_const,
                        .is_volatile = const_volatile_ptr.is_volatile,
                    } });
                },
                else => @compileError("ConstVolatilePtr \"" ++ @typeName(ConstVolatilePtr) ++ "\" is not a pointer"),
            }
        },
        else => @compileError("BasePtr \"" ++ @typeName(BasePtr) ++ "\" is not a pointer"),
    }
}
pub const Dirent = extern struct {
    ino: u64,
    off: u64,
    namelen: u32,
    type: u32,
    _name: [0]u8,

    /// size, if properly aligned
    pub fn size(self: *const Dirent) usize {
        return alignU64(NAME_OFFSET + self.namelen);
    }

    pub const NAME_OFFSET = @offsetOf(Dirent, "_name");

    fn NameType(comptime SelfType: type) type {
        switch (@typeInfo(SelfType)) {
            .Pointer => TransferConstVolatile([]u8, SelfType),
            else => @compileError("Flexible Array Members can only be accessed via a pointer"),
        }
    }
    /// Gets access to the flexible array member @name.
    /// Zig doesn't really have FAMs, so we simulate it here.
    /// Note that if @namelen is set incorrectly, this may access invalid memory
    // TODO: should this be [*]u8 or []u8? should we provide both APIs?
    pub fn name(self: anytype) NameType(@TypeOf(self)) {
        const manyPtr = @as(
            TransferConstVolatile([*]u8, @TypeOf(self)),
            @ptrCast(&self._name),
        );
        return manyPtr[0..self.namelen];
    }
    // this seems higher-level than belongs here
    // pub fn setName(self: *Dirent, new_name: []const u8) void {
    //     self.namelen = name.len;
    //     @memcpy(self.name(), new_name);
    // }
};
pub const DirentPlus = extern struct {
    entryOut: EntryOut = zeroes(EntryOut),
    dirent: Dirent = zeroes(Dirent),
    pub const NAME_OFFSET = @offsetOf(DirentPlus, "dirent") + Dirent.NAME_OFFSET;
    pub fn size(self: *const DirentPlus) usize {
        return alignU64(NAME_OFFSET + self.dirent.namelen);
    }
};
pub const NotifyInvalInodeOut = extern struct {
    ino: u64,
    off: i64,
    len: i64,
};
pub const NotifyInvalEntryFlags = packed struct(u32) {
    expire_only: bool = false,

    _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
};
pub const NotifyInvalEntryOut = extern struct {
    parent: u64,
    namelen: u32,
    flags: NotifyInvalEntryFlags,
};
pub const NotifyDeleteOut = extern struct {
    parent: u64,
    child: u64,
    namelen: u32,
    padding: u32 = zeroes(u32),
};
pub const NotifyStoreOut = extern struct {
    nodeid: u64,
    offset: u64,
    size: u32,
    padding: u32 = zeroes(u32),
};
pub const NotifyRetrieveOut = extern struct {
    notify_unique: u64,
    nodeid: u64,
    offset: u64,
    size: u32,
    padding: u32 = zeroes(u32),
};
// Matches the size of fuse_write_in
pub const NotifyRetrieveIn = extern struct {
    dummy1: u64 = zeroes(u64),
    offset: u64,
    size: u32,
    dummy2: u32 = zeroes(u32),
    dummy3: u64 = zeroes(u64),
    dummy4: u64 = zeroes(u64),
};
pub const LseekIn = extern struct {
    fh: u64,
    offset: u64,
    whence: u32,
    padding: u32 = zeroes(u32),
};
pub const LseekOut = extern struct {
    offset: u64 = zeroes(u64),
};
pub const CopyFileRangeIn = extern struct {
    fh_in: u64,
    off_in: u64,
    nodeid_out: u64,
    fh_out: u64,
    off_out: u64,
    len: u64,
    flags: u64,
};
pub const SetupmappingIn = extern struct {
    /// An already open handle
    fh: u64,
    /// Offset into the file to start the mapping
    foffset: u64,
    /// Length of mapping required
    len: u64,
    /// Flags
    flags: Flags,
    /// Offset in Mmeory Window
    moffset: u64,
    pub const Flags = packed struct(u64) {
        write: bool = false,
        read: bool = false,
        _padding: std.meta.Int(.unsigned, 64 - 2) = 0,
    };
};

pub const REMOVEMAPPING_MAX_ENTRY = std.mem.page_size / @sizeOf(RemovemappingOne);

pub const RemovemappingIn = extern struct {
    /// number of RemovemappingOne follows
    count: u32,
};
pub const RemovemappingOne = extern struct {
    /// Offset into hte dax window start the unmapping
    moffset: u64,
    /// Length of mapping required
    len: u64,
};
pub const SyncfsIn = extern struct {
    padding: u64 = zeroes(u64),
};
/// For each security context, send Secctx with size of security context
/// Secctx will be followed by security context name and this in turn
/// will be followed by actual context label.
/// Secctx, name, context
pub const Secctx = extern struct {
    size: u32,
    padding: u32 = zeroes(u32),
};
/// Contains the information about how many secctx structures are being
/// sent and what's the total size of all security contexts (including
/// size of SecctxHeader).
pub const SecctxHeader = extern struct {
    size: u32,
    nr_secctx: u32,
};
/// ExtHeader - extension header
/// @size: total size of this extension including this header
/// @type: type of extension
/// This is made compatible with SecctxHeader by using type values > MAX_NR_SECCTX
pub const ExtHeader = extern struct {
    size: u32,
    type: u32,
};
/// struct fuse_supp_groups - Supplementary group extension
/// @nr_groups: number of supplementary groups
/// @groups: flexible array of group IDs
pub const SuppGroups = extern struct {
    nr_groups: u32,
    pub fn groups(self: anytype) std.zig.c_translation.FlexibleArrayType(@TypeOf(self), c_uint) {
        return @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + 4));
    }
};

/// device ioctls
// SEE: https://john-millikin.com/the-fuse-protocol#multi-threading
pub const DEV_IOC_MAGIC = 229;
pub const FUSE_DEV_IOC_CLONE = std.os.linux.IOCTL.IOR(DEV_IOC_MAGIC, 0, u32);

pub const Cuse = struct {
    pub const InitFlags = packed struct(u32) {
        unrestricted_ioctl: bool = false,
        _padding: std.meta.Int(.unsigned, 32 - 1) = 0,
    };
    pub const InitIn = extern struct {
        major: u32,
        minor: u32,
        unused: u32 = zeroes(u32),
        flags: Cuse.InitFlags,
    };
    pub const InitOut = extern struct {
        major: u32,
        minor: u32,
        unused: u32 = zeroes(u32),
        flags: Cuse.InitFlags,
        max_read: u32,
        max_write: u32,
        dev_major: u32, // chardev major
        dev_minor: u32, // chardev minor
        spare: [10]u32 = zeroes([10]u32),
    };
    pub const INIT_INFO_MAX = 4096;
};
