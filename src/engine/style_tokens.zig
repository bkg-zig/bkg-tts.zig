//! ONNX-Backend fuer Modelle mit Stimmembedding und Tokenfolge.
//!
//! Der Weg ist fuer alle Modelle dieser Art gleich: Text vorbereiten,
//! abschnittsweise phonemisieren, tokenisieren, Stimmzeile waehlen, den
//! Graphen laufen lassen und die Ausgabe schneiden. Was davon variiert,
//! steht im Deskriptor.
//!
//! Das Backend kennt keine Modellfamilie. Es liest die Namen der Ein- und
//! Ausgaenge aus dem Deskriptor und sucht sie im Graphen.
const std = @import("std");

const backend = @import("backend.zig");
const chunk = @import("../tts/chunk.zig");
const descriptor = @import("../tts/descriptor.zig");
const loader = @import("loader.zig");
const ort = @import("../tts/ort.zig");
const phonemes = @import("phonemes.zig");
const tokens = @import("../tts/tokens.zig");

/// Fehler, die nur dieses Backend liefert.
pub const Error = error{
    /// Der Deskriptor verlangt einen anderen Verarbeitungsweg.
    UnsupportedBackend,
    /// Der Graph erwartet einen Typ, den dieses Backend nicht erzeugen kann.
    UnsupportedInput,
    /// Der Deskriptor nennt fuer den Tokenizer keine Datei.
    MissingTokenizerFile,
    /// Der Deskriptor nennt die Sonderzeichen der Phonem-ID-Map nicht.
    MissingFramePhoneme,
    /// Der Text enthaelt nichts zum Sprechen.
    EmptyText,
    /// Die angeforderte Sprache passt nicht zum Modell.
    LanguageMismatch,
    /// Die angeforderte Stimme gibt es nicht.
    VoiceNotFound,
};

/// Vorgaben, die der Deskriptor nicht selbst nennt.
pub const Options = loader.Options;

/// Laedt ein Modell und gibt den passenden Backend-Handle zurueck.
pub fn create(
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *ort.Runtime,
    desc: *const descriptor.Descriptor,
    options: Options,
) !backend.Backend {
    if (desc.backend != .style_tokens) return error.UnsupportedBackend;

    const model = try loader.load(gpa, io, runtime, desc, options);
    return .{ .vtable = &vtable, .ctx = model };
}

const vtable = backend.VTable{
    .deinit = deinitModel,
    .synthesize = synthesizeModel,
    .sampleRate = modelSampleRate,
    .voiceNames = modelVoiceNames,
    .resolveVoice = modelResolveVoice,
    .modelId = modelId,
    .modelName = modelName,
    .language = modelLanguage,
};

fn deinitModel(ctx: *anyopaque) void {
    const model: *loader.Model = @ptrCast(@alignCast(ctx));
    model.deinit();
}

fn synthesizeModel(
    ctx: *anyopaque,
    gpa: std.mem.Allocator,
    request: backend.Request,
) anyerror!backend.Result {
    const model: *loader.Model = @ptrCast(@alignCast(ctx));
    return synthesize(model, gpa, request);
}

fn modelSampleRate(ctx: *const anyopaque) u32 {
    const model: *const loader.Model = @ptrCast(@alignCast(ctx));
    return model.sample_rate;
}

fn modelVoiceNames(ctx: *const anyopaque, gpa: std.mem.Allocator) anyerror![][]const u8 {
    const model: *const loader.Model = @ptrCast(@alignCast(ctx));
    return model.table.names(gpa);
}

fn modelResolveVoice(ctx: *const anyopaque, gpa: std.mem.Allocator, requested: []const u8) anyerror!?[]const u8 {
    const model: *const loader.Model = @ptrCast(@alignCast(ctx));
    const voice = backend.resolveVoice(model.desc, &model.table, requested) catch return null;
    return try gpa.dupe(u8, voice.name);
}

fn modelId(ctx: *const anyopaque) []const u8 {
    const model: *const loader.Model = @ptrCast(@alignCast(ctx));
    return model.desc.model;
}

fn modelName(ctx: *const anyopaque) []const u8 {
    const model: *const loader.Model = @ptrCast(@alignCast(ctx));
    return model.desc.name;
}

fn modelLanguage(ctx: *const anyopaque) []const u8 {
    const model: *const loader.Model = @ptrCast(@alignCast(ctx));
    return model.desc.text.language;
}

