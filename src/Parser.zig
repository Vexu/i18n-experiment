const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.i18n);
const math = std.math;
const mem = std.mem;
const lib = @import("lib.zig");
const Definitions = lib.Definitions;
const Inst = lib.Definitions.Inst;

const Parser = @This();

const max_format_args = @typeInfo(std.fmt.ArgSetType).Int.bits;
const ArgPos = enum(u8) {
    @"var" = 0xFF,
    _,

    inline fn toInt(ap: ArgPos) u5 {
        return @intCast(u5, @enumToInt(ap));
    }
};

rules: std.StringHashMapUnmanaged(u32) = .{},
insts: std.MultiArrayList(Inst) = .{},
extra: std.ArrayListUnmanaged(u32) = .{},
strings: std.ArrayListUnmanaged(u8) = .{},

inst_buf: std.ArrayListUnmanaged(Inst.Ref) = .{},
arg_names: std.StringHashMapUnmanaged(ArgPos) = .{},

input: [:0]const u8,
index: usize = 0,
line: usize = 1,
col: usize = 1,
gpa: Allocator,

pub fn parse(gpa: Allocator, input: [:0]const u8) !Definitions {
    var parser = Parser{ .gpa = gpa, .input = input };
    errdefer {
        parser.rules.deinit(gpa);
        parser.insts.deinit(gpa);
        parser.extra.deinit(gpa);
        parser.strings.deinit(gpa);
    }
    defer {
        parser.inst_buf.deinit(gpa);
        parser.arg_names.deinit(gpa);
    }

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
    return .{
        .rules = parser.rules,
        .insts = parser.insts,
        .extra = parser.extra,
        .strings = parser.strings,
    };
}

const invalid_args = std.math.maxInt(u32);

fn addInst(p: *Parser, comptime op: Inst.Op, input: op.Data()) !Inst.Ref {
    const ref = @intToEnum(Inst.Ref, p.insts.len);
    try p.insts.append(p.gpa, .{
        .op = op,
        .data = switch (op) {
            .end => undefined,
            .set_arg => .{
                .lhs = @intToEnum(Inst.Ref, input.pos),
                .rhs = input.operand,
            },
            .set_var => blk: {
                const offset = p.strings.items.len;
                try p.strings.appendSlice(p.gpa, input.@"var");

                const extra_index = p.extra.items.len;
                try p.extra.append(p.gpa, @intCast(u32, offset));
                try p.extra.append(p.gpa, @intCast(u32, input.@"var".len));
                break :blk .{
                    .lhs = @intToEnum(Inst.Ref, extra_index),
                    .rhs = input.operand,
                };
            },
            .@"if" => blk: {
                const extra_index = p.extra.items.len;
                try p.extra.append(p.gpa, input.then_body);
                try p.extra.append(p.gpa, input.else_body);
                break :blk .{
                    .lhs = input.cond,
                    .rhs = @intToEnum(Inst.Ref, extra_index),
                };
            },
            .@"var", .str => blk: {
                const offset = p.strings.items.len;
                try p.strings.appendSlice(p.gpa, input);
                break :blk .{
                    .lhs = @intToEnum(Inst.Ref, offset),
                    .rhs = @intToEnum(Inst.Ref, input.len),
                };
            },
            .arg => .{ .lhs = @intToEnum(Inst.Ref, input), .rhs = undefined },
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
    const start_len = p.strings.items.len;
    var opt_def_name = try p.str(.collect);
    var gop: @TypeOf(p.rules).GetOrPutResult = undefined;
    if (opt_def_name) |def_name| {
        // TODO handle this better
        const name_str = blk: {
            const data = p.insts.items(.data)[@enumToInt(def_name)];
            const offset = @enumToInt(data.lhs);
            const len = @enumToInt(data.rhs);
            const name_str = p.strings.items[offset..][0..len];
            break :blk try p.gpa.dupe(u8, name_str);
        };

        p.strings.items.len = start_len;
        gop = try p.rules.getOrPut(p.gpa, name_str);
        if (gop.found_existing) {
            p.warn("ignoring duplicate definition for '{s}'", .{name_str});
            opt_def_name = null;
        }
    } else {
        p.warn("ignoring unnamed definition", .{});
    }
    if (opt_def_name == null) p.arg_names.size = invalid_args;
    errdefer if (opt_def_name) |_| assert(p.rules.remove(gop.key_ptr.*));

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
    const body = @intCast(u32, p.extra.items.len);
    try p.extra.appendSlice(p.gpa, @ptrCast([]u32, p.inst_buf.items));
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

    const offset = p.strings.items.len;
    const slice = p.input[start..p.index];
    try p.strings.ensureUnusedCapacity(p.gpa, slice.len);
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
                            p.strings.appendSliceAssumeCapacity(buf[0..len]);
                        } else {
                            p.strings.appendAssumeCapacity(@intCast(u8, codepoint));
                        }
                    },
                    .failure => {
                        p.warn("invalid escape sequence", .{});
                        continue;
                    },
                }
            },
            '\n' => {
                p.strings.appendAssumeCapacity('\n');
                p.line += 1;
                p.col = 1;
                i += 1;
            },
            '"' => break,
            '{', '}' => try p.strArg(slice, &i, arg_mode),
            else => |c| {
                p.strings.appendAssumeCapacity(c);
                p.col += 1;
                i += 1;
            },
        }
    }

    const ref = @intToEnum(Inst.Ref, p.insts.len);
    try p.insts.append(p.gpa, .{
        .op = .str,
        .data = .{
            .lhs = @intToEnum(Inst.Ref, offset),
            .rhs = @intToEnum(Inst.Ref, p.strings.items.len - offset),
        },
    });
    return ref;
}

