const std = @import("std");
const x = @import("x11.zig");
const Magic = @import("magic.zig").Magic;
const log = std.log.scoped(.xclipboard);

const OurAtoms = enum {
    CLIPBOARD,
    UTF8_STRING,
    TARGETS,
    ATOM,
};

const Self = @This();

XA: std.EnumArray(OurAtoms, x.Atom),
magic: *Magic,
x_clipboard_owner: x.Window,
clipboard_mx: std.Thread.Mutex = .{},
clipboard: []const u8,
mime: [:0]const u8,
xa_mime: x.Atom,
// TODO: do I actually need the allocator here, or can i just pass it in to copy()
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Self {
    x.DPY = try x.Display.open(null);
    errdefer x.DPY.close() catch |e| std.debug.panic("X11 failed to close properly: {}", .{e});

    const XA = try x.internAtoms(OurAtoms, false);

    const screen = x.defaultScreen();
    const root = screen.rootWindow();

    // dummy window to receive messages from the client that wants the clipboard
    // XXX: the tutorial positions the window at -10, -10, but the function takes an unsigned value...

    const x_clipboard_owner = try root.createSimpleWindow(1, 1, 1, 1, 0, 0, 0);
    errdefer x_clipboard_owner.destroy() catch |e| std.debug.panic("X11 window failed to close properly: {}", .{e});

    const magic = Magic.open(.{ .mime_type = true });
    errdefer magic.close();
    errdefer magic.logIfError();

    try magic.load(null);
    // TODO: do i need this sometimes? how do i tell if the loaded file has already been compiled?
    // _ = magic.c.magic_compile(mag, null);

    return Self{
        .XA = XA,
        .magic = magic,
        .x_clipboard_owner = x_clipboard_owner,
        .clipboard = &.{},
        .mime = undefined,
        .xa_mime = x.Atom.None,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    defer x.DPY.close() catch |e| std.debug.panic("X11 failed to close properly: {}", .{e});
    defer self.x_clipboard_owner.destroy() catch |e| std.debug.panic("X11 window failed to close properly: {}", .{e});
    defer self.magic.close();
}

// TODO: I don't like this name
pub fn errdeinit(self: *Self) void {
    defer self.magic.logIfError();
}

pub fn eventLoop(self: *Self) !noreturn {
    while (true) try self.processEvent();
}

pub fn processEvent(self: *Self) !void {
    log.info("processing event", .{});
    // selection events can't be masked
    const ev = x.nextEvent();
    switch (ev.type) {
        .SelectionClear => {
            // TODO: this is triggering at startup for seemingly no reason
            log.info("Lost selection ownership", .{});
            // TODO: free clipboard memory?
        },
        .SelectionRequest => {
            // is this copying it? is that a problem?
            const sev = ev.selection_request;
            log.info("Requestor: {x}", .{sev.requestor});
            if (sev.property == x.Atom.None) {
                try reject(sev);
            } else if (sev.target == self.XA.get(.TARGETS)) {
                try self.send_targets(sev);
            } else if (sev.target == self.xa_mime) {
                try self.send_data(sev);
            } else {
                try reject(sev);
            }
        },
        else => {},
    }
}

pub fn copy(self: *Self, data: []const u8) !void {
    {
        self.clipboard_mx.lock();
        defer self.clipboard_mx.unlock();

        // XXX: leaking old clipboard
        self.clipboard = try self.allocator.dupe(u8, data);

        // TODO: only calculate the mime type when it's needed (you can compare generational references)
        self.mime = try self.magic.buffer(data);
        log.info("new clipboard has mime type '{s}'", .{self.mime});
        self.xa_mime = if (std.mem.eql(u8, self.mime, "text/plain"))
            self.XA.get(.UTF8_STRING)
        else
            try x.internAtom(self.mime, false);
    }

    try self.x_clipboard_owner.setSelectionOwner(self.XA.get(.CLIPBOARD));

    log.info("took ownership", .{});
}

fn reject(sev: x.Event.SelectionRequest) !void {
    {
        const target_n = try x.getAtomName(sev.target);
        defer x.free(target_n);
        log.warn("denying request of type .{s}", .{target_n});
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
    log.info("Sending {s} to window {x}, property '{s}'", .{ target_n, sev.requestor, property_n });
}

fn send_targets(self: *Self, sev: x.Event.SelectionRequest) !void {
    try log_send(sev);

    const data = [_]x.Atom{
        self.XA.get(.TARGETS),
        self.xa_mime,
    };

    try sev.requestor.changeProperty(sev.property, self.XA.get(.ATOM), .Replace, &data);

    try response_sent(sev);
}

fn send_data(self: *Self, sev: x.Event.SelectionRequest) !void {
    try log_send(sev);

    {
        self.clipboard_mx.lock();
        defer self.clipboard_mx.unlock();
        try sev.requestor.changeProperty(sev.property, self.xa_mime, .Replace, self.clipboard);
    }

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
