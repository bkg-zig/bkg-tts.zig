//! Zeichenquellen und Tokenbildung fuer die Textpfade der Engine.
//!
//! Die Engine braucht drei Arten von Zeichenquellen:
//!
//! * eine eingebaute Symboltabelle (Kitten),
//! * eine Vokabulardatei mit einer Zeile je Symbol (Kokoro),
//! * eine Phonem-ID-Map aus einer Modelldatei (Piper).
//!
//! Alle drei liefern eine Zuordnung Codepoint zu Token-ID. Der Textpfad der
//! Backends baut daraus die Tokenfolge, die das Modell erwartet.
const std = @import("std");

const unicode = @import("unicode.zig");
const unicode_word = @import("unicode_word.zig");

/// Obergrenze fuer die Groesse einer Symboltabelle.
pub const max_symbols = 512;

/// Regel, nach der ein doppelt vorhandenes Zeichen behandelt wird.
pub const SymbolScheme = enum {
    /// Das erste Vorkommen gewinnt. Das ist die Regel der Kitten-Referenz.
    first_wins,
    /// Das letzte Vorkommen gewinnt. Das ist die Regel des Python-Servers.
    last_wins,
};

const pad_symbol = "$";
const punctuation_symbols = ";:,.!?¡¿—…\"«»\"\" ";
const letter_symbols = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const ipa_symbols = "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'̩'ᵻ";

const Symbol = struct {
    codepoint: u21,
    index: u16,
};

