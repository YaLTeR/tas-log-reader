const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const root = @import("root.zig");
const Tracy = root.Tracy;
const TasLog = root.TasLog;

const LoadedLog = @This();

buf: []u8,
log: TasLog,
rows: ArrayList(Row),

const Row = struct {
    pf: *const TasLog.PhysicsFrame,
    cf: ?*const TasLog.CommandFrame,
};

pub fn init(self: *LoadedLog, io: Io, gpa: Allocator, path: []const u8) !void {
    const zone = Tracy.zoneN(@src(), "Log::init");
    defer zone.end();

    const file = try Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(io);

    const size = try file.length(io);
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);

    const n = try file.readPositionalAll(io, buf, 0);
    if (n != size) return error.UnexpectedEndOfFile;

    self.* = .{
        .buf = buf,
        .log = undefined,
        .rows = .empty,
    };
    try self.log.parse(gpa, buf);

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
    gpa.free(self.buf);

    self.* = undefined;
}
