const std = @import("std");

pub fn main() !void {
    std.debug.print("size ?*many={d} many={d} opt-many={d}\n", .{
        @sizeOf(?*[*c][*:0]u8),
        @sizeOf([*c][*:0]u8),
        @sizeOf(?[*c][*:0]u8),
    });
}
