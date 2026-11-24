//! Gemeinsamer Vertrag aller Modell-Backends.
//!
//! Die Engine kennt keine Modellfamilie. Jedes Backend meldet sich mit
//! demselben Vertrag an: Es synthetisiert Text zu Samples, nennt seine
//! Stimmen und beschreibt sich selbst. Die Auswahl des Backend-Wegs steht
//! im Deskriptor des Modells.
const std = @import("std");

const descriptor = @import("../tts/descriptor.zig");
const voices = @import("../tts/voices.zig");

/// Ergebnis einer Synthese.
pub const Result = struct {
    /// Audio-Samples als Float32.
    pcm: []f32,
    /// Abtastrate der Samples in Hertz.
    sample_rate: u32,
};

/// Anfrage an ein Backend.
pub const Request = struct {
    /// Text, der gesprochen werden soll.
    text: []const u8,
    /// Name der Stimme. Leer bedeutet: die erste Stimme der Tabelle.
    voice: []const u8 = "",
    /// Sprache des Textes. Null bedeutet: die Sprache des Deskriptors.
    language: ?[]const u8 = null,
    /// Sprechtempo. 1.0 ist die normale Geschwindigkeit.
    speed: f32 = 1.0,
};

/// Eine aufgeloeste Stimme mit ihrem Platz in der Stimmtabelle.
pub const VoiceRef = struct {
    /// Interner Name der Stimme.
    name: []const u8,
    /// Index der Stimme in der Tabelle.
    index: usize,
    /// Zeilen der Stimmtabelle dieser Stimme.
    rows: usize,
    /// Spalten je Zeile.
    columns: usize,
};

/// Die Funktionszeiger eines Backends.
pub const VTable = struct {
    /// Gibt alle Ressourcen des Backends frei.
    deinit: *const fn (ctx: *anyopaque) void,
    /// Synthetisiert Text zu Samples.
    synthesize: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, request: Request) anyerror!Result,
    /// Abtastrate der erzeugten Samples.
    sampleRate: *const fn (ctx: *const anyopaque) u32,
    /// Namen aller Stimmen des Modells.
    voiceNames: *const fn (ctx: *const anyopaque, gpa: std.mem.Allocator) anyerror![][]const u8,
    /// Loest einen Anfragestimmnamen auf den internen Namen auf.
    ///
    /// Der Name liegt in eigenem Speicher und wird vom Aufrufer freigegeben.
    /// Null bedeutet: die Stimme gibt es nicht.
    resolveVoice: *const fn (ctx: *const anyopaque, gpa: std.mem.Allocator, requested: []const u8) anyerror!?[]const u8,
    /// Eindeutige Kennung des Modells.
    modelId: *const fn (ctx: *const anyopaque) []const u8,
    /// Anzeigename des Modells.
    modelName: *const fn (ctx: *const anyopaque) []const u8,
    /// Sprache, die das Modell versteht.
    language: *const fn (ctx: *const anyopaque) []const u8,
};

/// Handle auf ein geladenes Modell.
pub const Backend = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub fn deinit(self: *Backend) void {
        self.vtable.deinit(self.ctx);
        self.* = undefined;
    }

    pub fn synthesize(self: *const Backend, gpa: std.mem.Allocator, request: Request) anyerror!Result {
        return self.vtable.synthesize(self.ctx, gpa, request);
    }

    pub fn sampleRate(self: *const Backend) u32 {
        return self.vtable.sampleRate(self.ctx);
    }

    pub fn voiceNames(self: *const Backend, gpa: std.mem.Allocator) anyerror![][]const u8 {
        return self.vtable.voiceNames(self.ctx, gpa);
    }

    /// Loest einen Anfragestimmnamen auf den internen Namen auf.
    ///
    /// Der Name liegt in eigenem Speicher und wird vom Aufrufer freigegeben.
    /// Null bedeutet: die Stimme gibt es nicht.
    pub fn resolveVoice(self: *const Backend, gpa: std.mem.Allocator, requested: []const u8) anyerror!?[]const u8 {
        return self.vtable.resolveVoice(self.ctx, gpa, requested);
    }

    pub fn modelId(self: *const Backend) []const u8 {
        return self.vtable.modelId(self.ctx);
    }

    pub fn modelName(self: *const Backend) []const u8 {
        return self.vtable.modelName(self.ctx);
    }

    pub fn language(self: *const Backend) []const u8 {
        return self.vtable.language(self.ctx);
    }
};