/// Sortierte Zuordnung Codepoint zu Token-ID.
pub const SymbolTable = struct {
    entries: [max_symbols]Symbol = undefined,
    count: usize = 0,

    fn init(scheme: SymbolScheme) SymbolTable {
        @setEvalBranchQuota(200000);
        var table = SymbolTable{};
        var index: u16 = 0;
        for ([_][]const u8{ pad_symbol, punctuation_symbols, letter_symbols, ipa_symbols }) |source| {
            var iter = std.unicode.Utf8Iterator{ .bytes = source, .i = 0 };
            while (iter.nextCodepoint()) |codepoint| {
                var known = false;
                for (table.entries[0..table.count]) |*entry| {
                    if (entry.codepoint == codepoint) {
                        if (scheme == .last_wins) entry.index = index;
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

    /// Liefert die Token-ID eines Codepoints.
    pub fn lookup(self: *const SymbolTable, codepoint: u21) ?i64 {
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

const first_wins_table: SymbolTable = SymbolTable.init(.first_wins);
const last_wins_table: SymbolTable = SymbolTable.init(.last_wins);

/// Liefert die eingebaute Symboltabelle des gewaehlten Schemas.
pub fn builtinTable(scheme: SymbolScheme) *const SymbolTable {
    return switch (scheme) {
        .first_wins => &first_wins_table,
        .last_wins => &last_wins_table,
    };
}

/// Ein Eintrag einer Vokabulardatei.
pub const VocabEntry = struct {
    codepoint: u21,
    id: i64,
};

/// Zeichenweise Zuordnung Codepoint zu Token-ID aus einer Vokabulardatei.
pub const Vocab = struct {
    gpa: std.mem.Allocator,
    entries: []VocabEntry,

    pub fn deinit(self: *Vocab) void {
        self.gpa.free(self.entries);
        self.entries = &.{};
    }

    /// Liefert die Token-ID eines Codepoints.
    pub fn lookup(self: *const Vocab, codepoint: u21) ?i64 {
        var low: usize = 0;
        var high: usize = self.entries.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = self.entries[middle];
            if (entry.codepoint == codepoint) return entry.id;
            if (entry.codepoint < codepoint) low = middle + 1 else high = middle;
        }
        return null;
    }
};

const max_vocab_bytes = 4 * 1024 * 1024;

/// Liest eine Vokabulardatei mit einer Zeile je Symbol.
///
/// Das Format ist eine Zeile aus Symbol und Token-ID, getrennt durch
/// Leerzeichen. Das Symbol ist genau ein Codepoint, das Leerzeichen selbst
/// wird dadurch korrekt gelesen.
pub fn loadVocab(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Vocab {
    const data = try std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .limited(max_vocab_bytes));
    defer gpa.free(data);
    return parseVocab(gpa, data);
}

/// Liest eine Vokabulardatei aus einem Speicherbereich.
pub fn parseVocab(gpa: std.mem.Allocator, data: []const u8) !Vocab {
    var entries: std.ArrayList(VocabEntry) = .empty;
    errdefer entries.deinit(gpa);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const separator = std.mem.lastIndexOfAny(u8, line, " \t") orelse return error.InvalidVocabLine;
        const symbol = line[0..separator];
        const id_text = std.mem.trim(u8, line[separator + 1 ..], " \t");
        if (symbol.len == 0) return error.InvalidVocabLine;
        const id = std.fmt.parseInt(i64, id_text, 10) catch return error.InvalidVocabLine;

        const codepoint = singleCodepoint(symbol) orelse return error.InvalidVocabLine;
        try entries.append(gpa, .{ .codepoint = codepoint, .id = id });
    }

    const sorted = try entries.toOwnedSlice(gpa);
    std.mem.sort(VocabEntry, sorted, {}, struct {
        fn lessThan(_: void, left: VocabEntry, right: VocabEntry) bool {
            return left.codepoint < right.codepoint;
        }
    }.lessThan);

    return .{ .gpa = gpa, .entries = sorted };
}

/// Ein Eintrag einer Phonem-ID-Map.
pub const PhonemeEntry = struct {
    /// Schluessel des Phonems, genau so wie es in der Datei steht.
    key: []const u8,
    ids: []i64,
};

/// Zuordnung eines Phonems zu einer Liste von Token-IDs.
///
/// Der Schluessel wird als ganze Bytefolge verglichen. Das entspricht der
/// Piper-Referenz, die das Phonem als Zeichenkette nachschlaegt. Eine
/// Zuordnung ueber den ersten Codepoint wuerde dagegen Mehrzeichen-Phoneme
/// wie "aɪ" mit "a" verwechseln.
pub const PhonemeIdMap = struct {
    gpa: std.mem.Allocator,
    entries: []PhonemeEntry,

    pub fn deinit(self: *PhonemeIdMap) void {
        for (self.entries) |entry| {
            self.gpa.free(entry.key);
            self.gpa.free(entry.ids);
        }
        self.gpa.free(self.entries);
        self.entries = &.{};
    }

    /// Liefert die Token-IDs eines Phonems. Der Schluessel muss byteweise
    /// uebereinstimmen.
    pub fn lookup(self: *const PhonemeIdMap, key: []const u8) ?[]const i64 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.ids;
        }
        return null;
    }
};

const max_phoneme_map_bytes = 4 * 1024 * 1024;

/// Liest die Phonem-ID-Map aus einer JSON-Modelldatei.
///
/// Das Feld `field` benennt das Objekt in der JSON-Datei. Jeder Schluessel
/// ist ein Phonem, jeder Wert eine Liste von Token-IDs. Die Schluessel
/// werden byteweise verglichen, siehe `PhonemeIdMap`.
pub fn loadPhonemeIdMap(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    field: []const u8,
) !PhonemeIdMap {
    const data = try std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .limited(max_phoneme_map_bytes));
    defer gpa.free(data);

    return parsePhonemeIdMap(gpa, data, field);
}

/// Liest die Phonem-ID-Map aus einem Speicherbereich.
///
/// Der Inhalt ist eine JSON-Datei, in der das Feld `field` das Objekt mit den
/// Phonemen enthaelt.
pub fn parsePhonemeIdMap(
    gpa: std.mem.Allocator,
    data: []const u8,
    field: []const u8,
) !PhonemeIdMap {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidPhonemeMap,
    };
    const map_value = root.get(field) orelse return error.MissingPhonemeMapField;
    const map_object = switch (map_value) {
        .object => |object| object,
        else => return error.InvalidPhonemeMap,
    };

    var entries: std.ArrayList(PhonemeEntry) = .empty;
    errdefer {
        for (entries.items) |entry| {
            gpa.free(entry.key);
            gpa.free(entry.ids);
        }
        entries.deinit(gpa);
    }

    var iterator = map_object.iterator();
    while (iterator.next()) |pair| {
        if (pair.key_ptr.*.len == 0) return error.InvalidPhonemeMap;
        const ids_value = switch (pair.value_ptr.*) {
            .array => |array| array,
            else => return error.InvalidPhonemeMap,
        };
        const ids = try gpa.alloc(i64, ids_value.items.len);
        errdefer gpa.free(ids);
        for (ids_value.items, 0..) |item, index| {
            ids[index] = switch (item) {
                .integer => |value| value,
                .float => |value| @intFromFloat(value),
                else => return error.InvalidPhonemeMap,
            };
        }
        const key = try gpa.dupe(u8, pair.key_ptr.*);
        errdefer gpa.free(key);
        try entries.append(gpa, .{ .key = key, .ids = ids });
    }

    return .{ .gpa = gpa, .entries = try entries.toOwnedSlice(gpa) };
}

/// Verhalten bei Zeichen, die nicht im Vorrat stehen.
pub const UnknownPolicy = enum {
    /// Unbekannte Zeichen werden verworfen.
    drop,
    /// Unbekannte Zeichen fuehren zu einem Fehler.
    @"error",
};

/// Parameter der Tokenbildung.
pub const TokenOptions = struct {
    /// Wortzeichen werden zu Worten gruppiert und mit Leerzeichen getrennt.
    word_split: bool = false,
    /// IDs vor dem Textkoerper.
    prefix: []const i64 = &.{},
    /// IDs nach dem Textkoerper.
    suffix: []const i64 = &.{},
    /// Verhalten bei Zeichen, die nicht im Vorrat stehen.
    unknown: UnknownPolicy = .drop,
    /// Der Text wird vor der Zuordnung in Normalisierungsform D zerlegt.
    normalize_nfd: bool = false,
    /// Leerzeichen am Anfang und Ende des Textes werden entfernt.
    trim: bool = false,
    /// Maximale Zahl der Tokens im Textkoerper. Null schaltet die Grenze ab.
    ///
    /// Die Grenze gilt fuer den Textkoerper allein, der Rahmen aus Praefix
    /// und Suffix kommt danach dazu.
    max_body: usize = 0,
};

/// Eine fertige Tokenfolge.
pub const TokenSequence = struct {
    ids: []i64,
    /// Anzahl der Tokens ohne den Rahmen aus Praefix und Suffix.
    body_length: usize,

    pub fn deinit(self: *const TokenSequence, gpa: std.mem.Allocator) void {
        gpa.free(self.ids);
    }
};

/// Baut die Tokenfolge mit der eingebauten Symboltabelle.
///
/// Mit `word_split` werden Wortzeichen zu Woertern gruppiert und die Woerter
/// mit Leerzeichen getrennt. Das entspricht der Zerlegung der Kitten-Referenz:
/// Wortlaeufe bleiben zusammen, jedes Satzzeichen steht fuer sich und wird
/// durch ein Leerzeichen von den Nachbarn getrennt.
pub fn buildSymbolSequence(
    gpa: std.mem.Allocator,
    table: *const SymbolTable,
    phonemes: []const u8,
    options: TokenOptions,
) !TokenSequence {
    const prepared = try prepareText(gpa, phonemes, options);
    defer gpa.free(prepared);

    var body: std.ArrayList(i64) = .empty;
    defer body.deinit(gpa);

    var word_started = false;
    var have_group = false;
    var iter = std.unicode.Utf8Iterator{ .bytes = prepared, .i = 0 };
    while (iter.nextCodepoint()) |codepoint| {
        if (unicode.isWhitespace(codepoint)) {
            word_started = false;
            continue;
        }

        if (!options.word_split) {
            if (table.lookup(codepoint)) |id| {
                try body.append(gpa, id);
            } else if (options.unknown == .@"error") {
                return error.UnknownSymbol;
            }
            continue;
        }

        if (unicode_word.isWordChar(codepoint)) {
            if (!word_started) {
                word_started = true;
                if (have_group) try appendSpace(gpa, &body, table);
                have_group = true;
            }
            if (table.lookup(codepoint)) |id| {
                try body.append(gpa, id);
            } else if (options.unknown == .@"error") {
                return error.UnknownSymbol;
            }
            continue;
        }

        word_started = false;
        if (have_group) try appendSpace(gpa, &body, table);
        have_group = true;
        if (table.lookup(codepoint)) |id| {
            try body.append(gpa, id);
        } else if (options.unknown == .@"error") {
            return error.UnknownSymbol;
        }
    }

    return finishSequence(gpa, body.items, options);
}

/// Baut die Tokenfolge mit einer Vokabulardatei.
///
/// Jedes Zeichen des Textes wird einzeln zugeordnet. Unbekannte Zeichen
/// werden verworfen, das entspricht dem Kokoro-Textpfad.
pub fn buildVocabSequence(
    gpa: std.mem.Allocator,
    vocab: *const Vocab,
    phonemes: []const u8,
    options: TokenOptions,
) !TokenSequence {
    const prepared = try prepareText(gpa, phonemes, options);
    defer gpa.free(prepared);

    var body: std.ArrayList(i64) = .empty;
    defer body.deinit(gpa);

    var iter = std.unicode.Utf8Iterator{ .bytes = prepared, .i = 0 };
    while (iter.nextCodepoint()) |codepoint| {
        // Das Leerzeichen ist im Vokabular ein eigenes Symbol und wird
        // deshalb wie jedes andere Zeichen zugeordnet.
        if (vocab.lookup(codepoint)) |id| {
            try body.append(gpa, id);
        } else if (options.unknown == .@"error") {
            return error.UnknownSymbol;
        }
    }

    return finishSequence(gpa, body.items, options);
}

/// Rahmen einer Phonem-ID-Folge.
///
/// Die IDs stammen aus der Phonem-ID-Map des Modells. Welcher Schluessel
/// welche Rolle hat, steht im Deskriptor.
pub const PhonemeFrame = struct {
    /// IDs am Anfang der Folge.
    bos: []const i64,
    /// IDs, die nach jedem Phonem stehen.
    pad: []const i64,
    /// IDs am Ende der Folge.
    eos: []const i64,
};

/// Liefert den Rahmen aus den Sonder-Schluesseln der Phonem-ID-Map.
///
/// Die Schluessel kommen aus dem Deskriptor, damit die Engine keine
/// Konvention des Modellanbieters kennt.
pub fn phonemeFrame(
    map: *const PhonemeIdMap,
    start_key: []const u8,
    pad_key: []const u8,
    end_key: []const u8,
) !PhonemeFrame {
    const bos = map.lookup(start_key) orelse return error.MissingFramePhoneme;
    const pad = map.lookup(pad_key) orelse return error.MissingFramePhoneme;
    const eos = map.lookup(end_key) orelse return error.MissingFramePhoneme;
    return .{ .bos = bos, .pad = pad, .eos = eos };
}

/// Baut die Tokenfolge aus Phonem-IDs.
///
/// Der Text besteht aus Phonemen, jedes Zeichen ist ein Phonem. Die Folge
/// entsteht so:
///
///     Start, Fuellzeichen, je Phonem dessen IDs gefolgt vom Fuellzeichen,
///     Ende
///
/// Das ist die Reihenfolge der Piper-Referenz. Phoneme, die nicht in der Map
/// stehen, werden uebersprungen.
pub fn buildPhonemeIdSequence(
    gpa: std.mem.Allocator,
    map: *const PhonemeIdMap,
    phonemes: []const u8,
    frame: PhonemeFrame,
    options: TokenOptions,
) !TokenSequence {
    const prepared = try prepareText(gpa, phonemes, options);
    defer gpa.free(prepared);

    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(gpa);

    try ids.appendSlice(gpa, frame.bos);
    try ids.appendSlice(gpa, frame.pad);

    var count: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = prepared, .i = 0 };
    while (true) {
        const start = iter.i;
        _ = iter.nextCodepoint() orelse break;
        const key = prepared[start..iter.i];

        const phoneme_ids = map.lookup(key) orelse {
            if (options.unknown == .@"error") return error.UnknownPhoneme;
            continue;
        };
        try ids.appendSlice(gpa, phoneme_ids);
        try ids.appendSlice(gpa, frame.pad);
        count += 1;
    }

    try ids.appendSlice(gpa, frame.eos);

    const owned = try ids.toOwnedSlice(gpa);
    return .{ .ids = owned, .body_length = count };
}

