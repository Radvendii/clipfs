pub const c = @import("c.zig");

pub const Display = struct {
    raw: *c.Display,

    pub fn open(display_name: ?[]const u8) !Display {
        const raw = c.XOpenDisplay(@ptrCast(display_name)) orelse return error.NoDisplay;
        return .{ .raw = raw };
    }
    pub fn close(dpy: Display) !void {
        if (c.XCloseDisplay(dpy.raw) == c.BadGC)
            return error.BadGC;
    }

    pub fn defaultScreen(dpy: Display) Screen {
        return .{
            .dpy = dpy,
            .raw = c.DefaultScreen(dpy.raw),
        };
    }
};

// XXX: should this just be an enum? less convenient but more true to the C
pub const Screen = struct {
    dpy: Display,
    raw: c_int,

    pub fn rootWindow(screen: Screen) Window {
        return .{ .dpy = screen.dpy, .raw = c.RootWindow(screen.dpy.raw, screen.raw) };
    }
};
pub const Window = struct {
    dpy: Display,
    raw: c.Window,

    pub fn destroy(win: Window) !void {
        switch (c.XDestroyWindow(win.dpy.raw, win.raw)) {
            c.BadWindow => return error.BadWindow,
            else => {},
        }
    }

    pub fn createSimpleWindow(
        parent: Window,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        border_width: u32,
        border: u64,
        background: u64,
    ) !Window {
        const raw = c.XCreateSimpleWindow(
            parent.dpy.raw,
            parent.raw,
            @bitCast(x),
            @bitCast(y),
            @bitCast(width),
            @bitCast(height),
            @bitCast(border_width),
            @bitCast(border),
            @bitCast(background),
        );
        switch (raw) {
            c.BadAlloc => return error.BadAlloc,
            c.BadMatch => return error.BadMatch,
            c.BadValue => return error.BadValue,
            c.BadWindow => return error.BadWindow,
            else => {},
        }
        return .{
            .dpy = parent.dpy,
            .raw = raw,
        };
    }
};