/// Loest einen Anfragestimmnamen auf den internen Namen einer Stimme ab.
///
/// Die Reihenfolge ist: exakter Alias, Alias ohne Beachtung der
/// Grossschreibung, exakter Name der Stimmtabelle, Name der Stimmtabelle
/// ohne Beachtung der Grossschreibung. Eine leere Anfrage nimmt die erste
/// Stimme der Tabelle. Der Tempoprior des Deskriptors gehoert zum internen
/// Namen, nicht zum Alias.
pub fn resolveVoice(
    desc: *const descriptor.Descriptor,
    table: *const voices.Voices,
    requested: []const u8,
) error{VoiceNotFound}!VoiceRef {
    var wanted = requested;
    if (desc.aliasTarget(wanted)) |target| wanted = target;

    if (wanted.len == 0) {
        if (table.entries.len == 0) return error.VoiceNotFound;
        const entry = &table.entries[0];
        return .{
            .name = entry.name,
            .index = 0,
            .rows = entry.rows,
            .columns = entry.columns,
        };
    }

    for (table.entries, 0..) |*entry, index| {
        if (std.mem.eql(u8, entry.name, wanted)) {
            return .{
                .name = entry.name,
                .index = index,
                .rows = entry.rows,
                .columns = entry.columns,
            };
        }
    }

    for (table.entries, 0..) |*entry, index| {
        if (std.ascii.eqlIgnoreCase(entry.name, wanted)) {
            return .{
                .name = entry.name,
                .index = index,
                .rows = entry.rows,
                .columns = entry.columns,
            };
        }
    }

    return error.VoiceNotFound;
}

/// Berechnet die Zeile des Stimmembeddings aus der Laenge des Textes.
///
///     local = clamp(length - offset, min, max oder rows - 1)
///
/// Jede Stimme hat ihre eigene Matrix, deshalb beginnt die Zeilennummer
/// bei null. `length` ist die Zahl der Tokens mit Rahmen (Grundlage "tokens")
/// oder die Zahl der Symbole ohne Rahmen (Grundlage "symbols").
pub fn styleIndex(spec: descriptor.StyleIndexSpec, length: usize, rows: usize) usize {
    const shifted = length -| spec.offset;
    const upper = @max(spec.max orelse (rows -| 1), spec.min);
    return @min(@max(shifted, spec.min), upper);
}

/// Prueft, ob eine Sprache zum Modell passt.
///
/// Ohne Angabe gilt die Sprache des Deskriptors. Sonst muss die Sprache
/// gleich sein. Gross- und Kleinschreibung spielt keine Rolle. Zusaetzlich
/// passt ein Sprachcode, wenn sein erster Teil gleich ist: "en" passt zu
/// "en-us", "de" passt zu "de-de".
pub fn languageMatches(expected: []const u8, requested: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(expected, requested)) return true;

    const expected_primary = primarySubtag(expected);
    const requested_primary = primarySubtag(requested);
    if (expected_primary.len == 0 or requested_primary.len == 0) return false;
    return std.ascii.eqlIgnoreCase(expected_primary, requested_primary);
}

/// Der erste Teil eines Sprachcodes.
///
/// "en-us" wird zu "en", "de" bleibt "de". Der zweite Teil kann mit "-"
/// oder "_" beginnen.
fn primarySubtag(language: []const u8) []const u8 {
    var index: usize = 0;
    while (index < language.len) : (index += 1) {
        const c = language[index];
        if (c == '-' or c == '_') break;
    }
    return language[0..index];
}

