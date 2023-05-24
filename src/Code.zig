const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const log = std.log.scoped(.i18n);
const lib = @import("lib.zig");

const Code = @This();

pub const Program = struct { body: u32 };

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
                .int => i64,
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
        cond: Inst.Ref,
        then_body: u32,
        else_body: u32,
    };

    pub const Bin = extern struct {
        lhs: Inst.Ref,
        rhs: Inst.Ref,
    };

    pub const Ref = enum(u32) { _ };
};

pub const Vm = struct {
    ctx: *lib.Context,
    args: []lib.Context.Argument,
    vars: std.StringHashMapUnmanaged(lib.Value) = .{},

    pub fn deinit(vm: *Vm) void {
        vm.vars.deinit(vm.ctx.arena.child_allocator);
        vm.* = undefined;
    }

    pub fn run(vm: *Vm, program: Program) !lib.Value {
        const body = @ptrCast([]Inst.Ref, vm.ctx.code.extra.items[program.body..]);
        return vm.evalBody(body);
    }

    fn evalBody(vm: *Vm, body: []Inst.Ref) !lib.Value {
        var i: usize = 0;
        const ops = vm.ctx.code.insts.items(.op);
        while (true) {
            const inst = body[i];
            i += 1;
            switch (ops[@enumToInt(inst)]) {
                .set_var => {
                    const set = vm.ctx.code.getExtra(.set_var, inst);
                    const val = try vm.evalExpr(set.operand);
                    try vm.vars.put(vm.ctx.arena.child_allocator, set.@"var", val);
                },
                .set_arg => {
                    const set = vm.ctx.code.getExtra(.set_arg, inst);
                    const val = try vm.evalExpr(set.operand);
                    vm.args[set.pos].val = val;
                },
                .@"if" => {
                    const @"if" = vm.ctx.code.getExtra(.@"if", inst);
                    const cond = try vm.evalExpr(@"if".cond);
                    const cond_bool = switch (cond) {
                        .bool => |b| b,
                        .int => |int| int != 0,
                        .float => |float| float != 0,
                        else => {
                            log.warn("ignoring 'if' with non-boolean condition", .{});
                            continue;
                        },
                    };
                    const then_body = @ptrCast([]Inst.Ref, vm.ctx.code.extra.items[@"if".then_body..]);
                    const else_body = @ptrCast([]Inst.Ref, vm.ctx.code.extra.items[@"if".else_body..]);
                    const body_res = if (cond_bool)
                        try vm.evalBody(then_body)
                    else if (@"if".else_body != 0)
                        try vm.evalBody(else_body)
                    else
                        .none;
                    if (body_res == .str) return body_res;
                },
                .str => return .{ .str = vm.ctx.code.getExtra(.str, inst) },
                .end => return .none,
                else => unreachable,
            }
        }
    }

    fn evalExpr(vm: *Vm, inst: Inst.Ref) !lib.Value {
        const ops = vm.ctx.code.insts.items(.op);
        switch (ops[@enumToInt(inst)]) {
            .bool => return .{ .bool = vm.ctx.code.getExtra(.bool, inst) },
            .int => return .{ .int = vm.ctx.code.getExtra(.int, inst) },
            .float => return .{ .float = vm.ctx.code.getExtra(.float, inst) },
            .arg => return vm.args[vm.ctx.code.getExtra(.arg, inst)].val,
            .set_arg, .set_var, .@"if", .end => unreachable,
            else => |op| std.debug.panic("TODO eval {}", .{op}),
        }
    }
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
            const extra_index = @enumToInt(data.lhs);
            const offset = c.extra.items[extra_index];
            const len = c.extra.items[extra_index + 1];
            return .{
                .@"var" = c.strings.items[offset..][0..len],
                .operand = data.rhs,
            };
        },
        .set_arg => return .{
            .pos = @intCast(u5, @enumToInt(data.lhs)),
            .operand = data.rhs,
        },
        .@"if" => {
            const extra_index = @enumToInt(data.rhs);
            return .{
                .then_body = c.extra.items[extra_index],
                .else_body = c.extra.items[extra_index + 1],
                .cond = data.lhs,
            };
        },
        .@"var", .str => {
            const offset = @enumToInt(data.lhs);
            const len = @enumToInt(data.rhs);
            return c.strings.items[offset..][0..len];
        },
        .arg => return @intCast(u5, @enumToInt(data.lhs)),
        .bool => return @enumToInt(data.lhs) != 0,
        .int => return @bitCast(i64, data),
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
