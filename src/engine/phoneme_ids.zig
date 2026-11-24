//! ONNX-Backend fuer Modelle mit Phonem-IDs je Satz.
//!
//! Der Weg entspricht dem Piper-Vertrag, der in
//! `docs/PIPER-PHONEMIZATION.md` festgehalten ist:
//!
//! 1. espeak-ng uebersetzt den Text in Phoneme. Die Clauses werden zu
//!    Saetzen gruppiert, das Satzzeichen des Terminators wird angehaengt.
//! 2. Je Satz entsteht die Folge aus Start-, Fuell- und Endkennung. Nach
//!    jedem Phonem steht die Fuellkennung.
//! 3. Je Satz laeuft der Graph genau einmal. Die Eingaben heissen
//!    `input`, `input_lengths` und `scales`. Ihre Namen stehen im
//!    Deskriptor.
//!
//! Das Backend kennt keine Modellfamilie. Der Weg wird gewaehlt, weil der
//! Deskriptor es verlangt.
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
    if (desc.backend != .phoneme_ids) return error.UnsupportedBackend;

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
/// Der Text wird vorbereitet und in Abschnitte geteilt. Jeder Abschnitt wird
/// phonemisiert, und je Satz laeuft der Graph einmal. Die Ausgaben der
/// Saetze werden hintereinander gelegt.
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

    // Modelle dieses Wegs haben eine einzige Stimme. Die Aufloesung prueft
    // trotzdem, ob die Anfrage zur Stimme passt.
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
        const part = try synthesizeChunk(model, gpa, text, speed);
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
/// Der Abschnitt wird in Saetze zerlegt. Jeder Satz laeuft einzeln durch den
/// Graphen.
fn synthesizeChunk(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    text: []const u8,
    speed: f32,
) ![]f32 {
    const desc = model.desc;

    var prepared = try phonemes.preparePhonemes(gpa, &model.espeak, &desc.text, text);
    defer prepared.deinit();

    var audio: std.ArrayList(f32) = .empty;
    defer audio.deinit(gpa);

    for (prepared.pieces) |piece| {
        const part = try runSentence(model, gpa, piece.text, speed);
        defer gpa.free(part);
        try audio.appendSlice(gpa, part);
    }

    return audio.toOwnedSlice(gpa);
}

/// Baut die Phonem-IDs eines Satzes und laesst den Graphen laufen.
fn runSentence(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    phoneme_text: []const u8,
    speed: f32,
) ![]f32 {
    const desc = model.desc;

    const sequence = try buildIds(model, gpa, phoneme_text);
    defer sequence.deinit(gpa);

    if (sequence.ids.len == 0) return error.EmptyText;

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

    if (model.indices.lengths) |index| {
        const name = inputName(model, index);
        const shape = [_]i64{1};
        switch (model.types.lengths orelse .undefined_) {
            .int64 => {
                const values = try scratch_gpa.alloc(i64, 1);
                values[0] = @intCast(sequence.ids.len);
                const value = try model.session.createInt64Tensor(values, &shape, &failure);
                try inputs.append(gpa, .{ .name = name, .value = value });
            },
            .int32 => {
                const values = try scratch_gpa.alloc(i32, 1);
                values[0] = @intCast(sequence.ids.len);
                const value = try model.session.createInt32Tensor(values, &shape, &failure);
                try inputs.append(gpa, .{ .name = name, .value = value });
            },
            else => return error.UnsupportedInput,
        }
    }

    if (model.indices.scales) |index| {
        const scale_values = [_]f32{
            desc.inference.noise_scale,
            effectiveLengthScale(desc.inference.length_scale, speed),
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

/// Rechnet das Sprechtempo in die Dehnung des Textes um.
///
/// Modelle dieses Wegs kennen keinen eigenen Eingang fuer das Tempo. Die
/// Dehnung ist sein Gegenstueck: ein Wert ueber 1 spricht langsamer. Das
/// Tempo teilt deshalb die Dehnung. Die Dehnung wird nicht invertiert, das
/// entspricht der Referenz.
fn effectiveLengthScale(base: f32, speed: f32) f32 {
    if (!(speed > 0)) return base;
    return base / speed;
}

/// Erzeugt den Tensor der Phonem-IDs.
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

/// Baut die Phonem-ID-Folge eines Satzes.
///
/// Der Rahmen besteht aus Start-, Fuell- und Endkennung. Die Schluessel
/// dieser Kennungen stehen im Deskriptor.
fn buildIds(
    model: *loader.Model,
    gpa: std.mem.Allocator,
    text: []const u8,
) !tokens.TokenSequence {
    const spec = &model.desc.tokenizer;

    const map = switch (model.tokenizer) {
        .phoneme_ids => |*value| value,
        else => return error.MissingTokenizerFile,
    };

    const frame = try tokens.phonemeFrame(
        map,
        spec.start_key orelse return error.MissingFramePhoneme,
        spec.pad_key orelse return error.MissingFramePhoneme,
        spec.end_key orelse return error.MissingFramePhoneme,
    );

    const options: tokens.TokenOptions = .{
        .normalize_nfd = model.desc.text.normalize_nfd,
        .max_body = model.desc.text.max_tokens,
        .unknown = .drop,
        .report_missing = true,
    };

    return tokens.buildPhonemeIdSequence(gpa, map, text, frame, options);
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

test "Das Tempo teilt die Dehnung des Textes" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), effectiveLengthScale(1.0, 1.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), effectiveLengthScale(1.0, 2.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), effectiveLengthScale(2.0, 1.0), 1e-6);
}

test "Ein Tempo von null aendert die Dehnung nicht" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), effectiveLengthScale(1.0, 0.0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), effectiveLengthScale(1.0, -1.0), 1e-6);
}
