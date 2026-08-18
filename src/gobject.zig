const std = @import("std");
const c = @import("c");
const checks = @import("root").checks;

pub const Types = struct {
    pub var GFile: c.GType = undefined;
    pub var GtkApplication: c.GType = undefined;
    pub var GtkApplicationWindow: c.GType = undefined;
    pub var GtkWidget: c.GType = undefined;
    pub var GtkScrollable: c.GType = undefined;

    pub fn fetch() void {
        GFile = c.g_file_get_type();
        GtkApplication = c.gtk_application_get_type();
        GtkApplicationWindow = c.gtk_application_window_get_type();
        GtkWidget = c.gtk_widget_get_type();
        GtkScrollable = c.gtk_scrollable_get_type();
    }
};

pub inline fn isA(comptime derived: type, comptime parent: type) ?bool {
    if (derived == parent) return true;

    const info = switch (@typeInfo(derived)) {
        .@"struct" => |info| info,
        .@"opaque" => return null, // We can't tell.
        else => return false,
    };
    if (info.layout != .@"extern") return false;
    if (info.fields.len == 0) return false;

    const first = info.fields[0].type;
    return isA(first, parent);
}

pub inline fn as(comptime T: type, ptr: anytype) *T {
    comptime {
        const pointee = @typeInfo(@TypeOf(ptr)).pointer.child;
        if (isA(pointee, T) != true) {
            @compileError("ptr must be derived from " ++ @typeName(T) ++ ", got " ++ @typeName(pointee));
        }
    }

    return @ptrCast(ptr);
}

pub inline fn downcast(ptr: anytype, comptime T: type, g_type: c.GType) *T {
    if (!checks) return @ptrCast(@alignCast(ptr));

    const object = as(c.GObject, ptr);
    return @ptrCast(@alignCast(c.g_type_check_instance_cast(&object.g_type_instance, g_type)));
}

pub inline fn connect(
    instance: *anyopaque,
    signal: [*:0]const u8,
    comptime handler: anytype,
    data: c.gpointer,
) c.gulong {
    return connect_with_flags(instance, signal, handler, data, c.G_CONNECT_DEFAULT);
}

pub inline fn connect_swapped(
    instance: *anyopaque,
    signal: [*:0]const u8,
    comptime handler: anytype,
    data: c.gpointer,
) c.gulong {
    return connect_with_flags(instance, signal, handler, data, c.G_CONNECT_SWAPPED);
}

pub fn connect_with_flags(
    instance: *anyopaque,
    signal: [*:0]const u8,
    comptime handler: anytype,
    data: c.gpointer,
    flags: c.GConnectFlags,
) c.gulong {
    const conv = @typeInfo(@TypeOf(handler)).@"fn".calling_convention;
    comptime if (!std.builtin.CallingConvention.eql(conv, .c)) {
        @compileError("handler must have c calling convention, got: " ++ @tagName(conv));
    };

    return c.g_signal_connect_data(
        instance,
        signal,
        @ptrCast(&handler),
        data,
        null,
        flags,
    );
}

pub fn disconnect_by_func(instance: *anyopaque, comptime handler: anytype, data: c.gpointer) c.guint {
    return c.g_signal_handlers_disconnect_matched(
        instance,
        c.G_SIGNAL_MATCH_FUNC | c.G_SIGNAL_MATCH_DATA,
        0,
        0,
        null,
        @ptrCast(@constCast(&handler)),
        data,
    );
}

pub inline fn clear_object(object: anytype) void {
    comptime {
        const firstChild = @typeInfo(@TypeOf(object)).pointer.child;
        const secondPointer = @typeInfo(firstChild).optional.child;
        const objectType = @typeInfo(secondPointer).pointer.child;
        if (isA(objectType, c.GObject) == false) {
            @compileError("object must be *?*c.GObject, got: " ++ @typeName(@TypeOf(object)));
        }
    }

    if (object.*) |obj| {
        const o = obj;
        object.* = null;
        c.g_object_unref(o);
    }
}

pub inline fn set_object(object: *?*c.GObject, new_object: ?*c.GObject) bool {
    // Same order of operations as g_set_object().
    const old = object.*;
    if (old == new_object) return false;

    if (new_object) |obj| _ = c.g_object_ref(obj);
    object.* = new_object;
    if (old) |obj| c.g_object_unref(obj);

    return true;
}

pub fn type_register_static_simple(
    parent: c.GType,
    name: [*:0]const u8,
    Class: type,
    class_init_fn: fn (class: *Class) void,
    Instance: type,
    instance_init_fn: fn (instance: *Instance) void,
) c.GType {
    const Thunks = struct {
        fn class_init(class: c.gpointer, class_data: c.gpointer) callconv(.c) void {
            _ = &class_data;

            const cl: *Class = @ptrCast(@alignCast(class));
            class_init_fn(cl);
        }

        fn instance_init(instance: ?*c.GTypeInstance, g_class: c.gpointer) callconv(.c) void {
            _ = &g_class;

            const self: *Instance = @ptrCast(instance);
            instance_init_fn(self);
        }
    };

    return c.g_type_register_static_simple(
        parent,
        name,
        @sizeOf(Class),
        &Thunks.class_init,
        @sizeOf(Instance),
        &Thunks.instance_init,
        c.G_TYPE_FLAG_NONE,
    );
}
