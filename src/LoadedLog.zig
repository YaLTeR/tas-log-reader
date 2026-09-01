const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const root = @import("root.zig");
const Tracy = root.Tracy;
const TasLog = root.TasLog;

const LoadedLog = @This();

contents: []const u8,
log: TasLog,
rows: ArrayList(Row),

const Row = struct {
    pf: *const TasLog.PhysicsFrame,
    cf: ?*const TasLog.CommandFrame,
};

pub fn init(self: *LoadedLog, gpa: Allocator, contents: []const u8) !void {
    const zone = Tracy.zoneN(@src(), "Log::init");
    defer zone.end();

    self.* = .{
        .contents = contents,
        .log = undefined,
        .rows = .empty,
    };
    try self.log.parse(gpa, contents);

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

pub fn deinit(self: *LoadedLog) void {
    const zone = Tracy.zoneN(@src(), "Log::deinit");
    defer zone.end();

    const gpa = self.log.arena.child_allocator;
    self.rows.deinit(gpa);
    self.log.deinit();

    self.* = undefined;
}
