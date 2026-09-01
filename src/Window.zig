const std = @import("std");
const c = @import("c");
const g = @import("gobject.zig");
const Tracy = @import("root").Tracy;
const libadwaita = @import("build_options").libadwaita;

const TlrApplication = @import("Application.zig").TlrApplication;
const TlrTable = @import("Table.zig").TlrTable;

pub const TlrWindow = extern struct {
    parent: g.Structs.XApplicationWindow,

    table: ?*TlrTable,
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
            g.Types.XApplicationWindow,
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
        const table = TlrTable.new();
        self.table = table;

        const sw = c.gtk_scrolled_window_new();
        c.gtk_scrolled_window_set_child(@ptrCast(sw), table.as(c.GtkWidget));
        c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(sw), 1);

        if (libadwaita) {
            const toolbar_view = c.adw_toolbar_view_new();
            c.adw_toolbar_view_set_content(@ptrCast(toolbar_view), sw);
            const header_bar = c.adw_header_bar_new();
            c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar_view), header_bar);
            c.adw_toolbar_view_set_top_bar_style(@ptrCast(toolbar_view), c.ADW_TOOLBAR_RAISED_BORDER);
            c.adw_application_window_set_content(self.as(g.Structs.XApplicationWindow), toolbar_view);
        } else {
            c.gtk_window_set_child(self.as(c.GtkWindow), sw);
        }

        _ = c.g_object_bind_property(
            self.as(c.GObject),
            "file",
            table.as(c.GObject),
            "file",
            c.G_BINDING_DEFAULT,
        );
    }

    fn open(widget: ?*c.GtkWidget, action_name: ?[*]const u8, parameter: ?*c.GVariant) callconv(.c) void {
        _ = action_name;
        _ = parameter;

        const self = downcast(widget.?);

        var dialog = c.gtk_file_dialog_new();
        defer g.clear_object(&dialog);

        c.gtk_file_dialog_set_title(dialog, "Open TAS log");
        if (self.file) |file| {
            c.gtk_file_dialog_set_initial_file(dialog, file);
        }
        c.gtk_file_dialog_open(dialog, self.as(c.GtkWindow), null, open_response_cb, self);
    }

    fn open_response_cb(source: ?*c.GObject, result: ?*c.GAsyncResult, user_data: c.gpointer) callconv(.c) void {
        const dialog: *c.GtkFileDialog = @ptrCast(source.?);
        var err: ?*c.GError = null;
        if (c.gtk_file_dialog_open_finish(dialog, result, &err)) |file| {
            const self: *Self = @ptrCast(@alignCast(user_data));
            self.setFile(file);
            c.g_object_unref(file);
        } else {
            if (c.g_error_matches(err, c.gtk_dialog_error_quark(), c.GTK_DIALOG_ERROR_DISMISSED) == 0) {
                std.log.warn("error opening log: {s}", .{err.?.*.message});
            }
            c.g_error_free(err);
        }
    }

    fn reload(widget: ?*c.GtkWidget, action_name: ?[*]const u8, parameter: ?*c.GVariant) callconv(.c) void {
        _ = action_name;
        _ = parameter;

        const self = downcast(widget.?);
        if (self.table) |table| table.reload();
    }

    fn dispose(object: ?*c.GObject) callconv(.c) void {
        const self = downcast(object.?);

        self.table = null;
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

        const Parent = g.Structs.XApplicationWindowClass;
        var parent_class: *Parent = undefined;

        fn init(class: *Class) void {
            parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(class)));

            const widget_class = g.as(c.GtkWidgetClass, class);
            c.gtk_widget_class_install_action(widget_class, "win.open", null, Self.open);
            c.gtk_widget_class_install_action(widget_class, "win.reload", null, Self.reload);
            c.gtk_widget_class_add_binding_action(widget_class, c.GDK_KEY_o, c.GDK_CONTROL_MASK, "win.open", null);
            c.gtk_widget_class_add_binding_action(widget_class, c.GDK_KEY_F5, c.GDK_NO_MODIFIER_MASK, "win.reload", null);

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
