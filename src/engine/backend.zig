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
/// Grossschreibung, exakter Name der Stimmtabelle. Der Tempoprior des
/// Deskriptors gehoert zum internen Namen, nicht zum Alias.
pub fn resolveVoice(
    desc: *const descriptor.Descriptor,
    table: *const voices.Voices,
    requested: []const u8,
) error{VoiceNotFound}!VoiceRef {
    var wanted = requested;
    if (desc.aliasTarget(wanted)) |target| wanted = target;

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
/// gleich sein, Gross- und Kleinschreibung spielt keine Rolle.
pub fn languageMatches(expected: []const u8, requested: []const u8) bool {
    return std.ascii.eqlIgnoreCase(expected, requested);
}
