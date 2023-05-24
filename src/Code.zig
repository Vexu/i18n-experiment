const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;

const Code = @This();

pub const Program = struct {
    body: u32,
};

pub const Inst = struct {
    op: Op,
    data: Data,

    pub const Op = enum(u8) {
        end,
        set_arg,
        set_var,
        @"if",
        arg,
        @"var",
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

        pub fn Data(comptime op: Op) type {
            return switch (op) {
                .end => void,
                .arg => u5,
                .set_arg => SetArg,
                .set_var => SetVar,
                .@"if" => If,
                .@"var", .str => []const u8,
                .bool => bool,
                .int => u64,
                .float => f64,
                .not => Ref,
                else => Bin,
            };
        }
    };
    pub const Data = Bin;

    pub const SetVar = struct {
        @"var": []const u8,
        operand: Inst.Ref,
    };

    pub const SetArg = struct {
        pos: u5,
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

insts: std.MultiArrayList(Inst) = .{},
extra: std.ArrayListUnmanaged(u32) = .{},
strings: std.ArrayListUnmanaged(u8) = .{},

pub fn deinit(c: *Code, gpa: Allocator) void {
    c.insts.deinit(gpa);
    c.extra.deinit(gpa);
    c.strings.deinit(gpa);
    c.* = undefined;
}

pub fn getExtra(c: *Code, comptime op: Inst.Op, ref: Inst.Ref) op.Data() {
    const data = c.insts.items(.data)[@enumToInt(ref)];
    switch (op) {
        .end => {},
        .set_var => {
            const offset = c.extra.items[data.lhs];
            const len = c.extra.items[data.lhs + 1];
            return .{
                .@"var" = c.strings.items[offset..][0..len],
                .operand = data.rhs,
            };
        },
        .set_arg => return .{
            .pos = @intCast(u5, data.lhs),
            .operand = data.rhs,
        },
        .@"if" => return .{
            .then_body = c.extra.items[data.rhs],
            .else_body = c.extra.items[data.rhs + 1],
            .cond = data.lhs,
        },
        .@"var", .str => {
            const offset = @enumToInt(data.lhs);
            const len = @enumToInt(data.rhs);
            return c.strings.items[offset..][0..len];
        },
        .arg => return @intCast(u5, data.lhs),
        .bool => return data.lhs != 0,
        .int => return @bitCast(u64, data),
        .float => return @bitCast(f64, data),
        .not => return data.lhs,
        else => return data,
    }
}

pub fn addInst(c: *Code, gpa: Allocator, comptime op: Inst.Op, input: op.Data()) !Inst.Ref {
    const ref = @intToEnum(Inst.Ref, c.insts.len);
    try c.insts.append(gpa, .{
        .op = op,
        .data = switch (op) {
            .end => undefined,
            .set_arg => .{
                .lhs = @intToEnum(Inst.Ref, input.pos),
                .rhs = input.operand,
            },
            .set_var => blk: {
                const offset = c.strings.items.len;
                try c.strings.appendSlice(gpa, input.@"var");

                const extra_index = c.extra.items.len;
                try c.extra.append(gpa, @intCast(u32, offset));
                try c.extra.append(gpa, @intCast(u32, input.@"var".len));
                break :blk .{
                    .lhs = @intToEnum(Inst.Ref, extra_index),
                    .rhs = input.operand,
                };
            },
            .@"if" => blk: {
                const extra_index = c.extra.items.len;
                try c.extra.append(gpa, input.then_body);
                try c.extra.append(gpa, input.else_body);
                break :blk .{
                    .lhs = input.cond,
                    .rhs = @intToEnum(Inst.Ref, extra_index),
                };
            },
            .@"var", .str => blk: {
                const offset = c.strings.items.len;
                try c.strings.appendSlice(gpa, input);
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
