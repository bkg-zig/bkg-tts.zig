//! Gemeinsames Laden eines Modells.
//!
//! Der Loader nimmt die Dateien eines Modells auf: die ONNX-Session, die
//! Stimmdaten, den Tokenizer und die espeak-ng-Bibliothek. Er kennt keine
//! Modellfamilie. Welche Datei wofuer da ist und wie der Graph heisst,
//! steht im Deskriptor.
//!
//! Das geladene Modell gehoert dem Backend, das es benutzt. Das Backend gibt
//! es ueber den gemeinsamen Vertrag in `backend.zig` frei.
const std = @import("std");

const descriptor = @import("../tts/descriptor.zig");
const espeak = @import("../tts/espeak.zig");
const ort = @import("../tts/ort.zig");
const tokens = @import("../tts/tokens.zig");
const voices = @import("../tts/voices.zig");

/// Fehler, die beim Laden entstehen.
pub const Error = error{
    /// Der Graph kennt den im Deskriptor genannten Eingang nicht.
    MissingInput,
    /// Der Graph kennt den im Deskriptor genannten Ausgang nicht.
    MissingOutput,
    /// Der Deskriptor nennt fuer den Tokenizer keine Datei.
    MissingTokenizerFile,
    /// Der Deskriptor verlangt einen Verarbeitungsweg, den es nicht gibt.
    UnsupportedBackend,
};

/// Vorgaben, die der Deskriptor nicht selbst nennt.
pub const Options = struct {
    /// Pfad der espeak-ng-Bibliothek.
    espeak_library: []const u8 = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1",
    /// Verzeichnis mit den espeak-Daten.
    espeak_data: []const u8 = "/usr/lib/x86_64-linux-gnu/espeak-ng-data",
    /// Optionen der ONNX-Session.
    session: ort.SessionOptions = .{},
    /// Abtastrate, wenn weder Deskriptor noch Modell sie nennen.
    default_sample_rate: u32 = 24000,
};

/// Quelle der Token-IDs.
pub const Tokenizer = union(enum) {
    /// Eingebaute Symboltabelle.
    builtin: *const tokens.SymbolTable,
    /// Vokabular aus einer Datei.
    vocab: tokens.Vocab,
    /// Phonem-ID-Map aus einer JSON-Datei.
    phoneme_ids: tokens.PhonemeIdMap,

    pub fn deinit(self: *Tokenizer) void {
        switch (self.*) {
            .builtin => {},
            .vocab => |*vocab| vocab.deinit(),
            .phoneme_ids => |*map| map.deinit(),
        }
    }
};

/// Indices der Ein- und Ausgaenge im Graphen.
///
/// Die Namen stehen im Deskriptor. Die Reihenfolge der Ein- und Ausgaenge im
/// Graphen darf sich deshalb nicht im Code wiederholen.
pub const Indices = struct {
    /// Tokenfolge des Textes.
    tokens: usize,
    /// Stimmembedding. Null, wenn der Graph keinen kennt.
    style: ?usize = null,
    /// Sprechtempo. Null, wenn der Graph keinen kennt.
    speed: ?usize = null,
    /// Laenge der Tokenfolge. Null, wenn der Graph keinen kennt.
    lengths: ?usize = null,
    /// Werte der Inference. Null, wenn der Graph keinen kennt.
    scales: ?usize = null,
    /// Ausgang mit den Audiodaten.
    output: usize,
};

/// Ein geladenes Modell mit allen Mitteln fuer die Synthese.
pub const Model = struct {
    /// Allocator fuer alle Puffer des Modells.
    gpa: std.mem.Allocator,
    /// Eigene Kopie des Deskriptors. Sie lebt so lange wie das Modell.
    desc: *descriptor.Descriptor,
    /// Die ONNX-Session des Modells.
    session: ort.Session,
    /// Die Stimmdaten des Modells.
    table: voices.Voices,
    /// Die Quelle der Token-IDs.
    tokenizer: Tokenizer,
    /// Die eingebundene espeak-ng-Bibliothek.
    espeak: espeak.Espeak,
    /// Abtastrate der Ausgabe in Hertz.
    sample_rate: u32,
    /// Indices der Ein- und Ausgaenge im Graphen.
    indices: Indices,

    pub fn deinit(self: *Model) void {
        self.session.deinit(self.gpa);
        self.table.deinit();
        self.tokenizer.deinit();
        self.espeak.deinit();
        self.desc.deinit();
        self.gpa.destroy(self.desc);
        self.gpa.destroy(self);
    }
};

