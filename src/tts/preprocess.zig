//! Textvorverarbeitung: Zahlen und Waehrungsbetraege ausschreiben.
//!
//! Die Reihenfolge und die Einzelregeln entsprechen der Referenz der
//! Kitten-Modelle. Erst werden Waehrungsbetraege ersetzt, danach freistehende
//! Zahlen, zum Schluss wird der Leerraum normalisiert.
//!
//! Die Wortgrenzen der Referenzregex `\\b(\\d+)\\b` folgen der Unicode-
//! Eigenschaft Word. Eine Ziffernfolge wird nur ersetzt, wenn sie auf beiden
//! Seiten an einem Nicht-Wortzeichen liegt. In "abc123" bleibt die Zahl
//! deshalb unveraendert.

const std = @import("std");
const unicode = @import("unicode.zig");
const unicode_word = @import("unicode_word.zig");

const ones = [_][]const u8{
    "",     "one", "two",   "three", "four", "five",  "six",   "seven", "eight", "nine",
    "ten",  "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
    "seventeen", "eighteen", "nineteen",
};

const tens = [_][]const u8{
    "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
};

const scale = [_][]const u8{ "", "thousand", "million", "billion", "trillion" };

/// Schreibt eine Zahl als Wortfolge.
///
/// Exakte Hunderter bis 9999 werden als "twelve hundred" gesprochen, weil die
/// Referenz diese Form vor der allgemeinen Zerlegung anwendet.
pub fn numberToWords(gpa: std.mem.Allocator, value: i64) ![]u8 {
    if (value == 0) return gpa.dupe(u8, "zero");
    if (value < 0) {
        if (value == std.math.minInt(i64)) return error.NumberOutOfRange;
        const magnitude = try numberToWords(gpa, -value);
        defer gpa.free(magnitude);
        return std.fmt.allocPrint(gpa, "negative {s}", .{magnitude});
    }
    const magnitude: u64 = @intCast(value);

    if (magnitude >= 100 and magnitude <= 9999 and magnitude % 100 == 0 and magnitude % 1000 != 0) {
        const hundreds = magnitude / 100;
        if (hundreds < 20) {
            return std.fmt.allocPrint(gpa, "{s} hundred", .{ones[@intCast(hundreds)]});
        }
    }

    var parts: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (parts.items) |part| gpa.free(part);
        parts.deinit(gpa);
    }

    var rest = magnitude;
    for (scale) |unit| {
        const chunk = rest % 1000;
        if (chunk > 0) {
            const words = try threeDigitsToWords(gpa, chunk);
            if (unit.len == 0) {
                try parts.append(gpa, words);
            } else {
                const combined = std.fmt.allocPrint(gpa, "{s} {s}", .{ words, unit }) catch |err| {
                    gpa.free(words);
                    return err;
                };
                gpa.free(words);
                try parts.append(gpa, combined);
            }
        }
        rest /= 1000;
        if (rest == 0) break;
    }

    // Die Teile entstehen in aufsteigender Groessenordnung, das Ergebnis
    // steht in absteigender.
    std.mem.reverse([]const u8, parts.items);
    const result = try joinParts(gpa, parts.items);
    for (parts.items) |part| gpa.free(part);
    parts.deinit(gpa);
    return result;
}

/// Schreibt die Ziffernfolge einer Zahl als Wortfolge.
///
/// Die Referenz liest die Ziffern mit `i64::from_str`. Ziffern ausserhalb
/// ASCII und zu grosse Zahlen ergeben dort null, und so auch hier.
fn digitsToWords(gpa: std.mem.Allocator, digits: []const u8) ![]u8 {
    const value = std.fmt.parseInt(i64, digits, 10) catch 0;
    return numberToWords(gpa, value);
}

/// Schreibt eine Zahl unter 1000 als Wortfolge.
fn threeDigitsToWords(gpa: std.mem.Allocator, value: u64) ![]u8 {
    if (value == 0) return gpa.dupe(u8, "");

    var parts: [2][]const u8 = undefined;
    var count: usize = 0;

    const hundreds = value / 100;
    if (hundreds > 0) {
        parts[count] = try std.fmt.allocPrint(gpa, "{s} hundred", .{ones[@intCast(hundreds)]});
        count += 1;
    }

    const remainder = value % 100;
    if (remainder < 20) {
        if (remainder > 0) {
            parts[count] = try gpa.dupe(u8, ones[@intCast(remainder)]);
            count += 1;
        }
    } else {
        const tens_word = tens[@intCast(remainder / 10)];
        const ones_word = ones[@intCast(remainder % 10)];
        if (ones_word.len == 0) {
            parts[count] = try gpa.dupe(u8, tens_word);
        } else {
            parts[count] = try std.fmt.allocPrint(gpa, "{s}-{s}", .{ tens_word, ones_word });
        }
        count += 1;
    }

    const result = try joinParts(gpa, parts[0..count]);
    for (parts[0..count]) |part| gpa.free(part);
    return result;
}

