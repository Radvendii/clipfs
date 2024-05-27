const std = @import("std");
const x = @import("x11.zig");
const Magic = @import("magic.zig");

const OurAtoms = enum {
    CLIPBOARD,
    UTF8_STRING,
    TARGETS,
};
var OUR_ATOMS: std.EnumArray(OurAtoms, x.Atom) = undefined;

pub fn main() !void {
    var args = std.process.args();
    if (!args.skip()) {
        std.log.err("arg0 missing", .{});
        return error.Args;
    }

    const path_arg = args.next();

    if (args.next()) |_| {
        std.log.err("too many args", .{});
        return error.Args;
    }

    // Read in the new clipboard contents (the file specified as an argument, or stdin)
    const clip: []const u8 = clip: {
        const in: std.fs.File = in: {
            if (path_arg) |path| {
                break :in try std.fs.cwd().openFile(path, .{ .mode = .read_only });
            } else {
                break :in std.io.getStdIn();
            }
        };
        defer in.close();
        // TODO: handle arbitrary lengths
        var buf: [5_000_000]u8 = undefined;
        const bytes = try in.readAll(&buf);
        break :clip buf[0..bytes];
    };

    x.DPY = try x.Display.open(null);
    // XXX: what do we do if close() errors?
    defer x.DPY.close() catch unreachable;

    OUR_ATOMS = try x.internAtoms(OurAtoms, false);

    const screen = x.defaultScreen();

    const root = screen.rootWindow();

    // dummy window to receive messages from the client that wants the clipboard
    // XXX: the tutorial positions the window at -10, -10, but the function takes an unsigned value...
    const owner = try root.createSimpleWindow(1, 1, 1, 1, 0, 0, 0);
    defer owner.destroy() catch unreachable;

    const mime = mime: {
        const magic = Magic.open(.{ .mime_type = true });
        // remember that anything created by magic dies with it
        defer magic.close();
        try magic.load(null);
        // TODO: do i need this sometimes? how do i tell if the loaded file has already been compiled?
        // _ = magic.c.magic_compile(mag, null);
        const mime = try magic.file(path_arg);
        std.log.info("found file with mime type '{s}'", .{mime});

        if (std.mem.eql(u8, mime, "text/plain")) {
            break :mime OUR_ATOMS.get(.UTF8_STRING);
        } else {
            break :mime try x.internAtom(mime, false);
        }
    };

    const sel = OUR_ATOMS.get(.CLIPBOARD);

    try owner.setSelectionOwner(sel);

    std.log.info("Took selection ownership", .{});

    while (true) {
        // selection events can't be masked
        const ev = x.nextEvent();
        switch (ev.type) {
            .SelectionClear => {
                std.log.info("Lost selection ownership", .{});
                return;
            },
            .SelectionRequest => {
                // is this copying it? is that a problem?
                const sev = ev.selection_request;
                std.log.info("Requestor: {x}", .{sev.requestor});
                if (sev.property == x.Atom.None) {
                    try reject(sev);
                } else if (sev.target == OUR_ATOMS.get(.TARGETS)) {
                    try send_targets(sev, mime);
                } else if (sev.target == mime) {
                    try send_data(sev, mime, clip);
                } else {
                    try reject(sev);
                }
            },
            else => {},
        }
    }
}

fn reject(sev: x.Event.SelectionRequest) !void {
    {
        const target_n = try x.getAtomName(sev.target);
        defer x.free(target_n);
        std.log.warn("denying request of type .{s}", .{target_n});
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
    const property_n = try x.getAtomName(sev.property);
    const target_n = try x.getAtomName(sev.target);
    defer x.free(property_n);
    defer x.free(target_n);
    std.log.info("Sending {s} to window {x}, property '{s}'", .{ target_n, sev.requestor, property_n });
}

fn send_targets(sev: x.Event.SelectionRequest, mime: x.Atom) !void {
    _ = mime; // autofix
    try log_send(sev);

    const data = [_]x.Atom{
        OUR_ATOMS.get(.TARGETS),
        OUR_ATOMS.get(.UTF8_STRING),
        // mime,
    };

    try sev.requestor.changeProperty(sev.property, OUR_ATOMS.get(.TARGETS), .Replace, &data);

    try response_sent(sev);
}

fn send_data(sev: x.Event.SelectionRequest, mime: x.Atom, data: anytype) !void {
    try log_send(sev);

    try sev.requestor.changeProperty(sev.property, mime, .Replace, data);

    try response_sent(sev);
}

fn response_sent(sev: x.Event.SelectionRequest) !void {
    const ssev = x.Event{ .selection = .{
        .type = .SelectionNotify,
        .requestor = sev.requestor,
        .selection = sev.selection,
        .target = sev.target,
        .property = sev.property,
        .time = sev.time,
    } };

    try ssev.send(sev.requestor, true, x.Event.Mask{});
}
