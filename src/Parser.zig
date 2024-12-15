const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.i18n);
const math = std.math;
const mem = std.mem;
const lib = @import("lib.zig");
const Inst = lib.Code.Inst;

const Parser = @This();

const max_format_args = @typeInfo(std.fmt.ArgSetType).int.bits;
const ArgPos = enum(u8) {
    @"var" = 0xFF,
    _,

    inline fn toInt(ap: ArgPos) u5 {
        return @intCast(@intFromEnum(ap));
    }
};

ctx: *lib.Context,
inst_buf: std.ArrayListUnmanaged(Inst.Ref) = .{},
arg_names: std.StringHashMapUnmanaged(ArgPos) = .{},

input: [:0]const u8,
index: usize = 0,
line: usize = 1,
col: usize = 1,
gpa: Allocator,

pub fn parse(ctx: *lib.Context, input: [:0]const u8) !void {
    const gpa = ctx.arena.child_allocator;
    var parser = Parser{ .ctx = ctx, .gpa = gpa, .input = input };
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
}

fn addInst(p: *Parser, comptime op: Inst.Op, input: op.Data()) !Inst.Ref {
    return p.ctx.code.addInst(p.gpa, op, input);
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

fn word(p: *Parser, s: []const u8) bool {
    if (!mem.startsWith(u8, p.input[p.index..], s))
        return false;
    switch (p.input[p.index + s.len]) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => return false,
        else => {},
    }
    p.index += s.len;
    p.col += s.len;
    p.skipWhitespace();
    return true;
}

fn def(p: *Parser) !bool {
    if (!p.word("def")) return false;

    const strings = &p.ctx.code.strings;
    const start_len = strings.items.len;
    var opt_def_name = try p.str(.collect);
    var gop: @TypeOf(p.ctx.defs).GetOrPutResult = undefined;
    if (opt_def_name) |def_name| {
        // TODO handle this better
        const name_str = blk: {
            const data = p.ctx.code.insts.items(.data)[@intFromEnum(def_name)];
            const offset = @intFromEnum(data.lhs);
            const len = @intFromEnum(data.rhs);
            const name_str = strings.items[offset..][0..len];
            break :blk try p.gpa.dupe(u8, name_str);
        };

        strings.items.len = start_len;
        gop = try p.ctx.defs.getOrPut(p.gpa, name_str);
        if (gop.found_existing) {
            p.warn("ignoring duplicate definition for '{s}'", .{name_str});
            opt_def_name = null;
            p.gpa.free(name_str);
        }
    } else {
        p.warn("ignoring unnamed definition", .{});
    }
    errdefer if (opt_def_name) |_| p.ctx.defs.removeByPtr(gop.key_ptr);

    p.inst_buf.items.len = 0;
    var warned = false;
    while (true) {
        p.skipWhitespace();
        if (p.input[p.index] == 0 and p.index == p.input.len) {
            p.warn("unexpected EOF inside definition", .{});
            break;
        }
        if (p.word("end")) break;
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
    const body: u32 = @intCast(p.ctx.code.extra.items.len);
    try p.ctx.code.extra.appendSlice(p.gpa, @ptrCast(p.inst_buf.items));
    gop.value_ptr.* = .{ .body = body };
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

    const strings = &p.ctx.code.strings;
    const offset = strings.items.len;
    const slice = p.input[start..p.index];
    try strings.ensureUnusedCapacity(p.gpa, slice.len);
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
                            strings.appendSliceAssumeCapacity(buf[0..len]);
                        } else {
                            strings.appendAssumeCapacity(@intCast(codepoint));
                        }
                    },
                    .failure => {
                        p.warn("invalid escape sequence", .{});
                        continue;
                    },
                }
            },
            '\n' => {
                strings.appendAssumeCapacity('\n');
                p.line += 1;
                p.col = 1;
                i += 1;
            },
            '"' => break,
            '{', '}' => try p.strArg(slice, &i, arg_mode),
            else => |c| {
                strings.appendAssumeCapacity(c);
                p.col += 1;
                i += 1;
            },
        }
    }

    const ref: Inst.Ref = @enumFromInt(p.ctx.code.insts.len);
    try p.ctx.code.insts.append(p.gpa, .{
        .op = .str,
        .data = .{
            .lhs = @enumFromInt(offset),
            .rhs = @enumFromInt(strings.items.len - offset),
        },
    });
    return ref;
}

