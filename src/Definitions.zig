const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const log = std.log.scoped(.i18n);
const math = std.math;
const mem = std.mem;

const Definitions = @This();

rules: std.StringHashMapUnmanaged(u32) = .{},
insts: std.MultiArrayList(Inst) = .{},
extra: std.ArrayListUnmanaged(u32) = .{},
strings: std.ArrayListUnmanaged(u8) = .{},

pub fn deinit(defs: *Definitions, gpa: Allocator) void {
    var it = defs.rules.keyIterator();
    while (it.next()) |some| gpa.free(some.*);
    defs.rules.deinit(gpa);
    defs.insts.deinit(gpa);
    defs.extra.deinit(gpa);
    defs.strings.deinit(gpa);
    defs.* = undefined;
}

pub const Inst = struct {
    op: Op,
    data: Data,

    pub const Op = enum(u8) {
        end,
        set,
        @"if",
        arg,
        str,
        bool,
        int,
        float,

        eq,
        neq,
        lt,
        lte,
        gt,
        gte,
        @"and",
        @"or",
        not,

        fn Data(comptime op: Op) type {
            return switch (op) {
                .end => void,
                .set => Set,
                .@"if" => If,
                .arg, .str => []const u8,
                .bool => bool,
                .int => u64,
                .float => f64,
                .not => Ref,
                else => Bin,
            };
        }
    };
    pub const Data = Bin;

    pub const Set = struct {
        arg: []const u8,
        operand: Inst.Ref,
    };

    pub const If = struct {
        cond: Inst,
        then_body: u32,
        else_body: u32,
    };

    pub const Bin = struct {
        lhs: Inst.Ref,
        rhs: Inst.Ref,
    };

    pub const Ref = enum(u32) { _ };
};

pub fn getExtra(defs: *Definitions, comptime op: Inst.Op, ref: Inst.Ref) op.Data() {
    const data = defs.insts.items(.data)[@enumToInt(ref)];
    switch (op) {
        .end => {},
        .set => {
            const offset = defs.extra.items[data.rhs];
            const len = defs.extra.items[data.rhs + 1];
            return .{
                .arg = defs.strings.items[offset..][0..len],
                .operand = data.lhs,
            };
        },
        .@"if" => return .{
            .then_body = defs.extra.items[data.rhs],
            .else_body = defs.extra.items[data.rhs + 1],
            .cond = data.lhs,
        },
        .arg, .str => {
            const offset = @enumToInt(data.lhs);
            const len = @enumToInt(data.rhs);
            return defs.strings.items[offset..][0..len];
        },
        .bool => return data.lhs != 0,
        .int => return @bitCast(u64, data),
        .float => return @bitCast(f64, data),
        .not => return data.lhs,
        else => return data,
    }
}

