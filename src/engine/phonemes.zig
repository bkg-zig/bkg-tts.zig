//! Gemeinsame Textaufbereitung aller Backends.
//!
//! Die Pipeline besteht aus vier Schritten:
//!
//! 1. Der Text wird vorbereitet. Zahlen und Waehrungen werden optional zu
//!    Worten gemacht.
//! 2. espeak-ng uebersetzt den Text in IPA-Phoneme. espeak arbeitet dabei in
//!    Clauses, also an Komma, Doppelpunkt und Semikolon.
//! 3. Die Clauses werden zu Saetzen gruppiert. Ein Satz endet, wenn der
//!    Terminator des Clauses das Bit fuer Satzende gesetzt hat. Zwei Clauses
//!    eines Satzes trennt `spec.clause_separator`.
//! 4. Je nach Modus liefert die Pipeline einen einzigen Text oder einen Text
//!    je Satz.
//!
//! Die Regeln fuer Terminator, Leerzeichen und Satzzeichen stehen im
//! Deskriptor. So muss die Engine keine Modellfamilie kennen.
const std = @import("std");
const builtin = @import("builtin");

const descriptor = @import("../tts/descriptor.zig");
const espeak = @import("../tts/espeak.zig");
const preprocess = @import("../tts/preprocess.zig");
const unicode = @import("../tts/unicode.zig");

/// Ein Textstueck mit eigenem Speicher.
pub const Piece = struct {
    text: []u8,

    pub fn deinit(self: *Piece, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        self.text = &.{};
    }
};

/// Die aufbereiteten Texte eines Eingabetextes.
pub const Prepared = struct {
    gpa: std.mem.Allocator,
    pieces: []Piece,

    pub fn deinit(self: *Prepared) void {
        for (self.pieces) |*piece| piece.deinit(self.gpa);
        self.gpa.free(self.pieces);
        self.pieces = &.{};
    }
};

/// Bereitet einen Text fuer die Tokenbildung auf.
///
/// `spec` bestimmt, ob ein einziger Text oder je Satz ein Text entsteht.
/// Im Modus "whole" werden die Saetze mit `spec.clause_separator`
/// zusammengefuegt. Im Modus "clause" bleibt jeder Satz fuer sich.
pub fn prepare(
    gpa: std.mem.Allocator,
    espeak_instance: *espeak.Espeak,
    spec: *const descriptor.TextSpec,
    text: []const u8,
) !Prepared {
    const source = try preprocessText(gpa, spec.preprocess, text);
    defer gpa.free(source);
    return preparePhonemes(gpa, espeak_instance, spec, source);
}

/// Bereitet einen Text vor der Phonemisierung auf.
///
/// Die Vorverarbeitung laeuft vor der Aufteilung in Abschnitte. So entstehen
/// die Abschnitte aus demselben Text wie bei der Referenz.
pub fn preprocessText(
    gpa: std.mem.Allocator,
    mode: descriptor.PreprocessMode,
    text: []const u8,
) ![]u8 {
    return switch (mode) {
        .none => try gpa.dupe(u8, text),
        .numbers => try preprocess.preprocess(gpa, text),
    };
}

