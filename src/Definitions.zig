const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;

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

pub fn getExtra(defs: *Definitions, comptime op: Inst.Op, ref: Inst.Ref) op.Data() {
    const data = defs.insts.items(.data)[@enumToInt(ref)];
    switch (op) {
        .end => {},
        .set_var => {
            const offset = defs.extra.items[data.lhs];
            const len = defs.extra.items[data.lhs + 1];
            return .{
                .@"var" = defs.strings.items[offset..][0..len],
                .operand = data.rhs,
            };
        },
        .set_arg => return .{
            .pos = @intCast(u5, data.lhs),
            .operand = data.rhs,
        },
        .@"if" => return .{
            .then_body = defs.extra.items[data.rhs],
            .else_body = defs.extra.items[data.rhs + 1],
            .cond = data.lhs,
        },
        .@"var", .str => {
            const offset = @enumToInt(data.lhs);
            const len = @enumToInt(data.rhs);
            return defs.strings.items[offset..][0..len];
        },
        .arg => return @intCast(u5, data.lhs),
        .bool => return data.lhs != 0,
        .int => return @bitCast(u64, data),
        .float => return @bitCast(f64, data),
        .not => return data.lhs,
        else => return data,
    }
}
