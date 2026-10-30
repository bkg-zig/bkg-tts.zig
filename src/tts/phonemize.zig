//! Phonemisierung mit espeak-ng und Tokenisierung fuer die Kitten-Modelle.
//!
//! Das Modell erwartet eine Folge von Token-IDs. Der Weg vom Text zum Token
//! entspricht der Referenz-Implementierung des Rust-Projekts: espeak-ng
//! liefert IPA-Phoneme, die wie im Python-Server mit `\w+|[^\w\s]` in Tokens
//! zerlegt und mit Leerzeichen verbunden werden. Jedes Zeichen wird danach
//! ueber den Symbolvorrat des Modells in eine ID uebersetzt.
const std = @import("std");

const max_phoneme_bytes = 1 << 20;

/// Fuellzeichen des Modells.
pub const pad_id: i64 = 0;
/// Endtoken der Referenz-Implementierung.
pub const reference_end_id: i64 = 10;

const pad_symbol = "$";
const punctuation_symbols = ";:,.!?¡¿—…\"«»\"\" ";
const letter_symbols = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const ipa_symbols = "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'̩'ᵻ";

/// Zeichen aus dem Symbolvorrat, die kein Wortzeichen bilden.
const non_word_symbols = "˞↓↑→↗↘";

/// Zuordnung der Token-IDs.
pub const TokenScheme = enum {
    /// Referenz-Implementierung: das erste Vorkommen eines Zeichens gewinnt,
    /// danach folgen Endtoken 10 und ein Fuelltoken.
    reference,
    /// Python-Server: das letzte Vorkommen eines Zeichens gewinnt, am Ende
    /// folgt ein einzelnes Fuelltoken.
    python,
};

const Symbol = struct {
    codepoint: u21,
    index: u16,
};

/// Sortierte Zuordnung Codepoint zu Token-ID.
const SymbolTable = struct {
    entries: [256]Symbol = undefined,
    count: usize = 0,

    fn init(first_wins: bool) SymbolTable {
        var table = SymbolTable{};
        var index: u16 = 0;
        for ([_][]const u8{ pad_symbol, punctuation_symbols, letter_symbols, ipa_symbols }) |source| {
            var iter = std.unicode.Utf8Iterator{ .bytes = source, .i = 0 };
            while (iter.nextCodepoint()) |codepoint| {
                var known = false;
                for (table.entries[0..table.count]) |*entry| {
                    if (entry.codepoint == codepoint) {
                        if (!first_wins) entry.index = index;
                        known = true;
                        break;
                    }
                }
                if (!known) {
                    table.entries[table.count] = .{ .codepoint = codepoint, .index = index };
                    table.count += 1;
                }
                index += 1;
            }
        }

        // Einfuege-Sortierung nach Codepoint, damit die Suche binaer laeuft.
        var position: usize = 1;
        while (position < table.count) : (position += 1) {
            var back = position;
            while (back > 0 and table.entries[back].codepoint < table.entries[back - 1].codepoint) : (back -= 1) {
                const current = table.entries[back];
                table.entries[back] = table.entries[back - 1];
                table.entries[back - 1] = current;
            }
        }
        return table;
    }

    pub fn lookup(self: *const SymbolTable, codepoint: u21) ?u16 {
        var low: usize = 0;
        var high: usize = self.count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = self.entries[middle];
            if (entry.codepoint == codepoint) return entry.index;
            if (entry.codepoint < codepoint) low = middle + 1 else high = middle;
        }
        return null;
    }
};

const reference_table: SymbolTable = comptime SymbolTable.init(true);
const python_table: SymbolTable = comptime SymbolTable.init(false);

fn tableFor(scheme: TokenScheme) *const SymbolTable {
    return switch (scheme) {
        .reference => &reference_table,
        .python => &python_table,
    };
}

fn containsCodepoint(list: []const u8, codepoint: u21) bool {
    var iter = std.unicode.Utf8Iterator{ .bytes = list, .i = 0 };
    while (iter.nextCodepoint()) |item| {
        if (item == codepoint) return true;
    }
    return false;
}

fn isWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

/// Prueft, ob ein Zeichen zu einem Wort gehoert.
///
/// Die Regex-Vorlage der Referenz benutzt `\w`, also Buchstaben, Ziffern und
/// Unterstrich. Im IPA-Vorrat sind ausserdem Modifier wie `ˈ` und `ː`
/// Buchstaben und gehoeren deshalb zum Wort.
fn isWordChar(table: *const SymbolTable, codepoint: u21) bool {
    if (codepoint < 128) {
        return std.ascii.isAlphanumeric(codepoint) or codepoint == '_';
    }
    if (table.lookup(codepoint) == null) return false;
    if (containsCodepoint(punctuation_symbols, codepoint)) return false;
    if (containsCodepoint(non_word_symbols, codepoint)) return false;
    return true;
}

