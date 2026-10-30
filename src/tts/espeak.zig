//! espeak-ng als eingebundene Bibliothek.
//!
//! Die Bibliothek wird zur Laufzeit per dlopen geladen. Dafuer muss das Ziel
//! libc linken, wie es build.zig fuer den Server tut.
//!
//! espeak-ng haelt prozess-globalen Zustand: die Initialisierung, die aktive
//! Stimme und den Puffer der letzten Phonemisierung. Deshalb gibt es einen
//! statischen Mutex und einen statischen Globalzustand. Wechselt das
//! Datenverzeichnis oder die Stimme, wird espeak unter dem Mutex neu
//! initialisiert.
//!
//! espeak liefert die Phoneme in einem statischen Puffer, der beim naechsten
//! Aufruf ueberschrieben wird. Deshalb wird das Ergebnis sofort kopiert.
//!
//! espeak uebersetzt pro Aufruf nur eine Clause. Der Rest des Textes bleibt
//! im Decoder von espeak liegen und wuerde beim naechsten Aufruf erneut
//! uebersetzt. Deshalb wird der Decoder nach jeder Uebersetzung geleert.
const std = @import("std");
const builtin = @import("builtin");

/// Optionen der eingebundenen Bibliothek.
pub const Options = struct {
    /// Pfad der Shared Library, zum Beispiel "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1".
    library_path: []const u8,
    /// Datenverzeichnis von espeak-ng oder dessen Elternverzeichnis.
    data_dir: []const u8,
    /// Stimme, zum Beispiel "en-us" oder "de".
    voice: []const u8,
};

/// Ein Satz aus IPA-Phonemen mit dem Rohwert des Terminators.
pub const Clause = struct {
    /// Phoneme ohne Terminatorzeichen, UTF-8, vom Aufrufer freizugeben.
    text: []u8,
    /// Rohwert von espeak, ungefiltert.
    terminator: u32,
};

/// Fehler der Anbindung.
pub const Error = error{
    /// Das Datenverzeichnis fehlt oder ist unvollstaendig.
    MissingEspeakData,
    /// Die Bibliothek enthaelt eines der benoetigten Symbole nicht.
    SymbolMissing,
    /// Die Bibliothek konnte nicht geladen werden.
    LibraryOpenFailed,
    /// Eine andere Bibliothek ist bereits geladen.
    LibraryMismatch,
    /// espeak liess sich mit dem Datenverzeichnis nicht initialisieren.
    InitializeFailed,
    /// Die Stimme ist espeak unbekannt.
    VoiceNotFound,
    /// Die Bibliothek ist nicht geladen.
    LibraryNotLoaded,
    OutOfMemory,
};

/// AUDIO_OUTPUT_SYNCHRONOUS
const audio_output_synchronous: c_int = 2;
/// espeakCHARS_AUTO
///
/// Die Automatik probiert zuerst UTF-8 und faellt sonst auf die Zeichensatztabelle
/// der Stimme zurueck. Das ist der Weg, den die Kommandozeile und der
/// Piper-Pfad nehmen.
const chars_auto: c_int = 0;
/// espeakPHONEMES_IPA
const phonemes_ipa: c_int = 0x02;
/// EE_OK
const error_ok: c_int = 0;

/// CLAUSE_TYPE_SENTENCE
const clause_type_sentence: u32 = 0x0008_0000;
/// Untere 20 Bit des Terminators, so wie es der Piper-Pfad uebernimmt.
const terminator_mask: u32 = 0x000F_FFFF;

const InitializeFn = *const fn (
    output: c_int,
    buflength: c_int,
    path: ?[*:0]const u8,
    options: c_int,
) callconv(.c) c_int;

const SetVoiceByNameFn = *const fn (name: [*:0]const u8) callconv(.c) c_int;

const TextToPhonemesFn = *const fn (
    textptr: *?*anyopaque,
    textmode: c_int,
    phonememode: c_int,
    terminator: *c_int,
) callconv(.c) ?[*:0]const u8;

