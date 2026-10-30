//! Unicode-Hilfen fuer die Textpfade: NFD-Zerlegung und Codepoint-Iteration.
//!
//! Piper und Kokoro zerlegen ihre Phoneme in Normalisierungsform D, bevor
//! einzelne Codepoints gegen das Vokabular des Modells geprueft werden.
//! Die Zerlegungsregeln stehen in der erzeugten Datei `nfd_table.zig`.
const std = @import("std");
const table = @import("nfd_table.zig");

/// Prueft die Unicode-Eigenschaft White_Space.
///
/// Die Regex-Semantik von `\s` folgt dieser Eigenschaft. Rust, Python und
/// die Unicode-Datenbank liefern dieselbe Menge.
pub fn isWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000D,
        0x0020,
        0x0085,
        0x00A0,
        0x1680,
        0x2000...0x200A,
        0x2028,
        0x2029,
        0x202F,
        0x205F,
        0x3000,
        => true,
        else => false,
    };
}

/// Combining Class eines Codepoints. Null bedeutet "kein Markierungszeichen".
pub fn combiningClass(codepoint: u21) u8 {
    var low: usize = 0;
    var high: usize = table.combining_classes.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = table.combining_classes[mid];
        if (entry.codepoint == codepoint) return entry.class;
        if (entry.codepoint < codepoint) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return 0;
}

fn canonicalDecomposition(codepoint: u21) ?[]const u21 {
    var low: usize = 0;
    var high: usize = table.decompositions.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = table.decompositions[mid];
        if (entry.codepoint == codepoint) return entry.parts;
        if (entry.codepoint < codepoint) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return null;
}

/// Haengt die vollstaendige kanonische Zerlegung eines Codepoints an.
fn appendDecomposed(gpa: std.mem.Allocator, list: *std.ArrayList(u21), codepoint: u21) !void {
    const parts = canonicalDecomposition(codepoint) orelse {
        try list.append(gpa, codepoint);
        return;
    };
    for (parts) |part| try appendDecomposed(gpa, list, part);
}

/// Zerlegt UTF-8-Text in Normalisierungsform D.
///
/// Die Reihenfolge der Markierungszeichen wird nach ihrer Combining Class
/// sortiert, so wie es die kanonische Normalisierung vorschreibt.
pub fn normalizeNfd(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(gpa);

    var view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        try appendDecomposed(gpa, &codepoints, codepoint);
    }

    // Kanonische Reihenfolge: Markierungszeichen eines Laufs nach ihrer
    // Combining Class sortieren. Die Sortierung ist stabil.
    var index: usize = 1;
    while (index < codepoints.items.len) : (index += 1) {
        const class = combiningClass(codepoints.items[index]);
        if (class == 0) continue;
        var probe = index;
        while (probe > 0) : (probe -= 1) {
            const previous_class = combiningClass(codepoints.items[probe - 1]);
            if (previous_class == 0 or previous_class <= class) break;
            std.mem.swap(u21, &codepoints.items[probe - 1], &codepoints.items[probe]);
        }
    }

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    var buffer: [4]u8 = undefined;
    for (codepoints.items) |codepoint| {
        const length = try std.unicode.utf8Encode(codepoint, &buffer);
        try encoded.appendSlice(gpa, buffer[0..length]);
    }
    return encoded.toOwnedSlice(gpa);
}

test "NFD zerlegt den Cedilla in Grundbuchstabe und Marke" {
    const gpa = std.testing.allocator;
    const result = try normalizeNfd(gpa, "ç");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("c\u{0327}", result);
}

test "NFD laesst reine Phoneme unveraendert" {
    const gpa = std.testing.allocator;
    const result = try normalizeNfd(gpa, "həlˈoʊ");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("həlˈoʊ", result);
}

test "NFD sortiert Markierungszeichen nach ihrer Combining Class" {
    const gpa = std.testing.allocator;
    const result = try normalizeNfd(gpa, "q\u{0307}\u{0323}");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("q\u{0323}\u{0307}", result);
}