fn strArg(p: *Parser, slice: []const u8, offset: *usize, arg_mode: ArgMode) !void {
    const c = slice[offset.*];
    if (c == slice[offset.* + 1]) {
        p.strings.appendSliceAssumeCapacity("{{");
        p.col += 2;
        offset.* += 2;
        return;
    }
    if (c == '}') {
        p.warn("unescaped '}}' in string", .{});
        p.strings.appendSliceAssumeCapacity("{{");
        p.col += 1;
        offset.* += 1;
        return;
    }
    if (slice[offset.* + 1] != '%') {
        p.warn("expected '%' after '{{'", .{});
        p.strings.appendSliceAssumeCapacity("{{");
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
        if (p.arg_names.size >= max_format_args) {
            p.warn("too many arguments, max {d}", .{max_format_args});
            return;
        }

        const pos = @intToEnum(ArgPos, p.arg_names.size);
        const gop = try p.arg_names.getOrPut(p.gpa, arg_name);
        if (gop.found_existing) {
            p.warn("redeclaration of argument '%{s}'", .{arg_name});
        } else {
            gop.value_ptr.* = pos;
        }
        p.strings.appendSliceAssumeCapacity("{}");
        return;
    } else if (p.arg_names.size != invalid_args and
        !p.arg_names.contains(arg_name))
    {
        p.warn("use of undefined argument '%{s}'", .{arg_name});

        const undef = "[UNDEFINED ARGUMENT %";
        try p.strings.ensureTotalCapacity(p.gpa, p.strings.capacity + undef.len);

        p.strings.appendSliceAssumeCapacity(undef);
        p.strings.appendSliceAssumeCapacity(arg_name);
        p.strings.appendSliceAssumeCapacity("]");
        return;
    }

    p.strings.appendAssumeCapacity('{');
    if (p.arg_names.get(arg_name)) |pos| if (pos != .@"var") {
        p.strings.appendAssumeCapacity(@enumToInt(pos));
        p.strings.appendAssumeCapacity('}');
        return;
    };
    p.strings.appendSliceAssumeCapacity(arg_name);
    p.strings.appendAssumeCapacity('}');
}

fn arg(p: *Parser) !?[]const u8 {
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
    return p.input[start..p.index];
}

fn stmt(p: *Parser) !bool {
    if (p.skip("set")) {
        p.skipWhitespace();
        const dest = try p.arg();
        var pos: ArgPos = .@"var";
        if (dest) |some| {
            const gop = try p.arg_names.getOrPut(p.gpa, some);
            if (!gop.found_existing) {
                gop.value_ptr.* = pos;
            } else {
                pos = gop.value_ptr.*;
            }
        } else {
            p.warn("expected argument name after 'set'", .{});
        }
        p.skipWhitespace();
        if (!p.skip("to")) {
            p.warn("expected 'to' after argument to set", .{});
        }
        p.skipWhitespace();
        const val = (try p.expr()) orelse {
            p.warn("expected expression after 'to'", .{});
            return false;
        };
        if (dest == null) {
            return false;
        }
        const inst = if (pos == .@"var") try p.addInst(.set_var, .{
            .@"var" = dest.?,
            .operand = val,
        }) else try p.addInst(.set_arg, .{
            .pos = pos.toInt(),
            .operand = val,
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
    } else if (try p.arg()) |arg_name| {
        if (p.arg_names.size == invalid_args) {
            return try p.addInst(.@"var", arg_name);
        }
        const pos = p.arg_names.get(arg_name) orelse {
            p.warn("use of undefined argument '%{s}'", .{arg_name});
            return null;
        };
        if (pos == .@"var") {
            return try p.addInst(.@"var", arg_name);
        } else {
            return try p.addInst(.arg, pos.toInt());
        }
    } else {
        // TODO numbers
        return null;
    }
}
