const std = @import("std");
const Build = std.Build;

pub const i18n = @import("src/lib.zig");

pub fn build(b: *Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run all tests");
    const test_exe = b.addTest(.{ .root_source_file = b.path("src/lib.zig") });
    const run_test = b.addRunArtifact(test_exe);
    test_step.dependOn(&run_test.step);

    const example = b.addExecutable(.{
        .name = "example application",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("examples/generate_defs.zig"),
    });
    i18n.addTo(&example.root_module, b.path("src/lib.zig"));

    const generate_defs_step = b.step("generate_defs", "Generate definitions for the example ");
    const generate_defs = i18n.GenerateDefsStep.create(b, .{ .compile_step = example });
    generate_defs_step.dependOn(&generate_defs.step);
}