const testing = std.testing;

const test_config =
    \\{
    \\  "name": "Testmodell",
    \\  "model": "test",
    \\  "model_file": "test.onnx",
    \\  "voices": "voices.npz",
    \\  "voice_aliases": { "Bella": "expr-voice-2-f" }
    \\}
;

/// Laedt den Testdeskriptor und baut eine Stimmtabelle mit zwei Stimmen.
fn testSetup(gpa: std.mem.Allocator, tmp: *const testing.TmpDir) !struct {
    desc: descriptor.Descriptor,
    table: voices.Voices,
} {
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = test_config });

    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir_path);
    const config_path = try std.fs.path.join(gpa, &.{ dir_path, "config.json" });
    defer gpa.free(config_path);

    var desc = try descriptor.load(gpa, io, config_path);
    errdefer desc.deinit();

    const names = [_][]const u8{ "expr-voice-2-f", "expr-voice-3-m" };
    const entries = try gpa.alloc(voices.Voice, names.len);
    errdefer gpa.free(entries);
    for (names, 0..) |name, index| {
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        const embeddings = try gpa.alloc(f32, 4);
        errdefer gpa.free(embeddings);
        @memset(embeddings, 0);
        entries[index] = .{
            .name = owned,
            .rows = 1,
            .columns = 4,
            .embeddings = embeddings,
        };
    }

    return .{ .desc = desc, .table = .{ .gpa = gpa, .entries = entries } };
}

test "Stimme wird ueber Alias, Namen und Grossschreibung gefunden" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var setup = try testSetup(gpa, &tmp);
    defer setup.desc.deinit();
    defer setup.table.deinit();

    const by_alias = try resolveVoice(&setup.desc, &setup.table, "Bella");
    try testing.expectEqualStrings("expr-voice-2-f", by_alias.name);
    try testing.expectEqual(@as(usize, 0), by_alias.index);

    const by_name = try resolveVoice(&setup.desc, &setup.table, "expr-voice-3-m");
    try testing.expectEqual(@as(usize, 1), by_name.index);

    const by_case = try resolveVoice(&setup.desc, &setup.table, "EXPR-VOICE-2-F");
    try testing.expectEqual(@as(usize, 0), by_case.index);
}

test "Leere Stimme nimmt die erste der Tabelle" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var setup = try testSetup(gpa, &tmp);
    defer setup.desc.deinit();
    defer setup.table.deinit();

    const first = try resolveVoice(&setup.desc, &setup.table, "");
    try testing.expectEqualStrings("expr-voice-2-f", first.name);
    try testing.expectEqual(@as(usize, 0), first.index);
}

test "Unbekannte Stimme wird gemeldet" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var setup = try testSetup(gpa, &tmp);
    defer setup.desc.deinit();
    defer setup.table.deinit();

    try testing.expectError(
        error.VoiceNotFound,
        resolveVoice(&setup.desc, &setup.table, "Marta"),
    );
}

test "Sprache wird ueber den ersten Teil verglichen" {
    try testing.expect(languageMatches("en", "en"));
    try testing.expect(languageMatches("en-us", "en"));
    try testing.expect(languageMatches("en", "en-US"));
    try testing.expect(languageMatches("de-DE", "de-de"));
    try testing.expect(!languageMatches("en", "de"));
    try testing.expect(!languageMatches("en", "eng"));
    try testing.expect(!languageMatches("", "en"));
}

test "Zeile des Stimmembeddings wird begrenzt" {
    const spec = descriptor.StyleIndexSpec{ .offset = 1, .min = 0, .max = 510 };
    try testing.expectEqual(@as(usize, 0), styleIndex(spec, 1, 511));
    try testing.expectEqual(@as(usize, 4), styleIndex(spec, 5, 511));
    try testing.expectEqual(@as(usize, 510), styleIndex(spec, 1000, 511));
}
