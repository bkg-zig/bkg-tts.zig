//! Textaufbereitung fuer Modelle mit Unigram-Tokenizer.
//!
//! Die Modelle werden auf einzelne Saetze trainiert. Lange Eingaben werden
//! deshalb an Satzgrenzen geteilt und wieder zu Abschnitten zusammengefasst,
//! die in das Tokenbudget des Modells passen.
//!
//! Die Regeln entsprechen der Python-Laufzeit des Upstream-Projekts:
//! Absatzumbrueche bekommen einen Punkt, der erste Buchstabe wird
//! grossgeschrieben, fehlende Satzzeichen werden ergaenzt.
const std = @import("std");

const sentencepiece = @import("sentencepiece.zig");
const unicode = @import("unicode.zig");
const unicode_case = @import("unicode_case.zig");

/// Fehler der Textaufbereitung.
pub const Error = error{
    /// Der Text enthaelt nach der Aufbereitung nichts mehr.
    EmptyText,
};

/// Einstellungen der Textaufbereitung.
pub const Options = struct {
    /// Maximale Zahl der Tokens je Abschnitt.
    max_tokens: usize = 50,
    /// Kurze Eingaben bekommen acht Leerzeichen vorangestellt.
    pad_with_spaces_for_short_inputs: bool = false,
    /// Semikolons werden zu Kommas.
    remove_semicolons: bool = false,
};

/// Ein aufbereiteter Text mit der Schaetzung der Frames nach dem
/// Endzeichen.
pub const Prepared = struct {
    /// Der aufbereitete Text.
    text: []u8,
    /// Schaetzung der Frames, die nach dem Endzeichen noch kommen.
    frames_after_eos_guess: u32,

    pub fn deinit(self: Prepared, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
    }
};

/// Die Zeichen, die einen Absatz beenden duerfen.
///
/// Das Upstream-Projekt schliesst Anfuehrungszeichen, typografische
/// Anfuehrungszeichen sowie runde und eckige Klammern ein.
fn isClosing(codepoint: u21) bool {
    return switch (codepoint) {
        '"', '\'', 0x2019, 0x201D, ')', ']' => true,
        else => false,
    };
}

/// Ein Codepoint an einer Stelle im Text.
const Char = struct {
    codepoint: u21,
    length: usize,
};

/// Liest den Codepoint an der Stelle `index`.
fn charAt(text: []const u8, index: usize) ?Char {
    if (index >= text.len) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
    if (length == 0 or index + length > text.len) return null;
    const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch return null;
    return .{ .codepoint = codepoint, .length = length };
}

/// Liest den Codepoint, der vor der Stelle `end` endet.
fn charBefore(text: []const u8, end: usize) ?Char {
    if (end == 0 or end > text.len) return null;
    var index = end;
    while (index > 0) {
        index -= 1;
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
        if (length == 0 or index + length > end) return null;
        const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch return null;
        return .{ .codepoint = codepoint, .length = length };
    }
    return null;
}

/// Setzt Absatzumbrueche um.
///
/// Das Upstream-Projekt sucht mit einem regulaeren Ausdruck das letzte
/// Zeichen vor einer Leerzeile, die schliessenden Zeichen dahinter und den
/// Leerraum nach der Leerzeile. Steht vor der Leerzeile ein Buchstabe oder
/// eine Ziffer, bekommt der Absatz einen Punkt, sonst nur ein Leerzeichen.
pub fn breakParagraphs(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var index: usize = 0;
    while (index < text.len) {
        const first = charAt(text, index) orelse {
            try out.append(gpa, text[index]);
            index += 1;
            continue;
        };

        // Das erste Zeichen des Treffers ist weder Leerraum noch ein
        // schliessendes Zeichen.
        if (unicode.isPythonWhitespace(first.codepoint) or isClosing(first.codepoint)) {
            try out.appendSlice(gpa, text[index .. index + first.length]);
            index += first.length;
            continue;
        }

        // Danach folgt eine moeglichst lange Folge schliessender Zeichen.
        var closers_end = index + first.length;
        while (charAt(text, closers_end)) |next| {
            if (!isClosing(next.codepoint)) break;
            closers_end += next.length;
        }

        if (blankLine(text, closers_end)) |blank| {
            try out.appendSlice(gpa, text[index..closers_end]);
            if (unicode_case.isAlphanumeric(first.codepoint)) {
                try out.appendSlice(gpa, ". ");
            } else {
                try out.append(gpa, ' ');
            }
            index = blank.next_index;
            continue;
        }

        try out.appendSlice(gpa, text[index .. index + first.length]);
        index += first.length;
    }
    return out.toOwnedSlice(gpa);
}

