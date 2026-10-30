//! Vergleich der espeak-Anbindung mit der Kommandozeile.
const std = @import("std");
const espeak = @import("src/tts/espeak.zig");

const Case = struct {
    voice: []const u8,
    text: []const u8,
};

pub fn main() !void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const gpa = arena_inst.allocator();

    const cases = [_]Case{
        .{ .voice = "en-us", .text = "Hello world. How are you?" },
        .{ .voice = "en-us", .text = "Hello, world!" },
        .{ .voice = "en-us", .text = "Dr. Smith's number is 42." },
        .{ .voice = "en-us", .text = "hello world, how are you?" },
        .{ .voice = "de", .text = "Guten Tag, wie geht es Ihnen?" },
        .{ .voice = "de", .text = "Übergrößenträger: schön." },
    };

    for (cases) |case| {
        var instance = try espeak.Espeak.open(gpa, .{
            .library_path = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1",
            .data_dir = "/usr/lib/x86_64-linux-gnu/espeak-ng-data",
            .voice = case.voice,
        });
        defer instance.deinit();

        const clauses = try instance.phonemizeClauses(case.text);
        defer {
            for (clauses) |clause| gpa.free(clause.text);
            gpa.free(clauses);
        }

        std.debug.print("=== {s} | {s}\n", .{ case.voice, case.text });
        for (clauses) |clause| {
            std.debug.print("[{s}] 0x{x}\n", .{ clause.text, clause.terminator });
        }
    }
}