fn strArg(p: *Parser, slice: []const u8, offset: *usize, arg_mode: ArgMode) !void {
    const strings = &p.ctx.code.strings;
    const c = slice[offset.*];
    if (c == slice[offset.* + 1]) {
        strings.appendSliceAssumeCapacity("{{");
        p.col += 2;
        offset.* += 2;
        return;
    }
    if (c == '}') {
        p.warn("unescaped '}}' in string", .{});
        strings.appendSliceAssumeCapacity("{{");
        p.col += 1;
        offset.* += 1;
        return;
    }
    if (slice[offset.* + 1] != '%') {
        p.warn("expected '%' after '{{'", .{});
        strings.appendSliceAssumeCapacity("{{");
        p.col += 1;
        offset.* += 1;
        return;
    }
    offset.* += 2;
    const start = offset.*;
    while (true) switch (slice[offset.*]) {
        '0'...'9', 'a'...'z', 'A'...'Z', '_' => {
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

        const pos: ArgPos = @enumFromInt(p.arg_names.size);
        const gop = try p.arg_names.getOrPut(p.gpa, arg_name);
        if (gop.found_existing) {
            p.warn("redeclaration of argument '%{s}'", .{arg_name});
        } else {
            gop.value_ptr.* = pos;
        }
        strings.appendSliceAssumeCapacity("{}");
        return;
    } else if (!p.arg_names.contains(arg_name)) {
        p.warn("use of undefined argument '%{s}'", .{arg_name});

        const undef = "[UNDEFINED ARGUMENT %";
        try strings.ensureTotalCapacity(p.gpa, strings.capacity + undef.len);

        strings.appendSliceAssumeCapacity(undef);
        strings.appendSliceAssumeCapacity(arg_name);
        strings.appendSliceAssumeCapacity("]");
        return;
    }

    strings.appendAssumeCapacity('{');
    if (p.arg_names.get(arg_name)) |pos| if (pos != .@"var") {
        strings.appendAssumeCapacity(@intFromEnum(pos));
        strings.appendAssumeCapacity('}');
        return;
    };
    strings.appendSliceAssumeCapacity(arg_name);
    strings.appendAssumeCapacity('}');
}

fn arg(p: *Parser) !?[]const u8 {
    if (p.input[p.index] != '%') return null;
    p.col += 1;
    p.index += 1;

    const start = p.index;
    while (true) switch (p.input[p.index]) {
        '0'...'9', 'a'...'z', 'A'...'Z', '_' => {
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

fn stmt(p: *Parser) Allocator.Error!bool {
    if (p.word("set")) {
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
        if (!p.word("to")) {
            p.warn("expected 'to' after argument to set", .{});
        }
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
    } else if (p.word("if")) {
        return p.ifBody();
    } else if (try p.str(.check)) |inst| {
        try p.inst_buf.append(p.gpa, inst);
        return true;
    } else {
        return false;
    }
}

fn ifBody(p: *Parser) !bool {
    const cond = (try p.expr()) orelse {
        p.warn("expected if condition", .{});
        return false;
    };
    var start = p.inst_buf.items.len;
    defer p.inst_buf.items.len = start;

    var warned = false;
    var then_body: ?u32 = null;
    while (true) {
        p.skipWhitespace();
        if (p.input[p.index] == 0 and p.index == p.input.len) {
            p.warn("unexpected EOF inside 'if'", .{});
            break;
        }
        if (p.word("end")) break;
        if (p.word("elseif")) {
            then_body = try p.finishBody(start);
            _ = try p.ifBody();
            break;
        }
        if (p.word("else")) {
            if (then_body != null) {
                p.warn("ignoring duplicate 'else'", .{});
                continue;
            }
            then_body = try p.finishBody(start);
        }
        if (try p.stmt()) continue;
        if (!warned) {
            warned = true;
            p.warn("ignoring unexpected statement", .{});
        }
        p.col += 1;
        p.index += 1;
    }
    const else_body = try p.finishBody(start);
    const @"if" = try p.addInst(.@"if", .{
        .cond = cond,
        .then_body = then_body orelse else_body,
        .else_body = if (then_body != null) else_body else 0,
    });
    try p.inst_buf.append(p.gpa, @"if");
    start += 1;
    return true;
}

fn finishBody(p: *Parser, start: usize) !u32 {
    const index: u32 = @intCast(p.ctx.code.extra.items.len);
    try p.inst_buf.append(p.gpa, try p.addInst(.end, {}));
    try p.ctx.code.extra.appendSlice(p.gpa, @ptrCast(p.inst_buf.items[start..]));
    p.inst_buf.items.len = start;
    return index;
}

fn expr(p: *Parser) !?Inst.Ref {
    if (p.word("true")) {
        return try p.addInst(.bool, true);
    } else if (p.word("false")) {
        return try p.addInst(.bool, false);
    } else if (try p.str(.check)) |some| {
        return some;
    } else if (try p.arg()) |arg_name| {
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