/// Die aufgeloesten Symbole der Bibliothek.
const Api = struct {
    initialize: InitializeFn,
    set_voice_by_name: SetVoiceByNameFn,
    text_to_phonemes: TextToPhonemesFn,
};

/// Prozess-globaler Zustand von espeak-ng.
///
/// Der Mutex schuetzt die Bibliothek und diesen Zustand. Er wird fuer jeden
/// Zugriff gehalten, weil espeak selbst keinen eigenen Lock hat.
const Global = struct {
    mutex: std.Io.Mutex = .init,
    lib: ?std.DynLib = null,
    api: ?Api = null,
    library_path: ?[:0]u8 = null,
    data_dir: ?[:0]u8 = null,
    voice: ?[:0]u8 = null,
    users: usize = 0,
};

var global: Global = .{};

/// Die Io-Instanz fuer den globalen Mutex und die Dateisystempruefungen.
///
/// Die oeffentliche API nimmt kein Io entgegen, deshalb kommt hier die
/// globale Einzelthread-Instanz von std zum Einsatz.
fn stdIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Nimmt den globalen Mutex.
fn lockGlobal() void {
    global.mutex.lockUncancelable(stdIo());
}

/// Gibt den globalen Mutex wieder frei.
fn unlockGlobal() void {
    global.mutex.unlock(stdIo());
}

