//! Audioausgabe: WAV (RIFF/PCM16) und rohes PCM16.
//!
//! Die Kitten-ONNX-Modelle liefern Float-Samples in [-1, 1]. Fuer die
//! Ausgabe werden sie auf 16-Bit-Ganzzahlen quantisiert.
const std = @import("std");

pub const wav_header_bytes = 44;

/// Quantisiert Float-Samples auf 16-Bit und legt sie little-endian ab.
pub fn encodePcm16(gpa: std.mem.Allocator, samples: []const f32) ![]u8 {
    const byte_len = std.math.mul(usize, samples.len, 2) catch return error.AudioTooLarge;
    const bytes = try gpa.alloc(u8, byte_len);
    errdefer gpa.free(bytes);
    for (samples, 0..) |sample, index| {
        const clamped = @max(-1.0, @min(1.0, sample));
        const value: i16 = @intFromFloat(@round(clamped * 32767.0));
        std.mem.writeInt(i16, bytes[index * 2 ..][0..2], value, .little);
    }
    return bytes;
}

/// Baut eine mono-PCM16-WAV-Datei mit 44-Byte-Header.
pub fn encodeWav(gpa: std.mem.Allocator, samples: []const f32, sample_rate: u32) ![]u8 {
    const data_len = std.math.mul(usize, samples.len, 2) catch return error.AudioTooLarge;
    if (data_len > std.math.maxInt(u32) - wav_header_bytes) return error.AudioTooLarge;
    const total = data_len + wav_header_bytes;
    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);

    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], @intCast(total - 8), .little);
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, out[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, out[22..24], 1, .little); // mono
    std.mem.writeInt(u32, out[24..28], sample_rate, .little);
    std.mem.writeInt(u32, out[28..32], sample_rate * 2, .little); // byte rate
    std.mem.writeInt(u16, out[32..34], 2, .little); // block align
    std.mem.writeInt(u16, out[34..36], 16, .little); // bits per sample
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], @intCast(data_len), .little);

    const pcm = try encodePcm16(gpa, samples);
    defer gpa.free(pcm);
    @memcpy(out[44..], pcm);
    return out;
}

test "wav header describes mono pcm16" {
    const gpa = std.testing.allocator;
    const samples = [_]f32{ 0.0, 0.5, -0.5 };
    const wav = try encodeWav(gpa, &samples, 24000);
    defer gpa.free(wav);

    try std.testing.expectEqualStrings("RIFF", wav[0..4]);
    try std.testing.expectEqualStrings("WAVE", wav[8..12]);
    try std.testing.expectEqualStrings("fmt ", wav[12..16]);
    try std.testing.expectEqualStrings("data", wav[36..40]);
    try std.testing.expectEqual(@as(u32, 24000), std.mem.readInt(u32, wav[24..28], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, wav[22..24], .little));
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, wav[40..44], .little));
    try std.testing.expectEqual(@as(u32, 50), std.mem.readInt(u32, wav[4..8], .little));
    try std.testing.expectEqual(@as(i16, 16384), std.mem.readInt(i16, wav[46..48], .little));
}

test "pcm16 clamps out-of-range samples" {
    const gpa = std.testing.allocator;
    const samples = [_]f32{ -2.0, 2.0 };
    const pcm = try encodePcm16(gpa, &samples);
    defer gpa.free(pcm);
    try std.testing.expectEqual(@as(i16, -32767), std.mem.readInt(i16, pcm[0..2], .little));
    try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, pcm[2..4], .little));
}