/// Synthetisiert Text zu Samples.
///
/// Der Ablauf entspricht der Referenz der Kitten-Modelle: Der Text wird
/// vorbereitet, in Abschnitte geteilt und jeder Abschnitt einzeln gerechnet.
/// Die Abschnitte werden hintereinander gelegt.
fn synthesize(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    request: backend.Request,
) !backend.Result {
    const desc = model.desc;

    // Die Sprache muss zum Modell passen. Ohne Angabe gilt die Sprache des
    // Deskriptors.
    if (request.language) |language| {
        if (language.len > 0 and !backend.languageMatches(desc.text.language, language)) {
            return error.LanguageMismatch;
        }
    }

    const voice = try backend.resolveVoice(desc, &model.table, request.voice);

    // Der Tempoprior gehoert zum internen Namen der Stimme.
    var speed = request.speed;
    if (desc.speedPrior(voice.name)) |prior| speed *= prior;

    const source = try phonemes.preprocessText(gpa, desc.text.preprocess, request.text);
    defer gpa.free(source);

    const chunks = try chunk.chunkText(gpa, source, .{
        .max_len = desc.text.chunk_chars,
        .split_chars = desc.text.chunk_split,
        .append_punctuation = desc.text.chunk_punctuation,
    });
    defer chunks.deinit();

    if (chunks.items.len == 0) return error.EmptyText;

    var audio: std.ArrayList(f32) = .empty;
    defer audio.deinit(gpa);

    for (chunks.items) |text| {
        const part = try synthesizeChunk(model, gpa, text, voice, speed);
        defer gpa.free(part);
        try audio.appendSlice(gpa, part);
    }

    return .{
        .pcm = try audio.toOwnedSlice(gpa),
        .sample_rate = model.sample_rate,
    };
}

/// Synthetisiert einen Abschnitt.
///
/// Ein Abschnitt kann mehrere Saetze enthalten. Je nach Textart entsteht
/// daraus ein Text oder je Satz ein Text. Jeder Text wird einzeln gerechnet.
fn synthesizeChunk(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    text: []const u8,
    voice: backend.VoiceRef,
    speed: f32,
) ![]f32 {
    const desc = model.desc;

    var prepared = try phonemes.preparePhonemes(gpa, &model.espeak, &desc.text, text);
    defer prepared.deinit();

    var audio: std.ArrayList(f32) = .empty;
    defer audio.deinit(gpa);

    for (prepared.pieces) |piece| {
        const part = try runPiece(model, gpa, piece.text, voice, speed);
        defer gpa.free(part);
        try audio.appendSlice(gpa, part);
    }

    return audio.toOwnedSlice(gpa);
}

/// Baut die Tokenfolge, waehlt die Stimmzeile und laesst den Graphen laufen.
fn runPiece(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    phoneme_text: []const u8,
    voice: backend.VoiceRef,
    speed: f32,
) ![]f32 {
    const desc = model.desc;

    const sequence = try buildTokens(model, gpa, phoneme_text);
    defer sequence.deinit(gpa);

    if (sequence.ids.len == 0) return error.EmptyText;

    // Die Stimmzeile richtet sich nach der Laenge des Textes. Die Grundlage
    // steht im Deskriptor: "tokens" zaehlt die vollstaendige Folge mit Rahmen,
    // "symbols" nur die Symbole ohne Rahmen.
    const length = switch (desc.style.index.basis) {
        .tokens => sequence.ids.len,
        .symbols => sequence.body_length,
    };
    const row_index = backend.styleIndex(desc.style.index, length, voice.rows);
    const row = model.table.entries[voice.index].row(row_index);

    var failure: ort.Failure = .{};
    var inputs: std.ArrayList(ort.RunInput) = .empty;
    defer {
        for (inputs.items) |input| ort.releaseValue(&model.session, input.value);
        inputs.deinit(gpa);
    }

    // Die ONNX-Runtime uebernimmt die Zeiger auf die Daten. Alle Puffer, die
    // ein Tensor belegt, stehen deshalb in diesem Arena und bleiben bis zum
    // Ende des Laufs stehen.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const scratch_gpa = scratch.allocator();

    try appendTokenInput(model, gpa, scratch_gpa, &inputs, &failure, sequence.ids);

    if (model.indices.style) |index| {
        const shape = [_]i64{ 1, @intCast(row.len) };
        const value = try model.session.createFloatTensor(row, &shape, &failure);
        try inputs.append(gpa, .{ .name = inputName(model, index), .value = value });
    }

    // Die ONNX-Runtime uebernimmt den Zeiger auf die Daten. Die Puffer
    // muessen deshalb bis zum Ende des Laufs stehen bleiben.
    var speed_value = [_]f32{speed};
    if (model.indices.speed) |index| {
        const shape = [_]i64{1};
        const value = try model.session.createFloatTensor(&speed_value, &shape, &failure);
        try inputs.append(gpa, .{ .name = inputName(model, index), .value = value });
    }

    if (model.indices.lengths != null) {
        try appendLengthsInput(model, gpa, scratch_gpa, &inputs, &failure, sequence.ids.len);
    }

    if (model.indices.scales) |index| {
        const scale_values = [_]f32{
            desc.inference.noise_scale,
            desc.inference.length_scale,
            desc.inference.noise_w,
        };
        const shape = [_]i64{scale_values.len};
        const value = try model.session.createFloatTensor(&scale_values, &shape, &failure);
        try inputs.append(gpa, .{ .name = inputName(model, index), .value = value });
    }

    var output = try ort.run(&model.session, gpa, inputs.items, model.indices.output, &failure);
    defer output.deinit();

    const samples = try output.asFloats();

    // Die Ausgabe schneiden und gegebenenfalls normalisieren.
    const trim = @min(desc.output.trim_tail_samples, samples.len);
    const kept = samples[0 .. samples.len - trim];

    const result = try gpa.alloc(f32, kept.len);
    errdefer gpa.free(result);
    @memcpy(result, kept);

    switch (desc.output.normalize) {
        .none => {},
        .peak => normalizePeak(result),
    }

    return result;
}