/// Wandelt Phoneme in Token-IDs um.
pub fn tokenIds(
    gpa: std.mem.Allocator,
    scheme: TokenScheme,
    phonemes: []const u8,
) ![]i64 {
    const table = tableFor(scheme);
    const space_index = table.lookup(' ') orelse return error.MissingSpaceSymbol;

    var body: std.ArrayList(i64) = .empty;
    defer body.deinit(gpa);

    var token_number: usize = 0;
    var in_word = false;
    var iter = std.unicode.Utf8Iterator{ .bytes = phonemes, .i = 0 };
    while (iter.nextCodepoint()) |codepoint| {
        if (isWhitespace(codepoint)) {
            in_word = false;
            continue;
        }
        if (isWordChar(table, codepoint)) {
            if (!in_word) {
                in_word = true;
                if (token_number > 0) try body.append(space_index);
                token_number += 1;
            }
            if (table.lookup(codepoint)) |index| try body.append(index);
            continue;
        }
        in_word = false;
        if (token_number > 0) try body.append(space_index);
        token_number += 1;
        if (table.lookup(codepoint)) |index| try body.append(index);
    }

    const extra: usize = switch (scheme) {
        .reference => 3,
        .python => 2,
    };
    const ids = try gpa.alloc(i64, body.items.len + extra);
    errdefer gpa.free(ids);
    ids[0] = pad_id;
    @memcpy(ids[1 .. 1 + body.items.len], body.items);
    switch (scheme) {
        .reference => {
            ids[1 + body.items.len] = reference_end_id;
            ids[2 + body.items.len] = pad_id;
        },
        .python => {
            ids[1 + body.items.len] = pad_id;
        },
    }
    return ids;
}

/// Ruft espeak-ng auf und liefert die IPA-Phoneme.
pub const Phonemizer = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    executable: []const u8,
    voice: []const u8,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        executable: []const u8,
        voice: []const u8,
    ) Phonemizer {
        return .{
            .io = io,
            .gpa = gpa,
            .executable = executable,
            .voice = voice,
        };
    }

    /// Wandelt Text in IPA-Phoneme um.
    pub fn phonemize(self: *const Phonemizer, text: []const u8) ![]u8 {
        var child = try std.process.spawn(self.io, .{
            .argv = &.{
                self.executable,
                "--ipa",
                "-q",
                "--sep=",
                "-v",
                self.voice,
                text,
            },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(self.io);

        var stdout_buffer: [4096]u8 = undefined;
        var stdout_reader = child.stdout.?.readerStreaming(self.io, &stdout_buffer);
        const phonemes = try stdout_reader.interface.allocRemaining(self.gpa, .limited(max_phoneme_bytes));

        var stderr_buffer: [1024]u8 = undefined;
        var stderr_reader = child.stderr.?.readerStreaming(self.io, &stderr_buffer);
        const diagnostics = try stderr_reader.interface.allocRemaining(self.gpa, .limited(max_phoneme_bytes));
        defer self.gpa.free(diagnostics);

        const term = try child.wait(self.io);
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    std.log.err("espeak-ng beendete mit Code {d}: {s}", .{ code, std.mem.trim(u8, diagnostics, " \n\r\t") });
                    self.gpa.free(phonemes);
                    return error.PhonemizerFailed;
                }
            },
            else => {
                self.gpa.free(phonemes);
                return error.PhonemizerFailed;
            },
        }
        return phonemes;
    }
};

test "Symbolvorrat enthaelt Fuellzeichen und Leerzeichen" {
    try std.testing.expectEqual(@as(?u16, 0), reference_table.lookup('$'));
    try std.testing.expectEqual(@as(?u16, 16), reference_table.lookup(' '));
}

test "Anfuehrungszeichen: erstes Vorkommen gewinnt" {
    try std.testing.expectEqual(@as(?u16, 11), reference_table.lookup('"'));
    try std.testing.expectEqual(@as(?u16, 15), python_table.lookup('"'));
}

test "Tokenfolge enthaelt Start- und Endtoken" {
    const gpa = std.testing.allocator;
    const ids = try tokenIds(gpa, .reference, "hɛloʊ");
    defer gpa.free(ids);
    try std.testing.expectEqual(pad_id, ids[0]);
    try std.testing.expectEqual(reference_end_id, ids[ids.len - 2]);
    try std.testing.expectEqual(pad_id, ids[ids.len - 1]);
}

test "Wortzeichen bleiben zusammen, Satzzeichen einzeln" {
    const gpa = std.testing.allocator;
    const ids = try tokenIds(gpa, .reference, "hɛloʊ wˈɜːld");
    defer gpa.free(ids);
    // Start, h, ɛ, l, o, ʊ, Leerzeichen, w, ˈ, ɜ, ː, l, d, Ende, Fuellung
    try std.testing.expectEqual(@as(usize, 15), ids.len);
    try std.testing.expectEqual(@as(i64, 16), ids[6]);
}
