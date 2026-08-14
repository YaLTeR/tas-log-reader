const std = @import("std");
const SourceLocation = std.builtin.SourceLocation;
const build_options = @import("build_options");

const enable = build_options.tracy_enable;
const on_demand = build_options.tracy_on_demand;

// FIXME: in Zig 0.17.0 the void field ABI should be fixed.
// Switch to u64/void conditional field.
const ___tracy_c_zone_context = if (on_demand) extern struct {
    id: u32,
    active: i32,
    connectionId: u64,

    pub inline fn end(self: @This()) void {
        ___tracy_emit_zone_end(self);
    }
} else extern struct {
    id: u32,
    active: i32,

    pub inline fn end(self: @This()) void {
        ___tracy_emit_zone_end(self);
    }
};

pub const Zone = if (enable) ___tracy_c_zone_context else struct {
    pub inline fn end(self: @This()) void {
        _ = self;
    }
};

pub inline fn zone(comptime src: SourceLocation) Zone {
    if (!enable) return .{};

    const global = struct {
        const loc: ___tracy_source_location_data = .{
            .name = null,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .color = 0,
        };
    };

    return ___tracy_emit_zone_begin(&global.loc, 1);
}

pub inline fn zoneN(comptime src: SourceLocation, comptime name: [:0]const u8) Zone {
    if (!enable) return .{};

    const global = struct {
        const loc: ___tracy_source_location_data = .{
            .name = name,
            .function = src.fn_name,
            .file = src.file,
            .line = src.line,
            .color = 0,
        };
    };

    return ___tracy_emit_zone_begin(&global.loc, 1);
}

const ___tracy_source_location_data = extern struct {
    name: ?[*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32,
};

extern fn ___tracy_emit_zone_begin(srcloc: *const ___tracy_source_location_data, active: i32) ___tracy_c_zone_context;
extern fn ___tracy_emit_zone_end(ctx: ___tracy_c_zone_context) void;
