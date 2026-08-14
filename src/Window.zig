const std = @import("std");
const c = @import("c");
const g = @import("gobject.zig");
const Tracy = @import("root").Tracy;

const TlrApplication = @import("Application.zig").TlrApplication;
const TlrTable = @import("Table.zig").TlrTable;

pub const TlrWindow = extern struct {
    parent: c.GtkApplicationWindow,

    file: ?*c.GFile,

    pub const Self = @This();
    pub var g_type: c.GType = undefined;

    const Prop = enum(c.guint) { file = 1, N };
    var properties = [_]?*c.GParamSpec{null} ** @intFromEnum(Prop.N);

    inline fn pSpec(comptime p: Prop) *?*c.GParamSpec {
        return &properties[@intFromEnum(p)];
    }

    pub fn register() void {
        g_type = g.type_register_static_simple(
            g.Types.GtkApplicationWindow,
            "TlrWindow",
            Class,
            Class.init,
            Self,
            Self.init,
        );
    }

    pub inline fn as(self: *Self, comptime T: type) *T {
        return g.as(T, self);
    }

    pub inline fn downcast(object: anytype) *Self {
        return g.downcast(object, Self, g_type);
    }

    pub fn new(app: *TlrApplication, file: ?*c.GFile) *Self {
        return @ptrCast(@alignCast(c.g_object_new(
            Self.g_type,
            "application",
            app,
            "file",
            file,
            @as([*c]const c.gchar, null),
        )));
    }

    pub fn present(self: *Self) void {
        const zone = Tracy.zone(@src());
        defer zone.end();

        c.gtk_window_present(self.as(c.GtkWindow));
    }

    pub fn setFile(self: *Self, file: ?*c.GFile) void {
        const zone = Tracy.zone(@src());
        defer zone.end();

        if (!g.set_object(@ptrCast(&self.file), @ptrCast(@alignCast(file)))) return;

        c.g_object_notify_by_pspec(self.as(c.GObject), pSpec(Prop.file).*);
    }

    fn init(self: *Self) void {
        const table = TlrTable.new(null);
        c.gtk_window_set_child(self.as(c.GtkWindow), table.as(c.GtkWidget));

        _ = c.g_object_bind_property(
            self.as(c.GObject),
            "file",
            table.as(c.GObject),
            "file",
            c.G_BINDING_DEFAULT,
        );
    }

    fn dispose(object: ?*c.GObject) callconv(.c) void {
        const self = downcast(object.?);

        g.clear_object(&self.file);

        g.as(c.GObjectClass, Class.parent_class).dispose.?(object);
    }

    fn set_property(object: ?*c.GObject, property_id: c.guint, value: ?*const c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
        _ = pspec;

        const self = downcast(object.?);
        switch (property_id) {
            @intFromEnum(Prop.file) => self.setFile(@ptrCast(@alignCast(c.g_value_get_object(value)))),
            else => unreachable,
        }
    }

    fn get_property(object: ?*c.GObject, property_id: c.guint, value: ?*c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
        _ = pspec;

        const self = downcast(object.?);
        switch (property_id) {
            @intFromEnum(Prop.file) => c.g_value_set_object(value, self.file),
            else => unreachable,
        }
    }

    pub const Class = extern struct {
        parent: Parent,

        const Parent = c.GtkApplicationWindowClass;
        var parent_class: *Parent = undefined;

        fn init(class: *Class) void {
            parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(class)));

            const object_class = g.as(c.GObjectClass, class);
            object_class.dispose = Self.dispose;
            object_class.set_property = Self.set_property;
            object_class.get_property = Self.get_property;

            pSpec(Prop.file).* = c.g_param_spec_object(
                "file",
                "",
                "",
                g.Types.GFile,
                c.G_PARAM_READWRITE | c.G_PARAM_EXPLICIT_NOTIFY | c.G_PARAM_STATIC_STRINGS,
            );

            c.g_object_class_install_properties(object_class, @intFromEnum(Prop.N), &properties);
        }
    };
};