/// Der Leerraum nach einer Leerzeile.
const BlankLine = struct {
    /// Erste Stelle nach der Leerzeile und dem folgenden Leerraum.
    next_index: usize,
};

/// Prueft, ob an der Stelle eine Leerzeile mit optionalem Leerraum folgt.
///
/// Gesucht wird die Folge von Leerzeichen und Tabulatoren, einem Zeilenumbruch,
/// erneut Leerzeichen und Tabulatoren, einem weiteren Zeilenumbruch und dem
/// Leerraum dahinter.
fn blankLine(text: []const u8, start: usize) ?BlankLine {
    var index = start;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) index += 1;
    if (index >= text.len or text[index] != '\n') return null;
    index += 1;
    while (index < text.len and (text[index] == ' ' or text[index] == '\t')) index += 1;
    if (index >= text.len or text[index] != '\n') return null;
    index += 1;
    while (charAt(text, index)) |next| {
        if (!unicode.isPythonWhitespace(next.codepoint)) break;
        index += next.length;
    }
    return .{ .next_index = index };
}

/// Prueft, ob ein Codepoint Buchstabe oder Ziffer ist.
///
/// Python zaehlt die Kategorien L und N.
fn isAlphanumeric(codepoint: u21) bool {
    return unicode_case.isAlphanumeric(codepoint);
}

/// Prueft, ob ein Codepoint eine Ziffer ist.
///
/// Python zaehlt Nd und die Numeric_Type-Eigenschaft Digit.
fn isDigit(codepoint: u21) bool {
    return unicode_case.isDigit(codepoint);
}

/// Prueft, ob ein Codepoint ein Grossbuchstabe ist.
///
/// Python zaehlt die Kategorie Lu und die Eigenschaft Other_Uppercase.
fn isUpperCase(codepoint: u21) bool {
    return unicode_case.isUpperCase(codepoint);
}

/// Schreibt den ersten Buchstabe eines Textes gross.
///
/// Die Zuordnung folgt Python. Sie nutzt die einfache Zuordnung der
/// Unicode-Datenbank und die unbedingten Eintraege aus SpecialCasing.
fn writeUpperCase(out: *std.ArrayList(u8), gpa: std.mem.Allocator, codepoint: u21) !void {
    if (unicode_case.upperMapping(codepoint)) |mapped| {
        try out.appendSlice(gpa, mapped);
        return;
    }
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(codepoint, &buffer) catch {
        try out.append(gpa, '?');
        return;
    };
    try out.appendSlice(gpa, buffer[0..length]);
}

/// Entfernt Leerraum am Anfang und am Ende.
///
/// Die Menge folgt Python. Sie umfasst mehr als die Unicode-Eigenschaft
/// White_Space.
pub fn trimWhitespace(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const first = charAt(text, start) orelse break;
        if (!unicode.isPythonWhitespace(first.codepoint)) break;
        start += first.length;
    }
    var end = text.len;
    while (end > start) {
        const last = charBefore(text, end) orelse break;
        if (!unicode.isPythonWhitespace(last.codepoint)) break;
        end -= last.length;
    }
    return text[start..end];
}

/// Zaehlt die Woerter eines Textes. Getrennt wird an jedem Leerraum.
pub fn wordCount(text: []const u8) usize {
    var count: usize = 0;
    var in_word = false;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| {
        const space = unicode.isPythonWhitespace(codepoint);
        if (space) {
            in_word = false;
            continue;
        }
        if (!in_word) {
            count += 1;
            in_word = true;
        }
    }
    return count;
}

