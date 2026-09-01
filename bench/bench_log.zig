const std = @import("std");

const tas_log_reader = @import("tas_log_reader");
const LoadedLog = tas_log_reader.LoadedLog;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const path = args.next() orelse return error.NoArgument;

    const buf = try readContents(gpa, io, path);
    defer gpa.free(buf);

    var log: LoadedLog = undefined;
    try log.init(gpa, buf);
    defer log.deinit();

    std.mem.doNotOptimizeAway(log);
}

fn readContents(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(io);

    const size = try file.length(io);
    const buf = try gpa.alloc(u8, size);
    errdefer gpa.free(buf);

    const n = try file.readPositionalAll(io, buf, 0);
    if (n != size) return error.UnexpectedEndOfFile;

    return buf;
}