/// Binding auf espeak-ng.
pub const Espeak = struct {
    gpa: std.mem.Allocator,
    library_path: [:0]u8,
    data_dir: [:0]u8,
    voice: [:0]u8,

    /// Laedt die Bibliothek, prueft das Datenverzeichnis und initialisiert espeak.
    ///
    /// Fehlt ein Pflichtsymbol, wird `error.SymbolMissing` geliefert. Ein
    /// unvollstaendiges Datenverzeichnis fuehrt zu `error.MissingEspeakData`,
    /// damit espeak nicht still auf seinen Systemstandard zurueckfaellt.
    pub fn open(gpa: std.mem.Allocator, options: Options) Error!Espeak {
        const library_path = try gpa.dupeZ(u8, options.library_path);
        errdefer gpa.free(library_path);
        const voice = try gpa.dupeZ(u8, options.voice);
        errdefer gpa.free(voice);

        lockGlobal();
        defer unlockGlobal();

        try loadLibrary(library_path);
        errdefer {
            if (global.users == 0) unloadLibrary();
        }

        const data_dir = normalizeDataDir(gpa, options.data_dir) catch |err| switch (err) {
            error.MissingEspeakData => {
                if (options.data_dir.len == 0) {
                    std.log.err("espeak-ng: Datenverzeichnis ist leer", .{});
                } else {
                    std.log.err("espeak-ng: Datenverzeichnis {s} ist unvollstaendig, die Datei phontab fehlt", .{options.data_dir});
                }
                return error.MissingEspeakData;
            },
            else => |other| return other,
        };
        errdefer gpa.free(data_dir);

        try ensureState(data_dir, voice);

        global.users += 1;
        return .{
            .gpa = gpa,
            .library_path = library_path,
            .data_dir = data_dir,
            .voice = voice,
        };
    }

    /// Gibt den eigenen Zustand frei.
    ///
    /// Die Bibliothek bleibt geladen, solange andere Instanzen sie benutzen.
    pub fn deinit(self: *Espeak) void {
        lockGlobal();
        defer unlockGlobal();

        self.gpa.free(self.library_path);
        self.gpa.free(self.data_dir);
        self.gpa.free(self.voice);
        self.* = undefined;

        if (global.users > 0) global.users -= 1;
        if (global.users == 0) unloadLibrary();
    }

    /// Ganzer Text in einem Aufruf. Liefert die IPA-Phoneme als kopierten Puffer.
    ///
    /// espeak uebersetzt pro Aufruf nur eine Clause, das Ergebnis ist daher
    /// der erste Clause des Textes. Fuer Texte mit mehreren Clauses liefert
    /// `phonemizeClauses` alle Clauses mit ihren Terminatoren.
    ///
    /// Der Rest des Textes bleibt im Decoder von espeak. Damit der naechste
    /// Aufruf nicht mit diesem Rest beginnt, wird der Decoder nach dem
    /// Kopieren geleert. Die Phoneme des Restes werden verworfen.
    ///
    /// Leere Eingaben und Eingaben ohne Ergebnis liefern einen leeren Puffer.
    pub fn phonemize(self: *Espeak, text: []const u8) Error![]u8 {
        lockGlobal();
        defer unlockGlobal();

        try ensureState(self.data_dir, self.voice);

        if (text.len == 0) return self.gpa.alloc(u8, 0);

        const api = global.api orelse return error.LibraryNotLoaded;
        const text_z = try self.gpa.dupeZ(u8, text);
        defer self.gpa.free(text_z);

        var textptr: ?*anyopaque = @ptrCast(text_z.ptr);
        var terminator: c_int = 0;
        const step = nextClause(api, &textptr, &terminator);

        // Der Rest des Textes muss aus dem Decoder, sonst beginnt der
        // naechste Aufruf mit dem Rest des vorherigen Textes.
        errdefer _ = drainDecoder(api, &textptr);

        const result = if (step.phonemes) |phonemes|
            try self.gpa.dupe(u8, std.mem.span(phonemes))
        else
            try self.gpa.alloc(u8, 0);

        if (!drainDecoder(api, &textptr)) {
            std.log.err("espeak-ng: Textzeiger steht still, der Resttext im Decoder bleibt liegen", .{});
        }
        return result;
    }

    /// Clause-Loop wie Piper: liefert pro Satz ein Phonemstueck und den Terminator.
    ///
    /// Der Textzeiger wandert mit jedem Aufruf weiter und ist am Ende null.
    /// Der Text laeuft durch genau einen Clause-Loop.
    pub fn phonemizeClauses(self: *Espeak, text: []const u8) Error![]Clause {
        lockGlobal();
        defer unlockGlobal();

        try ensureState(self.data_dir, self.voice);

        var clauses: std.ArrayList(Clause) = .empty;
        errdefer {
            for (clauses.items) |clause| self.gpa.free(clause.text);
            clauses.deinit(self.gpa);
        }

        if (text.len == 0) return clauses.toOwnedSlice(self.gpa);

        const api = global.api orelse return error.LibraryNotLoaded;
        const text_z = try self.gpa.dupeZ(u8, text);
        defer self.gpa.free(text_z);

        var textptr: ?*anyopaque = @ptrCast(text_z.ptr);
        var stalled = false;
        while (textptr != null) {
            var terminator: c_int = 0;
            const step = nextClause(api, &textptr, &terminator);
            const phonemes = step.phonemes orelse break;
            const copied = try self.gpa.dupe(u8, std.mem.span(phonemes));
            try clauses.append(self.gpa, .{
                .text = copied,
                .terminator = @bitCast(terminator),
            });

            // Ohne Fortschritt wuerde der Loop endlos laufen.
            if (!step.advanced) {
                stalled = true;
                break;
            }
        }

        // Der Loop endet normalerweise mit einem leeren Decoder. Nur wenn er
        // vorzeitig endet, liegt noch Resttext im Decoder.
        const drained = drainDecoder(api, &textptr);
        if (stalled or !drained) {
            std.log.err("espeak-ng: Textzeiger ist nicht weitergewandt, der Clause-Loop endet", .{});
        }
        return clauses.toOwnedSlice(self.gpa);
    }
};

/// Ergebnis eines Aufrufs von espeak fuer den naechsten Clause.
const ClauseStep = struct {
    /// Phoneme des Clauses oder null, wenn die Textquelle leer ist.
    phonemes: ?[*:0]const u8,
    /// false, wenn der Textzeiger nicht weitergewandt ist.
    advanced: bool,
};