/// Bereitet einen Textabschnitt auf.
///
/// Der Text bekommt einen Punkt am Absatzende, einen grossen ersten
/// Buchstaben und ein Satzzeichen am Ende, falls das letzte Zeichen ein
/// Buchstabe oder eine Ziffer ist.
pub fn prepareTextPrompt(gpa: std.mem.Allocator, text: []const u8, options: Options) !Prepared {
    const trimmed = trimWhitespace(text);
    const broken = try breakParagraphs(gpa, trimmed);
    defer gpa.free(broken);
    if (broken.len == 0) return error.EmptyText;

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(gpa);
    for (broken) |char| {
        if (char == '\n' or char == '\r') {
            try buffer.append(gpa, ' ');
        } else {
            try buffer.append(gpa, char);
        }
    }

    // Zwei Leerzeichen werden zu einem. Die Ersetzung laeuft einmal ueber
    // den Text, wie im Upstream-Projekt.
    var collapsed: std.ArrayList(u8) = .empty;
    errdefer collapsed.deinit(gpa);
    var index: usize = 0;
    while (index < buffer.items.len) {
        if (index + 1 < buffer.items.len and buffer.items[index] == ' ' and buffer.items[index + 1] == ' ') {
            try collapsed.append(gpa, ' ');
            index += 2;
            continue;
        }
        try collapsed.append(gpa, buffer.items[index]);
        index += 1;
    }
    buffer.deinit(gpa);
    buffer = collapsed;

    if (options.remove_semicolons) {
        for (buffer.items) |*char| {
            if (char.* == ';') char.* = ',';
        }
    }

    const guess: u32 = if (wordCount(buffer.items) <= 4) 3 else 1;

    var iterator = std.unicode.Utf8Iterator{ .bytes = buffer.items, .i = 0 };
    if (iterator.nextCodepoint()) |first| {
        if (!isUpperCase(first)) {
            var upper: std.ArrayList(u8) = .empty;
            errdefer upper.deinit(gpa);
            try writeUpperCase(&upper, gpa, first);
            try upper.appendSlice(gpa, buffer.items[iterator.i..]);
            buffer.deinit(gpa);
            buffer = upper;
        }
    }

    if (buffer.items.len > 0) {
        const last_codepoint = lastCodepoint(buffer.items) orelse 0;
        if (isAlphanumeric(last_codepoint)) try buffer.append(gpa, '.');
    }

    if (options.pad_with_spaces_for_short_inputs and wordCount(buffer.items) < 5) {
        var padded: std.ArrayList(u8) = .empty;
        errdefer padded.deinit(gpa);
        try padded.appendNTimes(gpa, ' ', 8);
        try padded.appendSlice(gpa, buffer.items);
        buffer.deinit(gpa);
        buffer = padded;
    }

    return .{ .text = try buffer.toOwnedSlice(gpa), .frames_after_eos_guess = guess };
}

/// Teilt einen Text in Abschnitte, die in das Tokenbudget passen.
pub fn splitIntoBestSentences(
    gpa: std.mem.Allocator,
    model: *const sentencepiece.Model,
    text: []const u8,
    options: Options,
) ![][]u8 {
    const prepared = try prepareTextPrompt(gpa, text, options);
    defer prepared.deinit(gpa);

    const trimmed = trimWhitespace(prepared.text);
    const tokens = try model.encode(gpa, trimmed);
    defer gpa.free(tokens);

    const sentence_ends = try boundaryIds(gpa, model, ".!...");
    defer gpa.free(sentence_ends);
    const fallback = try boundaryIds(gpa, model, ",;:");
    defer gpa.free(fallback);

    var sentences: std.ArrayList(Sentence) = .empty;
    defer sentences.deinit(gpa);
    try collectSentences(gpa, model, tokens, sentence_ends, &sentences, true);

    // Zu lange Saetze werden an Kommas, Semikolons und Doppelpunkten
    // getrennt.
    var refined: std.ArrayList(Sentence) = .empty;
    defer refined.deinit(gpa);
    for (sentences.items) |sentence| {
        if (sentence.count <= options.max_tokens) {
            try refined.append(gpa, sentence);
            continue;
        }
        const sub_tokens = try model.encode(gpa, trimWhitespace(sentence.text));
        defer gpa.free(sub_tokens);
        var sub: std.ArrayList(Sentence) = .empty;
        defer sub.deinit(gpa);
        try collectSentences(gpa, model, sub_tokens, fallback, &sub, false);
        if (sub.items.len > 1) {
            for (sub.items) |part| try refined.append(gpa, part);
        } else {
            try refined.append(gpa, sentence);
        }
    }

    var chunks: std.ArrayList([]u8) = .empty;
    errdefer {
        for (chunks.items) |chunk| gpa.free(chunk);
        chunks.deinit(gpa);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);
    var current_count: usize = 0;
    for (refined.items) |sentence| {
        if (current.items.len == 0) {
            try current.appendSlice(gpa, sentence.text);
            current_count = sentence.count;
            continue;
        }
        if (current_count + sentence.count > options.max_tokens) {
            try chunks.append(gpa, try gpa.dupe(u8, trimWhitespace(current.items)));
            current.clearRetainingCapacity();
            try current.appendSlice(gpa, sentence.text);
            current_count = sentence.count;
            continue;
        }
        try current.append(gpa, ' ');
        try current.appendSlice(gpa, sentence.text);
        current_count += sentence.count;
    }
    if (current.items.len > 0) {
        try chunks.append(gpa, try gpa.dupe(u8, trimWhitespace(current.items)));
    }
    return chunks.toOwnedSlice(gpa);
}

