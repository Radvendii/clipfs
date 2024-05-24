const std = @import("std");
const x = @import("x11.zig");

pub fn main() !void {
    x.DPY = try x.Display.open(null);
    // XXX: what do we do if close() errors?
    defer x.DPY.close() catch unreachable;

    const screen = x.defaultScreen();

    const root = screen.rootWindow();

    // dummy window to receive messages from the client that wants the clipboard
    // XXX: the tutorial positions the window at -10, -10, but the function takes an unsigned value...
    const owner = try root.createSimpleWindow(1, 1, 1, 1, 0, 0, 0);
    defer owner.destroy() catch unreachable;

    const sel = try x.internAtom("CLIPBOARD", false);
    const utf8 = try x.internAtom("UTF8_STRING", false);

    try owner.setSelectionOwner(sel);

    std.log.info("Took selection ownership\n", .{});

    while (true) {
        const ev = x.nextEvent();
        switch (ev.type) {
            .SelectionClear => {
                std.log.info("Lost selection ownership\n", .{});
                return;
            },
            .SelectionRequest => {
                // is this copying it? is that a problem?
                const sev = ev.selection_request;
                std.log.info("Requestor: {x}", .{sev.requestor});
                if (sev.target != utf8 or sev.property == x.Atom.None) {
                    try send_no(sev);
                } else {
                    try send_utf8(sev, utf8);
                }
            },
            else => {},
        }
    }
}

fn send_no(sev: x.SelectionRequestEvent) !void {
    const an = try x.getAtomName(sev.target);
    defer x.free(an);
    std.log.warn("denying request of type .{s}", .{an});

    const ssev = x.Event{ .selection = .{
        .type = .SelectionNotify,
        .requestor = sev.requestor,
        .selection = sev.selection,
        .target = sev.target,
        .property = x.Atom.None,
        .time = sev.time,
    } };

    return ssev.send(sev.requestor, true, x.c.NoEventMask);
}

fn send_utf8(sev: x.SelectionRequestEvent, utf8: x.Atom) !void {
    const an = try x.getAtomName(sev.property);
    defer x.free(an);
    std.log.info("Sending data to window {x}, property '{s}'", .{ sev.requestor, an });

    try sev.requestor.changeProperty(sev.property, utf8, .Replace, u8, "hello, world");

    const ssev = x.Event{ .selection = .{
        .type = .SelectionNotify,
        .requestor = sev.requestor,
        .selection = sev.selection,
        .target = sev.target,
        .property = sev.property,
        .time = sev.time,
    } };

    return ssev.send(sev.requestor, true, x.c.NoEventMask);
}
