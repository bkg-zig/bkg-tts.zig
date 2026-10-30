//! Werkzeug: schreibt den Laufzeitvertrag eines ONNX-Modells auf die Konsole.
//!
//! Aufruf:
//!   BKG_TTS_ORT_LIB=~/.local/share/onnxruntime/lib/libonnxruntime.so \
//!   ./zig-out/bin/bkg-tts-probe <modell.onnx>
//!
//! Das Werkzeug gehoert nicht zum Serverpfad. Es hilft beim Pruefen, welche
//! Eingaben, Ausgaben und Metadaten ein Modell wirklich erwartet.
const std = @import("std");
const ort = @import("tts/ort.zig");

const default_ort_lib = "/home/openchamber/.local/share/onnxruntime/lib/libonnxruntime.so";
const max_metadata_bytes = 4000;

/// Schreibt eine Tensorform als `[1, 256]` in den Puffer.
fn formatShape(buffer: []u8, shape: []const i64) []const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    stream.writeAll("[") catch return buffer[0..0];
    for (shape, 0..) |dim, index| {
        if (index > 0) stream.writeAll(", ") catch return buffer[0..0];
        stream.print("{d}", .{dim}) catch return buffer[0..0];
    }
    stream.writeAll("]") catch return buffer[0..0];
    return stream.buffered();
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var args = init.args.iterate();
    _ = args.next();
    const model_arg = args.next() orelse {
        std.debug.print("Aufruf: bkg-tts-probe <modell.onnx>\n", .{});
        return error.MissingArgument;
    };

    const lib_path = std.process.Environ.getPosix(init.environ, "BKG_TTS_ORT_LIB") orelse default_ort_lib;

    var failure = ort.Failure{};
    var runtime = try ort.Runtime.open(lib_path, &failure);
    defer runtime.deinit();

    const model_path = try gpa.dupeZ(u8, model_arg);
    defer gpa.free(model_path);

    var session = try ort.Session.create(&runtime, gpa, model_path, .{}, &failure);
    defer session.deinit(gpa);

    std.debug.print("Modell: {s}\n", .{model_arg});
    std.debug.print("Runtime: {s}\n\n", .{runtime.version});

    for (session.input_names, 0..) |name, index| {
        var info = try session.inputInfo(gpa, index, &failure);
        defer info.deinit();
        var shape_buffer: [256]u8 = undefined;
        std.debug.print("Eingang {d}: {s} Typ={s} Form={s}\n", .{
            index,
            name,
            @tagName(info.element_type),
            formatShape(&shape_buffer, info.shape),
        });
    }

    for (session.output_names, 0..) |name, index| {
        var info = try session.outputInfo(gpa, index, &failure);
        defer info.deinit();
        var shape_buffer: [256]u8 = undefined;
        std.debug.print("Ausgang {d}: {s} Typ={s} Form={s}\n", .{
            index,
            name,
            @tagName(info.element_type),
            formatShape(&shape_buffer, info.shape),
        });
    }

    std.debug.print("\nMetadaten ({d} Schluessel):\n", .{session.metadata_keys.len});
    for (session.metadata_keys) |key| {
        const value = try session.metadataValue(gpa, key, &failure);
        defer if (value) |text| gpa.free(text);
        if (value) |text| {
            const clipped = text[0..@min(text.len, max_metadata_bytes)];
            std.debug.print("  {s} = {s}{s}\n", .{
                key,
                clipped,
                if (text.len > clipped.len) " ...(gekuerzt)" else "",
            });
        } else {
            std.debug.print("  {s} = (leer)\n", .{key});
        }
    }
}
