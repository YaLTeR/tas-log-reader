const std = @import("std");
const c = @import("c");
const g = @import("gobject.zig");
const Tracy = @import("root").Tracy;

const TlrTable = @import("Table.zig").TlrTable;
const TlrWindow = @import("Window.zig").TlrWindow;

pub const TlrApplication = extern struct {
    parent: c.GtkApplication,

    pub const Self = @This();
    pub var g_type: c.GType = undefined;

    pub fn register() void {
        g.Types.GtkApplication = c.gtk_application_get_type();

        g_type = g.type_register_static_simple(
            g.Types.GtkApplication,
            "TlrApplication",
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

    pub fn new() *Self {
        return @ptrCast(@alignCast(c.g_object_new(
            Self.g_type,
            "application-id",
            "rs.bxt.TasLogReader",
            "flags",
            c.G_APPLICATION_HANDLES_OPEN,
            @as([*c]const c.gchar, null),
        )));
    }

    pub fn run(self: *Self, args: std.process.Args) c_int {
        return c.g_application_run(
            self.as(c.GApplication),
            @intCast(args.vector.len),
            @ptrCast(@constCast(args.vector.ptr)),
        );
    }

    pub fn createNewWindow(self: *Self, file: ?*c.GFile) *TlrWindow {
        const window = TlrWindow.new(self, file);

        // Put it in a new window group so modal dialogs don't block other windows.
        const group = c.gtk_window_group_new();
        defer c.g_object_unref(group);
        c.gtk_window_group_add_window(group, window.as(c.GtkWindow));

        return window;
    }

    fn init(self: *Self) void {
        _ = self;
    }

    fn startup(app: ?*c.GApplication) callconv(.c) void {
        const zone = Tracy.zone(@src());
        defer zone.end();

        std.log.debug("startup", .{});

        // Now that we're going to run the app, fetch the rest of the types.
        g.Types.fetch();
        TlrWindow.register();
        TlrTable.register();

        g.as(c.GApplicationClass, Class.parent_class).startup.?(app);
    }

    fn activate(app: ?*c.GApplication) callconv(.c) void {
        const zone = Tracy.zone(@src());
        defer zone.end();

        const self = downcast(app.?);
        std.log.debug("activate", .{});

        const window = self.createNewWindow(null);
        window.present();
    }

    fn open(app: ?*c.GApplication, files: ?[*]?*c.GFile, n_files: c.gint, hint: ?[*:0]const u8) callconv(.c) void {
        const zone = Tracy.zone(@src());
        defer zone.end();

        const self = downcast(app.?);
        _ = hint;
        std.log.debug("open", .{});

        for (files.?[0..@intCast(n_files)]) |file| {
            // const path = @as(?[*:0]u8, c.g_file_get_path(file)) orelse continue;
            // defer c.g_free(path);
            //
            // std.log.debug("path={s}", .{path});

            const window = self.createNewWindow(file);
            window.present();
        }
    }

    pub const Class = extern struct {
        parent: Parent,

        const Parent = c.GtkApplicationClass;
        var parent_class: *Parent = undefined;

        fn init(class: *Class) void {
            parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(class)));

            const application_class = g.as(c.GApplicationClass, class);
            application_class.startup = Self.startup;
            application_class.activate = Self.activate;
            application_class.open = Self.open;
        }
    };
};
