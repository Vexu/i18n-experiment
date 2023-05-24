const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const log = std.log.scoped(.i18n);
const lib = @import("lib.zig");

const Context = @This();

pub const Argument = struct {
    val: lib.Value,
    fmt_options: std.fmt.FormatOptions,
    kind: enum { decimal, scientific, hex },
    case: std.fmt.Case,
    base: u8,
};
const max_format_args = @typeInfo(std.fmt.ArgSetType).Int.bits;

defs: std.StringHashMapUnmanaged(lib.Code.Program) = .{},
code: lib.Code = .{},
arena: ArenaAllocator,

pub fn deinit(ctx: *Context) void {
    const gpa = ctx.arena.child_allocator;
    var it = ctx.defs.keyIterator();
    while (it.next()) |some| gpa.free(some.*);
    ctx.defs.deinit(gpa);
    ctx.code.deinit(gpa);
    ctx.arena.deinit();
    ctx.* = undefined;
}

pub fn format(
    ctx: *Context,
    writer: anytype,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .Struct) {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }

    const fields_info = args_type_info.Struct.fields;
    if (fields_info.len > max_format_args) {
        @compileError("32 arguments max are supported per format call");
    }

    _ = ctx.arena.reset(.{ .retain_with_limit = 4069 });
    var options: [max_format_args]Argument = undefined;

    @setEvalBranchQuota(2000000);
    comptime var arg_state: std.fmt.ArgState = .{ .args_len = fields_info.len };
    comptime var i = 0;
    comptime var options_i = 0;
    comptime var query_str: []const u8 = "";
    inline while (i < fmt.len) {
        const start_index = i;

        inline while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '{', '}' => break,
                else => {},
            }
        }

        comptime var end_index = i;
        comptime var unescape_brace = false;

        // Handle {{ and }}, those are un-escaped as single braces
        if (i + 1 < fmt.len and fmt[i + 1] == fmt[i]) {
            unescape_brace = true;
            // Make the first brace part of the literal...
            end_index += 1;
            // ...and skip both
            i += 2;
        }

        // Write out the literal
        if (start_index != end_index) {
            query_str = query_str ++ fmt[start_index..end_index];
        }

        // We've already skipped the other brace, restart the loop
        if (unescape_brace) continue;

        if (i >= fmt.len) break;

        if (fmt[i] == '}') {
            @compileError("missing opening {");
        }

        // Get past the {
        comptime assert(fmt[i] == '{');
        i += 1;

        const fmt_begin = i;
        // Find the closing brace
        inline while (i < fmt.len and fmt[i] != '}') : (i += 1) {}
        const fmt_end = i;

        if (i >= fmt.len) {
            @compileError("missing closing }");
        }

        // Get past the }
        comptime assert(fmt[i] == '}');
        i += 1;

        comptime var placeholder = std.fmt.Placeholder.parse(fmt[fmt_begin..fmt_end].*);
        const arg_pos = comptime switch (placeholder.arg) {
            .none => null,
            .number => |pos| pos,
            .named => |arg_name| std.meta.fieldIndex(ArgsType, arg_name) orelse
                @compileError("no argument with name '" ++ arg_name ++ "'"),
        };

        const width = comptime switch (placeholder.width) {
            .none => null,
            .number => |v| v,
            .named => |arg_name| blk: {
                const arg_i = std.meta.fieldIndex(ArgsType, arg_name) orelse
                    @compileError("no argument with name '" ++ arg_name ++ "'");
                _ = arg_state.nextArg(arg_i) orelse @compileError("too few arguments");
                break :blk @field(args, arg_name);
            },
        };

        const precision = comptime switch (placeholder.precision) {
            .none => null,
            .number => |v| v,
            .named => |arg_name| blk: {
                const arg_i = std.meta.fieldIndex(ArgsType, arg_name) orelse
                    @compileError("no argument with name '" ++ arg_name ++ "'");
                _ = arg_state.nextArg(arg_i) orelse @compileError("too few arguments");
                break :blk @field(args, arg_name);
            },
        };

        const arg_to_print = comptime arg_state.nextArg(arg_pos) orelse
            @compileError("too few arguments");

        query_str = query_str ++ "{}";
        const fmt_options = std.fmt.FormatOptions{
            .fill = placeholder.fill,
            .alignment = placeholder.alignment,
            .width = width,
            .precision = precision,
        };
        const spec = placeholder.specifier_arg;
        options[options_i] = .{
            .val = try lib.Value.from(&ctx.arena, @field(args, fields_info[arg_to_print].name), spec, fmt_options),
            .fmt_options = fmt_options,
            .case = comptime if (std.mem.eql(u8, spec, "X")) .upper else .lower,
            .base = comptime if (std.mem.eql(u8, spec, "b"))
                2
            else if (std.mem.eql(u8, spec, "o"))
                8
            else if (std.mem.eql(u8, spec, "x") or std.mem.eql(u8, spec, "X"))
                16
            else
                10,
            .kind = comptime if (std.mem.eql(u8, spec, "d"))
                .decimal
            else if (std.mem.eql(u8, spec, "x"))
                .hex
            else
                .scientific,
        };
        options_i += 1;
    }

    if (comptime arg_state.hasUnusedArgs()) {
        const missing_count = arg_state.args_len - @popCount(arg_state.used_args);
        switch (missing_count) {
            0 => unreachable,
            1 => @compileError("unused argument in '" ++ fmt ++ "'"),
            else => @compileError(std.fmt.comptimePrint("{d}", .{missing_count}) ++ " unused arguments in '" ++ fmt ++ "'"),
        }
    }

    var vm = lib.Code.Vm{ .ctx = ctx, .args = options[0..options_i] };
    defer vm.deinit();
    const rule = (try query(&vm, query_str)) orelse query_str;
    try render(rule, &vm, writer);
}

