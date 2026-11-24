//! Aufteilung eines Textes in Abschnitte, die einzeln synthetisiert werden.
//!
//! Die Regeln stehen in `Options`. Der Deskriptor des Modells liefert sie:
//!
//! * Der Text wird an den Zeichen aus `split_chars` getrennt, die Trenner
//!   entfallen.
//! * Jeder Abschnitt wird getrimmt und leerer Inhalt wird uebersprungen.
//! * Ein Abschnitt, der laenger als `max_len` ist, wird an Wortgrenzen
//!   geteilt. Die Grenze wird in Bytes gemessen.
//! * Ein Abschnitt ohne Satzzeichen am Ende bekommt `append_punctuation`
//!   angehaengt.
//!
//! Die Vorgaben entsprechen der Kitten-Referenz. Modelle, die den Text
//! unveraendert brauchen, setzen `split_chars` und `append_punctuation` auf
//! einen leeren String.

const std = @import("std");

const unicode = @import("unicode.zig");

/// Zeichen, nach denen ein Abschnitt bereits mit Satzzeichen endet.
const sentence_terminators = ".!?,;:";

/// Regeln fuer die Aufteilung eines Textes in Abschnitte.
pub const Options = struct {
    /// Maximale Laenge eines Abschnitts in Byte. Null schaltet die Grenze ab.
    max_len: usize = 400,
    /// Zeichen, an denen ein Abschnitt endet. Die Zeichen entfallen.
    /// Leer bedeutet: der Text wird nicht getrennt.
    split_chars: []const u8 = ".!?",
    /// Zeichen, das an einen Abschnitt angehaengt wird, der nicht mit einem
    /// Satzzeichen endet. Leer bedeutet: es wird nichts angehaengt.
    append_punctuation: []const u8 = ",",
};

/// Eine Liste von Textabschnitten mit eigenem Speicher.
pub const ChunkList = struct {
    gpa: std.mem.Allocator,
    items: [][]u8,

    pub fn deinit(self: *const ChunkList) void {
        for (self.items) |item| self.gpa.free(item);
        self.gpa.free(self.items);
    }
};

/// Teilt den Text nach den Regeln aus `options` in Abschnitte.
///
/// `options.max_len` von null schaltet die Aufteilung an Wortgrenzen ab.
/// `options.split_chars` ohne Zeichen schaltet die Trennung an Satzzeichen ab.
pub fn chunkText(gpa: std.mem.Allocator, text: []const u8, options: Options) !ChunkList {
    var chunks: std.ArrayList([]u8) = .empty;
    errdefer {
        for (chunks.items) |item| gpa.free(item);
        chunks.deinit(gpa);
    }

    var sentences: std.ArrayList([]const u8) = .empty;
    defer sentences.deinit(gpa);
    try splitSentences(gpa, text, options.split_chars, &sentences);

    for (sentences.items) |raw| {
        const sentence = trimUnicode(raw);
        if (sentence.len == 0) continue;

        if (options.max_len == 0 or sentence.len <= options.max_len) {
            try chunks.append(gpa, try ensurePunctuation(gpa, sentence, options.append_punctuation));
            continue;
        }
        try splitLongSentence(gpa, sentence, options, &chunks);
    }

    return .{ .gpa = gpa, .items = try chunks.toOwnedSlice(gpa) };
}

/// Haengt `punctuation` an, wenn der Abschnitt nicht mit einem Satzzeichen endet.
///
/// Ein leeres `punctuation` laesst den Abschnitt unveraendert.
pub fn ensurePunctuation(
    gpa: std.mem.Allocator,
    text: []const u8,
    punctuation: []const u8,
) ![]u8 {
    const trimmed = trimUnicode(text);
    if (trimmed.len == 0 or punctuation.len == 0) return gpa.dupe(u8, trimmed);

    const last = lastCodepoint(trimmed) orelse return gpa.dupe(u8, trimmed);
    if (last <= 0x7F and std.mem.indexOfScalar(u8, sentence_terminators, @intCast(last)) != null) {
        return gpa.dupe(u8, trimmed);
    }
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ trimmed, punctuation });
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