/// Haengt das Leerzeichen-Symbol an, falls das Vokabular eines kennt.
fn appendSpace(gpa: std.mem.Allocator, body: *std.ArrayList(i64), table: *const SymbolTable) !void {
    if (table.lookup(' ')) |id| try body.append(gpa, id);
}

/// Setzt den Rahmen um den Textkoerper und liefert die Tokenfolge.
///
/// Ist `max_body` gesetzt, wird der Textkoerper vorher gekuerzt. Die
/// Tokenfolge entsteht dann aus dem gekuerzten Koerper.
fn finishSequence(
    gpa: std.mem.Allocator,
    body: []const i64,
    options: TokenOptions,
) !TokenSequence {
    const kept = if (options.max_body == 0) body else body[0..@min(body.len, options.max_body)];
    const total = kept.len + options.prefix.len + options.suffix.len;
    const ids = try gpa.alloc(i64, total);
    errdefer gpa.free(ids);

    var position: usize = 0;
    for (options.prefix) |id| {
        ids[position] = id;
        position += 1;
    }
    @memcpy(ids[position .. position + kept.len], kept);
    position += kept.len;
    for (options.suffix) |id| {
        ids[position] = id;
        position += 1;
    }
    return .{ .ids = ids, .body_length = kept.len };
}

