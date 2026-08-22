const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const math = std.math;
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
const border_opacity = 0.15;

const Buf = [16]u8;
const AttrBuf = [2]?*c.PangoAttribute;

const Log = struct {
    file: Io.File,
    mmap: Io.File.MemoryMap,
    log: TasLog,
    rows: ArrayList(Row),

    const Row = struct {
        pf: *const TasLog.PhysicsFrame,
        cf: ?*const TasLog.CommandFrame,
    };

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
            .rows = .empty,
        };
        try self.log.parse(gpa, mmap.memory);

        // self.log.pf.shrinkRetainingCapacity(50);

        errdefer self.log.deinit();
        errdefer self.rows.deinit(gpa);

        for (self.log.pf.items) |*pf| {
            if (pf.cf.len == 0) {
                const row = Row{
                    .pf = pf,
                    .cf = null,
                };
                try self.rows.append(gpa, row);
            } else {
                for (pf.cf) |*cf| {
                    const row = Row{
                        .pf = pf,
                        .cf = cf,
                    };
                    try self.rows.append(gpa, row);
                }
            }
        }
    }

    fn deinit(self: *@This(), io: Io) void {
        const zone = Tracy.zoneN(@src(), "Log::deinit");
        defer zone.end();

        const gpa = self.log.arena.child_allocator;
        self.rows.deinit(gpa);
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

const Align = enum { left, center, right };

fn transparent(row: Column.Data) ?c.GdkRGBA {
    _ = row;
    return null;
}

const Column = struct {
    name: []const u8,
    template: []const u8, // Template string for measuring the size.

    header_layout: ?SizedLayout,
    template_layout: ?SizedLayout,

    layouts: ArrayList(*c.PangoLayout),

    xalign: Align,
    static_attrs: [2]?*c.PangoAttribute,
    bind: *const BindFn,
    background: *const ColorFn,

    const BindFn = fn (buf: *Buf, attrs: *AttrBuf, row: Data) []const u8;
    const ColorFn = fn (row: Data) ?c.GdkRGBA;

    const Data = struct {
        n: usize,
        pf: *const TasLog.PhysicsFrame,
        cf: ?*const TasLog.CommandFrame,
    };

    fn init(
        name: []const u8,
        template: []const u8,
        xalign: Align,
        static_attrs: ?[2]?*c.PangoAttribute,
        bind: *const BindFn,
        background: ?*const ColorFn,
    ) @This() {
        return .{
            .name = name,
            .template = template,
            .header_layout = null,
            .template_layout = null,
            .layouts = .empty,
            .xalign = xalign,
            .static_attrs = static_attrs orelse .{ null, null },
            .bind = bind,
            .background = background orelse transparent,
        };
    }

    fn dispose(self: *@This(), gpa: Allocator) void {
        std.debug.assert(self.header_layout == null);
        std.debug.assert(self.template_layout == null);

        for (self.static_attrs) |a| if (a) |aa| c.pango_attribute_destroy(aa) else break;
        self.static_attrs = .{ null, null };

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

    // Extern structs aren't allowed to contain ?[]Column...
    columns: ?*[29]Column,
    first_row_is: usize,
    last_row_is: usize,

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
        self.first_row_is = 0;
        self.last_row_is = 0;
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
            _ = g.disconnect_by_func(prev, Self.adjustmentValueChanged, self);
            c.g_object_unref(prev);
        }
    }

    fn adjustmentValueChanged(self: *Self, adj: ?*c.GtkAdjustment) callconv(.c) void {
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
            _ = g.connect_swapped(p, "value-changed", Self.adjustmentValueChanged, self);
        }

        self.adjustmentValueChanged(null);
    }

    pub fn setVAdjustment(self: *Self, adj: ?*c.GtkAdjustment) void {
        if (self.vadjustment == adj) return;
        defer c.g_object_notify_by_pspec(self.as(c.GObject), pSpec(Prop.vadjustment).*);

        self.clearAdjustment(&self.vadjustment);
        self.vadjustment = adj;

        if (adj) |p| {
            _ = c.g_object_ref(g.as(c.GObject, p));
            _ = g.connect_swapped(p, "value-changed", Self.adjustmentValueChanged, self);
        }

        self.adjustmentValueChanged(null);
    }

    fn parseLog(self: *Self, path: []const u8) !void {
        std.debug.assert(self.log == null);

        const log = try root.gpa.create(Log);
        errdefer root.gpa.destroy(log);

        try log.init(root.io, root.gpa, path);
        std.log.debug("loaded {} rows", .{log.rows.items.len});

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
        const Bind = struct {
            const Data = Column.Data;

            fn fit(buf: *Buf, comptime fmt: []const u8, args: anytype) []const u8 {
                return std.fmt.bufPrint(buf, fmt, args) catch return buf;
            }

            fn frame(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                return fit(buf, "{}", .{row.n});
            }

            fn time(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const ft = row.pf.ft orelse return "";
                return fit(buf, "{:.3}", .{ft});
            }

            fn ms(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                return fit(buf, "{}", .{cf.ms});
            }

            fn speed(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                const pm = cf.postpm orelse return "";

                const vel = pm.vel;
                if (vel[0] == 0 and vel[1] == 0) return "";

                return fit(buf, "{:.3}", .{math.hypot(vel[0], vel[1])});
            }

            fn vel_yaw(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                const pm = cf.postpm orelse return "";

                const vel = pm.vel;
                if (vel[0] == 0 and vel[1] == 0) return "";

                return fit(buf, "{:.3}", .{math.atan2(vel[1], vel[0]) * math.deg_per_rad});
            }

            fn vert_speed(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                const cf = row.cf orelse return "";
                const pm = cf.postpm orelse return "";

                const z = pm.vel[2];
                if (z == 0) return "";

                if (z > 0) {
                    attrs[0] = c.pango_attr_foreground_new(0x1c * 257, 0x71 * 257, 0xd8 * 257);
                } else {
                    attrs[0] = c.pango_attr_foreground_new(0xed * 257, 0x33 * 257, 0x3b * 257);
                }

                return fit(buf, "{:.1}", .{z});
            }

            fn G(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn K(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn L(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn W(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn J(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn D(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn F(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                const cf = row.cf orelse return "";

                const x = cf.fsu[0];
                if (x == 0) return "";

                return if (x > 0) "F" else "B";
            }

            fn S(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                const cf = row.cf orelse return "";

                const x = cf.fsu[1];
                if (x == 0) return "";

                return if (x > 0) "R" else "L";
            }

            fn U(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                const cf = row.cf orelse return "";

                const x = cf.fsu[2];
                if (x == 0) return "";

                return if (x > 0) "U" else "D";
            }

            fn yaw(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                return fit(buf, "{:.3}", .{cf.view[0]});
            }

            fn pitch(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                return fit(buf, "{:.3}", .{cf.view[1]});
            }

            fn health(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                const hp = cf.hp orelse return "";
                return fit(buf, "{:.0}", .{hp});
            }

            fn armor(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                const ap = cf.ap orelse return "";
                return fit(buf, "{:.1}", .{ap});
            }

            fn E(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn A1(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn A2(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn R(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = buf;
                _ = attrs;
                _ = row;
                return "";
            }

            fn cl_state(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                if (row.pf.cls != 5) {
                    attrs[0] = c.pango_attr_foreground_new(0xed * 257, 0x33 * 257, 0x3b * 257);
                    attrs[1] = c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD);
                } else {
                    // Signal to reset.
                    attrs[0] = null;
                }
                return fit(buf, "{}", .{row.pf.cls});
            }

            fn z_pos(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                const pm = cf.postpm orelse return "";
                return fit(buf, "{:.3}", .{pm.pos[2]});
            }

            fn x_pos(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                const pm = cf.postpm orelse return "";
                return fit(buf, "{:.3}", .{pm.pos[0]});
            }

            fn y_pos(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                const pm = cf.postpm orelse return "";
                return fit(buf, "{:.3}", .{pm.pos[1]});
            }

            fn sh_seed(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                return fit(buf, "{}", .{cf.ss});
            }

            fn fr_time_rem(buf: *Buf, attrs: *AttrBuf, row: Data) []const u8 {
                _ = attrs;
                const cf = row.cf orelse return "";
                const rem = cf.rem orelse return "";
                return fit(buf, "{e:.2}", .{rem});
            }
        };

        const Background = struct {
            const Data = Column.Data;

            fn rgba(hex: u32) c.GdkRGBA {
                return .{
                    .red = @as(f32, @floatFromInt(hex >> 16)) / 255,
                    .green = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255,
                    .blue = @as(f32, @floatFromInt(hex & 0xFF)) / 255,
                    .alpha = 1,
                };
            }

            fn G(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const pm = cf.postpm orelse return null;
                return if (pm.og) rgba(0x2ec27e) else null;
            }

            fn K(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const pm = cf.postpm orelse return null;
                return switch (pm.dst) {
                    1 => rgba(0x77767b),
                    2 => rgba(0x241f31),
                    else => null,
                };
            }

            fn L(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const pm = cf.postpm orelse return null;
                return if (pm.ol) rgba(0x865e3c) else null;
            }

            fn W(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const pm = cf.postpm orelse return null;
                return switch (pm.wlvl) {
                    1 => rgba(0x62a0ea),
                    2 => rgba(0x1a5fb4),
                    else => null,
                };
            }

            fn J(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const down = (cf.btns & (1 << 1)) > 0;
                return if (down) rgba(0xf5c211) else null;
            }

            fn D(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const down = (cf.btns & (1 << 2)) > 0;
                return if (down) rgba(0xdc8add) else null;
            }

            fn F(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const x = cf.fsu[0];
                if (x == 0) return null;
                return if (x > 0) rgba(0x3584e4) else rgba(0xed333b);
            }

            fn S(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const x = cf.fsu[1];
                if (x == 0) return null;
                return if (x > 0) rgba(0x3584e4) else rgba(0xed333b);
            }

            fn U(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const x = cf.fsu[2];
                if (x == 0) return null;
                return if (x > 0) rgba(0x3584e4) else rgba(0xed333b);
            }

            fn E(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const down = (cf.btns & (1 << 5)) > 0;
                return if (down) rgba(0xf5c211) else null;
            }

            fn A1(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const down = (cf.btns & (1 << 0)) > 0;
                return if (down) rgba(0xf5c211) else null;
            }

            fn A2(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const down = (cf.btns & (1 << 11)) > 0;
                return if (down) rgba(0xf5c211) else null;
            }

            fn R(row: Data) ?c.GdkRGBA {
                const cf = row.cf orelse return null;
                const down = (cf.btns & (1 << 13)) > 0;
                return if (down) rgba(0xf5c211) else null;
            }
        };

        self.columns = root.gpa.create([29]Column) catch @panic("out of memory");
        self.columns.?.* = .{
            .init("Frame", "99999", .right, null, Bind.frame, null),
            .init("Time", "0.000", .left, .{ c.pango_attr_foreground_alpha_new(dimmed), null }, Bind.time, null),
            .init("Ms", "99", .right, .{ c.pango_attr_foreground_alpha_new(dimmed), null }, Bind.ms, null),
            .init("Speed", "9999.999", .right, null, Bind.speed, null),
            .init("Vel. Yaw", "-999.999", .right, null, Bind.vel_yaw, null),
            .init("Vert. Speed", "-9999.9", .right, null, Bind.vert_speed, null),
            .init("G", "W", .left, null, Bind.G, Background.G),
            .init("K", "W", .left, null, Bind.K, Background.K),
            .init("L", "W", .left, null, Bind.L, Background.L),
            .init("W", "W", .left, null, Bind.W, Background.W),
            .init("J", "W", .left, null, Bind.J, Background.J),
            .init("D", "W", .left, null, Bind.D, Background.D),
            .init("F", "W", .center, .{ c.pango_attr_foreground_new(65535, 65535, 65535), c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD) }, Bind.F, Background.F),
            .init("S", "W", .center, .{ c.pango_attr_foreground_new(65535, 65535, 65535), c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD) }, Bind.S, Background.S),
            .init("U", "W", .center, .{ c.pango_attr_foreground_new(65535, 65535, 65535), c.pango_attr_weight_new(c.PANGO_WEIGHT_BOLD) }, Bind.U, Background.U),
            .init("Yaw", "-999.999", .right, null, Bind.yaw, null),
            .init("Pitch", "-999.999", .right, null, Bind.pitch, null),
            .init("Health", "999", .right, null, Bind.health, null),
            .init("Armor", "999.9", .right, null, Bind.armor, null),
            .init("E", "W", .left, null, Bind.E, Background.E),
            .init("1", "W", .left, null, Bind.A1, Background.A1),
            .init("2", "W", .left, null, Bind.A2, Background.A2),
            .init("R", "W", .left, null, Bind.R, Background.R),
            .init("CL State", "9", .center, .{ c.pango_attr_foreground_alpha_new(dimmed), null }, Bind.cl_state, null),
            .init("Z Position", "-9999.999", .right, null, Bind.z_pos, null),
            .init("X Position", "-9999.999", .right, null, Bind.x_pos, null),
            .init("Y Position", "-9999.999", .right, null, Bind.y_pos, null),
            .init("Sh. Seed", "99999", .right, .{ c.pango_attr_foreground_alpha_new(dimmed), null }, Bind.sh_seed, null),
            .init("Fr. Time Rem.", "9.99e-9", .right, .{ c.pango_attr_foreground_alpha_new(dimmed), null }, Bind.fr_time_rem, null),
        };

        c.gtk_widget_add_css_class(self.as(c.GtkWidget), "view");
        c.gtk_widget_set_overflow(self.as(c.GtkWidget), c.GTK_OVERFLOW_HIDDEN);
    }

    fn get_border(scrollable: ?*c.GtkScrollable, border: ?*c.GtkBorder) callconv(.c) c_int {
        const zone = Tracy.zoneN(@src(), "TlrTable::get_border");
        defer zone.end();

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

        var total_w: i32 = 0;
        var h: i32 = 0;
        var header_h: i32 = 0;
        var row_h: i32 = 0;

        for (0.., self.columns.?) |i, *column| {
            column.ensureSizingLayouts(widget.?);

            if (i > 0) total_w += 1; // Border.
            total_w += column.width() + x_padding * 2;
            header_h = @max(header_h, column.header_layout.?.h);
            row_h = @max(row_h, column.template_layout.?.h);
        }
        header_h += 1; // Border.
        const n_rows: i32 = if (self.log) |log| @intCast(log.rows.items.len) else 0;
        h = header_h + row_h * n_rows + y_padding * 2 * (n_rows + 1) + (n_rows - 1);

        switch (orientation) {
            c.GTK_ORIENTATION_HORIZONTAL => {
                min.?.* = total_w;
                nat.?.* = total_w;
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
        const zone = Tracy.zoneN(@src(), "TlrTable::size_allocate");
        defer zone.end();

        const self = downcast(widget.?);
        _ = baseline;

        var total_w: i32 = 0;
        var h: i32 = 0;
        var header_h: i32 = 0;
        var row_h: i32 = 0;

        for (0.., self.columns.?) |i, *column| {
            if (i > 0) total_w += 1; // Border.
            total_w += column.width() + x_padding * 2;
            header_h = @max(header_h, column.header_layout.?.h);
            row_h = @max(row_h, column.template_layout.?.h);
        }
        header_h += 1; // Border.
        const n_rows: i32 = if (self.log) |log| @intCast(log.rows.items.len) else 0;
        h = (row_h + y_padding * 2) * n_rows + (n_rows - 1);

        if (self.hadjustment) |adj| {
            const val = c.gtk_adjustment_get_value(adj);
            const page_size: f64 = @floatFromInt(width);
            c.gtk_adjustment_configure(
                adj,
                val,
                0,
                @max(total_w, page_size),
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

        var total_w: i32 = 0;
        var header_h: i32 = 0;
        var row_h: i32 = 0;
        for (0.., self.columns.?) |i, *column| {
            if (i > 0) total_w += 1; // Border.
            total_w += column.width() + x_padding * 2;
            header_h = @max(header_h, column.header_layout.?.h);
            row_h = @max(row_h, column.template_layout.?.h);
        }
        header_h += y_padding * 2 + 1;
        row_h += y_padding * 2;

        c.gtk_snapshot_translate(snap, &.{
            .x = if (self.hadjustment) |adj| @floatCast(-c.gtk_adjustment_get_value(adj)) else 0,
            .y = 0,
        });

        var color: c.GdkRGBA = undefined;
        c.gtk_widget_get_color(widget, &color);
        const border_color = c.GdkRGBA{
            .red = color.red,
            .green = color.green,
            .blue = color.blue,
            .alpha = color.alpha * border_opacity,
        };

        const full_height = c.gtk_widget_get_height(self.as(c.GtkWidget));

        // Snapshot the rows.
        var h: i32 = 0;
        if (self.log) |log| {
            const start_y = if (self.vadjustment) |adj| c.gtk_adjustment_get_value(adj) else 0;
            const start_row = start_y / (row_h + 1); // Fractional rows.
            const y_offset: i32 = @round(-@mod(start_row, 1) * (row_h + 1));
            const first_row: usize = @intFromFloat(start_row);

            var n: usize = 0;
            for (0.., self.columns.?) |i, *column| {
                const border: i32 = if (i > 0) 1 else 0;
                const column_w = column.width();

                h = header_h + y_offset;
                c.gtk_snapshot_translate(snap, &.{
                    .x = @floatFromInt(border),
                    .y = @floatFromInt(h),
                });

                // TODO: avoid reformatting when scrolling slowly.
                const format_from = if (first_row == self.first_row_is) self.last_row_is - self.first_row_is else 0;

                // Cannot use for (0..) |n| because Zig complains about an unbounded loop...
                n = 0;
                while (h < full_height and n + first_row < log.rows.items.len) {
                    if (column.layouts.items.len <= n) {
                        const layout = c.gtk_widget_create_pango_layout(widget, null).?;

                        // We don't know here if the column uses dynamic attrs; in case it doesn't, set here.
                        const attrs = c.pango_attr_list_new().?;
                        c.pango_attr_list_insert(attrs, c.pango_attr_font_features_new("tnum"));
                        for (column.static_attrs) |a| if (a) |aa| {
                            c.pango_attr_list_insert(attrs, c.pango_attribute_copy(aa));
                        } else break;
                        c.pango_layout_set_attributes(layout, attrs);
                        c.pango_attr_list_unref(attrs);

                        column.layouts.append(root.gpa, layout) catch @panic("out of memory");
                    }
                    const layout = column.layouts.items[n];

                    const log_row = log.rows.items[n + first_row];
                    const row = Column.Data{
                        .n = n + first_row + 1,
                        .pf = log_row.pf,
                        .cf = log_row.cf,
                    };

                    if (n >= format_from) {
                        var buf: Buf = undefined;
                        // 8 is a marker that the column does not need to reset attrs.
                        var attr_buf: AttrBuf = .{ @ptrFromInt(8), null };
                        const text = column.bind(&buf, &attr_buf, row);

                        // Avoid reformatting if text matches.
                        //
                        // It's fine for us, whereas pango will always reallocate and recompute layout.
                        const prev: [*:0]const u8 = c.pango_layout_get_text(layout);
                        if (!std.mem.eql(u8, text, std.mem.span(prev))) {
                            c.pango_layout_set_text(layout, text.ptr, @intCast(text.len));

                            // If it's null we still want to reset the attributes to fresh ones.
                            if (@intFromPtr(attr_buf[0]) != 8) {
                                const attrs = c.pango_attr_list_new().?;
                                c.pango_attr_list_insert(attrs, c.pango_attr_font_features_new("tnum"));
                                for (column.static_attrs) |a| if (a) |aa| {
                                    c.pango_attr_list_insert(attrs, c.pango_attribute_copy(aa));
                                } else break;
                                for (attr_buf) |a| if (a) |aa| c.pango_attr_list_insert(attrs, aa) else break;
                                c.pango_layout_set_attributes(layout, attrs);
                                c.pango_attr_list_unref(attrs);
                            }

                            // Force Pango to lay out our string here.
                            //
                            // Do it so all layout costs in profiling is accounted
                            // to this line, rather than being spread between the
                            // (conditional) get_pixel_size() and (unconditional)
                            // append_layout() below.
                            _ = c.pango_layout_get_lines_readonly(layout);
                        } else if (@intFromPtr(attr_buf[0]) > 8) {
                            for (attr_buf) |a| if (a) |aa| c.pango_attribute_destroy(aa) else break;
                        }
                    }

                    if (column.background(row)) |background| {
                        c.gtk_snapshot_append_color(snap, &background, &.{
                            .origin = .{ .x = 0, .y = 0 },
                            .size = .{
                                .width = @floatFromInt(column_w + x_padding * 2),
                                .height = @floatFromInt(row_h),
                            },
                        });
                    }

                    var w = column_w;
                    if (column.xalign != .left) {
                        c.pango_layout_get_pixel_size(layout, &w, null);
                        if (column.xalign == .center)
                            w = @divTrunc(column_w + w, 2);
                    }
                    const offset: f32 = @floatFromInt(column_w - w);
                    c.gtk_snapshot_translate(snap, &.{ .x = x_padding + offset, .y = y_padding });
                    c.gtk_snapshot_append_layout(snap, layout, &color);
                    c.gtk_snapshot_translate(snap, &.{ .x = -(x_padding + offset), .y = @floatFromInt(row_h - y_padding + 1) });
                    h += row_h + 1;

                    n += 1;
                }
                // std.log.debug("first row is {}, drew {}", .{ first_row, n });

                c.gtk_snapshot_translate(snap, &.{
                    .x = @floatFromInt(column_w + x_padding * 2),
                    .y = @floatFromInt(-h),
                });
            }

            // Draw horizontal lines.
            c.gtk_snapshot_translate(snap, &.{ .x = @floatFromInt(-total_w), .y = 0 });

            const base = header_h + y_offset - 1;
            for (1..n) |i| {
                c.gtk_snapshot_append_color(snap, &border_color, &.{
                    .origin = .{ .x = 0, .y = @floatFromInt(@as(i32, @intCast(i)) * (row_h + 1) + base) },
                    .size = .{ .width = @floatFromInt(total_w), .height = @floatFromInt(1) },
                });
            }

            self.first_row_is = first_row;
            self.last_row_is = first_row + n;
        }

        // Snapshot the header and the vertical lines.
        const style = c.gtk_widget_get_style_context(self.as(c.GtkWidget));
        c.gtk_snapshot_render_background(snap, style, 0, 0, total_w, header_h);
        c.gtk_snapshot_append_color(snap, &border_color, &.{
            .origin = .{ .x = 0, .y = @floatFromInt(header_h - 1) },
            .size = .{ .width = @floatFromInt(total_w), .height = 1 },
        });

        const view_height = @min(@max(h, header_h), full_height);
        for (0.., self.columns.?) |i, column| {
            const border: i32 = if (i > 0) 1 else 0;
            if (border == 1) {
                c.gtk_snapshot_append_color(snap, &border_color, &.{
                    .origin = .{ .x = 0, .y = 0 },
                    .size = .{ .width = 1, .height = @floatFromInt(view_height) },
                });
            }

            const column_w = column.width();
            const header_off = @divFloor(column_w - column.header_layout.?.w, 2);
            c.gtk_snapshot_translate(snap, &.{ .x = @floatFromInt(border + x_padding + header_off), .y = y_padding });
            c.gtk_snapshot_append_layout(snap, column.header_layout.?.layout, &color);
            c.gtk_snapshot_translate(snap, &.{ .x = @floatFromInt(-header_off + column_w + x_padding), .y = -y_padding });
        }
    }

    fn unroot(widget: ?*c.GtkWidget) callconv(.c) void {
        const self = downcast(widget.?);
        for (self.columns.?) |*column| column.destroyLayouts();
        self.first_row_is = 0;
        self.last_row_is = 0;

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

        g.as(c.GObjectClass, Class.parent_class).finalize.?(object);
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

    pub const Class = extern struct {
        parent: Parent,

        const Parent = c.GtkWidgetClass;
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
