const std = @import("std");
const x = @import("x11.zig");

pub fn main() !void {
    const dpy = try x.Display.open(null);
    // XXX: what do we do if close() errors?
    defer dpy.close() catch unreachable;
    x.DPY = dpy;

    const screen = dpy.defaultScreen();

    const root = screen.rootWindow();

    // dummy window to receive messages from the client that wants the clipboard
    // XXX: the tutorial positions the window at -10, -10, but the function takes an unsigned value...
    const owner = try root.createSimpleWindow(1, 1, 1, 1, 0, 0, 0);
    defer owner.destroy() catch unreachable;

    const sel = try dpy.internAtom("CLIPBOARD", false);
    const utf8 = try dpy.internAtom("UTF8_STRING", false);
    _ = utf8; // autofix

    try owner.setSelectionOwner(sel);

    std.log.info("Took selection ownership\n", .{});

    while (true) {
        const ev = dpy.nextEvent();
        switch (ev.type) {
            x.c.SelectionClear => {
                std.log.info("Lost selection ownership\n", .{});
                return;
            },
            x.c.SelectionRequest => {
                const sev = ev.xselectionrequest;
                std.log.info("Requestor: {}", .{sev.requestor});
            },
            else => {},
        }
    }
}
