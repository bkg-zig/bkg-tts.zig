const std = @import("std");
const espeak = @import("src/tts/espeak.zig");

fn dump(gpa: std.mem.Allocator, e: *espeak.Espeak, text: []const u8) !void {
    std.debug.print("--- input [{s}]\n", .{text});
    const clauses = try e.phonemizeClauses(text);
    defer {
        for (clauses) |c| gpa.free(c.text);
        gpa.free(clauses);
    }
    std.debug.print("clauses={d}\n", .{clauses.len});
    for (clauses) |c| {
        std.debug.print("  [{s}] term=0x{x} len={d}\n", .{ c.text, c.terminator, c.text.len });
    }
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;

    var e = try espeak.Espeak.open(gpa, .{
        .library_path = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1",
        .data_dir = "/usr/lib/x86_64-linux-gnu/espeak-ng-data",
        .voice = "en-us",
    });
    defer e.deinit();

    try dump(gpa, &e, "Hello world.");
    try dump(gpa, &e, "Hello world, this is a test,");
    try dump(gpa, &e, "Hello. World");
    try dump(gpa, &e, "Really?");
}
