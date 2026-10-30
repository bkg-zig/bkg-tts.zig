//! Aufteilung eines Textes in Abschnitte, die einzeln synthetisiert werden.
//!
//! Die Regeln entsprechen der Kitten-Referenz:
//!
//! * Der Text wird an Folgen von Punkt, Frage- und Ausrufezeichen getrennt,
//!   die Trenner entfallen.
//! * Jeder Abschnitt wird getrimmt und leerer Inhalt wird uebersprungen.
//! * Ein Abschnitt, der laenger als die Grenze ist, wird an Wortgrenzen
//!   geteilt. Die Grenze wird in Bytes gemessen.
//! * Ein Abschnitt ohne Satzzeichen am Ende bekommt ein Komma angehaengt.

const std = @import("std");

const unicode = @import("unicode.zig");

/// Zeichen, an denen ein Abschnitt endet.
const sentence_end = ".!?";

/// Zeichen, nach denen ein Abschnitt bereits mit Satzzeichen endet.
const sentence_terminators = ".!?,;:";

/// Eine Liste von Textabschnitten mit eigenem Speicher.
pub const ChunkList = struct {
    gpa: std.mem.Allocator,
    items: [][]u8,

    pub fn deinit(self: *const ChunkList) void {
        for (self.items) |item| self.gpa.free(item);
        self.gpa.free(self.items);
    }
};

/// Teilt den Text in Abschnitte, die hoechstens `max_len` Bytes lang sind.
///
/// `max_len` von null schaltet die Aufteilung ab. Dann wird der Text an den
/// Satzzeichen getrennt, aber nicht an Wortgrenzen.
pub fn chunkText(gpa: std.mem.Allocator, text: []const u8, max_len: usize) !ChunkList {
    var chunks: std.ArrayList([]u8) = .empty;
    errdefer {
        for (chunks.items) |item| gpa.free(item);
        chunks.deinit(gpa);
    }

    var sentences: std.ArrayList([]const u8) = .empty;
    defer sentences.deinit(gpa);
    try splitSentences(gpa, text, &sentences);

    for (sentences.items) |raw| {
        const sentence = trimUnicode(raw);
        if (sentence.len == 0) continue;

        if (max_len == 0 or sentence.len <= max_len) {
            try chunks.append(gpa, try ensurePunctuation(gpa, sentence));
            continue;
        }
        try splitLongSentence(gpa, sentence, max_len, &chunks);
    }

    return .{ .gpa = gpa, .items = try chunks.toOwnedSlice(gpa) };
}

/// Haengt ein Komma an, wenn der Abschnitt nicht mit einem Satzzeichen endet.
pub fn ensurePunctuation(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = trimUnicode(text);
    if (trimmed.len == 0) return gpa.dupe(u8, trimmed);

    const last = lastCodepoint(trimmed) orelse return gpa.dupe(u8, trimmed);
    if (last <= 0x7F and std.mem.indexOfScalar(u8, sentence_terminators, @intCast(last)) != null) {
        return gpa.dupe(u8, trimmed);
    }
    return std.fmt.allocPrint(gpa, "{s},", .{trimmed});
}

/// Entfernt Leerraum an beiden Enden.
///
/// Als Leerraum gilt die Unicode-Eigenschaft White_Space. Das entspricht dem
/// Verhalten der Rust-Referenz, die `str::trim` und `str::split_whitespace`
/// benutzt.
pub fn trimUnicode(text: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = text.len;

    while (start < end) {
        const next = nextCodepoint(text, start) orelse break;
        if (!unicode.isWhitespace(next.codepoint)) break;
        start += next.length;
    }

    while (end > start) {
        var probe = end - 1;
        while (probe > start and (text[probe] & 0xC0) == 0x80) probe -= 1;
        const next = nextCodepoint(text, probe) orelse break;
        if (probe + next.length != end) break;
        if (!unicode.isWhitespace(next.codepoint)) break;
        end = probe;
    }

    return text[start..end];
}

/// Ein Codepoint mit seiner Bytelaenge.
const Codepoint = struct {
    codepoint: u21,
    length: usize,
};

/// Liest den Codepoint an der angegebenen Stelle.
fn nextCodepoint(text: []const u8, index: usize) ?Codepoint {
    if (index >= text.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
    if (index + length > text.len) return null;
    const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch return null;
    return .{ .codepoint = codepoint, .length = length };
}

/// Liest den letzten Codepoint eines Textes.
fn lastCodepoint(text: []const u8) ?u21 {
    if (text.len == 0) return null;
    var probe = text.len - 1;
    while (probe > 0 and (text[probe] & 0xC0) == 0x80) probe -= 1;
    const next = nextCodepoint(text, probe) orelse return null;
    return next.codepoint;
}

/// Trennt den Text an Folgen von Satzzeichen. Die Trenner entfallen.
fn splitSentences(
    gpa: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.indexOfScalar(u8, sentence_end, text[index]) == null) {
            index += 1;
            continue;
        }
        try out.append(gpa, text[start..index]);
        while (index < text.len and std.mem.indexOfScalar(u8, sentence_end, text[index]) != null) {
            index += 1;
        }
        start = index;
    }
    try out.append(gpa, text[start..]);
}

