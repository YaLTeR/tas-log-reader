const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = @import("c");
const g = @import("gobject.zig");
const root = @import("root");
const Tracy = root.Tracy;

const tas_log_reader = @import("tas_log_reader");
const TasLog = tas_log_reader.TasLog;

const Log = struct {
    file: Io.File,
    mmap: Io.File.MemoryMap,
    log: TasLog,

    fn init(self: *@This(), io: Io, gpa: Allocator, path: []const u8) !void {
        const zone = Tracy.zoneN(@src(), "Log.init");
        defer zone.end();

        const file = try Io.Dir.cwd().openFile(io, path, .{
            .mode = .read_only,
            .allow_directory = false,
        });
        errdefer file.close(io);

        const size = try file.length(io);
        var mmap = try file.createMemoryMap(io, .{
            .len = size,
            .protection = .{ .read = true },
        });
        errdefer mmap.destroy(io);

        self.* = .{
            .file = file,
            .mmap = mmap,
            .log = undefined,
        };
        try self.log.parse(gpa, mmap.memory);
    }

    fn deinit(self: *@This(), io: Io) void {
        const zone = Tracy.zoneN(@src(), "Log.deinit");
        defer zone.end();

        self.log.deinit();
        self.mmap.destroy(io);
        self.file.close(io);
    }
};

pub const TlrTable = extern struct {
    parent: c.GtkWidget,

    file: ?*c.GFile,
    layout: ?*c.PangoLayout,

    log: ?*Log,

    pub const Self = @This();
    pub var g_type: c.GType = undefined;

    const Prop = enum(c.guint) { file = 1, N };
    var properties = [_]?*c.GParamSpec{null} ** @intFromEnum(Prop.N);

    inline fn pSpec(comptime p: Prop) *?*c.GParamSpec {
        return &properties[@intFromEnum(p)];
    }

    pub fn register() void {
        g_type = g.type_register_static_simple(
            g.Types.GtkWidget,
            "TlrTable",
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

    pub fn new(file: ?*c.GFile) *Self {
        return @ptrCast(@alignCast(c.g_object_new(
            Self.g_type,
            "file",
            file,
            @as([*c]const c.gchar, null),
        )));
    }

    pub fn setFile(self: *Self, file: ?*c.GFile) void {
        if (!g.set_object(@ptrCast(&self.file), @ptrCast(@alignCast(file)))) return;

        defer c.g_object_notify_by_pspec(self.as(c.GObject), pSpec(Prop.file).*);

        if (self.file == null) {
            return;
        }

        if (@as(?[*:0]u8, c.g_file_get_path(self.file))) |path| {
            self.parseLog(std.mem.span(path)) catch |err| {
                std.log.warn("error parsing log: {}", .{err});
            };
            c.g_free(path);
        }
    }

    fn parseLog(self: *Self, path: []const u8) !void {
        self.clearLog();

        const log = try root.gpa.create(Log);
        errdefer root.gpa.destroy(log);

        try log.init(root.io, root.gpa, path);

        self.log = log;
    }

    fn clearLog(self: *Self) void {
        if (self.log) |log| {
            const l = log;
            self.log = null;
            l.deinit(root.io);
            root.gpa.destroy(l);
        }
    }

    fn init(self: *Self) void {
        _ = self;
    }

    fn measure(
        widget: ?*c.GtkWidget,
        orientation: c.GtkOrientation,
        for_size: c_int,
        min: ?*c_int,
        nat: ?*c_int,
        min_baseline: ?*c_int,
        nat_baseline: ?*c_int,
    ) callconv(.c) void {
        const self = downcast(widget.?);
        _ = for_size;

        if (self.layout == null) {
            const text = if (self.log) |log|
                log.log.meta.tool_ver orelse "missing"
            else
                "no log";
            const textZ = root.gpa.dupeSentinel(u8, text, 0) catch |e| std.debug.panic("{}", .{e});
            defer root.gpa.free(textZ);

            self.layout = c.gtk_widget_create_pango_layout(widget, textZ);

            const attrs = c.pango_attr_list_new();
            defer c.pango_attr_list_unref(attrs);

            c.pango_attr_list_insert(attrs, c.pango_attr_font_features_new("tnum"));

            c.pango_layout_set_attributes(self.layout, attrs);
        }

        var width: c_int = undefined;
        var height: c_int = undefined;
        c.pango_layout_get_pixel_size(self.layout, &width, &height);

        if (min_baseline) |p| p.* = -1;
        if (nat_baseline) |p| p.* = -1;

        switch (orientation) {
            c.GTK_ORIENTATION_HORIZONTAL => {
                if (min) |p| p.* = width;
                if (nat) |p| p.* = width;
            },
            c.GTK_ORIENTATION_VERTICAL => {
                if (min) |p| p.* = height;
                if (nat) |p| p.* = height;
            },
            else => unreachable,
        }
    }

    fn size_allocate(
        widget: ?*c.GtkWidget,
        width: c_int,
        height: c_int,
        baseline: c_int,
    ) callconv(.c) void {
        const self = downcast(widget.?);
        _ = self;
        _ = width;
        _ = height;
        _ = baseline;
    }

    fn snapshot(widget: ?*c.GtkWidget, snap: ?*c.GtkSnapshot) callconv(.c) void {
        const self = downcast(widget.?);

        // const w = c.gtk_widget_get_width(widget);
        // const h = c.gtk_widget_get_height(widget);
        //
        // c.gtk_snapshot_append_color(
        //     snap,
        //     &.{ .red = 1, .green = 0, .blue = 0, .alpha = 1 },
        //     &.{
        //         .origin = .{ .x = 0, .y = 0 },
        //         .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) },
        //     },
        // );

        var color: c.GdkRGBA = undefined;
        c.gtk_widget_get_color(widget, &color);
        c.gtk_snapshot_append_layout(snap, self.layout, &color);
    }

    fn unroot(widget: ?*c.GtkWidget) callconv(.c) void {
        const self = downcast(widget.?);

        g.clear_object(&self.layout);
    }

    fn dispose(object: ?*c.GObject) callconv(.c) void {
        const self = downcast(object.?);

        g.clear_object(&self.file);
        self.clearLog();

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

            const widget_class = g.as(c.GtkWidgetClass, class);
            widget_class.measure = Self.measure;
            widget_class.size_allocate = Self.size_allocate;
            widget_class.snapshot = Self.snapshot;
            widget_class.unroot = Self.unroot;

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