/// Ruft espeak fuer den naechsten Clause auf.
///
/// Der Textzeiger wandert mit jedem Aufruf weiter und ist am Ende null.
fn nextClause(api: Api, textptr: *?*anyopaque, terminator: *c_int) ClauseStep {
    const before = textptr.* orelse return .{ .phonemes = null, .advanced = true };
    const phonemes = api.text_to_phonemes(textptr, chars_auto, phonemes_ipa, terminator);
    const advanced = if (textptr.*) |current| current != before else true;
    return .{ .phonemes = phonemes, .advanced = advanced };
}

/// Leert den Resttext im Decoder von espeak.
///
/// Nach einem Aufruf von espeak_TextToPhonemesWithTerminator bleibt der Rest
/// des Textes im Decoder. Ein weiterer Aufruf wuerde ihn mituebersetzen.
/// Deshalb wird der Rest uebersetzt und verworfen, bis der Textzeiger null
/// ist. Der Decoder ist danach wieder leer.
///
/// Gibt false zurueck, wenn der Textzeiger nicht weiterwandt. Dann liegt der
/// Resttext weiter im Decoder.
fn drainDecoder(api: Api, textptr: *?*anyopaque) bool {
    while (textptr.* != null) {
        var terminator: c_int = 0;
        const step = nextClause(api, textptr, &terminator);
        if (step.phonemes == null) break;
        if (!step.advanced) return false;
    }
    return true;
}

/// Satzende, wenn Bit 0x80000 gesetzt ist.
pub fn isSentenceEnd(terminator: u32) bool {
    return (terminator & clause_type_sentence) != 0;
}

/// Terminator auf die unteren 20 Bit beschneiden, wie es der Piper-Pfad tut.
pub fn maskTerminator(terminator: u32) u32 {
    return terminator & terminator_mask;
}

/// Satzzeichen, das zu einem Terminator gehoert.
///
/// Die Masken stammen aus den_clause-Konstanten der espeak-Anbindung von
/// Piper. Der Terminator wird zuerst auf die unteren 20 Bit beschneiden,
/// danach wird die Maske verglichen. Ein unbekannter Terminator liefert
/// keinen Text.
pub fn terminatorText(terminator: u32) []const u8 {
    return switch (maskTerminator(terminator)) {
        0x0008_0028 => ".",
        0x0008_2028 => "?",
        0x0008_302d => "!",
        0x0004_1014 => ",",
        0x0004_001e => ":",
        0x0004_101e => ";",
        else => "",
    };
}

/// Traegt der Terminator ein Satzzeichen, das kein Satzende ist?
///
/// Nach einem Komma, Doppelpunkt oder Semikolon setzt der Piper-Pfad ein
/// Leerzeichen hinter das Zeichen.
pub fn terminatorNeedsSpace(terminator: u32) bool {
    return switch (maskTerminator(terminator)) {
        0x0004_1014, 0x0004_001e, 0x0004_101e => true,
        else => false,
    };
}

/// Laedt die Bibliothek und loest die Pflichtsymbole auf.
fn loadLibrary(path: [:0]const u8) Error!void {
    if (global.lib != null) {
        const loaded = global.library_path orelse return error.LibraryNotLoaded;
        if (!std.mem.eql(u8, loaded, path)) {
            std.log.err("espeak-ng: {s} ist bereits geladen, {s} kann nicht parallel geladen werden", .{ loaded, path });
            return error.LibraryMismatch;
        }
        return;
    }

    var lib = std.DynLib.open(path) catch |err| {
        std.log.err("espeak-ng: Bibliothek {s} konnte nicht geladen werden: {s}", .{ path, @errorName(err) });
        return error.LibraryOpenFailed;
    };
    errdefer lib.close();

    const api = try resolveApi(&lib);

    const stored_path = std.heap.page_allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(stored_path);

    global.lib = lib;
    global.api = api;
    global.library_path = stored_path;
}

