const std = @import("std");
const x = @import("x11.zig");

const OurAtoms = enum {
    CLIPBOARD,
    UTF8_STRING,
    TARGETS,
};
var OUR_ATOMS: std.EnumArray(OurAtoms, x.Atom) = undefined;

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

    OUR_ATOMS = try x.internAtoms(OurAtoms, false);

    const sel = OUR_ATOMS.get(.CLIPBOARD);

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
                if (sev.property == x.Atom.None) {
                    try reject(sev);
                } else {
                    if (sev.target == OUR_ATOMS.get(.UTF8_STRING)) {
                        try send_utf8(sev);
                    } else if (sev.target == OUR_ATOMS.get(.TARGETS)) {
                        try send_targets(sev);
                    } else {
                        try reject(sev);
                    }
                    // can't switch on runtime values
                    // switch (sev.target) {
                    //     OUR_ATOMS.get(.UTF8_STRING) => try send_utf8(sev),
                    //     OUR_ATOMS.get(.TARGETS) => try send_targets(sev),
                    //     else => try reject(sev),
                    // }
                }
            },
            else => {},
        }
    }
}

fn reject(sev: x.Event.SelectionRequest) !void {
    {
        const an = try x.getAtomName(sev.target);
        defer x.free(an);
        std.log.warn("denying request of type .{s}", .{an});
    }
    const ssev = x.Event{ .selection = .{
        .type = .SelectionNotify,
        .requestor = sev.requestor,
        .selection = sev.selection,
        .target = sev.target,
        .property = x.Atom.None,
        .time = sev.time,
    } };

    return ssev.send(sev.requestor, true, x.Event.Mask{});
}

fn log_send(sev: x.Event.SelectionRequest) !void {
    const an = try x.getAtomName(sev.property);
    defer x.free(an);
    std.log.info("Sending utf8 to window {x}, property '{s}'", .{ sev.requestor, an });
}

fn send_targets(sev: x.Event.SelectionRequest) !void {
    try log_send(sev);

    const data = [_]x.Atom{
        OUR_ATOMS.get(.TARGETS),
        OUR_ATOMS.get(.UTF8_STRING),
    };

    try sev.requestor.changeProperty(sev.property, OUR_ATOMS.get(.TARGETS), .Replace, &data);
}

fn send_utf8(sev: x.Event.SelectionRequest) !void {
    try log_send(sev);

    try sev.requestor.changeProperty(sev.property, OUR_ATOMS.get(.UTF8_STRING), .Replace, "hello, world");

    const ssev = x.Event{ .selection = .{
        .type = .SelectionNotify,
        .requestor = sev.requestor,
        .selection = sev.selection,
        .target = sev.target,
        .property = sev.property,
        .time = sev.time,
    } };

    return ssev.send(sev.requestor, true, x.Event.Mask{});
}