pub fn parse(gpa: Allocator, input: [:0]const u8) !Definitions {
    var defs = Definitions{};
    errdefer defs.deinit(gpa);
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
    inst_buf: std.ArrayListUnmanaged(Inst.Ref) = .{},
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
        p.inst_buf.deinit(p.gpa);
        p.arg_names.deinit(p.gpa);
        p.* = undefined;
    }

    fn addInst(p: *Parser, comptime op: Inst.Op, input: op.Data()) !Inst.Ref {
        const ref = @intToEnum(Inst.Ref, p.defs.insts.len);
        try p.defs.insts.append(p.gpa, .{
            .op = op,
            .data = switch (op) {
                .end => undefined,
                .set => blk: {
                    const offset = p.defs.strings.items.len;
                    try p.defs.strings.appendSlice(p.gpa, input.arg);

                    const extra_index = p.defs.extra.items.len;
                    try p.defs.extra.append(p.gpa, @intCast(u32, offset));
                    try p.defs.extra.append(p.gpa, @intCast(u32, input.arg.len));
                    break :blk .{
                        .lhs = input.operand,
                        .rhs = @intToEnum(Inst.Ref, extra_index),
                    };
                },
                .@"if" => blk: {
                    const extra_index = p.defs.extra.items.len;
                    try p.defs.extra.append(p.gpa, input.then_body);
                    try p.defs.extra.append(p.gpa, input.else_body);
                    break :blk .{
                        .lhs = input.cond,
                        .rhs = @intToEnum(Inst.Ref, extra_index),
                    };
                },
                .arg, .str => blk: {
                    const offset = p.defs.strings.items.len;
                    try p.defs.strings.appendSlice(p.gpa, input);
                    break :blk .{
                        .lhs = @intToEnum(Inst.Ref, offset),
                        .rhs = @intToEnum(Inst.Ref, input.len),
                    };
                },
                .bool => .{ .lhs = @intToEnum(Inst.Ref, @boolToInt(input)), .rhs = undefined },
                .int => @bitCast(Inst.Data, input),
                .float => @bitCast(Inst.Data, input),
                .not => .{ .lhs = input, .rhs = undefined },
                else => input,
            },
        });
        return ref;
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
        const start_len = p.defs.strings.items.len;
        var opt_def_name = try p.str(.collect);
        var gop: @TypeOf(p.defs.rules).GetOrPutResult = undefined;
        if (opt_def_name) |def_name| {
            // TODO handle this better
            const name_str = p.defs.getExtra(.str, def_name);
            const duped = try p.gpa.dupe(u8, name_str);
            p.defs.strings.items.len = start_len;
            gop = try p.defs.rules.getOrPut(p.gpa, duped);
            if (gop.found_existing) {
                p.warn("ignoring duplicate definition for '{s}'", .{name_str});
                opt_def_name = null;
            }
        } else {
            p.warn("ignoring unnamed definition", .{});
        }
        if (opt_def_name == null) p.arg_names.size = invalid_args;
        errdefer if (opt_def_name) |_| assert(p.defs.rules.remove(gop.key_ptr.*));

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

        const end_inst = try p.addInst(.end, {});
        try p.inst_buf.append(p.gpa, end_inst);
        const body = @intCast(u32, p.defs.extra.items.len);
        try p.defs.extra.appendSlice(p.gpa, @ptrCast([]u32, p.inst_buf.items));
        gop.value_ptr.* = body;
        return true;
    }

    const ArgMode = enum { collect, check };

    fn str(p: *Parser, arg_mode: ArgMode) !?Inst.Ref {
        if (arg_mode == .collect) p.arg_names.clearRetainingCapacity();
        if (p.input[p.index] != '"') return null;

        const start = p.index + 1;
        var escape = true;
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

        const offset = p.defs.strings.items.len;
        const slice = p.input[start..p.index];
        try p.defs.strings.ensureUnusedCapacity(p.gpa, slice.len);
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
                                p.defs.strings.appendSliceAssumeCapacity(buf[0..len]);
                            } else {
                                p.defs.strings.appendAssumeCapacity(@intCast(u8, codepoint));
                            }
                        },
                        .failure => {
                            p.warn("invalid escape sequence", .{});
                            continue;
                        },
                    }
                },
                '\n' => {
                    p.defs.strings.appendAssumeCapacity('\n');
                    p.line += 1;
                    p.col = 1;
                    i += 1;
                },
                '"' => break,
                '{', '}' => try p.strArg(slice, &i, arg_mode),
                else => |c| {
                    p.defs.strings.appendAssumeCapacity(c);
                    p.col += 1;
                    i += 1;
                },
            }
        }

        const ref = @intToEnum(Inst.Ref, p.defs.insts.len);
        try p.defs.insts.append(p.gpa, .{
            .op = .str,
            .data = .{
                .lhs = @intToEnum(Inst.Ref, offset),
                .rhs = @intToEnum(Inst.Ref, p.defs.strings.items.len - offset),
            },
        });
        return ref;
    }

    fn strArg(p: *Parser, slice: []const u8, offset: *usize, arg_mode: ArgMode) !void {
        const c = slice[offset.*];
        if (c == slice[offset.* + 1]) {
            p.defs.strings.appendSliceAssumeCapacity("{{");
            p.col += 2;
            offset.* += 2;
            return;
        }
        if (c == '}') {
            p.warn("unescaped '}}' in string", .{});
            p.defs.strings.appendSliceAssumeCapacity("{{");
            p.col += 1;
            offset.* += 1;
            return;
        }
        if (slice[offset.* + 1] != '%') {
            p.warn("expected '%' after '{{'", .{});
            p.defs.strings.appendSliceAssumeCapacity("{{");
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

            const undef = "[UNDEFINED ARGUMENT %";
            try p.defs.strings.ensureTotalCapacity(p.gpa, p.defs.strings.capacity + undef.len);

            p.defs.strings.appendSliceAssumeCapacity(undef);
            p.defs.strings.appendSliceAssumeCapacity(arg_name);
            p.defs.strings.appendSliceAssumeCapacity("]");
            return;
        }

        p.defs.strings.appendSliceAssumeCapacity("{%");
        p.defs.strings.appendSliceAssumeCapacity(arg_name);
        p.defs.strings.appendAssumeCapacity('}');
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
        return arg_name;
    }

    fn stmt(p: *Parser) !bool {
        if (p.skip("set")) {
            p.skipWhitespace();
            const dest = try p.arg(.collect);
            p.skipWhitespace();
            if (!p.skip("to")) {
                p.warn("expected 'to' after argument to set", .{});
            }
            p.skipWhitespace();
            const val = try p.expr();
            if (dest == null or val == null) {
                return false;
            }

            const inst = try p.addInst(.set, .{
                .arg = dest.?,
                .operand = val.?,
            });
            try p.inst_buf.append(p.gpa, inst);
            return true;
        } else if (p.skip("if")) {
            // TODO
            return true;
        } else if (try p.str(.check)) |inst| {
            try p.inst_buf.append(p.gpa, inst);
            return true;
        } else {
            return false;
        }
    }

    fn expr(p: *Parser) !?Inst.Ref {
        if (p.skip("true")) {
            return try p.addInst(.bool, true);
        } else if (p.skip("false")) {
            return try p.addInst(.bool, false);
        } else if (try p.str(.check)) |some| {
            return some;
        } else if (try p.arg(.check)) |some| {
            return try p.addInst(.arg, some);
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
    const gpa = std.testing.allocator;
    var defs = try parse(gpa, input);
    defer defs.deinit(gpa);

    try expect(defs.rules.count() == 1);
    const rule = defs.rules.get("Hello {%0}!");
    try expect(rule != null);
    const op = defs.insts.items(.op);
    const string_inst = defs.extra.items[rule.?];
    try expect(op[string_inst] == .str);
    try expectEqualStrings("Moikka {%0}!", defs.getExtra(.str, @intToEnum(Inst.Ref, string_inst)));
    try expect(op[defs.extra.items[rule.? + 1]] == .end);
}
