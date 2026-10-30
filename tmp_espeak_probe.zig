const std = @import("std");

const InitializeFn = *const fn (
    output: c_int,
    buflength: c_int,
    path: ?[*:0]const u8,
    options: c_int,
) callconv(.c) c_int;

const SetVoiceByNameFn = *const fn (name: [*:0]const u8) callconv(.c) c_int;

const TextToPhonemesFn = *const fn (
    textptr: *?*anyopaque,
    textmode: c_int,
    phonememode: c_int,
    terminator: *u32,
) callconv(.c) ?[*:0]const u8;

fn step(name: []const u8) void {
    std.debug.print("[step] {s}\n", .{name});
}

pub fn main() !void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const gpa = arena_inst.allocator();

    step("dlopen");
    var lib = std.DynLib.open("/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1") catch |err| {
        std.debug.print("dlopen failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer lib.close();

    step("lookup symbols");
    const initialize = lib.lookup(InitializeFn, "espeak_Initialize").?;
    const set_voice = lib.lookup(SetVoiceByNameFn, "espeak_SetVoiceByName").?;
    const to_phonemes = lib.lookup(TextToPhonemesFn, "espeak_TextToPhonemesWithTerminator").?;

    const data_dir = try gpa.dupeZ(u8, "/usr/lib/x86_64-linux-gnu/espeak-ng-data");
    const voice = try gpa.dupeZ(u8, "en-us");

    step("espeak_Initialize(data_dir)");
    const rate = initialize(2, 0, data_dir.ptr, 0);
    std.debug.print("initialize -> {d}\n", .{rate});

    step("espeak_SetVoiceByName");
    const status = set_voice(voice.ptr);
    std.debug.print("set_voice -> {d}\n", .{status});

    step("espeak_TextToPhonemesWithTerminator");
    const text = try gpa.dupeZ(u8, "Hello world.");
    var textptr: ?*anyopaque = @ptrCast(text.ptr);
    var terminator: u32 = 0;
    const phonemes = to_phonemes(&textptr, 1, 0x02, &terminator);
    std.debug.print("phonemes ptr = {*}\n", .{phonemes});
    if (phonemes) |p| {
        std.debug.print("phonemes = [{s}] terminator = 0x{x}\n", .{ std.mem.span(p), terminator });
    }
    step("done");
}
