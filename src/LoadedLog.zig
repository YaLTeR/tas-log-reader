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

// Borrows from contents. Contents must be kept alive until deinit().
pub fn init(self: *LoadedLog, gpa: Allocator, contents: []const u8) !void {
    self.* = .{
        .contents = contents,
        .log = undefined,
    };
    return self.log.parse(gpa, contents);
}

pub fn deinit(self: *LoadedLog) void {
    self.log.deinit();
    self.* = undefined;
}