fn joinParts(gpa: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    for (parts, 0..) |part, index| {
        if (index > 0) try output.append(gpa, ' ');
        try output.appendSlice(gpa, part);
    }
    return output.toOwnedSlice(gpa);
}

/// Ersetzt Waehrungsbetraege wie "$42.50" durch Wortfolgen.
///
/// Die Referenzregex lautet `\$(\d+)(?:\.(\d{2}))?`. Zwei Ziffern hinter dem
/// Punkt bilden den Centbetrag, sonst bleibt der Punkt im Text.
pub fn expandCurrency(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    var cursor = Cursor{ .text = text };
    var copied_until: usize = 0;

    while (cursor.peek()) |codepoint| {
        if (codepoint != '$') {
            _ = cursor.next();
            continue;
        }
        const dollar_at = cursor.index;
        _ = cursor.next();

        const digits_start = cursor.index;
        while (cursor.peek()) |digit| {
            if (!unicode_word.isDecimalDigit(digit)) break;
            _ = cursor.next();
        }
        const digits_end = cursor.index;
        if (digits_end == digits_start) continue;

        var cents: ?[]const u8 = null;
        if (cursor.peek() == '.') {
            const point_at = cursor.index;
            _ = cursor.next();
            const cents_start = cursor.index;
            var count: usize = 0;
            while (count < 2) {
                const digit = cursor.peek() orelse break;
                if (!unicode_word.isDecimalDigit(digit)) break;
                _ = cursor.next();
                count += 1;
            }
            if (count == 2) {
                cents = text[cents_start..cursor.index];
            } else {
                cursor.index = point_at;
                cursor.index = point_at;
            }
        }

        try output.appendSlice(gpa, text[copied_until..dollar_at]);

        const dollars_text = text[digits_start..digits_end];
        const dollars = try digitsToWords(gpa, dollars_text);
        defer gpa.free(dollars);

        try output.appendSlice(gpa, dollars);
        try output.appendSlice(gpa, if (isOne(dollars_text)) " dollar" else " dollars");

        if (cents) |cents_text| {
            // Die Referenz spricht den Centbetrag nur, wenn er groesser als
            // null ist.
            if (!isZero(cents_text)) {
                const cents_words = try digitsToWords(gpa, cents_text);
                defer gpa.free(cents_words);
                try output.appendSlice(gpa, " and ");
                try output.appendSlice(gpa, cents_words);
                try output.appendSlice(gpa, if (isOne(cents_text)) " cent" else " cents");
            }
        }

        copied_until = cursor.index;
    }

    try output.appendSlice(gpa, text[copied_until..]);
    return output.toOwnedSlice(gpa);
}

/// Ersetzt freistehende Zahlen durch Wortfolgen.
///
/// Die Referenzregex `\\b(\\d+)\\b` ersetzt nur Zahlen, die auf beiden Seiten
/// an einem Nicht-Wortzeichen liegen.
pub fn expandNumbers(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    var cursor = Cursor{ .text = text };
    var copied_until: usize = 0;

    while (cursor.peek()) |codepoint| {
        if (!unicode_word.isDecimalDigit(codepoint)) {
            _ = cursor.next();
            continue;
        }

        const run_start = cursor.index;
        while (cursor.peek()) |digit| {
            if (!unicode_word.isDecimalDigit(digit)) break;
            _ = cursor.next();
        }
        const run_end = cursor.index;

        const before_ok = run_start == 0 or !unicode_word.isWordChar(previousCodepoint(text, run_start));
        const after_ok = run_end == text.len or !unicode_word.isWordChar(peekCodepoint(text, run_end) orelse 0);

        if (!before_ok or !after_ok) continue;

        try output.appendSlice(gpa, text[copied_until..run_start]);
        const words = try digitsToWords(gpa, text[run_start..run_end]);
        defer gpa.free(words);
        try output.appendSlice(gpa, words);
        copied_until = run_end;
    }

    try output.appendSlice(gpa, text[copied_until..]);
    return output.toOwnedSlice(gpa);
}

/// Vollstaendige Vorverarbeitung des Textes.
pub fn preprocess(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const currency = try expandCurrency(gpa, text);
    defer gpa.free(currency);

    const numbers = try expandNumbers(gpa, currency);
    defer gpa.free(numbers);

    return normalizeWhitespace(gpa, numbers);
}

