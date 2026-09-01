const std = @import("std");

const tas_log_reader = @import("tas_log_reader");
const LoadedLog = tas_log_reader.LoadedLog;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const path = args.next() orelse return error.NoArgument;

    var log: LoadedLog = undefined;
    try log.init(io, gpa, path);
    defer log.deinit(io);

    std.mem.doNotOptimizeAway(log);
}
