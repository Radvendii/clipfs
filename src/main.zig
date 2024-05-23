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
    const owner = try root.createSimpleWindow(1, 1, 1, 1, 0, 0, 0);
    defer owner.destroy() catch unreachable;
}
