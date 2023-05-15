const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;
const log = std.log.scoped(.i18n);
const math = std.math;
const mem = std.mem;

const Definitions = @This();

rules: std.StringHashMapUnmanaged(Program) = .{},
arena: ArenaAllocator,

pub fn init(gpa: Allocator) Definitions {
    return .{ .arena = ArenaAllocator.init(gpa) };
}

pub fn deinit(defs: *Definitions) void {
    defs.rules.deinit(defs.arena.child_allocator);
    defs.arena.deinit();
    defs.* = undefined;
}

pub const Program = struct {
    body: [*]const Instruction,

    pub const Instruction = union(enum) {
        end,
        set: *Set,
        @"if": *If,
        str: []const u8,
        arg: []const u8,

        eq: *Bin,
        neq: *Bin,
        lt: *Bin,
        lte: *Bin,
        gt: *Bin,
        gte: *Bin,

        @"and": *Bin,
        @"or": *Bin,
        not: *Instruction,

        pub const Set = struct {
            arg: []const u8,
            rhs: Instruction,
        };

        pub const If = struct {
            cond: Instruction,
            then: [*]const Instruction,
            @"else": [*]const Instruction,
        };

        pub const Bin = struct {
            lhs: Instruction,
            rhs: Instruction,
        };
    };
};

pub fn parse(gpa: Allocator, input: [:0]const u8) !Definitions {
    var defs = Definitions.init(gpa);
    errdefer defs.deinit();
    var parser = Parser{
        .defs = &defs,
        .string_buf = std.ArrayList(u8).init(gpa),
        .inst_buf = std.ArrayList(Program.Inst).init(gpa),
        .input = input,
    };
    defer parser.string_buf.deinit();
    defer parser.inst_buf.deinit();

    var warned = false;
    while (true) {
        parser.skipWhitespace();
        if (parser.input[parser.i] == 0 and parser.i == parser.input.len) break;

        if (parser.def()) {
            warned = false;
        } else {
            if (!warned) parser.warn("ignoring unexpected input", .{});
            parser.col += 1;
            parser.i += 1;
        }
    }
}

const Parser = struct {
    defs: *Definitions,
    string_buf: std.ArrayList(u8),
    inst_buf: std.ArrayList(Program.Inst),
    input: [:0]const u8,
    i: usize = 0,
    line: usize = 1,
    col: usize = 1,

    fn skipWhitespace(parser: *Parser) void {
        while (true) switch (parser.input[parser.i]) {
            '\n' => {
                parser.col = 1;
                parser.line += 1;
                parser.i += 1;
            },
            ' ', '\t', '\r' => {
                parser.col += 1;
                parser.i += 1;
            },
            '#' => while (true) switch (parser.input[parser.i]) {
                0 => return,
                '\n' => {
                    parser.col = 1;
                    parser.line += 1;
                    parser.i += 1;
                    break;
                },
                else => {},
            },
            else => return,
        };
    }

    fn warn(parser: Parser, comptime fmt: []const u8, args: anytype) void {
        log.warn(fmt ++ " at line {d}, column {d}", args ++ .{ parser.line, parser.col });
    }

    fn skip(parser: *Parser, s: []const u8) bool {
        if (!mem.startsWith(u8, parser.input[parser.i..], s))
            return false;
        parser.i += s.len;
        parser.col += s.len;
        return true;
    }

    fn def(parser: *Parser) !bool {
        if (!parser.skip("def")) return false;

        parser.skipWhitespace();
        var opt_def_name = try parser.str();
        var gop: @TypeOf(parser.defs.rules).GetOrPutResult = undefined;
        if (opt_def_name) |def_name| {
            gop = try parser.defs.rules.getOrPut(parser.inst_buf.allocator, def_name);
            if (gop.found_existing) {
                parser.warn("ignoring duplicate definition for '{s}'", .{def_name});
                opt_def_name = null;
            }
        } else {
            try parser.warn("ignoring unnamed definition", .{});
        }
        errdefer if (opt_def_name) |def_name| parser.defs.rules.remove(def_name);

        parser.inst_buf.len = 0;
        while (!parser.skip("end")) {
            parser.skipWhitespace();
            if (parser.input[parser.i] == 0 and parser.i == parser.input.len) {
                parser.warn("unexpected EOF inside definition", .{});
                break;
            }
            try parser.inst();
        }
        if (opt_def_name == null) return;

        try parser.inst_buf.append(.end);
        gop.value_ptr.* = try parser.defs.arena.allocator().dupe(Program.Inst, parser.inst_buf.items);
    }

    fn str(parser: *Parser) !?[]u8 {
        if (parser.input[parser.i] != '"') return null;
        // TODO
        return "";
    }

    fn inst(parser: *Parser) !void {
        _ = parser;
        // TODO
    }
};
