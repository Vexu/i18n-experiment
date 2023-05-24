const std = @import("std");
const lib = @import("lib.zig");

test "simple translation" {
    try testFormat(
        \\# Comment explaining something about this translation
        \\def "Hello {%name}!"
        \\    "Moikka {%name}!"
        \\end
    , "Hello {s}!", .{.{
        .{"Veikka"},
        "Moikka Veikka!",
    }});
}

test "use of undefined argument" {
    try testFormat(
        \\def "Bye {%name}!"
        \\    "Heippa {%foo}!"
        \\end
    , "Bye {s}!", .{.{
        .{"Veikka"},
        "Heippa [UNDEFINED ARGUMENT %foo]!",
    }});
}

test "complex value" {
    try testFormat(
        \\def "This is a tuple {%0}!"
        \\    "Tämä on monikko {%0}!"
        \\end
    , "This is a tuple {}!", .{.{
        .{.{ .hello_world, 1 }},
        "Tämä on monikko { .hello_world, 1 }!",
    }});
}

test "numbers in binary" {
    try testFormat(
        \\def "{%dec} in binary is {%bin}"
        \\    "binääri {%bin} on {%dec}"
        \\end
    , "{[0]} in binary is {[0]b}", .{.{
        .{12},
        "binääri 1100 on 12",
    }});
}

test "set argument" {
    try testFormat(
        \\def "this is {%bool}"
        \\    set %bool to false
        \\    "this is {%bool}"
        \\end
    , "this is {}", .{.{
        .{true},
        "this is false",
    }});
}

test "set variable" {
    try testFormat(
        \\def "no arguments here"
        \\    set %my_var to true
        \\    "but my var is {%my_var}"
        \\end
    , "no arguments here", .{.{
        .{},
        "but my var is true",
    }});
}

test "simple if" {
    try testFormat(
        \\def "{%bool1} {%bool2}"
        \\    if %bool1
        \\        "bool1"
        \\    elseif %bool2
        \\       "bool2"
        \\    else
        \\        "neither"
        \\    end
        \\end
    , "{} {}", .{
        .{
            .{ false, false },
            "neither",
        },
        .{
            .{ true, false },
            "bool1",
        },
        .{
            .{ false, true },
            "bool2",
        },
    });
}

fn testFormat(input: [:0]const u8, comptime fmt: []const u8, comptime tests: anytype) !void {
    const a = std.testing.allocator;
    var ctx = lib.Context{ .arena = std.heap.ArenaAllocator.init(a) };
    defer ctx.deinit();

    try lib.parse(&ctx, input);

    var out_buf = std.ArrayList(u8).init(a);
    defer out_buf.deinit();

    inline for (tests) |@"test"| {
        try ctx.format(out_buf.writer(), fmt, @"test"[0]);
        try std.testing.expectEqualStrings(@as([]const u8, @"test"[1]), out_buf.items);
        out_buf.items.len = 0;
    }
}
