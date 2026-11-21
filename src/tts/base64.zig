//! Base64-Decoder fuer eingebettete Modellmetadaten.
//!
//! Manche ONNX-Dateien legen Binaerdaten als Base64-Text in den
//! Metadaten ab. Der Decoder akzeptiert das Standard-Alphabet mit
//! `=`-Padding und ignoriert Leerraum, wie ihn die Metadaten-Produzenten
//! verwenden.
const std = @import("std");

/// Fehler des Decoders.
pub const Error = error{
    /// Ein Zeichen gehoert nicht zum Base64-Alphabet.
    InvalidCharacter,
    /// Die Laenge der Eingabe passt zu keiner gueltigen Base64-Laenge.
    InvalidLength,
    /// Das Padding steht an einer falschen Stelle.
    InvalidPadding,
    /// Der Speicher reicht nicht aus.
    OutOfMemory,
};

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Wert eines Base64-Zeichens. 64 steht fuer das Fuellzeichen `=`.
fn decodeChar(char: u8) Error!u8 {
    if (char == '=') return 64;
    for (alphabet, 0..) |candidate, index| {
        if (candidate == char) return @intCast(index);
    }
    return error.InvalidCharacter;
}

/// Prueft, ob ein Zeichen Leerraum ist.
fn isWhitespace(char: u8) bool {
    return char == ' ' or char == '\t' or char == '\n' or char == '\r';
}

/// Dekodiert Base64-Text.
///
/// Die Funktion erwartet eine gepufferte Eingabe. Zwischen den Gruppen
/// duerfen Leerzeichen stehen. Das Padding muss am Ende stehen und zur
/// Laenge der restlichen Daten passen.
pub fn decode(gpa: std.mem.Allocator, input: []const u8) Error![]u8 {
    var values: std.ArrayList(u8) = .empty;
    defer values.deinit(gpa);

    var padding: usize = 0;
    for (input) |char| {
        if (isWhitespace(char)) continue;

        if (char == '=') {
            padding += 1;
            continue;
        }
        // Nach dem Fuellzeichen darf kein Datenzeichen mehr kommen.
        if (padding > 0) return error.InvalidPadding;

        const value = try decodeChar(char);
        try values.append(gpa, value);
    }

    const count = values.items.len;
    if (padding > 2) return error.InvalidPadding;
    // Ein Fuellzeichen beendet eine Gruppe. Zwei Fuellzeichen gehoeren zu
    // einer Gruppe mit zwei Datenzeichen, ein Fuellzeichen zu einer Gruppe
    // mit drei Datenzeichen.
    if (padding > 0 and count % 4 != 4 - padding) return error.InvalidPadding;
    if ((count + padding) % 4 != 0) return error.InvalidLength;

    const rest: usize = switch (count % 4) {
        0 => 0,
        2 => 1,
        3 => 2,
        else => unreachable,
    };
    const output_len: usize = count / 4 * 3 + rest;

    const output = try gpa.alloc(u8, output_len);
    errdefer gpa.free(output);

    var written: usize = 0;
    var index: usize = 0;
    while (index + 4 <= count) : (index += 4) {
        const a = values.items[index];
        const b = values.items[index + 1];
        const c = values.items[index + 2];
        const d = values.items[index + 3];
        output[written] = @truncate(@as(u32, a) << 2 | @as(u32, b) >> 4);
        output[written + 1] = @truncate(@as(u32, b) << 4 | @as(u32, c) >> 2);
        output[written + 2] = @truncate(@as(u32, c) << 6 | @as(u32, d));
        written += 3;
    }

    if (count % 4 == 2) {
        const a = values.items[index];
        const b = values.items[index + 1];
        output[written] = @truncate(@as(u32, a) << 2 | @as(u32, b) >> 4);
    } else if (count % 4 == 3) {
        const a = values.items[index];
        const b = values.items[index + 1];
        const c = values.items[index + 2];
        output[written] = @truncate(@as(u32, a) << 2 | @as(u32, b) >> 4);
        output[written + 1] = @truncate(@as(u32, b) << 4 | @as(u32, c) >> 2);
    }

    return output;
}

test "Base64 dekodiert bekannte Werte" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { encoded: []const u8, expected: []const u8 }{
        .{ .encoded = "", .expected = "" },
        .{ .encoded = "TQ==", .expected = "M" },
        .{ .encoded = "TWE=", .expected = "Ma" },
        .{ .encoded = "TWFu", .expected = "Man" },
        .{ .encoded = "TWFuTWFu", .expected = "ManMan" },
        .{ .encoded = "TWEgcTQ=", .expected = "Ma q4" },
    };

    for (cases) |case| {
        const decoded = try decode(gpa, case.encoded);
        defer gpa.free(decoded);
        try std.testing.expectEqualStrings(case.expected, decoded);
    }
}

test "Base64 ignoriert Leerraum" {
    const gpa = std.testing.allocator;
    const decoded = try decode(gpa, "TWFu\n TWFu\r\n");
    defer gpa.free(decoded);
    try std.testing.expectEqualStrings("ManMan", decoded);
}

test "Base64 lehnt kaputte Eingaben ab" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(error.InvalidCharacter, decode(gpa, "TWF*"));
    try std.testing.expectError(error.InvalidLength, decode(gpa, "TWF"));
    try std.testing.expectError(error.InvalidPadding, decode(gpa, "T=WF"));
    try std.testing.expectError(error.InvalidPadding, decode(gpa, "TWFu="));
}