/// Ersetzt Folgen von Leerraum durch ein einzelnes Leerzeichen und trimmt.
pub fn normalizeWhitespace(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    var cursor = Cursor{ .text = text };
    var pending_space = false;
    while (cursor.peek()) |codepoint| {
        _ = cursor.next();
        if (unicode.isWhitespace(codepoint)) {
            pending_space = output.items.len > 0;
            continue;
        }
        if (pending_space) {
            try output.append(gpa, ' ');
            pending_space = false;
        }
        try output.appendSlice(gpa, text[cursor.index - widthOf(text, cursor.index) .. cursor.index]);
    }

    return output.toOwnedSlice(gpa);
}

/// Prueft, ob die Ziffernfolge genau die Eins ergibt.
fn isOne(digits: []const u8) bool {
    const value = std.fmt.parseInt(i64, digits, 10) catch return false;
    return value == 1;
}

/// Prueft, ob die Ziffernfolge den Wert null ergibt.
fn isZero(digits: []const u8) bool {
    const value = std.fmt.parseInt(i64, digits, 10) catch return false;
    return value == 0;
}

/// Ein Cursor ueber UTF-8-Text mit Vorschau.
const Cursor = struct {
    text: []const u8,
    index: usize = 0,

    fn peek(self: *const Cursor) ?u21 {
        if (self.index >= self.text.len) return null;
        const width = std.unicode.utf8ByteSequenceLength(self.text[self.index]) catch return null;
        if (self.index + width > self.text.len) return null;
        return std.unicode.utf8Decode(self.text[self.index..][0..width]) catch null;
    }

    fn next(self: *Cursor) ?u21 {
        const codepoint = self.peek() orelse return null;
        const width = std.unicode.utf8ByteSequenceLength(self.text[self.index]) catch return null;
        self.index += width;
        return codepoint;
    }
};

/// Breite des Codepoints, der bei `index` beginnt.
fn widthOf(text: []const u8, index: usize) usize {
    if (index == 0 or index > text.len) return 0;
    const width = std.unicode.utf8ByteSequenceLength(text[index - 1]) catch return 1;
    return width;
}

/// Codepoint unmittelbar vor der Byteposition `index`.
fn previousCodepoint(text: []const u8, index: usize) u21 {
    if (index == 0 or index > text.len) return 0;
    var start = index - 1;
    while (start > 0 and (text[start] & 0xC0) == 0x80) start -= 1;
    const width = std.unicode.utf8ByteSequenceLength(text[start]) catch return 1;
    if (start + width > index) return text[start];
    return std.unicode.utf8Decode(text[start..index]) catch 0;
}

/// Codepoint an der Byteposition `index`.
fn peekCodepoint(text: []const u8, index: usize) ?u21 {
    if (index >= text.len) return null;
    const width = std.unicode.utf8ByteSequenceLength(text[index]) catch return null;
    if (index + width > text.len) return null;
    return std.unicode.utf8Decode(text[index..][0..width]) catch null;
}

test "Zahlen werden wie in der Referenz ausgeschrieben" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { value: i64, words: []const u8 }{
        .{ .value = 0, .words = "zero" },
        .{ .value = 42, .words = "forty-two" },
        .{ .value = 1200, .words = "twelve hundred" },
        .{ .value = 1000, .words = "one thousand" },
        .{ .value = 1_000_000, .words = "one million" },
        .{ .value = 2100, .words = "two thousand one hundred" },
        .{ .value = -7, .words = "negative seven" },
    };
    for (cases) |case| {
        const words = try numberToWords(gpa, case.value);
        defer gpa.free(words);
        try std.testing.expectEqualStrings(case.words, words);
    }
}

test "Waehrungsbetraege werden ersetzt" {
    const gpa = std.testing.allocator;
    const result = try expandCurrency(gpa, "It costs $42.50 and $1.");
    defer gpa.free(result);
    try std.testing.expectEqualStrings(
        "It costs forty-two dollars and fifty cents and one dollar.",
        result,
    );
}

test "Zahlen ohne Wortgrenze bleiben unveraendert" {
    const gpa = std.testing.allocator;
    const result = try expandNumbers(gpa, "abc123 and 456");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("abc123 and four hundred fifty-six", result);
}

test "Leerraum wird normalisiert und getrimmt" {
    const gpa = std.testing.allocator;
    const result = try normalizeWhitespace(gpa, "  a \n\t b  ");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("a b", result);
}

test "Vorverarbeitung erweitert Waehrung und Zahlen" {
    const gpa = std.testing.allocator;
    const result = try preprocess(gpa, "  Price $10.00, count 3.  ");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("Price ten dollars, count three.", result);
}
