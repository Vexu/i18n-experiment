const std = @import("std");
const i18n = @import("i18n");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const input =
        \\def "Hello {%name}!"
        \\    "Moikka {%name}!"
        \\end
        \\
    ;

    var ctx = i18n.Context{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer ctx.deinit();
    try i18n.parse(&ctx, input);

    var out_buf = std.ArrayList(u8).init(gpa);
    defer out_buf.deinit();

    try ctx.format(out_buf.writer(), "Hello foo {s}!", .{"Veikka"});
    try ctx.format(out_buf.writer(), "Hello baz {s}!", .{"Veikka"});
    try ctx.format(out_buf.writer(), "Hello bar {s}!", .{"Veikka"});
}
