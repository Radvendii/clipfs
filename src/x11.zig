const std = @import("std");
pub const c = @import("c.zig");

// The need to pass a display everywhere ruins any attmept I've made at a nice interface.
// Most of the time, there will just be a single display operated on the whole program.
// In the small remainder of cases, you can juggle the state yourself.
// Turns out, OpenGL had the right state structure after all
// And X11 is already not thread-safe.
pub var DPY: Display = undefined;

// x11 has a bunch of error codes e.g. c.BadAlloc, c.BadValue, etc.
// this converts them all from c.Foo to error.Foo for a given set of error values possible
// this could be cleaner with e.g. https://github.com/ziglang/zig/issues/12250
// we could cast it to an enum with all the errors defined, and then in then inline else the conversion
// checkErrors(error{Foo, Bar}, val);
// =>
// switch (val) {
//      c.Foo => error.Foo,
//      c.Bar => error.Bar,
//      else => val
//  }
// I'm still not decided which syntax I like better. checkErrors() is kind of messy and less readable, but also less error prone and repetitive
// I suspect this is a problem I will keep coming back to with comptime
// other design: check against all possible errors, and then process afterwards. possibly panicing if it's an error we should get.
// ideal interface would be if we could define the possible errors in the return type, and then refer to that to do the error checking
fn checkErrors(val: anytype, comptime errorset: type) errorset!@TypeOf(val) {
    switch (@typeInfo(errorset)) {
        .ErrorSet => |_errs| {
            const errs = _errs orelse
                @compileError("got null errorset. not sure yet what that means\n");
            inline for (errs) |err| {
                if (!@hasDecl(c, err.name)) {
                    @compileError("x11 does not define the error code " ++ err.name);
                }
                if (val == @field(c, err.name)) {
                    return @field(anyerror, err.name);
                }
            }
            return val;
        },
        else => @compileError("checkErrors must be called with an errorset\n"),
    }
}

test {
    const err = checkErrors(c.BadAlloc, error{BadAlloc});
    if (@TypeOf(err) != @TypeOf(error.BadAlloc)) {
        return error.NotError;
    }
    if (err != error.BadAlloc) {
        return error.NotBadAlloc;
    }
}

test {
    const err = checkErrors(c.BadValue, error{BadAlloc});
    if (@TypeOf(err) == @TypeOf(error.BadAlloc)) {
        return error.MistakenError;
    }
    if (err != c.BadValue) {
        return error.FailedRoundTrip;
    }
}

pub const Atom = struct {
    raw: c.Atom,
};

pub const Display = struct {
    raw: *c.Display,

    pub fn use(dpy: Display) void {
        DPY = dpy;
    }

    pub fn open(display_name: ?[]const u8) !Display {
        const raw = c.XOpenDisplay(@ptrCast(display_name)) orelse return error.NoDisplay;
        return .{ .raw = raw };
    }
    pub fn close(dpy: Display) !void {
        _ = try checkErrors(
            c.XCloseDisplay(dpy.raw),
            error{BadGC},
        );
    }

    pub fn defaultScreen(dpy: Display) Screen {
        return .{ .raw = c.DefaultScreen(dpy.raw) };
    }
    pub fn internAtom(dpy: Display, atom_name: [:0]const u8, only_if_exists: bool) !Atom {
        const maybe_atom = c.XInternAtom(dpy.raw, atom_name.ptr, @intCast(@intFromBool(only_if_exists)));
        const atom = try checkErrors(
            maybe_atom,
            error{ BadAlloc, BadValue, None },
        );
        return .{ .raw = atom };
    }
    // XXX: dilema: i want nice union(enum) syntax, but then you have to do an expensive conversion from the c.Event
    pub fn nextEvent(dpy: Display) c.XEvent {
        var ev: c.XEvent = undefined;
        _ = c.XNextEvent(dpy.raw, &ev);
        return ev;
    }
};

// XXX: should this just be an enum? less convenient but more true to the C
pub const Screen = struct {
    raw: c_int,

    pub fn rootWindow(screen: Screen) Window {
        return .{ .raw = c.RootWindow(DPY.raw, screen.raw) };
    }
};

pub const Window = struct {
    raw: c.Window,

    pub fn destroy(win: Window) !void {
        _ = try checkErrors(
            c.XDestroyWindow(DPY.raw, win.raw),
            error{BadWindow},
        );
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
        const maybe_win = c.XCreateSimpleWindow(
            DPY.raw,
            parent.raw,
            @bitCast(x),
            @bitCast(y),
            @bitCast(width),
            @bitCast(height),
            @bitCast(border_width),
            @bitCast(border),
            @bitCast(background),
        );
        const win = try checkErrors(
            maybe_win,
            error{ BadAlloc, BadMatch, BadValue, BadWindow },
        );
        return .{ .raw = win };
    }

    pub fn map(win: Window) !void {
        _ = try checkErrors(
            c.XMapWindow(DPY.raw, win.raw),
            error{BadWindow},
        );
    }

    pub fn mapRaised(win: Window) !void {
        _ = try checkErrors(
            c.XMapRaised(DPY.raw, win.raw),
            error{BadWindow},
        );
    }

    pub fn mapSubwindows(win: Window) !void {
        _ = try checkErrors(
            c.XMapSubwindows(DPY.raw, win.raw),
            error{BadWindow},
        );
    }

    pub fn setSelectionOwner(owner: Window, sel: Atom) !void {
        // XXX: is there ever a reason to pass a value besides CurrentTime?
        _ = try checkErrors(
            c.XSetSelectionOwner(DPY.raw, sel.raw, owner.raw, c.CurrentTime),
            error{ BadAtom, BadWindow },
        );
    }
};
