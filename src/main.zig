const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const c = @import("c");
const g = @import("gobject.zig");

pub const checks = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseSmall, .ReleaseFast => false,
};

// While it is possible to pass these via boxed properties,
// it's quite annoying and not really needed.
pub var gpa: std.mem.Allocator = undefined;
pub var io: std.Io = undefined;

const tas_log_reader = @import("tas_log_reader");
const TasLog = tas_log_reader.TasLog;
pub const Tracy = tas_log_reader.Tracy;

const TlrApplication = @import("Application.zig").TlrApplication;

pub fn main(init: std.process.Init.Minimal) u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const use_debug_allocator = builtin.mode == .Debug;
    gpa = if (use_debug_allocator) debug_allocator.allocator() else std.heap.c_allocator;
    defer if (use_debug_allocator) {
        _ = debug_allocator.deinit();
    };

    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(.{ .vector = init.args.vector }),
        .environ = .{ .block = init.environ.block },
    });
    defer threaded.deinit();
    io = threaded.io();

    TlrApplication.register();
    const app = TlrApplication.new();
    defer c.g_object_unref(app);

    return @intCast(app.run(init.args));
}