/// Bereitet den Text vor: Normalisierung, trimmen, NFD.
fn prepareText(gpa: std.mem.Allocator, text: []const u8, options: TokenOptions) ![]u8 {
    var current = text;
    if (options.trim) current = std.mem.trim(u8, current, " \t\r\n");
    if (options.normalize_nfd) {
        const decomposed = try unicode.normalizeNfd(gpa, current);
        if (options.trim) {
            const trimmed = try gpa.dupe(u8, std.mem.trim(u8, decomposed, " \t\r\n"));
            gpa.free(decomposed);
            return trimmed;
        }
        return decomposed;
    }
    return gpa.dupe(u8, current);
}

/// Liest genau einen Codepoint aus einem UTF-8-Text.
fn singleCodepoint(text: []const u8) ?u21 {
    var view = std.unicode.Utf8View.init(text) catch return null;
    var iterator = view.iterator();
    const first = iterator.nextCodepoint() orelse return null;
    if (iterator.nextCodepoint() != null) return null;
    return first;
}

/// Liest den ersten Codepoint aus einem UTF-8-Text.
fn firstCodepoint(text: []const u8) ?u21 {
    var view = std.unicode.Utf8View.init(text) catch return null;
    var iterator = view.iterator();
    return iterator.nextCodepoint();
}

