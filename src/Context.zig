const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const log = std.log.scoped(.i18n);
const lib = @import("lib.zig");

const Context = @This();

defs: lib.Definitions = .{},
vals: std.StringHashMapUnmanaged(struct {
    val: lib.Value,
    opts: std.fmt.FormatOptions,
}) = .{},
gpa: Allocator,

pub fn deinit(ctx: *Context) void {
    ctx.vals.deinit(ctx.gpa);
    ctx.defs.deinit(ctx.gpa);
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
    const max_format_args = @typeInfo(std.fmt.ArgSetType).Int.bits;
    if (fields_info.len > max_format_args) {
        @compileError("32 arguments max are supported per format call");
    }

    ctx.vals.clearRetainingCapacity();
    try ctx.vals.ensureTotalCapacity(ctx.gpa, max_format_args);

    @setEvalBranchQuota(2000000);
    comptime var arg_state: std.fmt.ArgState = .{ .args_len = fields_info.len };
    comptime var i = 0;
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
        inline while (i < fmt.len and fmt[i] != '}' and fmt[i] != '%') : (i += 1) {}
        const fmt_end = i;
        if (fmt[i] == '%') {
            i += 1;
        }
        inline while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '0'...'9', 'a'...'z', 'A'...'Z' => {},
                '}' => break,
                else => @compileError("invalid character in argument name"),
            }
        }
        const key_end = i;

        if (i >= fmt.len) {
            @compileError("missing closing }");
        }

        // Get past the }
        comptime assert(fmt[i] == '}');
        i += 1;

        comptime var placeholder = std.fmt.Placeholder.parse(fmt[fmt_begin..fmt_end].*);
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
        const arg_pos = comptime switch (placeholder.arg) {
            .none => arg_state.nextArg(null) orelse
                @compileError("too few arguments"),
            .number => |pos| pos,
            .named => |arg_name| std.meta.fieldIndex(ArgsType, arg_name) orelse
                @compileError("no argument with name '" ++ arg_name ++ "'"),
        };
        const arg_name = comptime if (fmt_end != key_end) blk: {
            if (placeholder.arg != .none) @compileError("cannot specify argument name and argument specifier");
            break :blk fmt[fmt_end + 1 .. key_end];
        } else switch (placeholder.arg) {
            .named => |arg_name| arg_name,
            else => std.fmt.comptimePrint("{d}", .{arg_pos}),
        };
        query_str = query_str ++ "{%" ++ arg_name ++ "}";
        ctx.vals.putAssumeCapacity(arg_name, .{
            .val = try lib.Value.from(@field(args, fields_info[arg_pos].name)),
            .opts = .{
                .fill = placeholder.fill,
                .alignment = placeholder.alignment,
                .width = width,
                .precision = precision,
            },
        });
    }

    if (comptime arg_state.hasUnusedArgs()) {
        const missing_count = arg_state.args_len - @popCount(arg_state.used_args);
        switch (missing_count) {
            0 => unreachable,
            1 => @compileError("unused argument in '" ++ fmt ++ "'"),
            else => @compileError(std.fmt.comptimePrint("{d}", .{missing_count}) ++ " unused arguments in '" ++ fmt ++ "'"),
        }
    }

    const rule = (try ctx.query(query_str)) orelse query_str;
    try ctx.render(rule, writer);
}

pub fn query(ctx: *Context, key: []const u8) !?[]const u8 {
    const rule = ctx.defs.rules.get(key) orelse return null;
    // TODO execute rule
    return ctx.defs.getExtra(.str, @intToEnum(lib.Definitions.Inst.Ref, ctx.defs.extra.items[rule]));
}

fn render(ctx: *Context, rule: []const u8, writer: anytype) !void {
    var i: usize = 0;
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
        assert(rule[i + 1] == '%');
        i += 2;

        const name_start = i;
        while (rule[i] != '}') : (i += 1) {}
        const name = rule[name_start..i];
        assert(rule[i] == '}');
        i += 1;

        const val = ctx.vals.get(name).?;

        // TODO properly render value
        try writer.writeAll(val.val.str);
    }
}