pub fn query(vm: *lib.Code.Vm, key: []const u8) !?[]const u8 {
    const program = vm.ctx.defs.get(key) orelse return null;
    const res = try vm.run(program);
    switch (res) {
        .str => |str| return str,
        else => {
            log.err("definition for '{s}' did not result in a format string", .{key});
            return null;
        },
    }
}

pub fn render(rule: []const u8, vm: *lib.Code.Vm, writer: anytype) !void {
    var i: usize = 0;
    var arg_i: u8 = 0;
    while (i < rule.len) {
        const start_index = i;
        while (i < rule.len) : (i += 1) {
            switch (rule[i]) {
                '{', '}' => break,
                else => {},
            }
        }
        // Handle {{ and }}, those are un-escaped as single braces
        var unescape = false;
        if (i + 1 < rule.len and rule[i + 1] == rule[i]) {
            unescape = true;
            i += 1;
        }
        try writer.writeAll(rule[start_index..i]);
        if (unescape) {
            i += 1;
            continue;
        }

        if (i >= rule.len) break;

        // The parser validates these.
        assert(rule[i] == '{');
        i += 1;

        const name_start = i;
        while (rule[i] != '}') : (i += 1) {}
        const name = rule[name_start..i];
        assert(rule[i] == '}');
        i += 1;

        const options = if (name.len == 0)
            vm.args[arg_i]
        else if (name.len == 1 and name[0] < max_format_args)
            vm.args[name[0]]
        else
            Argument{
                .fmt_options = .{},
                .kind = .decimal,
                .case = .lower,
                .base = 10,
                .val = vm.vars.get(name) orelse {
                    try writer.print("[USE OF UNDEFINED VARIABLE %{s}]", .{name});
                    continue;
                },
            };

        arg_i += 1;
        switch (options.val) {
            .str, .preformatted => |str| try writer.writeAll(str),
            .bool => |b| try std.fmt.formatBuf(if (b) "true" else "false", options.fmt_options, writer),
            .int => |int| {
                try std.fmt.formatInt(int, options.base, options.case, options.fmt_options, writer);
            },
            .float => |float| {
                switch (options.kind) {
                    .decimal => try std.fmt.formatFloatDecimal(float, options.fmt_options, writer),
                    .hex => try std.fmt.formatFloatHexadecimal(float, options.fmt_options, writer),
                    .scientific => try std.fmt.formatFloatScientific(float, options.fmt_options, writer),
                }
            },
            .none => unreachable,
        }
    }
}
