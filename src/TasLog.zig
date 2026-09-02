const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const json = std.json;
const Scanner = json.Scanner;
const ParseError = json.ParseError;
const ParseOptions = json.ParseOptions;
const Token = json.Token;

const Tracy = @import("root.zig").Tracy;

const TasLog = @This();

meta: Meta,
pf: ArrayList(PhysicsFrame),
cf: ArrayList(CommandFrame),
rows: ArrayList(Row),
arena: ArenaAllocator,

pub const Meta = struct {
    tool_ver: ?[]const u8 = null,
    mod: ?[]const u8 = null,
    build: ?u32 = null,

    pub fn parse(allocator: Allocator, source: *Scanner, options: ParseOptions) ParseError(Scanner)!@This() {
        var rv: @This() = .{};

        while (true) {
            const name_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            const field_name = switch (name_token) {
                inline .string, .allocated_string => |slice| slice,
                .object_end => break, // Not really expected here but can happen I guess.
                else => return error.UnexpectedToken,
            };

            inline for (@typeInfo(@This()).@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    freeAllocated(allocator, name_token);
                    @field(rv, field.name) = try json.innerParse(field.type, allocator, source, options);
                    break;
                }
            } else {
                // Didn't match anything.
                if (std.mem.eql(u8, "pf", field_name)) {
                    // Reached the main array, we're done here.
                    freeAllocated(allocator, name_token);
                    break;
                }
                freeAllocated(allocator, name_token);

                try source.skipValue();
            }
        }

        return rv;
    }
};

pub const PhysicsFrame = struct {
    ft: ?f64 = null,
    cls: i32 = 5,
    p: bool = false,
    rng: ?Rng = null,
    cbuf: ?[]const u8 = null,
    cfi: ?u32 = null,
    cmsg: ?[][]const u8 = null,
};

pub const Rng = struct {
    idum: i32,
};

pub const CommandFrame = struct {
    bid: ?usize = null,
    rem: ?f64 = null,
    ms: u8,
    btns: u16,
    impls: ?u8 = null,
    fsu: [3]f32,
    view: [3]f32,
    ss: u32,
    hp: ?f32 = null,
    ap: ?f32 = null,
    efric: f32 = 1,
    egrav: f32 = 1,
    pview: [3]f32 = .{ 0, 0, 0 },
    prepm: ?PmState = null,
    postpm: ?PmState = null,
};

pub const PmState = struct {
    pos: [3]f32,
    vel: [3]f32,
    og: bool,
    ol: bool = false,
    bvel: [3]f32 = .{ 0, 0, 0 },
    wlvl: i32 = 0,
    dst: u8 = 0,
};

pub const Row = struct {
    pfi: u32,
    // Command frame number (add to pf.cfi).
    cfn: u32,
};

const Parser = struct {
    log: *TasLog,
    scanner: *Scanner,

    fn arena(self: *Parser) Allocator {
        return self.log.arena.allocator();
    }

    fn gpa(self: *Parser) Allocator {
        return self.log.arena.child_allocator;
    }

    fn options(self: *Parser) ParseOptions {
        return .{
            .ignore_unknown_fields = true,
            .max_value_len = self.scanner.input.len,
            .allocate = .alloc_if_needed,
        };
    }

    fn parse(self: *Parser) ParseError(Scanner)!void {
        if (.object_begin != try self.scanner.next()) return error.UnexpectedToken;
        self.log.meta = try TasLog.Meta.parse(self.arena(), self.scanner, self.options());

        self.parsePhysicsFrames() catch |err| {
            // End of input is fine when the log terminates before completion.
            if (err != error.UnexpectedEndOfInput) return err;
        };
    }

    fn parsePhysicsFrames(self: *Parser) ParseError(Scanner)!void {
        if (.array_begin != try self.scanner.next()) return error.UnexpectedToken;

        while (true) {
            switch (try self.scanner.next()) {
                .array_end => break,
                .object_begin => {},
                else => return error.UnexpectedToken,
            }

            try self.parsePhysicsFrame();
        }
    }

    fn parsePhysicsFrame(self: *Parser) ParseError(Scanner)!void {
        const arena_ = self.arena();
        const scanner = self.scanner;
        const options_ = self.options();
        const gpa_ = self.gpa();

        const cf_start = self.log.cf.items.len;
        // On error, roll back partially parsed command frames.
        errdefer self.log.cf.shrinkRetainingCapacity(cf_start);

        var pf = PhysicsFrame{};
        while (true) {
            const name_token = try scanner.nextAllocMax(arena_, .alloc_if_needed, options_.max_value_len.?);
            const field_name = switch (name_token) {
                inline .string, .allocated_string => |slice| slice,
                .object_end => break,
                else => return error.UnexpectedToken,
            };

            inline for (@typeInfo(PhysicsFrame).@"struct".fields) |field| {
                // cfi is not a field from the JSON representation.
                comptime if (std.mem.eql(u8, field.name, "cfi")) {
                    continue;
                };

                if (std.mem.eql(u8, field.name, field_name)) {
                    freeAllocated(arena_, name_token);
                    @field(pf, field.name) = try json.innerParse(field.type, arena_, scanner, options_);
                    break;
                }
            } else {
                // Didn't match any struct field.
                if (std.mem.eql(u8, "cf", field_name)) {
                    freeAllocated(arena_, name_token);

                    // Parse command frames array.
                    if (try scanner.next() != .array_begin) return error.UnexpectedToken;

                    while (true) {
                        switch (try scanner.peekNextTokenType()) {
                            .array_end => break,
                            .object_begin => {},
                            else => return error.UnexpectedToken,
                        }

                        try self.parseCommandFrame();
                    }

                    // Consume .array_end.
                    _ = try scanner.next();
                } else {
                    // Unknown field name.
                    freeAllocated(arena_, name_token);
                    try scanner.skipValue();
                }
            }
        }

        // Now that we successfully parsed a full pf, commit it to memory.
        const cf_count = self.log.cf.items.len - cf_start;

        try self.log.pf.ensureUnusedCapacity(gpa_, 1);
        try self.log.rows.ensureUnusedCapacity(gpa_, @max(1, cf_count));

        const pfi: u32 = @intCast(self.log.pf.items.len);

        // Create a row if there were no command frames.
        if (cf_count == 0) {
            self.log.rows.appendAssumeCapacity(Row{ .pfi = pfi, .cfn = 0 });
        } else {
            pf.cfi = @intCast(cf_start);

            for (0..cf_count) |cfn| {
                self.log.rows.appendAssumeCapacity(Row{ .pfi = pfi, .cfn = @intCast(cfn) });
            }
        }

        self.log.pf.appendAssumeCapacity(pf);
    }

    fn parseCommandFrame(self: *Parser) ParseError(Scanner)!void {
        try self.log.cf.ensureUnusedCapacity(self.gpa(), 1);
        const cf = try std.json.innerParse(TasLog.CommandFrame, self.arena(), self.scanner, self.options());
        self.log.cf.appendAssumeCapacity(cf);
    }
};

