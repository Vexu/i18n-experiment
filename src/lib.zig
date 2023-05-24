const std = @import("std");
const Step = std.Build.Step;

pub const Code = @import("Code.zig");
pub const Context = @import("Context.zig");
pub const Value = @import("value.zig").Value;
pub const parse = @import("Parser.zig").parse;

pub const GenerateDefsStep = struct {
    step: Step,
    compile_step: *Step.Compile,

    pub const base_id = .custom;

    pub const Options = struct {
        compile_step: *Step.Compile,
    };

    pub fn create(owner: *std.Build, options: Options) *GenerateDefsStep {
        const self = owner.allocator.create(GenerateDefsStep) catch @panic("OOM");
        self.* = .{
            .step = Step.init(.{
                .id = base_id,
                .name = "GenerateDefsStep",
                .owner = owner,
                .makeFn = make,
            }),
            .compile_step = options.compile_step,
        };

        const new_options = owner.addOptions();
        new_options.addOption(bool, "log_fmts", true);
        const i18n_module = options.compile_step.modules.get("i18n").?;
        i18n_module.dependencies.values()[0] = new_options.createModule();
        self.step.dependOn(&new_options.step);
        return self;
    }

    fn make(step: *Step, prog_node: *std.Progress.Node) !void {
        const self = @fieldParentPtr(GenerateDefsStep, "step", step);
        // Make the compilation step as usual.
        self.compile_step.step.make(prog_node) catch {};
        const log_txt = self.compile_step.step.result_error_bundle.getCompileLogOutput();

        var list = std.ArrayList([]const u8).init(step.owner.allocator);
        defer list.deinit();
        var start: usize = 0;
        while (true) {
            start = std.mem.indexOfScalarPos(u8, log_txt, start, '"') orelse break;
            const end = std.mem.indexOfScalarPos(u8, log_txt, start, '\n') orelse log_txt.len;
            try list.append(log_txt[start .. end - 1]);
            start = end;
        }
        const lessThan = struct {
            pub fn lessThan(_: void, rhs: []const u8, lhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs).compare(.lt);
            }
        }.lessThan;
        std.mem.sort([]const u8, list.items, {}, lessThan);

        const file = blk: {
            var dir = try step.owner.build_root.handle.makeOpenPath("res", .{});
            defer dir.close();
            break :blk try dir.createFile("base.def", .{});
        };
        defer file.close();
        var buf = std.io.bufferedWriter(file.writer());
        const w = buf.writer();
        for (list.items) |item| {
            try w.print("# def {s}\n", .{item});
        }
        try buf.flush();
    }
};

// TODO this should probably take a *Module but I don't know how
pub fn addTo(cs: *Step.Compile, path: []const u8) void {
    const b = cs.step.owner;
    const options = b.addOptions();
    options.addOption(bool, "log_fmts", false);
    const module = b.createModule(.{
        .source_file = .{ .path = path },
        .dependencies = &.{.{
            .name = "options",
            .module = options.createModule(),
        }},
    });
    return cs.addModule("i18n", module);
}

test {
    _ = @import("test.zig");
}
