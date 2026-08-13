const std = @import("std");
const c = @import("c");
const g = @import("gobject.zig");
const Tracy = @import("root").Tracy;

const TlrApplication = @import("Application.zig").TlrApplication;

pub const TlrWindow = extern struct {
    parent: c.GtkApplicationWindow,

    file: ?*c.GFile,

    pub const Self = @This();
    pub var gType: c.GType = undefined;

    const Prop = enum(c.guint) { file = 1, N };
    var properties = [_]?*c.GParamSpec{null} ** @intFromEnum(Prop.N);

    pub fn register() void {
        gType = g.type_register_static_simple(
            g.Types.GtkApplicationWindow,
            "TlrWindow",
            Class,
            Class.init,
            Self,
            Self.init,
        );
    }

    pub fn new(app: *TlrApplication, file: ?*c.GFile) *Self {
        return @ptrCast(@alignCast(c.g_object_new(
            Self.gType,
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

        c.gtk_window_present(@ptrCast(self));
    }

    pub fn setFile(self: *Self, file: ?*c.GFile) void {
        const zone = Tracy.zone(@src());
        defer zone.end();

        if (c.g_set_object(@ptrCast(&self.file), @ptrCast(@alignCast(file))) == 0)
            return;

        const path = @as(?[*:0]u8, c.g_file_get_path(self.file)) orelse return;
        defer c.g_free(path);

        const label = c.gtk_window_get_child(@ptrCast(self));
        c.gtk_label_set_label(@ptrCast(label), path);
    }

    fn init(self: *Self) void {
        const label = c.gtk_label_new("No file");
        c.gtk_window_set_child(@ptrCast(self), label);
    }

    fn dispose(object: ?*c.GObject) callconv(.c) void {
        const self: *Self = @ptrCast(object.?);

        g.clear_object(@ptrCast(&self.file));

        const object_class: *c.GObjectClass = @ptrCast(Class.parent_class);
        object_class.dispose.?(object);
    }

    fn set_property(object: ?*c.GObject, property_id: c.guint, value: ?*const c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
        _ = pspec;

        const self: *Self = @ptrCast(object.?);
        switch (property_id) {
            @intFromEnum(Prop.file) => self.setFile(@ptrCast(@alignCast(c.g_value_get_object(value)))),
            else => unreachable,
        }
    }

    fn get_property(object: ?*c.GObject, property_id: c.guint, value: ?*c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
        _ = pspec;

        const self: *Self = @ptrCast(object.?);
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

            const object_class: *c.GObjectClass = @ptrCast(class);
            object_class.dispose = Self.dispose;
            object_class.set_property = Self.set_property;
            object_class.get_property = Self.get_property;

            properties[@intFromEnum(Prop.file)] = c.g_param_spec_object(
                "file",
                "",
                "",
                g.Types.GFile,
                c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS,
            );

            c.g_object_class_install_properties(object_class, @intFromEnum(Prop.N), &properties);
        }
    };
};
