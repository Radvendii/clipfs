const std = @import("std");
const x = @import("x11.zig");
const Magic = @import("magic.zig").Magic;

const OurAtoms = enum {
    CLIPBOARD,
    UTF8_STRING,
    TARGETS,
    ATOM,
};
var XA: std.EnumArray(OurAtoms, x.Atom) = undefined;

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

    const owner = try init_x_window();
    defer deinit_x_window(owner) catch |e|
        std.debug.panic("X11 failed to close properly: {}", .{e});

    const magic = try init_magic();
    defer magic.close();
    // if magic fails, tell us why
    errdefer _ = magic.logIfError();

    const mime = mime: {
        const mime = try magic.buffer(clip);
        std.log.info("clipboard has mime type '{s}'", .{mime});

        if (std.mem.eql(u8, mime, "text/plain")) {
            break :mime XA.get(.UTF8_STRING);
        } else {
            break :mime try x.internAtom(mime, false);
        }
    };

    const sel = XA.get(.CLIPBOARD);

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
                } else if (sev.target == XA.get(.TARGETS)) {
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

fn init_magic() !*Magic {
    const magic = Magic.open(.{ .mime_type = true });

    try magic.load(null);
    // TODO: do i need this sometimes? how do i tell if the loaded file has already been compiled?
    // _ = magic.c.magic_compile(mag, null);

    return magic;
}

fn init_x_window() !x.Window {
    x.DPY = try x.Display.open(null);
    XA = try x.internAtoms(OurAtoms, false);

    const screen = x.defaultScreen();

    const root = screen.rootWindow();

    // dummy window to receive messages from the client that wants the clipboard
    // XXX: the tutorial positions the window at -10, -10, but the function takes an unsigned value...
    return root.createSimpleWindow(1, 1, 1, 1, 0, 0, 0);
}
fn deinit_x_window(w: x.Window) !void {
    try w.destroy();
    try x.DPY.close();
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
    try log_send(sev);

    const data = [_]x.Atom{
        XA.get(.TARGETS),
        mime,
    };

    try sev.requestor.changeProperty(sev.property, XA.get(.ATOM), .Replace, &data);

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