/// Ein Satzabschnitt mit der Zahl seiner Tokens.
const Sentence = struct {
    /// Zahl der Tokens.
    count: usize,
    /// Der Text des Abschnitts.
    text: []u8,
};

/// Liefert die IDs der Satzzeichen im Vokabular.
///
/// Das erste Token der Kodierung ist der Leerraum-Marker des Praefixes und
/// gehoert nicht zu den Satzzeichen.
fn boundaryIds(gpa: std.mem.Allocator, model: *const sentencepiece.Model, marks: []const u8) ![]i32 {
    const ids = try model.encode(gpa, marks);
    if (ids.len == 0) return ids;
    const first = model.pieceText(ids[0]) orelse return ids;
    if (!std.mem.eql(u8, first, sentencepiece.space_marker)) return ids;
    const out = try gpa.alloc(i32, ids.len - 1);
    @memcpy(out, ids[1..]);
    gpa.free(ids);
    return out;
}

/// Sammelt die Satzabschnitte einer Tokenfolge.
fn collectSentences(
    gpa: std.mem.Allocator,
    model: *const sentencepiece.Model,
    tokens: []const i32,
    boundary: []const i32,
    out: *std.ArrayList(Sentence),
    skip_decimal_periods: bool,
) !void {
    const indices = try boundaryIndices(gpa, model, tokens, boundary, skip_decimal_periods);
    defer gpa.free(indices);

    var index: usize = 0;
    while (index + 1 < indices.len) : (index += 1) {
        const start = indices[index];
        const end = indices[index + 1];
        const text = try model.decode(gpa, tokens[start..end]);
        try out.append(gpa, .{ .count = end - start, .text = text });
    }
}

/// Liefert die Stellen, an denen ein Abschnitt beginnt.
fn boundaryIndices(
    gpa: std.mem.Allocator,
    model: *const sentencepiece.Model,
    tokens: []const i32,
    boundary: []const i32,
    skip_decimal_periods: bool,
) ![]usize {
    var indices: std.ArrayList(usize) = .empty;
    errdefer indices.deinit(gpa);
    try indices.append(gpa, 0);

    var previous_was_boundary = false;
    for (tokens, 0..) |token, index| {
        if (contains(boundary, token)) {
            previous_was_boundary = true;
            continue;
        }
        if (previous_was_boundary) {
            if (skip_decimal_periods and try isDecimalPeriodBoundary(gpa, model, tokens, index)) {
                previous_was_boundary = false;
                continue;
            }
            try indices.append(gpa, index);
        }
        previous_was_boundary = false;
    }
    try indices.append(gpa, tokens.len);
    return indices.toOwnedSlice(gpa);
}

fn contains(list: []const i32, value: i32) bool {
    for (list) |entry| {
        if (entry == value) return true;
    }
    return false;
}

/// Prueft, ob an der Stelle ein Punkt innerhalb einer Zahl steht.
fn isDecimalPeriodBoundary(
    gpa: std.mem.Allocator,
    model: *const sentencepiece.Model,
    tokens: []const i32,
    start: usize,
) !bool {
    const prefix = try model.decode(gpa, tokens[0..start]);
    defer gpa.free(prefix);
    const suffix = try model.decode(gpa, tokens[start..]);
    defer gpa.free(suffix);

    const prefix_last = lastCodepoint(prefix) orelse return false;
    if (prefix_last != '.') return false;
    const prefix_before = codepointBefore(prefix, prefix.len - 1) orelse return false;
    if (!isDigit(prefix_before)) return false;

    const suffix_first = firstCodepoint(suffix) orelse return false;
    return isDigit(suffix_first);
}

fn firstCodepoint(text: []const u8) ?u21 {
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    return iterator.nextCodepoint();
}

fn lastCodepoint(text: []const u8) ?u21 {
    var result: ?u21 = null;
    var iterator = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iterator.nextCodepoint()) |codepoint| result = codepoint;
    return result;
}

/// Liefert den Codepoint vor der Stelle `end`.
fn codepointBefore(text: []const u8, end: usize) ?u21 {
    if (end == 0) return null;
    var index = end;
    while (index > 0) {
        index -= 1;
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
        if (length == 0 or index + length > end) return null;
        const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch return null;
        return codepoint;
    }
    return null;
}

/// Ein Fall der Absatzaufbereitung.
const ParagraphCase = struct {
    text: []const u8,
    expected: []const u8,
};