/// Phonemisierung ohne Vorverarbeitung.
///
/// Die Clauses werden zu Saetzen gruppiert. Im Modus "whole" werden die
/// Saetze mit `spec.clause_separator` zusammengefuegt, im Modus "clause"
/// bleibt jeder Satz fuer sich.
pub fn preparePhonemes(
    gpa: std.mem.Allocator,
    espeak_instance: *espeak.Espeak,
    spec: *const descriptor.TextSpec,
    text: []const u8,
) !Prepared {
    const clauses = try espeak_instance.phonemizeClauses(text);
    defer {
        for (clauses) |clause| gpa.free(clause.text);
        gpa.free(clauses);
    }

    // Saetze sammeln. Jeder Clause wird an den aktuellen Satz angehaengt.
    var sentences: std.ArrayList(Piece) = .empty;
    defer {
        for (sentences.items) |*piece| piece.deinit(gpa);
        sentences.deinit(gpa);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);

    for (clauses) |clause| {
        const clause_text = try clauseText(gpa, spec, clause);
        defer gpa.free(clause_text);

        // Zwei Clauses eines Satzes trennt der Trenner aus dem Deskriptor.
        // Er steht an der Stelle des Zeilenumbruchs, den die Referenz aus dem
        // Aufruf von espeak uebernimmt.
        if (needsSeparator(current.items, spec.clause_separator)) {
            try current.appendSlice(gpa, spec.clause_separator);
        }

        try current.appendSlice(gpa, clause_text);

        if (espeak.isSentenceEnd(clause.terminator)) {
            const sentence = try current.toOwnedSlice(gpa);
            errdefer gpa.free(sentence);
            try sentences.append(gpa, .{ .text = sentence });
        }
    }

    // Text ohne Satzzeichen am Ende bildet einen eigenen Satz.
    if (current.items.len > 0) {
        try sentences.append(gpa, .{ .text = try current.toOwnedSlice(gpa) });
    }

    switch (spec.mode) {
        .whole => {
            var joined: std.ArrayList(u8) = .empty;
            errdefer joined.deinit(gpa);
            for (sentences.items, 0..) |sentence, index| {
                if (index > 0) try joined.appendSlice(gpa, spec.clause_separator);
                try joined.appendSlice(gpa, sentence.text);
            }

            const replaced = try applyReplacements(gpa, joined.items, spec.replacements);
            joined.deinit(gpa);

            var pieces: std.ArrayList(Piece) = .empty;
            errdefer {
                for (pieces.items) |*piece| piece.deinit(gpa);
                pieces.deinit(gpa);
            }
            try pieces.append(gpa, .{ .text = replaced });
            return .{ .gpa = gpa, .pieces = try pieces.toOwnedSlice(gpa) };
        },
        .clause => {
            var pieces: std.ArrayList(Piece) = .empty;
            errdefer {
                for (pieces.items) |*piece| piece.deinit(gpa);
                pieces.deinit(gpa);
            }
            for (sentences.items) |sentence| {
                const replaced = try applyReplacements(gpa, sentence.text, spec.replacements);
                try pieces.append(gpa, .{ .text = replaced });
            }
            return .{ .gpa = gpa, .pieces = try pieces.toOwnedSlice(gpa) };
        },
    }
}

/// Baut den Phonemtext eines Clauses.
///
/// Die Klammern fuer den Sprachwechsel fallen weg. Danach kommt das
/// Satzzeichen des Terminators, wenn der Deskriptor es verlangt. Bei Komma,
/// Doppelpunkt und Semikolon folgt ein Leerzeichen, so wie es der
/// Piper-Pfad macht.
fn clauseText(
    gpa: std.mem.Allocator,
    spec: *const descriptor.TextSpec,
    clause: espeak.Clause,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    const cleaned = try stripParentheses(gpa, clause.text);
    defer gpa.free(cleaned);
    try output.appendSlice(gpa, cleaned);

    if (spec.append_terminator) {
        try output.appendSlice(gpa, espeak.terminatorText(clause.terminator));
        if (espeak.terminatorNeedsSpace(clause.terminator)) {
            try output.append(gpa, ' ');
        }
    }

    return output.toOwnedSlice(gpa);
}

/// Braucht der aktuelle Satz einen Trenner vor dem naechsten Clause?
///
/// Ohne Separator, ohne bisherigen Text oder wenn der Text bereits mit dem
/// Separator endet, wird nichts eingefuegt.
fn needsSeparator(current: []const u8, separator: []const u8) bool {
    if (separator.len == 0) return false;
    if (current.len == 0) return false;
    if (std.mem.endsWith(u8, current, separator)) return false;
    return true;
}