/// Loest die drei Symbole auf, die die Anbindung braucht.
fn resolveApi(lib: *std.DynLib) Error!Api {
    const initialize = lib.lookup(InitializeFn, "espeak_Initialize") orelse {
        std.log.err("espeak-ng: Symbol espeak_Initialize fehlt in der geladenen Bibliothek", .{});
        return error.SymbolMissing;
    };
    const set_voice_by_name = lib.lookup(SetVoiceByNameFn, "espeak_SetVoiceByName") orelse {
        std.log.err("espeak-ng: Symbol espeak_SetVoiceByName fehlt in der geladenen Bibliothek", .{});
        return error.SymbolMissing;
    };
    const text_to_phonemes = lib.lookup(TextToPhonemesFn, "espeak_TextToPhonemesWithTerminator") orelse {
        std.log.err("espeak-ng: Symbol espeak_TextToPhonemesWithTerminator fehlt in der geladenen Bibliothek", .{});
        return error.SymbolMissing;
    };
    return .{
        .initialize = initialize,
        .set_voice_by_name = set_voice_by_name,
        .text_to_phonemes = text_to_phonemes,
    };
}

/// Entlaedt die Bibliothek und setzt den Globalzustand zurueck.
fn unloadLibrary() void {
    if (global.lib) |*lib| lib.close();
    global.lib = null;
    global.api = null;
    if (global.library_path) |path| std.heap.page_allocator.free(path);
    global.library_path = null;
    if (global.data_dir) |path| std.heap.page_allocator.free(path);
    global.data_dir = null;
    if (global.voice) |name| std.heap.page_allocator.free(name);
    global.voice = null;
}

/// Stellt sicher, dass espeak mit dem gewuenschten Datenverzeichnis und der
/// gewuenschten Stimme laeuft.
///
/// Der Mutex muss gehalten sein. Weicht einer der beiden Werte vom
/// Globalzustand ab, wird espeak neu initialisiert.
fn ensureState(data_dir: [:0]const u8, voice: [:0]const u8) Error!void {
    const api = global.api orelse return error.LibraryNotLoaded;

    const same_data = global.data_dir != null and std.mem.eql(u8, global.data_dir.?, data_dir);
    const same_voice = global.voice != null and std.mem.eql(u8, global.voice.?, voice);
    if (same_data and same_voice) return;

    const sample_rate = api.initialize(audio_output_synchronous, 0, data_dir.ptr, 0);
    if (sample_rate < 0) {
        std.log.err("espeak-ng: Initialisierung mit dem Datenverzeichnis {s} fehlgeschlagen (Code {d})", .{ data_dir, sample_rate });
        return error.InitializeFailed;
    }

    const status = api.set_voice_by_name(voice.ptr);
    if (status != error_ok) {
        std.log.err("espeak-ng: Stimme {s} ist espeak unbekannt (Code {d})", .{ voice, status });
        return error.VoiceNotFound;
    }

    try storeState(data_dir, voice);
}

/// Uebernimmt Datenverzeichnis und Stimme in den Globalzustand.
fn storeState(data_dir: [:0]const u8, voice: [:0]const u8) Error!void {
    const new_data_dir = std.heap.page_allocator.dupeZ(u8, data_dir) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(new_data_dir);
    const new_voice = std.heap.page_allocator.dupeZ(u8, voice) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(new_voice);

    if (global.data_dir) |old| std.heap.page_allocator.free(old);
    if (global.voice) |old| std.heap.page_allocator.free(old);
    global.data_dir = new_data_dir;
    global.voice = new_voice;
}

