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
    name: []const u8,
    template: []const u8, // Template string for measuring the size.

    header_layout: ?SizedLayout,
    template_layout: ?SizedLayout,

    layouts: ArrayList(*c.PangoLayout),

    customize: ?*const fn (attrs: *c.PangoAttrList) void,
    format: *const fn (buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) []u8,

    fn init(
        name: []const u8,
        template: []const u8,
        customize: ?*const fn (attrs: *c.PangoAttrList) void,
        format: *const fn (buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) []u8,
    ) @This() {
        return .{
            .name = name,
            .template = template,
            .header_layout = null,
            .template_layout = null,
            .layouts = .empty,
            .customize = customize,
            .format = format,
        };
    }

    fn dispose(self: *@This(), gpa: Allocator) void {
        std.debug.assert(self.header_layout == null);
        std.debug.assert(self.template_layout == null);

        if (self.layouts.capacity == 0) return;

        std.debug.assert(self.layouts.items.len == 0);
        self.layouts.clearAndFree(gpa);
    }

    fn destroyLayouts(self: *@This()) void {
        if (self.header_layout) |sized| {
            const layout = sized.layout;
            self.header_layout = null;
            c.g_object_unref(@ptrCast(layout));
        }
        if (self.template_layout) |sized| {
            const layout = sized.layout;
            self.template_layout = null;
            c.g_object_unref(@ptrCast(layout));
        }

        for (self.layouts.items) |layout| {
            c.g_object_unref(@ptrCast(layout));
        }

        self.layouts.clearRetainingCapacity();
    }

    fn ensureSizingLayouts(self: *@This(), widget: *c.GtkWidget) void {
        if (self.header_layout != null) return;

        // Header.
        const header_layout = c.gtk_widget_create_pango_layout(widget, null).?;
        c.pango_layout_set_text(header_layout, self.name.ptr, @intCast(self.name.len));

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
        self.header_layout = header_sized;

        // Template.
        const template_layout = c.gtk_widget_create_pango_layout(widget, null).?;
        c.pango_layout_set_text(template_layout, self.template.ptr, @intCast(self.template.len));

        const attrs = c.pango_attr_list_new().?;
        defer c.pango_attr_list_unref(attrs);
        c.pango_attr_list_insert(attrs, c.pango_attr_font_features_new("tnum"));
        if (self.customize) |f| f(attrs);
        c.pango_layout_set_attributes(template_layout, attrs);

        var template_sized = SizedLayout{ .layout = template_layout, .w = undefined, .h = undefined };
        template_sized.measure();
        self.template_layout = template_sized;
    }

    fn width(self: *const @This()) i32 {
        return @max(self.header_layout.?.w, self.template_layout.?.w);
    }
};

