const std = @import("std");
const lib = @import("lib.zig");

test "simple translation" {
    try testFormat(
        \\# Comment explaining something about this translation
        \\def "Hello {%name}!"
        \\    "Moikka {%name}!"
        \\end
    ,
        "Hello {s}!",
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
        "Bye {s}!",
        .{"Veikka"},
        "Heippa [UNDEFINED ARGUMENT %foo]!",
    );
}

test "complex value" {
    try testFormat(
        \\def "This is a tuple {%0}!"
        \\    "Tämä on monikko {%0}!"
        \\end
    ,
        "This is a tuple {}!",
        .{.{ .hello_world, 1 }},
        "Tämä on monikko { .hello_world, 1 }!",
    );
}

test "numbers in binary" {
    try testFormat(
        \\def "{%dec} in binary is {%bin}"
        \\    "{%dec} on binäärinä {%bin}"
        \\end
    ,
        "{[0]} in binary is {[0]b}",
        .{12},
        "12 on binäärinä 1100",
    );
}

fn testFormat(input: [:0]const u8, comptime fmt: []const u8, args: anytype, expected: []const u8) !void {
    const a = std.testing.allocator;
    var ctx = lib.Context{ .arena = std.heap.ArenaAllocator.init(a) };
    defer ctx.deinit();

    try lib.parse(&ctx, input);

    var out_buf = std.ArrayList(u8).init(a);
    defer out_buf.deinit();

    try ctx.format(out_buf.writer(), fmt, args);
    try std.testing.expectEqualStrings(expected, out_buf.items);
}