test "Absatzumbrueche folgen der Python-Regel" {
    const cases = [_]ParagraphCase{
        .{ .text = "Hallo Welt", .expected = "Hallo Welt" },
        .{ .text = "erster absatz\n\nzweiter absatz", .expected = "erster absatz. zweiter absatz" },
        .{ .text = "erster absatz\n\n\nzweiter", .expected = "erster absatz. zweiter" },
        .{ .text = "absatz\n\n   mit leerraum", .expected = "absatz. mit leerraum" },
        .{ .text = "a\n\nb\n\nc", .expected = "a. b. c" },
        .{ .text = "Ende.\n\nWeiter", .expected = "Ende. Weiter" },
        .{ .text = "absatz mit \u{201E}anfuehrung\u{201C}\n\nweiter", .expected = "absatz mit \u{201E}anfuehrung\u{201C} weiter" },
        .{ .text = "absatz mit \u{201C}anfuehrung\u{201D}\n\nweiter", .expected = "absatz mit \u{201C}anfuehrung\u{201D}. weiter" },
        .{ .text = "text mit ) klammer\n\nmehr", .expected = "text mit ) klammer. mehr" },
        .{ .text = "3.14 ist eine zahl\n\nmehr", .expected = "3.14 ist eine zahl. mehr" },
        .{ .text = "nur ein zeilenumbruch\nhier", .expected = "nur ein zeilenumbruch\nhier" },
    };
    for (cases) |case| {
        const result = try breakParagraphs(std.testing.allocator, case.text);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case.expected, result);
    }
}

/// Ein Fall der Textaufbereitung.
const PrepareCase = struct {
    text: []const u8,
    remove_semicolons: bool,
    pad: bool,
    expected: []const u8,
    guess: u32,
};

test "Textaufbereitung folgt der Python-Regel" {
    const cases = [_]PrepareCase{
        .{ .text = "Hallo Welt", .remove_semicolons = false, .pad = false, .expected = "Hallo Welt.", .guess = 3 },
        .{ .text = "hallo welt", .remove_semicolons = false, .pad = false, .expected = "Hallo welt.", .guess = 3 },
        .{ .text = "erster absatz\n\nzweiter absatz", .remove_semicolons = false, .pad = false, .expected = "Erster absatz. zweiter absatz.", .guess = 3 },
        .{ .text = "\u{00DF} ist ein Buchstabe", .remove_semicolons = false, .pad = false, .expected = "SS ist ein Buchstabe.", .guess = 3 },
        .{ .text = "\u{01C5} ist ein Titelbuchstabe", .remove_semicolons = false, .pad = false, .expected = "\u{01C4} ist ein Titelbuchstabe.", .guess = 3 },
        .{ .text = "\u{2167} ist eine r\u{00F6}mische Ziffer", .remove_semicolons = false, .pad = false, .expected = "\u{2167} ist eine r\u{00F6}mische Ziffer.", .guess = 1 },
        .{ .text = "Text mit Semikolon; und mehr", .remove_semicolons = true, .pad = false, .expected = "Text mit Semikolon, und mehr.", .guess = 1 },
        .{ .text = "hi", .remove_semicolons = false, .pad = true, .expected = "        Hi.", .guess = 3 },
        .{ .text = "one two three four", .remove_semicolons = false, .pad = false, .expected = "One two three four.", .guess = 3 },
        .{ .text = "one two three four five", .remove_semicolons = false, .pad = false, .expected = "One two three four five.", .guess = 1 },
        .{ .text = "Hallo  Welt", .remove_semicolons = false, .pad = false, .expected = "Hallo Welt.", .guess = 3 },
        .{ .text = "  text  ", .remove_semicolons = false, .pad = false, .expected = "Text.", .guess = 3 },
        .{ .text = "\u{001C}\u{001C}text", .remove_semicolons = false, .pad = false, .expected = "Text.", .guess = 3 },
    };
    for (cases) |case| {
        const options = Options{
            .remove_semicolons = case.remove_semicolons,
            .pad_with_spaces_for_short_inputs = case.pad,
        };
        const prepared = try prepareTextPrompt(std.testing.allocator, case.text, options);
        defer prepared.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, prepared.text);
        try std.testing.expectEqual(case.guess, prepared.frames_after_eos_guess);
    }
}

test "Leere Texte werden abgewiesen" {
    try std.testing.expectError(
        error.EmptyText,
        prepareTextPrompt(std.testing.allocator, "   \n\n  ", .{}),
    );
}

test "Woerter werden an jedem Leerraum getrennt" {
    try std.testing.expectEqual(0, wordCount(""));
    try std.testing.expectEqual(1, wordCount("Hallo"));
    try std.testing.expectEqual(2, wordCount("Hallo Welt"));
    try std.testing.expectEqual(2, wordCount("Hallo\u{00A0}Welt"));
    try std.testing.expectEqual(1, wordCount("\u{001C}Hallo"));
}
