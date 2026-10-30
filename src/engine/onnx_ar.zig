//! ONNX-Backend für Modelle mit Stimmembedding und Tokenfolge.
//!
//! Der Weg ist derselbe für alle Modelle dieser Art: Text vorbereiten,
//! abschnittsweise phonemisieren, tokenisieren, Stimmzeile wählen, den
//! Graphen laufen lassen und die Ausgabe schneiden. Was davon variiert,
//! steht im Deskriptor.
//!
//! Das Backend kennt keine Modellfamilie. Es liest die Namen der Ein- und
//! Ausgänge aus dem Deskriptor und sucht sie im Graphen.
const std = @import("std");

const backend = @import("backend.zig");
const chunk = @import("../tts/chunk.zig");
const descriptor = @import("../tts/descriptor.zig");
const espeak = @import("../tts/espeak.zig");
const ort = @import("../tts/ort.zig");
const preprocess = @import("../tts/preprocess.zig");
const tokens = @import("../tts/tokens.zig");
const voices = @import("../tts/voices.zig");

/// Fehler, die nur dieses Backend liefert.
pub const Error = error{
    /// Der Graph kennt einen im Deskriptor genannten Eingang nicht.
    MissingInput,
    /// Der Graph kennt den im Deskriptor genannten Ausgang nicht.
    MissingOutput,
    /// Der Deskriptor verlangt einen Tokenizer, den dieses Backend nicht liest.
    UnsupportedTokenizer,
    /// Der Deskriptor verlangt eine Eingabe, die dieses Backend nicht fuellt.
    UnsupportedInput,
    /// Der Deskriptor verlangt eine Textart, die dieses Backend nicht kann.
    UnsupportedTextMode,
    /// Der Text enthaelt nichts zum Sprechen.
    EmptyText,
};

/// Vorgaben, die der Deskriptor nicht selbst nennt.
pub const Options = struct {
    /// Pfad der espeak-ng-Bibliothek.
    espeak_library: []const u8 = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1",
    /// Verzeichnis mit den espeak-Daten.
    espeak_data: []const u8 = "/usr/lib/x86_64-linux-gnu/espeak-ng-data",
    /// Optionen der ONNX-Session.
    session: ort.SessionOptions = .{},
};

/// Quelle der Token-IDs.
const Tokenizer = union(enum) {
    /// Eingebaute Symboltabelle.
    builtin: *const tokens.SymbolTable,
    /// Vokabular aus einer Datei.
    vocab: tokens.Vocab,

    fn deinit(self: *Tokenizer) void {
        switch (self.*) {
            .builtin => {},
            .vocab => |*vocab| vocab.deinit(),
        }
    }
};

/// Ein geladenes Modell mit allen Mitteln fuer die Synthese.
const Model = struct {
    gpa: std.mem.Allocator,
    runtime: *ort.Runtime,
    /// Eigene Kopie des Deskriptors. Sie lebt so lange wie das Backend.
    desc: *descriptor.Descriptor,
    session: ort.Session,
    table: voices.Voices,
    tokenizer: Tokenizer,
    espeak: espeak.Espeak,
    sample_rate: u32,
    /// Elementtyp der Token-Eingabe.
    token_type: ort.ElementType,

    fn deinit(self: *Model) void {
        self.session.deinit(self.gpa);
        self.table.deinit();
        self.tokenizer.deinit();
        self.espeak.deinit();
        self.desc.deinit();
        self.gpa.destroy(self.desc);
        self.gpa.destroy(self);
    }
};

/// Laedt ein Modell und gibt den passenden Backend-Handle zurueck.
pub fn create(
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *ort.Runtime,
    desc: *const descriptor.Descriptor,
    options: Options,
) !backend.Backend {
    const model = try load(gpa, io, runtime, desc, options);
    return .{ .vtable = &vtable, .ctx = model };
}

fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *ort.Runtime,
    desc: *const descriptor.Descriptor,
    options: Options,
) !*Model {
    if (desc.backend != .style_tokens) return error.UnsupportedBackend;

    const owned = try gpa.create(descriptor.Descriptor);
    errdefer gpa.destroy(owned);
    owned.* = try desc.clone(gpa);

    const model = try gpa.create(Model);
    errdefer gpa.destroy(model);
    model.* = .{
        .gpa = gpa,
        .runtime = runtime,
        .desc = owned,
        .session = undefined,
        .table = undefined,
        .tokenizer = undefined,
        .espeak = undefined,
        .sample_rate = 24000,
        .token_type = .int64,
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

    // Die Namen der Ein- und Ausgaenge kommen aus dem Deskriptor. Der Graph
    // entscheidet, welche davon es gibt.
    const token_index = model.session.inputIndexByName(owned.inputs.tokens) orelse {
        std.log.err("Modell {s} kennt keinen Eingang {s}", .{ owned.model, owned.inputs.tokens });
        return error.MissingInput;
    };
    const style_index = model.session.inputIndexByName(owned.inputs.style) orelse {
        std.log.err("Modell {s} kennt keinen Eingang {s}", .{ owned.model, owned.inputs.style });
        return error.MissingInput;
    };
    const speed_index = model.session.inputIndexByName(owned.inputs.speed) orelse {
        std.log.err("Modell {s} kennt keinen Eingang {s}", .{ owned.model, owned.inputs.speed });
        return error.MissingInput;
    };
    _ = style_index;
    _ = speed_index;

    if (owned.inputs.lengths != null or owned.inputs.scales != null) {
        std.log.err("Modell {s} verlangt eine Eingabe, die dieses Backend nicht fuellt", .{owned.model});
        return error.UnsupportedInput;
    }

    const output_index = model.session.outputIndexByName(owned.output.name) orelse {
        std.log.err("Modell {s} kennt keinen Ausgang {s}", .{ owned.model, owned.output.name });
        return error.MissingOutput;
    };
    model.output_index = output_index;

    var token_info = try model.session.inputInfo(gpa, token_index, &failure);
    defer token_info.deinit();
    model.token_type = token_info.element_type;
    if (model.token_type != .int64 and model.token_type != .int32) {
        std.log.err("Modell {s} erwartet Tokens vom Typ {s}", .{ owned.model, @tagName(model.token_type) });
        return error.UnsupportedInput;
    }

    model.table = try loadVoices(gpa, io, owned);
    errdefer model.table.deinit();

    model.tokenizer = try loadTokenizer(gpa, io, owned);
    errdefer model.tokenizer.deinit();

    model.espeak = try espeak.Espeak.open(gpa, .{
        .library_path = owned.espeak.library_path orelse options.espeak_library,
        .data_dir = owned.espeak.data_dir orelse options.espeak_data,
        .voice = owned.text.language,
    });
    errdefer model.espeak.deinit();

    model.sample_rate = try readSampleRate(gpa, model, owned);

    return model;
}

fn loadVoices(
    gpa: std.mem.Allocator,
    io: std.Io,
    desc: *const descriptor.Descriptor,
) !voices.Voices {
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

fn loadTokenizer(
    gpa: std.mem.Allocator,
    io: std.Io,
    desc: *const descriptor.Descriptor,
) !Tokenizer {
    switch (desc.tokenizer.mode) {
        .builtin => return .{ .builtin = tokens.builtinTable(desc.tokenizer.symbol_scheme) },
        .vocab => {
            const path = desc.tokenizer.symbols orelse return error.UnsupportedTokenizer;
            return .{ .vocab = try tokens.loadVocab(gpa, io, path) };
        },
        .phoneme_ids => return error.UnsupportedTokenizer,
    }
}

/// Liest die Abtastrate aus dem Deskriptor oder aus den Modellmetadaten.
fn readSampleRate(
    gpa: std.mem.Allocator,
    model: *Model,
    desc: *const descriptor.Descriptor,
) !u32 {
    if (desc.sample_rate) |rate| return rate;

    var failure: ort.Failure = .{};
    const raw = (try model.session.metadataValue(gpa, "sample_rate", &failure)) orelse return 24000;
    defer gpa.free(raw);
    const rate = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return 24000;
    return rate;
}
