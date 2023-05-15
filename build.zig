const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    _ = target;

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardOptimizeOption(.{});
    _ = mode;

    const tests_step = b.step("test", "Run all tests");
    var unit_tests = b.addTest(.{ .root_source_file = .{ .path = "src/main.zig" } });
    tests_step.dependOn(&unit_tests.step);
}