pub fn parse(rv: *TasLog, gpa: Allocator, contents: []const u8) ParseError(Scanner)!void {
    const zone = Tracy.zoneN(@src(), "TasLog::parse");
    defer zone.end();

    rv.* = .{
        .meta = undefined,
        .pf = .empty,
        .cf = .empty,
        .rows = .empty,
        .arena = ArenaAllocator.init(gpa),
    };
    errdefer rv.deinit();

    const arena = rv.arena.allocator();

    var scanner = Scanner.initCompleteInput(arena, contents);
    defer scanner.deinit();

    var parser = Parser{
        .log = rv,
        .scanner = &scanner,
    };
    try parser.parse();
}

pub fn deinit(self: *TasLog) void {
    const gpa = self.arena.child_allocator;
    self.arena.deinit();
    self.pf.deinit(gpa);
    self.cf.deinit(gpa);
    self.rows.deinit(gpa);
    self.* = undefined;
}

fn freeAllocated(allocator: Allocator, token: Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}

fn verifyInvariants(self: *TasLog) !void {
    for (self.rows.items) |row| {
        try std.testing.expect(row.pfi < self.pf.items.len);

        const pf = self.pf.items[row.pfi];
        if (pf.cfi) |cfi| {
            try std.testing.expect(cfi + row.cfn < self.cf.items.len);
        } else {
            try std.testing.expectEqual(0, row.cfn);
        }
    }
}

test "incomplete command frame rolls back its physics frame" {
    const contents =
        \\{"pf":[{"cf":[{"ms":1,"btns":0,"fsu":[0,0,0],"view":[0,0,0],"ss":1}]},
        \\  {"cf":[{"ms":1,"btns":0,"fsu":[0,0,0],"view":[0,0,0],"ss":1},{"ms":
    ;

    var log: TasLog = undefined;
    try log.parse(std.testing.allocator, contents);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 1), log.pf.items.len);
    try std.testing.expectEqual(@as(usize, 1), log.cf.items.len);
    try std.testing.expectEqual(@as(usize, 1), log.rows.items.len);
    try log.verifyInvariants();
}

test "incomplete later field rolls back command frames" {
    const contents =
        \\{"pf":[{"cf":[{"ms":1,"btns":0,"fsu":[0,0,0],"view":[0,0,0],"ss":1}]},
        \\  {"cf":[{"ms":1,"btns":0,"fsu":[0,0,0],"view":[0,0,0],"ss":1}],"cmsg":["unterminated
    ;

    var log: TasLog = undefined;
    try log.parse(std.testing.allocator, contents);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 1), log.pf.items.len);
    try std.testing.expectEqual(@as(usize, 1), log.cf.items.len);
    try std.testing.expectEqual(@as(usize, 1), log.rows.items.len);
    try log.verifyInvariants();
}

test "rows index command frames" {
    const contents =
        \\{"pf":[{"cf":[
        \\  {"ms":1,"btns":0,"fsu":[0,0,0],"view":[0,0,0],"ss":1},
        \\  {"ms":1,"btns":0,"fsu":[0,0,0],"view":[0,0,0],"ss":1}
        \\]},{"cf":[]}]}
    ;

    var log: TasLog = undefined;
    try log.parse(std.testing.allocator, contents);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 2), log.pf.items.len);
    try std.testing.expectEqual(@as(usize, 2), log.cf.items.len);
    try std.testing.expectEqual(@as(usize, 3), log.rows.items.len);
    try std.testing.expectEqual(Row{ .pfi = 0, .cfn = 0 }, log.rows.items[0]);
    try std.testing.expectEqual(Row{ .pfi = 0, .cfn = 1 }, log.rows.items[1]);
    try std.testing.expectEqual(Row{ .pfi = 1, .cfn = 0 }, log.rows.items[2]);
    try log.verifyInvariants();
}

test "fuzz" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    var buf: [1024]u8 = undefined;
    const contents = buf[0..smith.slice(&buf)];

    var log: TasLog = undefined;
    log.parse(std.testing.allocator, contents) catch return;
    defer log.deinit();
    try log.verifyInvariants();
}
