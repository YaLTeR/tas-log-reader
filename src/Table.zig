const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const c = @import("c");
const g = @import("gobject.zig");
const root = @import("root");
const Tracy = root.Tracy;

const tas_log_reader = @import("tas_log_reader");
const TasLog = tas_log_reader.TasLog;

// Values from libadwaita.
const dimmed = 36045;
const x_padding = 6;
const y_padding = 3;

const Log = struct {
    file: Io.File,
    mmap: Io.File.MemoryMap,
    log: TasLog,

    fn init(self: *@This(), io: Io, gpa: Allocator, path: []const u8) !void {
        const zone = Tracy.zoneN(@src(), "Log::init");
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
        const zone = Tracy.zoneN(@src(), "Log::deinit");
        defer zone.end();

        self.log.deinit();
        self.mmap.destroy(io);
        self.file.close(io);
    }
};

const SizedLayout = struct {
    layout: *c.PangoLayout,
    w: i32,
    h: i32,

    fn measure(self: *@This()) void {
        c.pango_layout_get_pixel_size(self.layout, &self.w, &self.h);
    }
};

const Column = struct {
    name: [:0]const u8,
    layouts: ArrayList(SizedLayout),
    width: i32,

    customize: ?*const fn (attrs: *c.PangoAttrList) void,
    format: *const fn (buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) [:0]u8,

    fn init(name: [:0]const u8, customize: ?*const fn (attrs: *c.PangoAttrList) void, format: *const fn (
        buf: []u8,
        n: usize,
        pf: *TasLog.PhysicsFrame
    ) [:0]u8,) @This() {
        return .{
            .name = name,
            .layouts = .empty,
            .width = undefined,
            .customize = customize,
            .format = format,
        };
    }

    fn dispose(self: *@This(), gpa: Allocator) void {
        if (self.layouts.capacity == 0) return;

        std.debug.assert(self.layouts.items.len == 0);
        self.layouts.clearAndFree(gpa);
    }

    fn destroyLayouts(self: *@This()) void {
        for (self.layouts.items) |sized| {
            c.g_object_unref(@ptrCast(sized.layout));
        }

        self.layouts.clearRetainingCapacity();
    }

    fn computeWidth(self: *@This()) void {
        // TODO: instead of this, measure one template string for width.
        self.width = 0;
        for (self.layouts.items) |sized| {
            self.width = @max(self.width, sized.w);
        }
    }
};