/// Teilt einen Satz an den Wortgrenzen auf.
///
/// Die Laengenpruefung der Referenz zaehlt die Bytes des Wortes und die
/// Bytes des bisherigen Abschnitts, aber nicht das Trennzeichen. Ein
/// Abschnitt kann deshalb ein Byte laenger werden als die Grenze erlaubt.
fn splitLongSentence(
    gpa: std.mem.Allocator,
    sentence: []const u8,
    max_len: usize,
    chunks: *std.ArrayList([]u8),
) !void {
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(gpa);
    try splitWords(gpa, sentence, &words);

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);

    for (words.items) |word| {
        if (current.items.len + word.len < max_len) {
            if (current.items.len > 0) try current.append(gpa, ' ');
            try current.appendSlice(gpa, word);
            continue;
        }

        if (current.items.len > 0) {
            try chunks.append(gpa, try ensurePunctuation(gpa, current.items));
        }
        current.clearRetainingCapacity();
        try current.appendSlice(gpa, word);
    }

    if (current.items.len > 0) {
        try chunks.append(gpa, try ensurePunctuation(gpa, current.items));
    }
}

/// Zerlegt einen Text in Woerter. Leerraumfolgen trennen die Woerter.
fn splitWords(
    gpa: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var index: usize = 0;
    while (index < text.len) {
        while (index < text.len) {
            const next = nextCodepoint(text, index) orelse break;
            if (!unicode.isWhitespace(next.codepoint)) break;
            index += next.length;
        }
        if (index >= text.len) break;

        const start = index;
        while (index < text.len) {
            const next = nextCodepoint(text, index) orelse {
                index += 1;
                continue;
            };
            if (unicode.isWhitespace(next.codepoint)) break;
            index += next.length;
        }
        try out.append(gpa, text[start..index]);
    }
}

test "Satzzeichen trennt Abschnitte und entfaellt" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "Hello world. Second one!", 400);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("Hello world,", chunks.items[0]);
    try std.testing.expectEqualStrings("Second one,", chunks.items[1]);
}

test "Abschnitt ohne Satzzeichen bekommt ein Komma" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "Hallo Welt", 400);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Hallo Welt,", chunks.items[0]);
}

test "Satzzeichen am Ende entfaellt und wird durch Komma ersetzt" {
    const gpa = std.testing.allocator;
    // Die Referenz trennt den Text an ".!?" und entfernt die Trenner. Der
    // Abschnitt endet danach ohne Satzzeichen und bekommt ein Komma.
    var chunks = try chunkText(gpa, "Really?", 400);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Really,", chunks.items[0]);
}

test "Komma und Doppelpunkt am Ende bleiben erhalten" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "Wait; really: yes;", 400);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Wait; really: yes;", chunks.items[0]);
}

test "Leerer und nur aus Leerraum bestehender Text liefert nichts" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "  ...  ", 400);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 0), chunks.items.len);
}

test "Zu langer Abschnitt wird an Wortgrenzen geteilt" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "aaaa bbbb cccc", 10);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("aaaa bbbb,", chunks.items[0]);
    try std.testing.expectEqualStrings("cccc,", chunks.items[1]);
}

test "Die Grenze wird in Bytes gemessen" {
    const gpa = std.testing.allocator;
    // "äöü" belegt sechs Bytes.
    var chunks = try chunkText(gpa, "äöü bbbb", 8);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("äöü,", chunks.items[0]);
    try std.testing.expectEqualStrings("bbbb,", chunks.items[1]);
}

test "Leerraum am Rand wird entfernt" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "\t Hallo Welt \n", 400);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Hallo Welt,", chunks.items[0]);
}

test "Kurzer Abschnitt behaelt seinen Leerraum unveraendert" {
    const gpa = std.testing.allocator;
    // Die Referenz teilt nur lange Abschnitte an Wortgrenzen auf. Ein kurzer
    // Abschnitt behält den ursprünglichen Leerraum, auch geschuetzte Leerzeichen.
    var chunks = try chunkText(gpa, "aaaa\u{00A0}bbbb", 400);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("aaaa\u{00A0}bbbb,", chunks.items[0]);
}

test "Geschuetzter Leerraum trennt Woerter in langen Abschnitten" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "aaaa\u{00A0}bbbb", 8);
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("aaaa,", chunks.items[0]);
    try std.testing.expectEqualStrings("bbbb,", chunks.items[1]);
}