/// Laedt ein Modell aus seinem Deskriptor.
///
/// Der Aufrufer bekommt das geladene Modell. Er gibt es ueber
/// `Model.deinit` wieder frei.
pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *ort.Runtime,
    desc: *const descriptor.Descriptor,
    options: Options,
) !*Model {
    if (desc.backend == .pocket_step) return error.UnsupportedBackend;

    // Das Modell arbeitet mit einer eigenen Kopie des Deskriptors. Die
    // Registry darf ihren Deskriptor austauschen, ohne das laufende Modell
    // zu beeinflussen.
    const owned = try gpa.create(descriptor.Descriptor);
    errdefer gpa.destroy(owned);
    owned.* = try desc.clone(gpa);

    const model = try gpa.create(Model);
    errdefer gpa.destroy(model);
    model.* = .{
        .gpa = gpa,
        .desc = owned,
        .session = undefined,
        .table = undefined,
        .tokenizer = undefined,
        .espeak = undefined,
        .sample_rate = options.default_sample_rate,
        .indices = undefined,
    };
    errdefer model.desc.deinit();

    const model_path = try gpa.dupeZ(u8, owned.model_file);
    defer gpa.free(model_path);

    var failure: ort.Failure = .{};
    model.session = ort.Session.create(runtime, gpa, model_path, options.session, &failure) catch |err| {
        std.log.err("ONNX-Session fuer {s} liess sich nicht oeffnen: {s}", .{ owned.model, failure.message() });
        return err;
    };
    errdefer model.session.deinit(gpa);

    model.indices = try resolveIndices(&model.session, owned);
    model.table = try loadVoices(gpa, io, owned);
    errdefer model.table.deinit();

    model.tokenizer = try loadTokenizer(gpa, io, owned);
    errdefer model.tokenizer.deinit();

    model.espeak = try openEspeak(gpa, owned, options);
    errdefer model.espeak.deinit();

    model.sample_rate = try readSampleRate(gpa, &model.session, owned, options);

    return model;
}

/// Sucht die Ein- und Ausgaenge des Graphen beim Namen.
///
/// Nur die Tokenfolge und der Ausgang mit den Audiodaten sind Pflicht. Die
/// anderen Eingaben nimmt das Backend nur, wenn es sie braucht.
fn resolveIndices(session: *const ort.Session, desc: *const descriptor.Descriptor) !Indices {
    const tokens_index = session.inputIndexByName(desc.inputs.tokens) orelse {
        std.log.err("Modell {s} kennt keinen Eingang {s}", .{ desc.model, desc.inputs.tokens });
        return error.MissingInput;
    };

    const output_index = session.outputIndexByName(desc.output.name) orelse {
        std.log.err("Modell {s} kennt keinen Ausgang {s}", .{ desc.model, desc.output.name });
        return error.MissingOutput;
    };

    return .{
        .tokens = tokens_index,
        .style = session.inputIndexByName(desc.inputs.style),
        .speed = session.inputIndexByName(desc.inputs.speed),
        .lengths = if (desc.inputs.lengths) |name| session.inputIndexByName(name) else null,
        .scales = if (desc.inputs.scales) |name| session.inputIndexByName(name) else null,
        .output = output_index,
    };
}

/// Laedt die Stimmdaten.
///
/// Modelle ohne Stimmdatei haben eine einzige Stimme. Sie bekommt den
/// Anzeigenamen des Modells und eine Zeile, damit die Stimmzuordnung immer
/// eine Zeile findet.
fn loadVoices(
    gpa: std.mem.Allocator,
    io: std.Io,
    desc: *const descriptor.Descriptor,
) !voices.Voices {
    if (desc.voices.file.len == 0) return implicitVoice(gpa, desc);

    switch (desc.voices.format) {
        .npz => return voices.load(gpa, io, desc.voices.file),
        .flat => {
            if (desc.voices.names.len == 0) return error.NoSpeakers;
            return voices.loadFlatBin(
                gpa,
                io,
                desc.voices.file,
                desc.voices.names,
                desc.voices.rows,
                desc.voices.columns,
            );
        },
    }
}

