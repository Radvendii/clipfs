// TODO: use translate-c and modify the generated x11 bindings

const std = @import("std");
pub const c = @import("c.zig");

const Outer = @This();

// The need to pass a display everywhere ruins any attmept I've made at a nice interface.
// Most of the time, there will just be a single display operated on the whole program.
// In the small remainder of cases, you can juggle the state yourself.
// Turns out, OpenGL had the right state structure after all
// And X11 is already not thread-safe.
pub var DPY: *Display = undefined;

fn IntFromAny(T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

// zig seems pathological about not letting me just @bitCast() from an arbitrary type to int, so we have to use this convoluted mess
fn asInt_helper(In: type, Out: type, t: anytype) Out {
    return switch (@typeInfo(In)) {
        .Type,
        .Void,
        .ComptimeFloat,
        .ComptimeInt,
        .Undefined,
        .Null,
        .ErrorUnion,
        .ErrorSet,
        .NoReturn,
        .Fn,
        .Opaque,
        .Frame,
        .AnyFrame,
        .Vector,
        .EnumLiteral,
        => unreachable,
        .Bool => @intFromBool(t),
        .Int => @intCast(t),
        .Float,
        .Union,
        .Struct,
        => @bitCast(t),
        .Pointer,
        .Array,
        => @intFromPtr(t),
        .Enum => @intFromEnum(t),
        .Optional => |opt| asInt_helper(opt.child, Out, t),
    };
}

// XXX: does this exist in std?
fn asInt(t: anytype) IntFromAny(@TypeOf(t)) {
    return asInt_helper(@TypeOf(t), IntFromAny(@TypeOf(t)), t);
}

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
        else => @compileError("checkErrors must be called with an errorset\n"),
        .ErrorSet => |_errs| {
            const errs = _errs orelse
                @compileError("got null errorset. not sure yet what that means\n");
            inline for (errs) |err| {
                if (!@hasDecl(c, err.name)) {
                    @compileError("x11 does not define the error code " ++ err.name);
                }
                if (asInt(val) == @field(c, err.name)) {
                    return @field(anyerror, err.name);
                }
            }
            return val;
        },
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

pub const Atom = enum(c.Atom) {
    None = c.None,
    _,
};

// XXX: it is annoying to have to duplicate these
pub fn defaultScreen() ScreenNum {
    return DPY.defaultScreen();
}
pub fn internAtom(atom_name: [:0]const u8, only_if_exists: bool) !Atom {
    return DPY.internAtom(atom_name, only_if_exists);
}
pub fn internAtoms(names: []const [*:0]const u8, only_if_exists: bool, atoms_return: []Atom) !void {
    return DPY.internAtoms(names, only_if_exists, atoms_return);
}
pub fn nextEvent() Event {
    return DPY.nextEvent();
}
pub fn maskEvent(event_mask: Event.Mask) Event {
    return DPY.maskEvent(event_mask);
}
pub fn getAtomName(a: Atom) ![*:0]u8 {
    return DPY.getAtomName(a);
}

pub fn free(x: anytype) void {
    if (@typeInfo(@TypeOf(x)) != .Pointer) {
        @compileError("Cannot XFree() a non-pointer object");
    }
    _ = c.XFree(@ptrCast(x));
}

pub const Display = opaque {
    inline fn raw(dpy: *Display) *c.Display {
        return @ptrCast(dpy);
    }

    pub fn use(dpy: *Display) void {
        DPY = dpy;
    }

    pub fn open(display_name: ?[]const u8) !*Display {
        const dpy = c.XOpenDisplay(@ptrCast(display_name)) orelse return error.NoDisplay;
        return @ptrCast(dpy);
    }
    pub fn close(dpy: *Display) !void {
        _ = try checkErrors(
            c.XCloseDisplay(dpy.raw()),
            error{BadGC},
        );
    }

    pub fn defaultScreen(dpy: *Display) ScreenNum {
        return @enumFromInt(c.DefaultScreen(dpy.raw()));
    }

    pub fn internAtom(dpy: *Display, atom_name: [:0]const u8, only_if_exists: bool) !Atom {
        const atom = try checkErrors(
            c.XInternAtom(dpy.raw(), atom_name.ptr, @intFromBool(only_if_exists)),
            error{ BadAlloc, BadValue },
        );
        return @enumFromInt(atom);
    }

    // XXX: i don't love taking in c-strings here.
    // but to convert them, we either need an allocator or a comptime-known length as another argument.
    pub fn internAtoms(dpy: *Display, names: []const [*:0]const u8, only_if_exists: bool, atoms_return: []Atom) !void {
        std.debug.assert(names.len == atoms_return.len);
        _ = try checkErrors(
            c.XInternAtoms(dpy.raw(), @constCast(@ptrCast(names.ptr)), @intCast(names.len), @intFromBool(only_if_exists), @ptrCast(atoms_return)),
            error{ BadAlloc, BadValue },
        );
    }

    pub fn nextEvent(dpy: *Display) Event {
        var ev: Event = undefined;
        _ = c.XNextEvent(dpy.raw(), @ptrCast(&ev));
        return ev;
    }

    // TODO: look at output assembly and see if RLS is applying to ev
    pub fn maskEvent(dpy: *Display, event_mask: Event.Mask) Event {
        var ev: Event = undefined;
        _ = c.XMaskEvent(dpy.raw(), @bitCast(event_mask), @ptrCast(&ev));
        return ev;
    }

    // returned string must be freed
    pub fn getAtomName(dpy: *Display, a: Atom) ![*:0]u8 {
        return checkErrors(
            @as([*:0]u8, @ptrCast(c.XGetAtomName(dpy.raw(), @intFromEnum(a)))),
            error{BadAtom},
        );
    }
};

// XXX: this is different from c.Screen
pub const ScreenNum = enum(c_int) {
    _,

    pub fn rootWindow(screen: ScreenNum) Window {
        return @enumFromInt(c.RootWindow(DPY.raw(), @intFromEnum(screen)));
    }
};

pub const Window = enum(c.Window) {
    _,

    pub fn destroy(win: Window) !void {
        _ = try checkErrors(
            c.XDestroyWindow(DPY.raw(), @intFromEnum(win)),
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
            DPY.raw(),
            @intFromEnum(parent),
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
        return @enumFromInt(win);
    }

    pub fn map(win: Window) !void {
        _ = try checkErrors(
            c.XMapWindow(DPY.raw(), win.raw),
            error{BadWindow},
        );
    }

    pub fn mapRaised(win: Window) !void {
        _ = try checkErrors(
            c.XMapRaised(DPY.raw(), win.raw),
            error{BadWindow},
        );
    }

    pub fn mapSubwindows(win: Window) !void {
        _ = try checkErrors(
            c.XMapSubwindows(DPY.raw(), win.raw),
            error{BadWindow},
        );
    }

    pub fn setSelectionOwner(owner: Window, sel: Atom) !void {
        // XXX: is there ever a reason to pass a value besides CurrentTime?
        _ = try checkErrors(
            c.XSetSelectionOwner(DPY.raw(), @intFromEnum(sel), @intFromEnum(owner), c.CurrentTime),
            error{ BadAtom, BadWindow },
        );
    }

    pub fn changeProperty(
        win: Window,
        property: Atom,
        typ: Atom,
        mode: PropMode,
        data: anytype,
    ) !void {
        const format: c_int = format: {
            // really we want
            // switch (@TypeOf(data)) {
            //     []const u8 => 8,
            //     []const u16 => 16,
            //     []const u32 => 32,
            // }
            // but we have to account for various types that implicitly coerce, such as *const [N]u8 or [:0]const u16
            // SEE: https://ziglang.org/documentation/master/#toc-Type-Coercion-Slices-Arrays-and-Pointers
            // There should be some builtin to test if one type coerces to another, but alas.
            const errText = @typeName(@TypeOf(data)) ++ " does not coerce to `[]const` of `u8`, `u16`, or `u32`.";
            const child = child: {
                switch (@typeInfo(@TypeOf(data))) {
                    else => @compileError(errText),
                    .Pointer => |ptr| {
                        switch (ptr.size) {
                            // looking for `*const [N]child`
                            .One => {
                                if (!ptr.is_const or ptr.is_allowzero or ptr.is_volatile) @compileError(errText);
                                switch (@typeInfo(ptr.child)) {
                                    .Array => |arr| break :child arr.child,
                                    else => @compileError(errText),
                                }
                            },
                            // looking for `[]const child` or `[*c]child`
                            .Slice, .C => {
                                if (!ptr.is_const or ptr.is_allowzero or ptr.is_volatile) @compileError(errText);
                                break :child ptr.child;
                            },
                            // We must know how long the array is
                            .Many => @compileError(errText),
                        }
                    },
                }
            };

            // make sure this does actually coerce like we thought it would
            // TODO: we could remove some of the checks above and rely on this instead
            _ = @as([]const child, data);

            switch (child) {
                u8 => break :format 8,
                u16 => break :format 16,
                u32 => break :format 32,
                else => @compileError(errText),
            }
        };

        _ = try checkErrors(
            c.XChangeProperty(
                DPY.raw(),
                @intFromEnum(win),
                @intFromEnum(property),
                @intFromEnum(typ),
                format,
                @intFromEnum(mode),
                @ptrCast(data.ptr),
                @intCast(data.len),
            ),
            error{
                BadAlloc,
                BadAtom,
                BadMatch,
                // unclear from the docs whether this can happen
                BadPixmap,
                BadValue,
                BadWindow,
            },
        );
    }
};

// XXX: does this go inside Event?
pub const PropMode = enum(c_int) {
    Replace = c.PropModeReplace,
    Prepend = c.PropModePrepend,
    Append = c.PropModeAppend,
};

pub const Event = extern union {
    pub const Tag = enum(c_int) {
        KeyPress = c.KeyPress,
        KeyRelease = c.KeyRelease,
        ButtonPress = c.ButtonPress,
        ButtonRelease = c.ButtonRelease,
        MotionNotify = c.MotionNotify,
        EnterNotify = c.EnterNotify,
        LeaveNotify = c.LeaveNotify,
        FocusIn = c.FocusIn,
        FocusOut = c.FocusOut,
        KeymapNotify = c.KeymapNotify,
        Expose = c.Expose,
        GraphicsExpose = c.GraphicsExpose,
        NoExpose = c.NoExpose,
        CirculateRequest = c.CirculateRequest,
        ConfigureRequest = c.ConfigureRequest,
        MapRequest = c.MapRequest,
        ResizeRequest = c.ResizeRequest,
        CirculateNotify = c.CirculateNotify,
        ConfigureNotify = c.ConfigureNotify,
        CreateNotify = c.CreateNotify,
        DestroyNotify = c.DestroyNotify,
        GravityNotify = c.GravityNotify,
        MapNotify = c.MapNotify,
        MappingNotify = c.MappingNotify,
        ReparentNotify = c.ReparentNotify,
        UnmapNotify = c.UnmapNotify,
        VisibilityNotify = c.VisibilityNotify,
        ColormapNotify = c.ColormapNotify,
        ClientMessage = c.ClientMessage,
        PropertyNotify = c.PropertyNotify,
        SelectionClear = c.SelectionClear,
        SelectionNotify = c.SelectionNotify,
        SelectionRequest = c.SelectionRequest,
    };

    type: Tag,
    any: Any,
    key: Key,
    button: Button,
    motion: Motion,
    crossing: Crossing,
    focus: FocusChange,
    expose: Expose,
    graphics_expose: GraphicsExpose,
    no_expose: NoExpose,
    visibility: Visibility,
    create_window: CreateWindow,
    destroy_window: DestroyWindow,
    unmap: Unmap,
    map: Map,
    map_request: MapRequest,
    reparent: Reparent,
    configure: Configure,
    gravity: Gravity,
    resize_request: ResizeRequest,
    configure_request: ConfigureRequest,
    circulate: Circulate,
    circulate_request: CirculateRequest,
    property: Property,
    selection_clear: SelectionClear,
    selection_request: SelectionRequest,
    selection: Selection,
    colormap: Event.Colormap,
    client: ClientMessage,
    mapping: Mapping,
    // error is a reserved keyword
    @"error": Error,
    keymap: Keymap,
    generic: Generic,
    cookie: GenericEventC,

    _pad: [24]c_long,

    pub fn send(event: *const Event, dest: Window, propagate: bool, event_mask: Mask) !void {
        // @ptrCast() is legal because we've made them have the same bit layout
        // @constCast() is legal because XSendEvent does not modify the event passed in
        const c_event = @as(*c.XEvent, @constCast(@ptrCast(event)));
        const ret = try checkErrors(
            c.XSendEvent(DPY.raw(), @intFromEnum(dest), @intFromBool(propagate), @bitCast(event_mask), c_event),
            error{ BadValue, BadWindow },
        );
        if (ret == 0) return error.WireProtocolConversionFailed;
    }
    // TODO: consider renaming this. "mask" mostly makes sense in the C context
    // on the other hand, it is the name people would look under
    pub const Mask = packed struct(c_long) {
        key_press: bool = false,
        key_release: bool = false,
        button_press: bool = false,
        button_release: bool = false,
        enter_window: bool = false,
        leave_window: bool = false,
        pointer_motion: bool = false,
        pointer_motion_hint: bool = false,
        button1_motion: bool = false,
        button2_motion: bool = false,
        button3_motion: bool = false,
        button4_motion: bool = false,
        button5_motion: bool = false,
        button_motion: bool = false,
        keymap_state: bool = false,
        exposure: bool = false,
        visibility_change: bool = false,
        structure_notify: bool = false,
        resize_redirect: bool = false,
        substructure_notify: bool = false,
        substructure_redirect: bool = false,
        focus_change: bool = false,
        property_change: bool = false,
        colormap_change: bool = false,
        owner_grab_button: bool = false,

        // XXX: magic number 25 is the number of fields before this
        _padding: std.meta.Int(.unsigned, @bitSizeOf(c_long) - 25) = 0,
    };

    // TODO: could I make `type` have appropriate defaults in the different sub-structs?
    // problem: e.g. KeyEvent could be KeyPressed or KeyReleased
    pub const Key = extern struct {
        type: Tag,
        // TODO: is this something we can give a more meaningful type to?
        // undefined because these get ignored by XSendEvent, so we don't need to bother setting them
        // but we want error checking on not setting them and then accessing (at least in debug mode)
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        root: Window,
        subwindow: Window,
        time: Time,
        x: c_int,
        y: c_int,
        x_root: c_int,
        y_root: c_int,
        state: ModifierState,
        // TODO: put a function to convert to keysym as a method
        keycode: c_uint,
        same_screen: c_bool,
    };
    pub const KeyPressed = Key;
    pub const KeyReleased = Key;
    pub const Button = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        root: Window,
        subwindow: Window,
        time: Time,
        x: c_int,
        y: c_int,
        x_root: c_int,
        y_root: c_int,
        state: ModifierState,
        button: c_uint,
        same_screen: c_bool,
    };
    pub const ButtonPressed = Button;
    pub const ButtonReleased = Button;
    pub const Motion = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        root: Window,
        subwindow: Window,
        time: Time,
        x: c_int,
        y: c_int,
        x_root: c_int,
        y_root: c_int,
        state: ModifierState,
        is_hint: IsHint,
        same_screen: c_int,
    };
    pub const PointerMoved = Motion;

    // TODO: beyond this point conversions unfinished
    pub const Crossing = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        root: Window,
        subwindow: Window,
        time: Time,
        x: c_int,
        y: c_int,
        x_root: c_int,
        y_root: c_int,
        mode: c_int,
        detail: c_int,
        same_screen: c_int,
        focus: c_int,
        state: c_uint,
    };
    pub const EnterWindow = Crossing;
    pub const LeaveWindow = Crossing;
    pub const FocusChange = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        mode: c_int,
        detail: c_int,
    };
    pub const FocusIn = FocusChange;
    pub const FocusOut = FocusChange;
    pub const Keymap = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        key_vector: [32]u8,
    };
    pub const Expose = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        count: c_int,
    };
    pub const GraphicsExpose = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        drawable: Drawable,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        count: c_int,
        major_code: c_int,
        minor_code: c_int,
    };
    pub const NoExpose = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        drawable: Drawable,
        major_code: c_int,
        minor_code: c_int,
    };
    pub const Visibility = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        state: c_int,
    };
    pub const CreateWindow = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        parent: Window,
        window: Window,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        border_width: c_int,
        override_redirect: c_int,
    };
    pub const DestroyWindow = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        event: Window,
        window: Window,
    };
    pub const Unmap = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        event: Window,
        window: Window,
        from_configure: c_int,
    };
    pub const Map = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        event: Window,
        window: Window,
        override_redirect: c_int,
    };
    pub const MapRequest = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        parent: Window,
        window: Window,
    };
    pub const Reparent = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        event: Window,
        window: Window,
        parent: Window,
        x: c_int,
        y: c_int,
        override_redirect: c_int,
    };
    pub const Configure = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        event: Window,
        window: Window,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        border_width: c_int,
        above: Window,
        override_redirect: c_int,
    };
    pub const Gravity = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        event: Window,
        window: Window,
        x: c_int,
        y: c_int,
    };
    pub const ResizeRequest = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        width: c_int,
        height: c_int,
    };
    pub const ConfigureRequest = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        parent: Window,
        window: Window,
        x: c_int,
        y: c_int,
        width: c_int,
        height: c_int,
        border_width: c_int,
        above: Window,
        detail: c_int,
        value_mask: c_ulong,
    };
    pub const Circulate = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        event: Window,
        window: Window,
        place: c_int,
    };
    pub const CirculateRequest = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        parent: Window,
        window: Window,
        place: c_int,
    };
    pub const Property = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        atom: Atom,
        time: Time,
        state: c_int,
    };
    pub const SelectionClear = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        selection: Atom,
        time: Time,
    };
    pub const SelectionRequest = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        owner: Window,
        requestor: Window,
        selection: Atom,
        target: Atom,
        property: Atom,
        time: Time,
    };
    pub const Selection = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        requestor: Window,
        selection: Atom,
        target: Atom,
        property: Atom,
        time: Time,
    };
    pub const Colormap = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        colormap: Outer.Colormap,
        new: c_int,
        state: c_int,
    };
    pub const ClientMessage = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        message_type: Atom,
        format: c_int,
        data: extern union {
            b: [20]u8,
            s: [10]c_short,
            l: [5]c_long,
        },
    };
    pub const Mapping = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
        request: c_int,
        first_keycode: c_int,
        count: c_int,
    };
    pub const Error = extern struct {
        type: Tag,
        display: *Display = undefined,
        resourceid: ID,
        serial: c_ulong = undefined,
        error_code: u8,
        request_code: u8,
        minor_code: u8,
    };
    pub const Any = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        window: Window,
    };
    pub const Generic = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        extension: c_int,
        evtype: Tag,
    };
    pub const GenericEventC = extern struct {
        type: Tag,
        serial: c_ulong = undefined,
        send_event: c_bool = undefined,
        display: *Display = undefined,
        extension: c_int,
        evtype: Tag,
        cookie: c_uint,
        data: ?*anyopaque,
    };
};
// TODO: move these into Event namespace?
// TODO: what should we do with bools? is being extern enough to force them to be `c_int`s?

