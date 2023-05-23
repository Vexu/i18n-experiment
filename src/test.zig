const std = @import("std");
const lib = @import("lib.zig");

test "simple translation" {
    try testFormat(
        \\# Comment explaining something about this translation
        \\def "Hello {%name}!"
        \\    "Moikka {%name}!"
        \\end
    ,
        "Hello {s:%name}!",
        .{"Veikka"},
        "Moikka Veikka!",
    );
}

test "use of undefined argument" {
    try testFormat(
        \\def "Bye {%name}!"
        \\    "Heippa {%foo}!"
        \\end
    ,
        "Bye {s:%name}!",
        .{"Veikka"},
        "Heippa [UNDEFINED ARGUMENT %foo]!",
    );
}

fn testFormat(input: [:0]const u8, comptime fmt: []const u8, args: anytype, expected: []const u8) !void {
    var ctx = ctx: {
        var defs = try lib.parse(std.testing.allocator, input);
        break :ctx lib.Context{ .defs = defs, .gpa = std.testing.allocator };
    };
    defer ctx.deinit();

    var out_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer out_buf.deinit();

    try ctx.format(out_buf.writer(), fmt, args);
    try std.testing.expectEqualStrings(expected, out_buf.items);
}
