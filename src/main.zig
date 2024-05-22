const std = @import("std");
const c = @import("c.zig");

pub fn main() !void {
    const dpy: *c.Display = c.XOpenDisplay(null) orelse return error.NoDisplay;
    const screen: c_int = c.DefaultScreen(dpy);
    const root: c.Window = c.RootWindow(dpy, screen);

    const owner: c_ulong = c.XCreateSimpleWindow(dpy, root, -10, -10, 1, 1, 0, 0, 0);
    _ = owner; // autofix
}