/// Trennt den Text an Folgen der Zeichen aus `split_chars`. Die Trenner
/// entfallen. Ohne `split_chars` bleibt der Text ungeteilt.
fn splitSentences(
    gpa: std.mem.Allocator,
    text: []const u8,
    split_chars: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (split_chars.len == 0) {
        try out.append(gpa, text);
        return;
    }

    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.indexOfScalar(u8, split_chars, text[index]) == null) {
            index += 1;
            continue;
        }
        try out.append(gpa, text[start..index]);
        while (index < text.len and std.mem.indexOfScalar(u8, split_chars, text[index]) != null) {
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
    options: Options,
    chunks: *std.ArrayList([]u8),
) !void {
    var words: std.ArrayList([]const u8) = .empty;
    defer words.deinit(gpa);
    try splitWords(gpa, sentence, &words);

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);

    for (words.items) |word| {
        if (current.items.len + word.len < options.max_len) {
            if (current.items.len > 0) try current.append(gpa, ' ');
            try current.appendSlice(gpa, word);
            continue;
        }

        if (current.items.len > 0) {
            try chunks.append(gpa, try ensurePunctuation(gpa, current.items, options.append_punctuation));
        }
        current.clearRetainingCapacity();
        try current.appendSlice(gpa, word);
    }

    if (current.items.len > 0) {
        try chunks.append(gpa, try ensurePunctuation(gpa, current.items, options.append_punctuation));
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
    var chunks = try chunkText(gpa, "Hello world. Second one!", .{ .max_len = 400 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("Hello world,", chunks.items[0]);
    try std.testing.expectEqualStrings("Second one,", chunks.items[1]);
}

test "Abschnitt ohne Satzzeichen bekommt ein Komma" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "Hallo Welt", .{ .max_len = 400 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Hallo Welt,", chunks.items[0]);
}

test "Satzzeichen am Ende entfaellt und wird durch Komma ersetzt" {
    const gpa = std.testing.allocator;
    // Die Referenz trennt den Text an ".!?" und entfernt die Trenner. Der
    // Abschnitt endet danach ohne Satzzeichen und bekommt ein Komma.
    var chunks = try chunkText(gpa, "Really?", .{ .max_len = 400 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Really,", chunks.items[0]);
}

test "Komma und Doppelpunkt am Ende bleiben erhalten" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "Wait; really: yes;", .{ .max_len = 400 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Wait; really: yes;", chunks.items[0]);
}

test "Leerer und nur aus Leerraum bestehender Text liefert nichts" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "  ...  ", .{ .max_len = 400 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 0), chunks.items.len);
}

test "Zu langer Abschnitt wird an Wortgrenzen geteilt" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "aaaa bbbb cccc", .{ .max_len = 10 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("aaaa bbbb,", chunks.items[0]);
    try std.testing.expectEqualStrings("cccc,", chunks.items[1]);
}

test "Die Grenze wird in Bytes gemessen" {
    const gpa = std.testing.allocator;
    // "äöü" belegt sechs Bytes.
    var chunks = try chunkText(gpa, "äöü bbbb", .{ .max_len = 8 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("äöü,", chunks.items[0]);
    try std.testing.expectEqualStrings("bbbb,", chunks.items[1]);
}

test "Leerraum am Rand wird entfernt" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "\t Hallo Welt \n", .{ .max_len = 400 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Hallo Welt,", chunks.items[0]);
}

test "Kurzer Abschnitt behaelt seinen Leerraum unveraendert" {
    const gpa = std.testing.allocator;
    // Die Referenz teilt nur lange Abschnitte an Wortgrenzen auf. Ein kurzer
    // Abschnitt behält den ursprünglichen Leerraum, auch geschuetzte Leerzeichen.
    var chunks = try chunkText(gpa, "aaaa\u{00A0}bbbb", .{ .max_len = 400 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("aaaa\u{00A0}bbbb,", chunks.items[0]);
}

test "Geschuetzter Leerraum trennt Woerter in langen Abschnitten" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "aaaa\u{00A0}bbbb", .{ .max_len = 8 });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 2), chunks.items.len);
    try std.testing.expectEqualStrings("aaaa,", chunks.items[0]);
    try std.testing.expectEqualStrings("bbbb,", chunks.items[1]);
}

test "Leere Trennzeichen lassen den Text ungeteilt" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "Hello world. Second one!", .{
        .max_len = 400,
        .split_chars = "",
        .append_punctuation = "",
    });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Hello world. Second one!", chunks.items[0]);
}

test "Eigene Trennzeichen werden verwendet" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "eins;zwei|drei", .{
        .max_len = 400,
        .split_chars = ";|",
        .append_punctuation = "",
    });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 3), chunks.items.len);
    try std.testing.expectEqualStrings("eins", chunks.items[0]);
    try std.testing.expectEqualStrings("zwei", chunks.items[1]);
    try std.testing.expectEqualStrings("drei", chunks.items[2]);
}

test "Ohne angehaengtes Satzzeichen bleibt der Abschnitt unveraendert" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "Hallo Welt", .{
        .max_len = 400,
        .append_punctuation = "",
    });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("Hallo Welt", chunks.items[0]);
}

test "Null als Laengengrenze schaltet die Worttrennung ab" {
    const gpa = std.testing.allocator;
    var chunks = try chunkText(gpa, "aaaa bbbb cccc", .{
        .max_len = 0,
        .split_chars = "",
        .append_punctuation = "",
    });
    defer chunks.deinit();

    try std.testing.expectEqual(@as(usize, 1), chunks.items.len);
    try std.testing.expectEqualStrings("aaaa bbbb cccc", chunks.items[0]);
}