/// Prueft das Datenverzeichnis und bringt es auf die Form, die espeak erwartet.
///
/// Liegt `phontab` direkt im Verzeichnis, ist dieses das Datenverzeichnis.
/// Liegt es in `espeak-ng-data`, ist dieser Unterordner das Datenverzeichnis.
/// Sonst gibt es `error.MissingEspeakData`, weil espeak sonst still auf
/// seinen Systemstandard zurueckfaellt.
///
/// Die Funktion meldet nichts selbst. `Espeak.open` schreibt die deutsche
/// Meldung, damit ein Fehler dort genau einmal erscheint.
fn normalizeDataDir(gpa: std.mem.Allocator, dir: []const u8) Error![:0]u8 {
    if (dir.len == 0) return error.MissingEspeakData;

    const direct = try std.fs.path.joinZ(gpa, &.{ dir, "phontab" });
    defer gpa.free(direct);
    if (isFile(direct)) return gpa.dupeZ(u8, dir);

    const nested_dir = try std.fs.path.joinZ(gpa, &.{ dir, "espeak-ng-data" });
    defer gpa.free(nested_dir);
    const nested = try std.fs.path.joinZ(gpa, &.{ dir, "espeak-ng-data", "phontab" });
    defer gpa.free(nested);
    if (isFile(nested)) return gpa.dupeZ(u8, nested_dir);

    return error.MissingEspeakData;
}

/// Prueft, ob der Pfad auf eine regulaere Datei zeigt.
fn isFile(path: []const u8) bool {
    return pathKind(path) == .file;
}

/// Prueft, ob der Pfad auf ein Verzeichnis zeigt.
fn isDirectory(path: []const u8) bool {
    return pathKind(path) == .directory;
}

/// Liest die Art des Pfades aus dem Dateisystem.
fn pathKind(path: []const u8) ?std.Io.File.Kind {
    const stat = std.Io.Dir.cwd().statFile(stdIo(), path, .{}) catch return null;
    return stat.kind;
}

const test_library_path = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1";
const test_data_dir = "/usr/lib/x86_64-linux-gnu/espeak-ng-data";

test "Terminator wird wie im Piper-Pfad behandelt" {
    try std.testing.expect(isSentenceEnd(0x0008_0000));
    try std.testing.expect(!isSentenceEnd(0x0004_0000));
    try std.testing.expect(!isSentenceEnd(0));
    try std.testing.expectEqual(@as(u32, 0x0002_3456), maskTerminator(0x0012_3456));
}

test "Datenverzeichnis ohne phontab wird abgelehnt" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.MissingEspeakData,
        normalizeDataDir(gpa, "/bkg-tts-gibt-es-nicht/espeak-ng-data"),
    );
    try std.testing.expectError(
        error.MissingEspeakData,
        normalizeDataDir(gpa, ""),
    );
}

test "Phonemisierung mit der Systembibliothek" {
    if (!builtin.link_libc) return error.SkipZigTest;
    if (!isFile(test_library_path)) return error.SkipZigTest;
    if (!isDirectory(test_data_dir)) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var espeak = try Espeak.open(gpa, .{
        .library_path = test_library_path,
        .data_dir = test_data_dir,
        .voice = "en-us",
    });
    defer espeak.deinit();

    const phonemes = try espeak.phonemize("Hello world.");
    defer gpa.free(phonemes);
    try std.testing.expect(phonemes.len > 0);

    const empty = try espeak.phonemize("");
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "Wiederholte Phonemisierung eines mehrteiligen Textes bleibt gleich" {
    if (!builtin.link_libc) return error.SkipZigTest;
    if (!isFile(test_library_path)) return error.SkipZigTest;
    if (!isDirectory(test_data_dir)) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var espeak = try Espeak.open(gpa, .{
        .library_path = test_library_path,
        .data_dir = test_data_dir,
        .voice = "en-us",
    });
    defer espeak.deinit();

    // Der Text hat zwei Clauses. Ohne das Leeren des Decoders wuerde der
    // zweite Aufruf den Rest des ersten Textes mituebersetzen.
    const first = try espeak.phonemize("Guten Tag, wie geht es Ihnen?");
    defer gpa.free(first);
    const second = try espeak.phonemize("Guten Tag, wie geht es Ihnen?");
    defer gpa.free(second);

    try std.testing.expect(first.len > 0);
    try std.testing.expectEqualStrings(first, second);
}