pub const TlrTable = extern struct {
    parent: c.GtkWidget,

    file: ?*c.GFile,

    log: ?*Log,

    columns: ?*[3]Column,

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
        const Customize = struct {
            fn time(attrs: *c.PangoAttrList) void {
                c.pango_attr_list_insert(attrs, c.pango_attr_foreground_alpha_new(dimmed));
            }

            fn ms(attrs: *c.PangoAttrList) void {
                c.pango_attr_list_insert(attrs, c.pango_attr_foreground_alpha_new(dimmed));
            }
        };

        const Format = struct {
            fn fit(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]u8 {
                return std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch {
                    buf[buf.len - 1] = 0;
                    return buf[0 .. buf.len - 1 :0];
                };
            }

            fn empty(buf: []u8) [:0]u8 {
                buf[0] = 0;
                return buf[0..0 :0];
            }

            fn frame(buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) [:0]u8 {
                _ = pf;
                return fit(buf, "{}", .{n});
            }

            fn time(buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) [:0]u8 {
                _ = n;
                return if (pf.ft) |ft|
                    fit(buf, "{:.3}", .{ft})
                else
                    empty(buf);
            }

            fn ms(buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) [:0]u8 {
                _ = n;
                // TODO need to show one row per command frame.
                return if (pf.cf.len > 0)
                    fit(buf, "{}", .{pf.cf[0].ms})
                else
                    empty(buf);
            }
        };

        self.columns = root.gpa.create([3]Column) catch |e| std.debug.panic("{}", .{e});
        self.columns.?.* = .{
            .init("Frame", null, Format.frame),
            .init("Time", Customize.time, Format.time),
            .init("Ms", Customize.ms, Format.ms),
        };
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
        const zone = Tracy.zoneN(@src(), "TlrTable::measure");
        defer zone.end();

        const self = downcast(widget.?);
        _ = for_size;
        _ = min_baseline;
        _ = nat_baseline;

        var w: i32 = 0;
        var h: i32 = 0;
        var header_h: i32 = 0;

        // Should be more than enough.
        var buf: [16]u8 = undefined;

        for (self.columns.?) |*column| {
            if (column.layouts.items.len == 0) {
                // Initialize layouts.

                // Header.
                const header_layout = c.gtk_widget_create_pango_layout(widget, column.name).?;

                const context = c.pango_layout_get_context(header_layout);
                const desc = c.pango_context_get_font_description(context);
                const size = c.pango_font_description_get_size(desc);
                std.debug.assert(c.pango_font_description_get_size_is_absolute(desc) != 0);

                const header_size = @divTrunc(size * 82, 100); // From libadwaita .caption-heading

                const header_attrs = c.pango_attr_list_new();
                defer c.pango_attr_list_unref(header_attrs);
                c.pango_attr_list_insert(header_attrs, c.pango_attr_size_new_absolute(header_size));
                c.pango_layout_set_attributes(header_layout, header_attrs);

                var header_sized = SizedLayout{ .layout = header_layout, .w = undefined, .h = undefined };
                header_sized.measure();
                column.layouts.append(root.gpa, header_sized) catch |e| std.debug.panic("{}", .{e});

                // Some rows.
                if (self.log) |log| {
                    const pfs = log.log.pf.items;
                    for (1.., pfs[0..@min(pfs.len, 16)]) |n, *pf| {
                        const text = column.format(&buf, n, pf);
                        const layout = c.gtk_widget_create_pango_layout(widget, text).?;

                        const attrs = c.pango_attr_list_new().?;
                        defer c.pango_attr_list_unref(attrs);
                        c.pango_attr_list_insert(attrs, c.pango_attr_font_features_new("tnum"));
                        if (column.customize) |f| f(attrs);
                        c.pango_layout_set_attributes(layout, attrs);

                        var sized = SizedLayout{ .layout = layout, .w = undefined, .h = undefined };
                        sized.measure();
                        column.layouts.append(root.gpa, sized) catch |e| std.debug.panic("{}", .{e});
                    }
                }

                column.computeWidth();
            }

            w += column.width + x_padding * 2;
            header_h = @max(header_h, column.layouts.items[0].h);

            if (column.layouts.items.len > 1) {
                h = @max(h, column.layouts.items[1].h);
            }
        }
        const n_rows: i32 = @intCast(self.columns.?[0].layouts.items.len - 1);
        h = header_h + h * n_rows + y_padding * 2 * (n_rows + 1);

        switch (orientation) {
            c.GTK_ORIENTATION_HORIZONTAL => {
                min.?.* = w;
                nat.?.* = w;
            },
            c.GTK_ORIENTATION_VERTICAL => {
                min.?.* = h;
                nat.?.* = h;
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

        var color: c.GdkRGBA = undefined;
        c.gtk_widget_get_color(widget, &color);

        for (self.columns.?) |column| {
            var h: i32 = y_padding;
            c.gtk_snapshot_translate(snap, &.{ .x = x_padding, .y = y_padding });
            for (column.layouts.items) |layout| {
                c.gtk_snapshot_append_layout(snap, layout.layout, &color);
                c.gtk_snapshot_translate(snap, &.{ .x = 0, .y = @floatFromInt(layout.h + y_padding * 2) });
                h += layout.h + y_padding * 2;
            }
            c.gtk_snapshot_translate(snap, &.{ .x = @floatFromInt(column.width + x_padding * 2), .y = @floatFromInt(-h) });
        }
    }

    fn unroot(widget: ?*c.GtkWidget) callconv(.c) void {
        const self = downcast(widget.?);
        for (self.columns.?) |*column| column.destroyLayouts();

        g.as(c.GtkWidgetClass, Class.parent_class).unroot.?(widget);
    }

    fn dispose(object: ?*c.GObject) callconv(.c) void {
        const self = downcast(object.?);

        g.clear_object(&self.file);
        self.clearLog();
        for (self.columns.?) |*column| column.dispose(root.gpa);

        g.as(c.GObjectClass, Class.parent_class).dispose.?(object);
    }

    fn finalize(object: ?*c.GObject) callconv(.c) void {
        const self = downcast(object.?);

        const columns = self.columns.?;
        self.columns = null;
        root.gpa.destroy(columns);

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
            object_class.finalize = Self.finalize;
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