test "eingebaute Symboltabelle kennt Fuellzeichen und Leerzeichen" {
    const table = builtinTable(.first_wins);
    try std.testing.expectEqual(@as(?i64, 0), table.lookup('$'));
    try std.testing.expectEqual(@as(?i64, 16), table.lookup(' '));
}

test "Anfuehrungszeichen: erstes Vorkommen gewinnt" {
    try std.testing.expectEqual(@as(?i64, 11), builtinTable(.first_wins).lookup('"'));
    try std.testing.expectEqual(@as(?i64, 15), builtinTable(.last_wins).lookup('"'));
}

test "Tokenfolge traegt Start- und Endtoken" {
    const gpa = std.testing.allocator;
    const table = builtinTable(.first_wins);
    const sequence = try buildSymbolSequence(gpa, table, "hɛloʊ", .{
        .prefix = &.{0},
        .suffix = &.{ 10, 0 },
    });
    defer sequence.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 0), sequence.ids[0]);
    try std.testing.expectEqual(@as(i64, 10), sequence.ids[sequence.ids.len - 2]);
    try std.testing.expectEqual(@as(i64, 0), sequence.ids[sequence.ids.len - 1]);
}

test "Wortzeichen bleiben zusammen, Satzzeichen einzeln" {
    const gpa = std.testing.allocator;
    const table = builtinTable(.first_wins);
    const sequence = try buildSymbolSequence(gpa, table, "hɛloʊ wˈɜːld", .{
        .word_split = true,
        .prefix = &.{0},
        .suffix = &.{ 10, 0 },
    });
    defer sequence.deinit(gpa);

    // Erwartet wird die Folge der Kitten-Referenz: Start, die Zeichen des
    // ersten Worts, ein Leerzeichen, die Zeichen des zweiten Worts, Endtoken
    // und Fuellzeichen.
    const expected = [_]i64{ 0, 50, 86, 54, 57, 135, 16, 65, 156, 87, 158, 54, 46, 10, 0 };
    try std.testing.expectEqualSlices(i64, &expected, sequence.ids);
}