/// Entfernt die Klammern, in denen espeak den Wechsel der Sprache markiert.
///
/// Das entspricht der Regel des Piper-Pfads, die alle Klammern mit Inhalt
/// aus dem Phonemtext entfernt.
fn stripParentheses(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    var inside = false;
    for (text) |byte| {
        switch (byte) {
            '(' => inside = true,
            ')' => inside = false,
            else => if (!inside) try output.append(gpa, byte),
        }
    }

    return output.toOwnedSlice(gpa);
}

/// Fuehrt die Ersetzungen des Deskriptors aus.
///
/// Die Reihenfolge der Ersetzungen bleibt wie im Deskriptor. Jede Ersetzung
/// greift auf das Ergebnis der vorherigen.
fn applyReplacements(
    gpa: std.mem.Allocator,
    text: []const u8,
    replacements: []const descriptor.Replacement,
) ![]u8 {
    var current = try gpa.dupe(u8, text);
    errdefer gpa.free(current);

    for (replacements) |replacement| {
        if (replacement.from.len == 0) continue;
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(gpa);

        var rest = current;
        while (std.mem.indexOf(u8, rest, replacement.from)) |position| {
            try next.appendSlice(gpa, rest[0..position]);
            try next.appendSlice(gpa, replacement.to);
            rest = rest[position + replacement.from.len ..];
        }
        try next.appendSlice(gpa, rest);

        gpa.free(current);
        current = try next.toOwnedSlice(gpa);
    }

    return current;
}

test "Klammern mit Sprachwechsel werden entfernt" {
    const gpa = std.testing.allocator;
    const cleaned = try stripParentheses(gpa, "həlˈoʊ (de) wˈɜːld");
    defer gpa.free(cleaned);
    try std.testing.expectEqualStrings("həlˈoʊ  wˈɜːld", cleaned);
}

test "Ersetzungen greifen nacheinander" {
    const gpa = std.testing.allocator;
    const replacements = [_]descriptor.Replacement{
        .{ .from = "a", .to = "b" },
        .{ .from = "b", .to = "c" },
    };
    const result = try applyReplacements(gpa, "aba", &replacements);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("ccc", result);
}

test "Trenner fehlt, wenn der Text schon mit einem Leerzeichen endet" {
    try std.testing.expect(needsSeparator("həlˈoʊ", " "));
    try std.testing.expect(!needsSeparator("həlˈoʊ ", " "));
    try std.testing.expect(!needsSeparator("", " "));
    try std.testing.expect(!needsSeparator("həlˈoʊ", ""));
}

const test_library_path = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1";
const test_data_dir = "/usr/lib/x86_64-linux-gnu/espeak-ng-data";

test "Zwei Clauses eines Satzes werden mit einem Leerzeichen getrennt" {
    if (!builtin.link_libc) return error.SkipZigTest;
    if (!fileExists(test_library_path)) return error.SkipZigTest;
    if (!directoryExists(test_data_dir)) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var engine = try espeak.Espeak.open(gpa, .{
        .library_path = test_library_path,
        .data_dir = test_data_dir,
        .voice = "en-us",
    });
    defer engine.deinit();

    const spec = descriptor.TextSpec{
        .preprocess = .none,
        .mode = .whole,
    };
    var prepared = try preparePhonemes(gpa, &engine, &spec, "Hello world, this is a test.");
    defer prepared.deinit();

    try std.testing.expectEqual(@as(usize, 1), prepared.pieces.len);
    try std.testing.expectEqualStrings(
        "həlˈoʊ wˈɜːld ðɪs ɪz ɐ tˈɛst",
        prepared.pieces[0].text,
    );
}

/// Prueft, ob der Pfad auf eine Datei zeigt.
fn fileExists(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(stdIo(), path, .{}) catch return false;
    return stat.kind == .file;
}

/// Prueft, ob der Pfad auf ein Verzeichnis zeigt.
fn directoryExists(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(stdIo(), path, .{}) catch return false;
    return stat.kind == .directory;
}

/// Standard-IO des Prozesses.
fn stdIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