pub const TlrTable = extern struct {
    parent: c.GtkWidget,

    file: ?*c.GFile,

    hadjustment: ?*c.GtkAdjustment,
    vadjustment: ?*c.GtkAdjustment,
    hscroll_policy: c.GtkScrollablePolicy,
    vscroll_policy: c.GtkScrollablePolicy,

    log: ?*Log,

    columns: ?*[3]Column,

    pub const Self = @This();
    pub var g_type: c.GType = undefined;

    const Prop = enum(c.guint) {
        file = 1,
        // GtkScrollable
        hadjustment,
        vadjustment,
        hscroll_policy,
        vscroll_policy,
        N,
    };
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

        c.g_type_add_interface_static(
            g_type,
            g.Types.GtkScrollable,
            &.{
                .interface_init = @ptrCast(&Self.scrollable_init),
                .interface_finalize = null,
                .interface_data = null,
            },
        );
    }

    fn scrollable_init(iface: *c.GtkScrollableInterface) callconv(.c) void {
        iface.get_border = Self.get_border;
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

        self.clearLog();
        // TODO: no need to destroy header & template here.
        for (self.columns.?) |*column| column.destroyLayouts();
        c.gtk_widget_queue_resize(self.as(c.GtkWidget));

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

    fn clearAdjustment(self: *Self, adj: *?*c.GtkAdjustment) void {
        if (adj.*) |prev| {
            adj.* = null;
            _ = g.disconnect_by_func(prev, Self.adjusmentValueChanged, self);
            c.g_object_unref(prev);
        }
    }

    fn adjusmentValueChanged(self: *Self, adj: ?*c.GtkAdjustment) callconv(.c) void {
        _ = adj;
        c.gtk_widget_queue_allocate(self.as(c.GtkWidget));
    }

    pub fn setHAdjustment(self: *Self, adj: ?*c.GtkAdjustment) void {
        if (self.hadjustment == adj) return;
        defer c.g_object_notify_by_pspec(self.as(c.GObject), pSpec(Prop.hadjustment).*);

        self.clearAdjustment(&self.hadjustment);
        self.hadjustment = adj;

        if (adj) |p| {
            _ = c.g_object_ref(g.as(c.GObject, p));
            _ = g.connect_swapped(p, "value-changed", Self.adjusmentValueChanged, self);
        }

        self.adjusmentValueChanged(null);
    }

    pub fn setVAdjustment(self: *Self, adj: ?*c.GtkAdjustment) void {
        if (self.vadjustment == adj) return;
        defer c.g_object_notify_by_pspec(self.as(c.GObject), pSpec(Prop.vadjustment).*);

        self.clearAdjustment(&self.vadjustment);
        self.vadjustment = adj;

        if (adj) |p| {
            _ = c.g_object_ref(g.as(c.GObject, p));
            _ = g.connect_swapped(p, "value-changed", Self.adjusmentValueChanged, self);
        }

        self.adjusmentValueChanged(null);
    }

    fn parseLog(self: *Self, path: []const u8) !void {
        std.debug.assert(self.log == null);

        const log = try root.gpa.create(Log);
        errdefer root.gpa.destroy(log);

        try log.init(root.io, root.gpa, path);

        // TODO
        log.log.pf.shrinkAndFree(root.gpa, @min(log.log.pf.items.len, 50));

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
            fn fit(buf: []u8, comptime fmt: []const u8, args: anytype) []u8 {
                return std.fmt.bufPrint(buf, fmt, args) catch return buf;
            }

            fn frame(buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) []u8 {
                _ = pf;
                return fit(buf, "{}", .{n});
            }

            fn time(buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) []u8 {
                _ = n;
                return if (pf.ft) |ft|
                    fit(buf, "{:.3}", .{ft})
                else
                    buf[0..0];
            }

            fn ms(buf: []u8, n: usize, pf: *TasLog.PhysicsFrame) []u8 {
                _ = n;
                // TODO need to show one row per command frame.
                return if (pf.cf.len > 0)
                    fit(buf, "{}", .{pf.cf[0].ms})
                else
                    buf[0..0];
            }
        };

        self.columns = root.gpa.create([3]Column) catch |e| std.debug.panic("{}", .{e});
        self.columns.?.* = .{
            .init("Frame", "99", null, Format.frame),
            .init("Time", "0.000", Customize.time, Format.time),
            .init("Ms", "99", Customize.ms, Format.ms),
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
        var row_h: i32 = 0;

        for (self.columns.?) |*column| {
            column.ensureSizingLayouts(widget.?);

            w += column.width() + x_padding * 2;
            header_h = @max(header_h, column.header_layout.?.h);
            row_h = @max(row_h, column.template_layout.?.h);
        }
        const n_rows: i32 = if (self.log) |log| @intCast(log.log.pf.items.len) else 0;
        h = header_h + row_h * n_rows + y_padding * 2 * (n_rows + 1);

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
        _ = baseline;

        var w: i32 = 0;
        var h: i32 = 0;
        var header_h: i32 = 0;
        var row_h: i32 = 0;

        for (self.columns.?) |*column| {
            w += column.width() + x_padding * 2;
            header_h = @max(header_h, column.header_layout.?.h);
            row_h = @max(row_h, column.template_layout.?.h);
        }
        const n_rows: i32 = if (self.log) |log| @intCast(log.log.pf.items.len) else 0;
        h = (row_h + y_padding * 2) * n_rows;

        if (self.hadjustment) |adj| {
            const val = c.gtk_adjustment_get_value(adj);
            const page_size: f64 = @floatFromInt(width);
            c.gtk_adjustment_configure(
                adj,
                val,
                0,
                @max(w, page_size),
                page_size * 0.1,
                page_size * 0.9,
                page_size,
            );
        }
        if (self.vadjustment) |adj| {
            const val = c.gtk_adjustment_get_value(adj);
            const border = header_h + y_padding * 2;
            const page_size: f64 = @floatFromInt(height - border);
            c.gtk_adjustment_configure(
                adj,
                val,
                0,
                @max(h, page_size),
                page_size * 0.1,
                page_size * 0.9,
                page_size,
            );
        }
    }

    fn snapshot(widget: ?*c.GtkWidget, snap: ?*c.GtkSnapshot) callconv(.c) void {
        const zone = Tracy.zoneN(@src(), "TlrTable::snapshot");
        defer zone.end();

        const self = downcast(widget.?);

        // TODO
        c.gtk_snapshot_translate(snap, &.{
            .x = if (self.hadjustment) |adj| @floatCast(-c.gtk_adjustment_get_value(adj)) else 0,
            .y = if (self.vadjustment) |adj| @floatCast(-c.gtk_adjustment_get_value(adj)) else 0,
        });

        var color: c.GdkRGBA = undefined;
        c.gtk_widget_get_color(widget, &color);

        for (self.columns.?) |*column| {
            var h: i32 = y_padding;
            c.gtk_snapshot_translate(snap, &.{ .x = x_padding, .y = y_padding });
            c.gtk_snapshot_append_layout(snap, column.header_layout.?.layout, &color);
            c.gtk_snapshot_translate(snap, &.{ .x = 0, .y = @floatFromInt(column.header_layout.?.h + y_padding * 2) });
            h += column.header_layout.?.h + y_padding * 2;

            if (self.log) |log| {
                if (column.layouts.items.len == 0) {
                    var buf: [16]u8 = undefined;
                    for (1.., log.log.pf.items) |n, *pf| {
                        const layout = c.gtk_widget_create_pango_layout(widget, null).?;
                        const text = column.format(&buf, n, pf);
                        c.pango_layout_set_text(layout, text.ptr, @intCast(text.len));

                        const attrs = c.pango_attr_list_new().?;
                        defer c.pango_attr_list_unref(attrs);
                        c.pango_attr_list_insert(attrs, c.pango_attr_font_features_new("tnum"));
                        if (column.customize) |f| f(attrs);
                        c.pango_layout_set_attributes(layout, attrs);

                        column.layouts.append(root.gpa, layout) catch |e| std.debug.panic("{}", .{e});
                    }
                }

                for (column.layouts.items) |layout| {
                    c.gtk_snapshot_append_layout(snap, layout, &color);
                    c.gtk_snapshot_translate(snap, &.{ .x = 0, .y = @floatFromInt(column.template_layout.?.h + y_padding * 2) });
                    h += column.template_layout.?.h + y_padding * 2;
                }
            }

            c.gtk_snapshot_translate(snap, &.{ .x = @floatFromInt(column.width() + x_padding * 2), .y = @floatFromInt(-h) });
        }
    }

    fn unroot(widget: ?*c.GtkWidget) callconv(.c) void {
        const self = downcast(widget.?);
        for (self.columns.?) |*column| column.destroyLayouts();

        g.as(c.GtkWidgetClass, Class.parent_class).unroot.?(widget);
    }

    fn dispose(object: ?*c.GObject) callconv(.c) void {
        const self = downcast(object.?);

        self.clearAdjustment(&self.hadjustment);
        self.clearAdjustment(&self.vadjustment);
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
            @intFromEnum(Prop.hadjustment) => self.setHAdjustment(@ptrCast(@alignCast(c.g_value_get_object(value)))),
            @intFromEnum(Prop.vadjustment) => self.setVAdjustment(@ptrCast(@alignCast(c.g_value_get_object(value)))),
            @intFromEnum(Prop.hscroll_policy) => {
                const val: c.GtkScrollablePolicy = @intCast(c.g_value_get_enum(value));
                if (val != self.hscroll_policy) {
                    self.hscroll_policy = val;
                    c.g_object_notify_by_pspec(self.as(c.GObject), pSpec(Prop.hscroll_policy).*);
                }
            },
            @intFromEnum(Prop.vscroll_policy) => {
                const val: c.GtkScrollablePolicy = @intCast(c.g_value_get_enum(value));
                if (val != self.vscroll_policy) {
                    self.vscroll_policy = val;
                    c.g_object_notify_by_pspec(self.as(c.GObject), pSpec(Prop.vscroll_policy).*);
                }
            },
            else => unreachable,
        }
    }

    fn get_property(object: ?*c.GObject, property_id: c.guint, value: ?*c.GValue, pspec: ?*c.GParamSpec) callconv(.c) void {
        _ = pspec;

        const self = downcast(object.?);
        switch (property_id) {
            @intFromEnum(Prop.file) => c.g_value_set_object(value, self.file),
            @intFromEnum(Prop.hadjustment) => c.g_value_set_object(value, self.hadjustment),
            @intFromEnum(Prop.vadjustment) => c.g_value_set_object(value, self.vadjustment),
            @intFromEnum(Prop.hscroll_policy) => c.g_value_set_enum(value, @intCast(self.hscroll_policy)),
            @intFromEnum(Prop.vscroll_policy) => c.g_value_set_enum(value, @intCast(self.vscroll_policy)),
            else => unreachable,
        }
    }

    fn get_border(scrollable: ?*c.GtkScrollable, border: ?*c.GtkBorder) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(scrollable.?));

        var header_h: i32 = 0;
        for (self.columns.?) |*column| {
            // This is called before measure...
            column.ensureSizingLayouts(self.as(c.GtkWidget));

            header_h = @max(header_h, column.header_layout.?.h);
        }
        border.?.*.top = @intCast(header_h + y_padding * 2);

        return 1;
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

            const scrollable = c.g_type_default_interface_peek(g.Types.GtkScrollable);
            pSpec(Prop.hadjustment).* = c.g_param_spec_override(
                "hadjustment",
                c.g_object_interface_find_property(scrollable, "hadjustment"),
            );
            pSpec(Prop.vadjustment).* = c.g_param_spec_override(
                "vadjustment",
                c.g_object_interface_find_property(scrollable, "vadjustment"),
            );
            pSpec(Prop.hscroll_policy).* = c.g_param_spec_override(
                "hscroll-policy",
                c.g_object_interface_find_property(scrollable, "hscroll-policy"),
            );
            pSpec(Prop.vscroll_policy).* = c.g_param_spec_override(
                "vscroll-policy",
                c.g_object_interface_find_property(scrollable, "vscroll-policy"),
            );

            c.g_object_class_install_properties(object_class, @intFromEnum(Prop.N), &properties);
        }
    };
};
