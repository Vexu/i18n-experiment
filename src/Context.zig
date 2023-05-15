const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const log = std.log.scoped(.i18n);
const lib = @import("lib.zig");

const Context = @This();

defs: lib.Definitions,
key_buf: std.ArrayListUnmanaged(u8) = .{},
vals: std.StringHashMapUnmanaged(struct {
    val: lib.Value,
    opts: std.fmt.FormatOptions,
}) = .{},

pub fn deinit(ctx: *Context) void {
    ctx.key_buf.deinit(ctx.defs.arena.child_allocator);
    ctx.vals.deinit(ctx.defs.arena.child_allocator);
    ctx.defs.deinit();
    ctx.* = undefined;
}

pub fn format(
    context: *Context,
    writer: anytype,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    _ = writer;
    const gpa = context.defs.arena.child_allocator;
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

    try context.vals.ensureTotalCapacity(gpa, max_format_args);

    @setEvalBranchQuota(2000000);
    comptime var arg_state: std.fmt.ArgState = .{ .args_len = fields_info.len };
    comptime var i = 0;
    inline while (i < fmt.len) {
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
        const arg_name = comptime switch (placeholder.arg) {
            .named => |arg_name| arg_name,
            else => std.fmt.comptimePrint("{d}", .{arg_pos}),
        };
        context.vals.putAssumeCapacity(arg_name, .{
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

    // TODO lookup definition
}

test "parsing a simple definition" {
    const input =
        \\# Comment explaining something about this translation
        \\def "Hello {%1}!"
        \\"Moikka {%1}!"
        \\end
        \\
    ;
    var ctx = ctx: {
        var defs = try lib.Definitions.parse(std.testing.allocator, input);
        break :ctx Context{ .defs = defs };
    };
    defer ctx.deinit();

    var out_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer out_buf.deinit();

    try ctx.format(out_buf.writer(), "Hello {s}!", .{"Veikka"});
    if (true) return error.SkipZigTest; // TODO
    try expectEqualStrings("Moikka Veikka!", out_buf.items);
}