/// Erzeugt den Tensor der Tokenfolge.
///
/// Der Graph entscheidet, ob er 32- oder 64-Bit-Ganzzahlen erwartet.
fn appendTokenInput(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    inputs: *std.ArrayList(ort.RunInput),
    failure: *ort.Failure,
    ids: []const i64,
) !void {
    const shape = [_]i64{ 1, @intCast(ids.len) };
    const name = inputName(model, model.indices.tokens);

    switch (model.types.tokens) {
        .int64 => {
            const value = try model.session.createInt64Tensor(ids, &shape, failure);
            try inputs.append(gpa, .{ .name = name, .value = value });
        },
        .int32 => {
            // Die verkuerzte Folge liegt im Arena, weil der Tensor auf sie
            // zeigt, bis der Lauf zu Ende ist.
            const narrow = try scratch.alloc(i32, ids.len);
            for (ids, 0..) |id, index| narrow[index] = @intCast(id);
            const value = try model.session.createInt32Tensor(narrow, &shape, failure);
            try inputs.append(gpa, .{ .name = name, .value = value });
        },
        else => return error.UnsupportedInput,
    }
}

/// Erzeugt den Tensor der Laengenangabe.
///
/// Der Wert ist die Zahl der Tokens. Der Graph entscheidet ueber den Typ.
fn appendLengthsInput(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    inputs: *std.ArrayList(ort.RunInput),
    failure: *ort.Failure,
    count: usize,
) !void {
    const index = model.indices.lengths.?;
    const name = inputName(model, index);
    const shape = [_]i64{1};

    switch (model.types.lengths orelse .undefined_) {
        .int64 => {
            const values = try scratch.alloc(i64, 1);
            values[0] = @intCast(count);
            const value = try model.session.createInt64Tensor(values, &shape, failure);
            try inputs.append(gpa, .{ .name = name, .value = value });
        },
        .int32 => {
            const values = try scratch.alloc(i32, 1);
            values[0] = @intCast(count);
            const value = try model.session.createInt32Tensor(values, &shape, failure);
            try inputs.append(gpa, .{ .name = name, .value = value });
        },
        else => return error.UnsupportedInput,
    }
}

/// Baut die Tokenfolge eines Phonemtextes.
///
/// Der Rahmen der Folge besteht aus Start-, End- und Fuellzeichen. Die
/// Zeichen stehen im Deskriptor.
fn buildTokens(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    text: []const u8,
) !tokens.TokenSequence {
    const desc = model.desc;
    const spec = &desc.tokenizer;

    var prefix_storage: [1]i64 = undefined;
    var suffix_storage: [2]i64 = undefined;
    var prefix_len: usize = 0;
    var suffix_len: usize = 0;

    if (spec.start_id) |id| {
        prefix_storage[prefix_len] = id;
        prefix_len += 1;
    }
    if (spec.end_id) |id| {
        suffix_storage[suffix_len] = id;
        suffix_len += 1;
    }
    if (spec.pad_id) |id| {
        suffix_storage[suffix_len] = id;
        suffix_len += 1;
    }

    const options: tokens.TokenOptions = .{
        .word_split = spec.word_split,
        .prefix = prefix_storage[0..prefix_len],
        .suffix = suffix_storage[0..suffix_len],
        .unknown = .drop,
        .normalize_nfd = desc.text.normalize_nfd,
        .max_body = desc.text.max_tokens,
    };

    switch (model.tokenizer) {
        .builtin => |table| return tokens.buildSymbolSequence(gpa, table, text, options),
        .vocab => |*vocab| return tokens.buildVocabSequence(gpa, vocab, text, options),
        .phoneme_ids => |*map| {
            const frame = try tokens.phonemeFrame(
                map,
                spec.start_key orelse return error.MissingFramePhoneme,
                spec.pad_key orelse return error.MissingFramePhoneme,
                spec.end_key orelse return error.MissingFramePhoneme,
            );
            return tokens.buildPhonemeIdSequence(gpa, map, text, frame, options);
        },
    }
}

/// Der Name eines Eingangs, wie ihn der Graph kennt.
fn inputName(model: *loader.Model, index: usize) [:0]const u8 {
    return model.session.input_names[index];
}

/// Bringt die Samples auf den groesten Wert 1.0.
fn normalizePeak(samples: []f32) void {
    var peak: f32 = 0;
    for (samples) |sample| peak = @max(peak, @abs(sample));
    if (peak == 0) return;

    const factor = 1.0 / peak;
    for (samples) |*sample| sample.* *= factor;
}
