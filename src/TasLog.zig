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
                freeAllocated(allocator, name_token);

                if (std.mem.eql(u8, "pf", field_name)) {
                    // Reached the main array, we're done here.
                    break;
                }

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
    cf: []CommandFrame,
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
    pview: [3]f32 = .{0, 0, 0},
    prepm: ?PmState = null,
    postpm: ?PmState = null,
};

pub const PmState = struct {
    pos: [3]f32,
    vel: [3]f32,
    og: bool,
    ol: bool = false,
    bvel: [3]f32 = .{0, 0, 0},
    wlvl: i32 = 0,
    dst: u8 = 0,
};

pub fn parse(gpa: Allocator, contents: []const u8) ParseError(Scanner)!TasLog {
    const zone = Tracy.zone(@src());
    defer zone.end();

    var rv: TasLog = .{
        .meta = undefined,
        .pf = .empty,
        .arena = ArenaAllocator.init(gpa),
    };
    errdefer rv.deinit();

    const arena = rv.arena.allocator();

    var scanner = Scanner.initCompleteInput(arena, contents);
    defer scanner.deinit();

    const options: std.json.ParseOptions = .{
        // .ignore_unknown_fields = true,
        .max_value_len = scanner.input.len,
        .allocate = .alloc_if_needed,
    };

    if (.object_begin != try scanner.next()) return error.UnexpectedToken;
    rv.meta = try TasLog.Meta.parse(arena, &scanner, options);

    if (.array_begin != try scanner.next()) return error.UnexpectedToken;

    while (true) {
        if (scanner.peekNextTokenType()) |next| switch (next) {
            .array_end => break,
            .object_begin => {},
            else => return error.UnexpectedToken,
        } else |err| {
            // End of input is fine when the log terminates before completion.
            if (err != error.UnexpectedEndOfInput) {
                return err;
            }
            break;
        }

        const pf = std.json.innerParse(TasLog.PhysicsFrame, arena, &scanner, options) catch |err| {
            if (err != error.UnexpectedEndOfInput) {
                return err;
            }
            break;
        };
        try rv.pf.append(gpa, pf);
    }

    return rv;
}

pub fn deinit(self: *TasLog) void {
    const gpa = self.arena.child_allocator;
    self.arena.deinit();
    self.pf.deinit(gpa);
}

fn freeAllocated(allocator: Allocator, token: Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}
