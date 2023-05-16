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
    var parser = Parser.init(gpa, &defs, input);
    defer parser.deinit();

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
    arg_names: std.ArrayList([]const u8),

    const invalid_args = std.math.maxInt(usize);

    fn init(gpa: Allocator, defs: *Definitions, input: [:0]const u8) Parser {
        return .{
            .defs = defs,
            .string_buf = std.ArrayList(u8).init(gpa),
            .inst_buf = std.ArrayList(Program.Instruction).init(gpa),
            .input = input,
            .arg_names = std.ArrayList([]const u8).init(gpa),
        };
    }

    fn deinit(parser: *Parser) void {
        parser.string_buf.deinit();
        parser.inst_buf.deinit();
        parser.arg_names.deinit();
        parser.* = undefined;
    }

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
        var opt_def_name = try parser.str(.collect);
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
        if (opt_def_name == null) parser.arg_names.items.len = invalid_args;
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

    const ArgMode = enum { collect, check, ignore };

    fn str(parser: *Parser, arg_mode: ArgMode) !?[]u8 {
        if (arg_mode == .collect) parser.arg_names.items.len = 0;
        const start = parser.i + 1;
        if (parser.input[parser.i] != '"') return null;
        var escape = true;
        parser.string_buf.items.len = 0;
        while (true) {
            const c = parser.input[parser.i];
            if (c == 0) {
                parser.warn("invalid null byte in string", .{});
                return null;
            }
            parser.i += 1;
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                break;
            }
        }
        const slice = parser.input[start..parser.i];
        var i: usize = 0;
        while (true) {
            const c = slice[i];
            switch (c) {
                '\\' => {
                    const escape_char_index = i + 1;
                    const result = std.zig.string_literal.parseEscapeSequence(slice, &i);
                    parser.col += (i - escape_char_index) + 1;
                    switch (result) {
                        .success => |codepoint| {
                            if (slice[escape_char_index] == 'u') {
                                var buf: [4]u8 = undefined;
                                const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                                    parser.warn("invalid unicode codepoint in escape sequence", .{});
                                    continue;
                                };
                                try parser.string_buf.appendSlice(buf[0..len]);
                            } else {
                                try parser.string_buf.append(@intCast(u8, codepoint));
                            }
                        },
                        .failure => {
                            parser.warn("invalid escape sequence", .{});
                            continue;
                        },
                    }
                },
                '\n' => {
                    try parser.string_buf.append(c);
                    parser.line += 1;
                    parser.col = 1;
                    i += 1;
                },
                '"' => break,
                '{', '}' => try parser.strArg(slice, &i, arg_mode),
                else => {
                    try parser.string_buf.append(c);
                    parser.col += 1;
                    i += 1;
                },
            }
        }
        return try parser.defs.arena.allocator().dupe(u8, parser.string_buf.items);
    }

    fn strArg(parser: *Parser, slice: []const u8, offset: *usize, arg_mode: ArgMode) !void {
        const c = slice[offset.*];
        if (arg_mode == .ignore) {
            try parser.string_buf.append(c);
            parser.col += 1;
            offset.* += 1;
            return;
        }
        if (c == slice[offset.* + 1]) {
            try parser.string_buf.appendNTimes(c, 2);
            parser.col += 2;
            offset.* += 2;
            return;
        }
        if (c == '}') {
            parser.warn("unescaped '}}' in string", .{});
            try parser.string_buf.appendNTimes(c, 2);
            parser.col += 1;
            offset.* += 1;
            return;
        }
        if (slice[offset.* + 1] != '%') {
            parser.warn("expected '%' after '{{'", .{});
            try parser.string_buf.appendNTimes(c, 2);
            parser.col += 1;
            offset.* += 1;
            return;
        }
        offset.* += 2;
        const start = offset.*;
        while (true) switch (slice[offset.*]) {
            '0'...'9', 'a'...'z', 'A'...'Z' => {
                offset.* += 1;
                parser.col += 1;
            },
            '}' => break,
            else => {
                parser.warn("invalid character in argument name", .{});
                return;
            },
        };
        const arg_name = slice[start..offset.*];
        offset.* += 1;
        parser.col += 1;

        if (arg_mode == .collect) {
            try parser.arg_names.append(arg_name);
        } else if (parser.arg_names.items.len != invalid_args) {
            for (parser.arg_names.items) |item| {
                if (mem.eql(u8, item, arg_name)) break;
            } else {
                parser.warn("use of undefined argument '%{s}'", .{arg_name});
                try parser.string_buf.appendSlice("[UNDEFINED ARGUMENT %");
                try parser.string_buf.appendSlice(arg_name);
                try parser.string_buf.appendSlice("]");
                return;
            }
        }

        try parser.string_buf.appendSlice("{%");
        try parser.string_buf.appendSlice(arg_name);
        try parser.string_buf.append('}');
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
        const arg_name = parser.input[start..parser.i];
        if (parser.arg_names.items.len != invalid_args) {
            for (parser.arg_names.items) |item| {
                if (mem.eql(u8, item, arg_name)) break;
            } else {
                parser.warn("use of undefined argument '%{s}'", .{arg_name});
                return null;
            }
        }
        return try parser.defs.arena.allocator().dupe(u8, arg_name);
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
        } else if (try parser.str(.check)) |some| {
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
        } else if (try parser.str(.ignore)) |some| {
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
