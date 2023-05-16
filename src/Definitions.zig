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
        if (parser.input[parser.index] == 0 and parser.index == parser.input.len) break;

        if (try parser.def()) {
            warned = false;
        } else {
            if (!warned) parser.warn("ignoring unexpected input", .{});
            parser.col += 1;
            parser.index += 1;
        }
    }
    return defs;
}

const Parser = struct {
    defs: *Definitions,
    string_buf: std.ArrayListUnmanaged(u8) = .{},
    inst_buf: std.ArrayListUnmanaged(Program.Instruction) = .{},
    input: [:0]const u8,
    index: usize = 0,
    line: usize = 1,
    col: usize = 1,
    arg_names: std.StringHashMapUnmanaged(void) = .{},
    gpa: Allocator,

    const invalid_args = std.math.maxInt(u32);

    fn init(gpa: Allocator, defs: *Definitions, input: [:0]const u8) Parser {
        return .{
            .defs = defs,
            .input = input,
            .gpa = gpa,
        };
    }

    fn deinit(p: *Parser) void {
        p.string_buf.deinit(p.gpa);
        p.inst_buf.deinit(p.gpa);
        p.arg_names.deinit(p.gpa);
        p.* = undefined;
    }

    fn skipWhitespace(p: *Parser) void {
        while (true) switch (p.input[p.index]) {
            '\n' => {
                p.col = 1;
                p.line += 1;
                p.index += 1;
            },
            ' ', '\t', '\r' => {
                p.col += 1;
                p.index += 1;
            },
            '#' => while (true) switch (p.input[p.index]) {
                0 => return,
                '\n' => {
                    p.col = 1;
                    p.line += 1;
                    p.index += 1;
                    break;
                },
                else => {
                    p.col += 1;
                    p.index += 1;
                },
            },
            else => return,
        };
    }

    fn warn(p: Parser, comptime fmt: []const u8, args: anytype) void {
        log.warn(fmt ++ " at line {d}, column {d}", args ++ .{ p.line, p.col });
    }

    fn skip(p: *Parser, s: []const u8) bool {
        if (!mem.startsWith(u8, p.input[p.index..], s))
            return false;
        p.index += s.len;
        p.col += s.len;
        return true;
    }

    fn def(p: *Parser) !bool {
        if (!p.skip("def")) return false;

        p.skipWhitespace();
        var opt_def_name = try p.str(.collect);
        var gop: @TypeOf(p.defs.rules).GetOrPutResult = undefined;
        if (opt_def_name) |def_name| {
            gop = try p.defs.rules.getOrPut(p.gpa, def_name);
            if (gop.found_existing) {
                p.warn("ignoring duplicate definition for '{s}'", .{def_name});
                opt_def_name = null;
            }
        } else {
            p.warn("ignoring unnamed definition", .{});
        }
        if (opt_def_name == null) p.arg_names.size = invalid_args;
        errdefer if (opt_def_name) |def_name| assert(p.defs.rules.remove(def_name));

        p.inst_buf.items.len = 0;
        var warned = false;
        while (true) {
            p.skipWhitespace();
            if (p.input[p.index] == 0 and p.index == p.input.len) {
                p.warn("unexpected EOF inside definition", .{});
                break;
            }
            if (p.skip("end")) break;
            if (try p.stmt()) continue;
            if (!warned) {
                warned = true;
                p.warn("ignoring unexpected statement", .{});
            }
            p.col += 1;
            p.index += 1;
        }
        if (opt_def_name == null) return true;

        try p.inst_buf.append(p.gpa, .end);
        const insts = try p.defs.arena.allocator().dupe(Program.Instruction, p.inst_buf.items);
        gop.value_ptr.* = .{ .body = insts.ptr };
        return true;
    }

    const ArgMode = enum { collect, check };

    fn str(p: *Parser, arg_mode: ArgMode) !?[]u8 {
        if (arg_mode == .collect) p.arg_names.clearRetainingCapacity();
        if (p.input[p.index] != '"') return null;

        const start = p.index + 1;
        var escape = true;
        p.string_buf.items.len = 0;
        while (true) {
            const c = p.input[p.index];
            if (c == 0) {
                p.warn("invalid null byte in string", .{});
                return null;
            }
            p.index += 1;
            if (escape) {
                escape = false;
            } else if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                break;
            }
        }

        const slice = p.input[start..p.index];
        var i: usize = 0;
        while (true) {
            switch (slice[i]) {
                '\\' => {
                    const escape_char_index = i + 1;
                    const result = std.zig.string_literal.parseEscapeSequence(slice, &i);
                    p.col += (i - escape_char_index) + 1;
                    switch (result) {
                        .success => |codepoint| {
                            if (slice[escape_char_index] == 'u') {
                                var buf: [4]u8 = undefined;
                                const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                                    p.warn("invalid unicode codepoint in escape sequence", .{});
                                    continue;
                                };
                                try p.string_buf.appendSlice(p.gpa, buf[0..len]);
                            } else {
                                try p.string_buf.append(p.gpa, @intCast(u8, codepoint));
                            }
                        },
                        .failure => {
                            p.warn("invalid escape sequence", .{});
                            continue;
                        },
                    }
                },
                '\n' => {
                    try p.string_buf.append(p.gpa, '\n');
                    p.line += 1;
                    p.col = 1;
                    i += 1;
                },
                '"' => break,
                '{', '}' => try p.strArg(slice, &i, arg_mode),
                else => |c| {
                    try p.string_buf.append(p.gpa, c);
                    p.col += 1;
                    i += 1;
                },
            }
        }
        return try p.defs.arena.allocator().dupe(u8, p.string_buf.items);
    }

    fn strArg(p: *Parser, slice: []const u8, offset: *usize, arg_mode: ArgMode) !void {
        const c = slice[offset.*];
        if (c == slice[offset.* + 1]) {
            try p.string_buf.appendNTimes(p.gpa, c, 2);
            p.col += 2;
            offset.* += 2;
            return;
        }
        if (c == '}') {
            p.warn("unescaped '}}' in string", .{});
            try p.string_buf.appendNTimes(p.gpa, c, 2);
            p.col += 1;
            offset.* += 1;
            return;
        }
        if (slice[offset.* + 1] != '%') {
            p.warn("expected '%' after '{{'", .{});
            try p.string_buf.appendNTimes(p.gpa, c, 2);
            p.col += 1;
            offset.* += 1;
            return;
        }
        offset.* += 2;
        const start = offset.*;
        while (true) switch (slice[offset.*]) {
            '0'...'9', 'a'...'z', 'A'...'Z' => {
                offset.* += 1;
                p.col += 1;
            },
            '}' => break,
            else => {
                p.warn("invalid character in argument name", .{});
                return;
            },
        };
        const arg_name = slice[start..offset.*];
        offset.* += 1;
        p.col += 1;

        if (arg_mode == .collect) {
            try p.arg_names.put(p.gpa, arg_name, {});
        } else if (p.arg_names.size != invalid_args and
            !p.arg_names.contains(arg_name))
        {
            p.warn("use of undefined argument '%{s}'", .{arg_name});
            try p.string_buf.appendSlice(p.gpa, "[UNDEFINED ARGUMENT %");
            try p.string_buf.appendSlice(p.gpa, arg_name);
            try p.string_buf.appendSlice(p.gpa, "]");
            return;
        }

        try p.string_buf.appendSlice(p.gpa, "{%");
        try p.string_buf.appendSlice(p.gpa, arg_name);
        try p.string_buf.append(p.gpa, '}');
    }

    fn arg(p: *Parser, arg_mode: ArgMode) !?[]const u8 {
        if (p.input[p.index] != '%') return null;
        p.col += 1;
        p.index += 1;

        const start = p.index;
        while (true) switch (p.input[p.index]) {
            '0'...'9', 'a'...'z', 'A'...'Z' => {
                p.col += 1;
                p.index += 1;
            },
            else => break,
        };
        if (start == p.index) {
            p.warn("expected argument name after '%'", .{});
            return null;
        }
        const arg_name = p.input[start..p.index];
        if (arg_mode == .collect) {
            try p.arg_names.put(p.gpa, arg_name, {});
        } else if (p.arg_names.size != invalid_args and
            !p.arg_names.contains(arg_name))
        {
            p.warn("use of undefined argument '%{s}'", .{arg_name});
            return null;
        }
        return try p.defs.arena.allocator().dupe(u8, arg_name);
    }

    fn stmt(p: *Parser) !bool {
        if (p.skip("set")) {
            p.skipWhitespace();
            const dest = try p.arg(.collect);
            _ = dest;
            p.skipWhitespace();
            if (!p.skip("to")) {
                p.warn("expected 'to' after argument to set", .{});
            }
            p.skipWhitespace();
            const val = try p.expr();
            _ = val;
            return true;
        } else if (p.skip("if")) {
            // TODO
            return true;
        } else if (try p.str(.check)) |some| {
            try p.inst_buf.append(p.gpa, .{ .str = some });
            return true;
        } else {
            return false;
        }
    }

    fn expr(p: *Parser) !?Program.Instruction {
        if (p.skip("true")) {
            return .{ .bool = true };
        } else if (p.skip("false")) {
            return .{ .bool = false };
        } else if (try p.str(.check)) |some| {
            return .{ .str = some };
        } else if (try p.arg(.check)) |some| {
            return .{ .arg = some };
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