test "Vokabular liest Symbole und Leerzeichen" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.Io.Dir.writeFile(tmp.dir, std.testing.io, .{
        .sub_path = "tokens.txt",
        .data = "$ 0\n  3\na 14\n",
    });
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, "tokens.txt", gpa);
    defer gpa.free(path);

    var vocab = try loadVocab(gpa, std.testing.io, path);
    defer vocab.deinit();
    try std.testing.expectEqual(@as(?i64, 0), vocab.lookup('$'));
    try std.testing.expectEqual(@as(?i64, 3), vocab.lookup(' '));
    try std.testing.expectEqual(@as(?i64, 14), vocab.lookup('a'));
    try std.testing.expectEqual(@as(?i64, null), vocab.lookup('z'));
}

test "Vokabular aus einem Speicherbereich" {
    const gpa = std.testing.allocator;
    var vocab = try parseVocab(gpa, "$ 0\n  3\na 14\n");
    defer vocab.deinit();
    try std.testing.expectEqual(@as(?i64, 14), vocab.lookup('a'));
}

test "Phonem-ID-Map liest Tokenlisten aus einer JSON-Datei" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.Io.Dir.writeFile(tmp.dir, std.testing.io, .{
        .sub_path = "model.onnx.json",
        .data = "{\"phoneme_id_map\":{\"_\":[0],\"^\":[1],\"a\":[14,15],\"aɪ\":[99]}}",
    });
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, "model.onnx.json", gpa);
    defer gpa.free(path);

    var map = try loadPhonemeIdMap(gpa, std.testing.io, path, "phoneme_id_map");
    defer map.deinit();
    try std.testing.expectEqualSlices(i64, &.{ 14, 15 }, map.lookup("a").?);
    try std.testing.expectEqualSlices(i64, &.{1}, map.lookup("^").?);
    try std.testing.expectEqual(@as(?[]const i64, null), map.lookup("z"));
    // Mehrzeichen-Schluessel werden nur bei byteweiser Uebereinstimmung
    // gefunden. Der erste Codepoint von "aɪ" darf nicht auf "a" zeigen.
    try std.testing.expectEqualSlices(i64, &.{99}, map.lookup("aɪ").?);
}

test "Phonem-ID-Folge traegt Start, Fuellzeichen und Ende" {
    const gpa = std.testing.allocator;
    var map = try parsePhonemeIdMap(gpa, "{\"phoneme_id_map\":{\"_\":[0],\"^\":[1],\"$\":[2],\"a\":[14],\"b\":[15]}}", "phoneme_id_map");
    defer map.deinit();

    const frame = try phonemeFrame(&map, "^", "_", "$");
    const sequence = try buildPhonemeIdSequence(gpa, &map, "ab", frame, .{});
    defer sequence.deinit(gpa);

    const expected = [_]i64{ 1, 0, 14, 0, 15, 0, 2 };
    try std.testing.expectEqualSlices(i64, &expected, sequence.ids);
    try std.testing.expectEqual(@as(usize, 2), sequence.body_length);
}

test "Phonem-ID-Folge ueberspringt unbekannte Phoneme" {
    const gpa = std.testing.allocator;
    var map = try parsePhonemeIdMap(gpa, "{\"phoneme_id_map\":{\"_\":[0],\"^\":[1],\"$\":[2],\"a\":[14]}}", "phoneme_id_map");
    defer map.deinit();

    const frame = try phonemeFrame(&map, "^", "_", "$");
    const sequence = try buildPhonemeIdSequence(gpa, &map, "az", frame, .{});
    defer sequence.deinit(gpa);

    const expected = [_]i64{ 1, 0, 14, 0, 2 };
    try std.testing.expectEqualSlices(i64, &expected, sequence.ids);
}

test "Textkoerper wird auf die Hoechstzahl gekuerzt" {
    const gpa = std.testing.allocator;
    const table = builtinTable(.first_wins);
    const sequence = try buildSymbolSequence(gpa, table, "abcde", .{
        .prefix = &.{0},
        .suffix = &.{ 10, 0 },
        .max_body = 3,
    });
    defer sequence.deinit(gpa);

    const expected = [_]i64{ 0, 43, 44, 45, 10, 0 };
    try std.testing.expectEqualSlices(i64, &expected, sequence.ids);
    try std.testing.expectEqual(@as(usize, 3), sequence.body_length);
}
