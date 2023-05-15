const std = @import("std");
const lib = @import("lib.zig");

pub const Value = union(enum) {
    int: i64,
    big_int: std.math.big.int.Const,
    float: f64,
    optional: ?*Value,
    err_union: struct {
        code: anyerror,
        payload: ?*Value,
    },
    err_set: anyerror,
    @"enum": *Value,
    @"union": *Union,
    pointer: usize,
    str: []const u8,
    arr: []Value,
    enum_lit: []const u8,

    pub const Union = struct {
        ty_name: []const u8,
        tag: []const u8,
        val: Value,
    };
    pub const Struct = struct {
        ty_name: []const u8,
        fields: []struct {
            name: []const u8,
            val: Value,
        },
    };

    pub fn from(value: anytype) !Value {
        const T = @TypeOf(value);
        if (comptime std.meta.trait.hasFn("format")(T)) {
            @compileError("TODO custom format functions");
        }
        switch (@typeInfo(T)) {
            .Void => {
                return .{ .str = "void" };
            },
            .Bool => {
                return .{ .str = if (value) "true" else "false" };
            },
            .Pointer => {
                if (comptime std.meta.trait.isZigString(T)) {
                    return .{ .str = value };
                }
                @compileError("TODO ptr");
            },
            .Array => |info| {
                if (info.child == u8) {
                    return .{ .str = value };
                }
                @compileError("TODO array");
            },
            .Type => {
                return .{ .str = @typeName(value) };
            },
            .EnumLiteral => {
                return .{ .str = [_]u8{'.'} ++ @tagName(value) };
            },
            .Null => {
                return .{ .str = "null" };
            },
            else => @compileError("unable to format type '" ++ @typeName(T) ++ "'"),
        }
    }
};
