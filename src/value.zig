const std = @import("std");
const lib = @import("lib.zig");

pub const Value = union(enum) {
    bool: bool,
    int: i64,
    float: f64,
    str: []const u8,
    preformatted: []const u8,

    pub fn from(
        arena: *std.heap.ArenaAllocator,
        value: anytype,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
    ) !Value {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .Bool => {
                if (fmt.len != 0) std.fmt.invalidFmtError(fmt, value);
                return .{ .bool = value };
            },
            .Pointer => {
                if (comptime std.mem.eql(u8, fmt, "s") and std.meta.trait.isZigString(T)) {
                    return .{ .str = value };
                }
            },
            .Int => {
                if (fmt.len > 1 or switch (fmt[0]) {
                    'd', 'c', 'u', 'b', 'x', 'X', 'o' => true,
                    else => false,
                }) std.fmt.invalidFmtError(fmt, value);
                if (std.math.cast(i64, value)) |some| {
                    return .{ .int = some };
                }
            },
            .Float => {
                if (fmt.len > 1 or switch (fmt[0]) {
                    'e', 'd', 'x' => true,
                    else => false,
                }) std.fmt.invalidFmtError(fmt, value);
                return .{ .int = value };
            },
            else => {},
        }
        var out_buf = std.ArrayList(u8).init(arena.child_allocator);
        defer out_buf.deinit();
        try std.fmt.formatType(value, fmt, options, out_buf.writer(), std.options.fmt_max_depth);

        return .{ .preformatted = try arena.allocator().dupe(u8, out_buf.items) };
    }
};
