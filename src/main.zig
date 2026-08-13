const std = @import("std");
const Io = std.Io;

const tas_log_reader = @import("tas_log_reader");
const TasLog = tas_log_reader.TasLog;
const Tracy = tas_log_reader.Tracy;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    for (args) |arg| {
        std.log.debug("arg: {s}", .{arg});
    }

    if (args.len != 2) {
        std.debug.print("usage: tas-log-reader <file>\n", .{});
        return error.InvalidArgs;
    }

    var fileZone = Tracy.zoneN(@src(), "open");
    errdefer fileZone.end();

    const file = try Io.Dir.cwd().openFile(io, args[1], .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(io);

    const size = try file.length(io);
    // std.log.debug("file size: {}", .{size});

    var mmap = try file.createMemoryMap(io, .{
        .len = size,
        .protection = .{ .read = true },
    });
    defer mmap.destroy(io);

    // const contents = try arena.alloc(u8, size);
    // @memcpy(contents, mmap.memory);

    fileZone.end();
    fileZone.active = 0;

    const start = Io.Clock.awake.now(io);
    var log = try TasLog.parse(init.gpa, mmap.memory);
    defer log.deinit();
    const took = start.untilNow(io, Io.Clock.awake);
    std.log.info("done! took {f}", .{took});

    const meta = &log.meta;
    std.log.debug("meta tool_ver=\"{?s}\", mod=\"{?s}\", build={?}", .{meta.tool_ver, meta.mod, meta.build});
}
