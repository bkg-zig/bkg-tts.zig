//! Grenzwerte des Vertrags zwischen Server, Browser und Kommandozeile.
//!
//! Die Werte stehen in diesem Modul, damit die drei Wege nicht
//! auseinanderlaufen. Der Browser bekommt sie ueber das WASM-Modul, die
//! Kommandozeile und der Server lesen sie hier direkt.
const std = @import("std");

/// Hoechste Laenge des Textes einer Anfrage.
///
/// Der Server vergleicht die Bytezahl des UTF-8-Textes mit diesem Wert.
pub const max_text_chars: usize = 5000;

/// Kleinstes Tempo der HTTP-Schnittstellen.
pub const min_speed: f32 = 0.25;

/// Groesstes Tempo der HTTP-Schnittstellen.
pub const max_speed: f32 = 4.0;

/// Kleinstes Tempo einer Realtime-Sitzung.
pub const realtime_min_speed: f32 = 0.5;

/// Groesstes Tempo einer Realtime-Sitzung.
pub const realtime_max_speed: f32 = 2.0;

/// Textform des kleinsten Tempos.
///
/// Die Zahlen und ihre Schreibweise muessen uebereinstimmen. Der Test am
/// Ende der Datei prueft das.
pub const min_speed_text = "0.25";

/// Textform des groessten Tempos.
pub const max_speed_text = "4.0";

/// Textform des Tempobereichs der HTTP-Schnittstellen.
pub const speed_range_text: []const u8 = std.fmt.comptimePrint("zwischen {s} und {s}", .{ min_speed_text, max_speed_text });

/// Textform der Textgrenze.
pub const max_text_text: []const u8 = std.fmt.comptimePrint("{d}", .{max_text_chars});

/// true, wenn das Tempo im Bereich der HTTP-Schnittstellen liegt.
pub fn speedAllowed(speed: f32) bool {
    return speed >= min_speed and speed <= max_speed;
}

/// true, wenn das Tempo im Bereich einer Realtime-Sitzung liegt.
pub fn realtimeSpeedAllowed(speed: f32) bool {
    return speed >= realtime_min_speed and speed <= realtime_max_speed;
}

test "die Tempo-Grenzen liegen am dokumentierten Vertrag" {
    try std.testing.expect(speedAllowed(0.25));
    try std.testing.expect(speedAllowed(4.0));
    try std.testing.expect(!speedAllowed(0.24));
    try std.testing.expect(!speedAllowed(4.01));
    try std.testing.expect(realtimeSpeedAllowed(0.5));
    try std.testing.expect(realtimeSpeedAllowed(2.0));
    try std.testing.expect(!realtimeSpeedAllowed(0.49));
    try std.testing.expect(!realtimeSpeedAllowed(2.01));
}

test "die Textform der Tempo-Grenzen nennt dieselben Zahlen" {
    const parsed_min = try std.fmt.parseFloat(f32, min_speed_text);
    const parsed_max = try std.fmt.parseFloat(f32, max_speed_text);
    try std.testing.expectEqual(min_speed, parsed_min);
    try std.testing.expectEqual(max_speed, parsed_max);
}