// This doesn't actually help much, since we can't add more decls
// pub fn Wrapper(T: type) type {
//     return enum(T) {
//         const Self = @This();
//         _,
//         pub inline fn unwrap(self: Self) T {
//             return @intFromEnum(self);
//         }
//         pub inline fn wrap(t: T) Self {
//             return @enumFromInt(t);
//         }
//     };
// }
pub const c_bool = c_int;
// time in miliseconds
pub const Time = enum(c_ulong) { _ };
pub const ModifierState = packed struct(c_uint) {
    shift: bool = false,
    lock: bool = false,
    control: bool = false,
    mod1: bool = false,
    mod2: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,
    button1: bool = false,
    button2: bool = false,
    button3: bool = false,
    button4: bool = false,
    button5: bool = false,

    // XXX: magic number 13 is the number of fields before this
    _padding: std.meta.Int(.unsigned, @bitSizeOf(c_int) - 13) = 0,
};
// TODO: exhaustive search?
test {
    const ours = ModifierState{
        .shift = true,
        .lock = true,
        .control = true,
        .mod1 = true,
        .mod2 = true,
        .mod3 = true,
        .mod4 = true,
        .mod5 = true,
        .button1 = true,
        .button2 = true,
        .button3 = true,
        .button4 = true,
        .button5 = true,
    };
    const theirs =
        c.ShiftMask |
        c.LockMask |
        c.ControlMask |
        c.Mod1Mask |
        c.Mod2Mask |
        c.Mod3Mask |
        c.Mod4Mask |
        c.Mod5Mask |
        c.Button1Mask |
        c.Button2Mask |
        c.Button3Mask |
        c.Button4Mask |
        c.Button5Mask;

    std.testing.expectEqual(@as(ModifierState, @bitCast(theirs)), ours);
}

pub const IsHint = enum(u8) {
    NotifyNormal = c.NotifyNormal,
    NotifyHint = c.NotifyHint,
};

pub const Drawable = enum(c.Drawable) { _ };
pub const Colormap = enum(c.Colormap) { _ };
pub const ID = enum(c.XID) { _ };
