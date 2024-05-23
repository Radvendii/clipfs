const std = @import("std");
const x = @import("x11.zig");

pub fn main() !void {
    const dpy = try x.Display.open(null);
    // XXX: what do we do if close() errors?
    defer dpy.close() catch unreachable;

    const screen = dpy.defaultScreen();

    const root = screen.rootWindow();

    // dummy window to receive messages from the client that wants the clipboard
    // XXX: the tutorial positions the window at -10, -10, but the function takes an unsigned value...
    const owner = try root.createSimpleWindow(1, 1, 500, 500, 1, x.c.BlackPixel(dpy.raw, screen.raw), x.c.WhitePixel(dpy.raw, screen.raw));
    // const owner = try root.createSimpleWindow(1, 1, 1, 1, 0, 0, 0);
    defer owner.destroy() catch unreachable;

    try owner.mapRaised();

    var e: x.c.XEvent = undefined;

    while (true) {
        _ = x.c.XNextEvent(dpy.raw, &e);
        if (e.type == x.c.Expose) {
            _ = x.c.XFillRectangle(dpy.raw, owner.raw, x.c.DefaultGC(dpy.raw, screen.raw), 20, 20, 10, 10);
            _ = x.c.XDrawString(dpy.raw, owner.raw, x.c.DefaultGC(dpy.raw, screen.raw), 10, 50, "hello".ptr, "hello".len);
        }
        if (e.type == x.c.KeyPress) {
            break;
        }
    }
}
