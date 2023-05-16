const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
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
        arg: []const u8,
        str: []const u8,
        bool: bool,
        int: i64,
        float: f64,

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
        .inst_buf = std.ArrayList(Program.Instruction).init(gpa),
        .input = input,
    };
    defer parser.string_buf.deinit();
    defer parser.inst_buf.deinit();

    var warned = false;
    while (true) {
        parser.skipWhitespace();
        if (parser.input[parser.i] == 0 and parser.i == parser.input.len) break;

        if (try parser.def()) {
            warned = false;
        } else {
            if (!warned) parser.warn("ignoring unexpected input", .{});
            parser.col += 1;
            parser.i += 1;
        }
    }
    return defs;
}

const Parser = struct {
    defs: *Definitions,
    string_buf: std.ArrayList(u8),
    inst_buf: std.ArrayList(Program.Instruction),
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
                else => {
                    parser.col += 1;
                    parser.i += 1;
                },
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
            parser.warn("ignoring unnamed definition", .{});
        }
        errdefer if (opt_def_name) |def_name| assert(parser.defs.rules.remove(def_name));

        parser.inst_buf.items.len = 0;
        var warned = false;
        while (true) {
            parser.skipWhitespace();
            if (parser.input[parser.i] == 0 and parser.i == parser.input.len) {
                parser.warn("unexpected EOF inside definition", .{});
                break;
            }
            if (parser.skip("end")) break;
            if (try parser.stmt()) continue;
            if (!warned) {
                warned = true;
                parser.warn("ignoring unexpected statement", .{});
            }
            parser.col += 1;
            parser.i += 1;
        }
        if (opt_def_name == null) return true;

        try parser.inst_buf.append(.end);
        const insts = try parser.defs.arena.allocator().dupe(Program.Instruction, parser.inst_buf.items);
        gop.value_ptr.* = .{ .body = insts.ptr };
        return true;
    }

    fn str(parser: *Parser) !?[]u8 {
        const start = parser.i;
        if (parser.input[parser.i] != '"') return null;
        var escape = true;
        while (true) {
            const c = parser.input[parser.i];
            parser.i += 1;
            parser.col += 1;
            if (c == 0) {
                parser.warn("invalid null byte in string", .{});
                return null;
            }
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                break;
            }
        }
        const slice = parser.input[start..parser.i];
        parser.string_buf.items.len = 0;
        const res = try std.zig.string_literal.parseWrite(parser.string_buf.writer(), slice);
        if (res != .success) parser.warn("invalid string '{s}'", .{slice});
        return try parser.defs.arena.allocator().dupe(u8, parser.string_buf.items);
    }

    fn arg(parser: *Parser) !?[]const u8 {
        if (parser.skip("%")) return null;
        const start = parser.i;
        while (true) switch (parser.input[parser.i]) {
            '0'...'9', 'a'...'z', 'A'...'Z' => {
                parser.col += 1;
                parser.i += 1;
            },
            else => break,
        };
        if (start == parser.i) {
            parser.warn("expected argument name after '%'", .{});
            return null;
        }
        return parser.input[start..parser.i];
    }

    fn stmt(parser: *Parser) !bool {
        if (parser.skip("set")) {
            parser.skipWhitespace();
            const dest = try parser.arg();
            _ = dest;
            parser.skipWhitespace();
            if (!parser.skip("to")) {
                parser.warn("expected 'to' after argument to set", .{});
            }
            parser.skipWhitespace();
            const val = try parser.expr();
            _ = val;
            return true;
        } else if (parser.skip("if")) {
            // TODO
            return true;
        } else if (try parser.str()) |some| {
            try parser.inst_buf.append(.{ .str = some });
            return true;
        } else {
            return false;
        }
    }

    fn expr(parser: *Parser) !?Program.Instruction {
        if (parser.skip("true")) {
            return .{ .bool = true };
        } else if (parser.skip("false")) {
            return .{ .bool = false };
        } else if (try parser.str()) |some| {
            return .{ .str = some };
        } else {
            // TODO numbers
            return null;
        }
    }
};

test "parsing a simple definition" {
    const input =
        \\# Comment explaining something about this translation
        \\def "Hello {%0}!"
        \\    "Moikka {%0}!"
        \\end
        \\
    ;
    var defs = try parse(std.testing.allocator, input);
    defer defs.deinit();

    try expect(defs.rules.count() == 1);
    const rule = defs.rules.get("Hello {%0}!");
    try expect(rule != null);
    const body = rule.?.body;
    try expect(body[0] == .str);
    try expectEqualStrings("Moikka {%0}!", body[0].str);
    try expect(body[1] == .end);
}