/// Erzeugt die einzige Stimme eines Modells ohne Stimmtabelle.
fn implicitVoice(gpa: std.mem.Allocator, desc: *const descriptor.Descriptor) !voices.Voices {
    const columns = if (desc.voices.columns > 0) desc.voices.columns else 256;
    const name = try gpa.dupe(u8, desc.name);
    errdefer gpa.free(name);

    const embeddings = try gpa.alloc(f32, columns);
    errdefer gpa.free(embeddings);
    @memset(embeddings, 0);

    const entries = try gpa.alloc(voices.Voice, 1);
    errdefer gpa.free(entries);
    entries[0] = .{
        .name = name,
        .rows = 1,
        .columns = columns,
        .embeddings = embeddings,
    };

    return .{ .gpa = gpa, .entries = entries };
}

/// Laedt die Quelle der Token-IDs.
fn loadTokenizer(
    gpa: std.mem.Allocator,
    io: std.Io,
    desc: *const descriptor.Descriptor,
) !Tokenizer {
    switch (desc.tokenizer.mode) {
        .builtin => return .{ .builtin = tokens.builtinTable(desc.tokenizer.symbol_scheme) },
        .vocab => {
            const path = desc.tokenizer.symbols orelse return error.MissingTokenizerFile;
            return .{ .vocab = try tokens.loadVocab(gpa, io, path) };
        },
        .phoneme_ids => {
            const path = desc.tokenizer.phoneme_id_map orelse return error.MissingTokenizerFile;
            return .{ .phoneme_ids = try tokens.loadPhonemeIdMap(
                gpa,
                io,
                path,
                desc.tokenizer.phoneme_id_map_field,
            ) };
        },
    }
}

/// Oeffnet espeak-ng mit den Angaben des Deskriptors.
///
/// Relative Pfade gelten gegen das Verzeichnis des Deskriptors. So bleibt
/// ein Modellordner beim Umzug unveraendert.
fn openEspeak(
    gpa: std.mem.Allocator,
    desc: *const descriptor.Descriptor,
    options: Options,
) !espeak.Espeak {
    const library = try resolveEspeakPath(gpa, desc, desc.espeak.library_path orelse options.espeak_library);
    defer gpa.free(library);

    const data = try resolveEspeakPath(gpa, desc, desc.espeak.data_dir orelse options.espeak_data);
    defer gpa.free(data);

    return espeak.Espeak.open(gpa, .{
        .library_path = library,
        .data_dir = data,
        .voice = desc.text.language,
    });
}

/// Loest einen espeak-Pfad auf.
///
/// Absolute Pfade bleiben unveraendert. Relative Pfade gelten gegen das
/// Verzeichnis des Deskriptors.
fn resolveEspeakPath(
    gpa: std.mem.Allocator,
    desc: *const descriptor.Descriptor,
    path: []const u8,
) ![]u8 {
    if (path.len == 0) return gpa.dupe(u8, path);
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ desc.base_dir, path });
}

/// Liest die Abtastrate aus dem Deskriptor oder aus den Modellmetadaten.
///
/// Ohne Angabe in beiden Quellen gilt die Vorgabe der Engine.
fn readSampleRate(
    gpa: std.mem.Allocator,
    session: *const ort.Session,
    desc: *const descriptor.Descriptor,
    options: Options,
) !u32 {
    if (desc.sample_rate) |rate| return rate;

    var failure: ort.Failure = .{};
    const raw = try session.metadataValue(gpa, "sample_rate", &failure);
    defer if (raw) |text| gpa.free(text);
    const text = raw orelse return options.default_sample_rate;

    const rate = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \t\r\n"), 10) catch {
        return options.default_sample_rate;
    };
    if (rate == 0) return options.default_sample_rate;
    return rate;
}
