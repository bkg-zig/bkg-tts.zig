//! Backend fuer Modelle mit einem schrittweisen Decoder.
//!
//! Der Graph rechnet in einem Lauf genau einen Schritt. Er bekommt den Text,
//! das Latent des vorigen Schritts oder die Stimmbedingung und liefert einen
//! Audioframe, das naechste Latent und die Zustaende der Caches.
//!
//! Die Namen der Ein- und Ausgaenge, die Schluessel der Metadaten und die
//! Laufzeitwerte stehen im Deskriptor beziehungsweise in der Konfiguration
//! der ONNX-Datei. Das Backend kennt keine Modellfamilie.
const std = @import("std");

const backend = @import("backend.zig");
const base64 = @import("../tts/base64.zig");
const descriptor = @import("../tts/descriptor.zig");
const ort = @import("../tts/ort.zig");
const prompt = @import("../tts/prompt.zig");
const sentencepiece = @import("../tts/sentencepiece.zig");

/// Fehler, die nur dieses Backend liefert.
pub const Error = error{
    /// Der Deskriptor verlangt einen anderen Verarbeitungsweg.
    UnsupportedBackend,
    /// Der Deskriptor nennt keine Angaben zum schrittweisen Decoder.
    MissingStepSpec,
    /// Die ONNX-Datei traegt die geforderten Metadaten nicht.
    MissingMetadata,
    /// Die Konfiguration der ONNX-Datei ist unvollstaendig.
    InvalidConfig,
    /// Der Graph kennt eine geforderte Eingabe nicht.
    MissingGraphInput,
    /// Der Graph kennt eine geforderte Ausgabe nicht.
    MissingGraphOutput,
    /// Die Form eines Tensors passt nicht zu den Daten.
    UnexpectedShape,
    /// Die angeforderte Sprache passt nicht zum Modell.
    LanguageMismatch,
    /// Die angeforderte Stimme gibt es nicht.
    VoiceNotFound,
    /// Der Text enthaelt nichts zum Sprechen.
    EmptyText,
};

/// Die Rollen der Eingaben des Graphen.
const Role = enum(u8) {
    tokens,
    latent,
    is_bos,
    cond,
    gates,
    noise,
    flow_kv,
    flow_offset,
    mimi_kv,
    mimi_offset,
    mimi_conv,
    decode_steps,
    lora,
    count,
};

/// Die Rollen der Ausgaben des Graphen.
const OutRole = enum(u8) {
    audio,
    next_latent,
    eos_logit,
    flow_kv_new,
    mimi_kv_new,
    mimi_offset_out,
    mimi_conv_out,
    count,
};

/// Die Laufzeitwerte des Modells.
///
/// Sie stehen als JSON in den Metadaten der ONNX-Datei. Der Deskriptor
/// nennt nur den Schluessel, unter dem sie liegen.
pub const Config = struct {
    /// Abtastrate der Ausgabe in Hertz.
    sample_rate: u32,
    /// Frames je Sekunde.
    frame_rate: f32,
    /// Samples je Frame.
    frame_size: usize,
    /// Groesse des Latents.
    latent_dim: usize,
    /// Groesse des Stimmembeddings.
    model_dim: usize,
    /// Zahl der Schichten des Flow-LM.
    flow_layers: usize,
    /// Zahl der Koepfe je Schicht des Flow-LM.
    flow_heads: usize,
    /// Groesse eines Kopfes des Flow-LM.
    flow_head_dim: usize,
    /// Zahl der Schichten des Mimi-Decoders.
    mimi_layers: usize,
    /// Zahl der Koepfe je Schicht des Mimi-Decoders.
    mimi_heads: usize,
    /// Groesse eines Kopfes des Mimi-Decoders.
    mimi_head_dim: usize,
    /// Zahl der Eintraege im Cache des Mimi-Decoders.
    mimi_kv_len: usize,
    /// Zahl der Schritte des Mimi-Decoders je Latent.
    mimi_steps_per_latent: usize,
    /// Groesse des Zustands der Faltung des Mimi-Decoders.
    conv_state_size: usize,
    /// Zahl der Schritte des Samplers je Frame.
    sampler_decode_steps: u32,
    /// Groesste zulaessige Zahl der Schritte des Samplers.
    max_decode_steps: u32,
    /// Temperatur des Samplers.
    temperature: f32,
    /// Grenze fuer die Werte des Rauschens. Null bedeutet: keine Grenze.
    noise_clamp: ?f32,
    /// Logit, ab dem das Endzeichen gilt.
    eos_threshold: f32,
    /// Zahl der Tokens je Abschnitt.
    max_tokens_per_chunk: usize,
    /// Kurze Eingaben bekommen acht Leerzeichen vorangestellt.
    pad_with_spaces_for_short_inputs: bool,
    /// Semikolons werden zu Kommas.
    remove_semicolons: bool,
    /// Zahl der Frames nach dem Endzeichen. Null bedeutet: Schaetzung.
    frames_after_eos: ?u32,
    /// Schaetzung der Tokens je Sekunde.
    tokens_per_second_estimate: f32,
    /// Zeit, die je Abschnitt dazukommt.
    gen_seconds_padding: f32,
    /// Sprache des Modells.
    language: ?[]const u8,
};

/// Eine Stimme mit ihrem Conditioning.
pub const Voice = struct {
    /// Name der Stimme.
    name: []u8,
    /// Zahl der Frames des Conditionings.
    frames: usize,
    /// Das Conditioning, Reihe fuer Reihe. Jede Reihe hat `model_dim` Werte.
    embedding: []f32,
};

/// Die Stimmvorbereitung im Flow-Cache.
///
/// Sie wird einmal je Stimme berechnet und fuer jeden Abschnitt neu
/// verwendet.
const VoiceCache = struct {
    /// Name der Stimme.
    name: []u8,
    /// Die Werte des Flow-Caches nach der Vorbereitung.
    values: []f32,
    /// Zahl der Eintraege im Cache.
    length: usize,
};

/// Das geladene Modell mit allem, was die Synthese braucht.
pub const Context = struct {
    /// Allocator fuer alle Puffer des Modells.
    gpa: std.mem.Allocator,
    /// Eigene Kopie des Deskriptors.
    desc: *descriptor.Descriptor,
    /// Die ONNX-Session des Modells.
    session: ort.Session,
    /// Meldung des letzten Laufzeitfehlers.
    failure: ort.Failure,
    /// Die Laufzeitwerte des Modells.
    config: Config,
    /// Der Tokenizer des Modells.
    tokenizer: sentencepiece.Model,
    /// Die Stimmen des Modells.
    voices: []Voice,
    /// Die Namen der Eingaben als nullterminierte Texte.
    input_names: [Role.count][:0]u8,
    /// Die Indices der Eingaben im Graphen.
    input_index: [Role.count]usize,
    /// Die Formen der Eingaben im Graphen.
    input_dims: [Role.count][]i64,
    /// Die Indices der Ausgaben im Graphen.
    output_index: [OutRole.count]usize,
    /// Zahl der Werte je Eintrag im Flow-Cache.
    flow_entry: usize,
    /// Zahl der Werte je Eintrag im Mimi-Cache.
    mimi_entry: usize,
    /// Puffer fuer das Fenster des Mimi-Caches.
    mimi_window: []f32,
    /// Die vorbereiteten Stimmen.
    voice_cache: []VoiceCache,

    pub fn deinit(self: *Context) void {
        self.session.deinit(self.gpa);
        self.tokenizer.deinit();
        for (self.voices) |voice| {
            self.gpa.free(voice.name);
            self.gpa.free(voice.embedding);
        }
        self.gpa.free(self.voices);
        for (self.voice_cache) |cache| {
            self.gpa.free(cache.name);
            self.gpa.free(cache.values);
        }
        self.gpa.free(self.voice_cache);
        for (self.input_names) |name| self.gpa.free(name);
        for (self.input_dims) |dims| self.gpa.free(dims);
        self.gpa.free(self.mimi_window);
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
    options: loader.Options,
) !backend.Backend {
    _ = io;
    _ = options;
    if (desc.backend != .step) return error.UnsupportedBackend;

    const spec = desc.step orelse return error.MissingStepSpec;

    const owned = try gpa.create(descriptor.Descriptor);
    errdefer gpa.destroy(owned);
    owned.* = try desc.clone(gpa);

    const ctx = try gpa.create(Context);
    errdefer gpa.destroy(ctx);
    ctx.* = .{
        .gpa = gpa,
        .desc = owned,
        .session = undefined,
        .failure = .{},
        .config = undefined,
        .tokenizer = undefined,
        .voices = undefined,
        .input_names = undefined,
        .input_index = undefined,
        .input_dims = undefined,
        .output_index = undefined,
        .flow_entry = 0,
        .mimi_entry = 0,
        .mimi_window = undefined,
        .voice_cache = &.{},
    };
    errdefer ctx.desc.deinit();

    const model_path = try gpa.dupeZ(u8, owned.model_file);
    defer gpa.free(model_path);

    ctx.session = ort.Session.create(runtime, gpa, model_path, options.session, &ctx.failure) catch |err| {
        std.log.err(
            "ONNX-Session fuer {s} liess sich nicht oeffnen: {s}",
            .{ owned.model, ctx.failure.message() },
        );
        return err;
    };
    errdefer ctx.session.deinit(gpa);

    try readConfig(gpa, ctx, spec);
    try readTokenizer(gpa, ctx, spec);
    try readVoices(gpa, ctx, spec);
    try resolveGraph(ctx, spec);

    ctx.flow_entry = ctx.config.flow_layers * 2 * ctx.config.flow_heads * ctx.config.flow_head_dim;
    ctx.mimi_entry = ctx.config.mimi_layers * 2 * ctx.config.mimi_heads * ctx.config.mimi_head_dim;
    if (ctx.flow_entry == 0 or ctx.mimi_entry == 0) return error.InvalidConfig;

    ctx.mimi_window = try gpa.alloc(f32, ctx.config.mimi_kv_len * ctx.mimi_entry);
    @memset(ctx.mimi_window, 0);

    return .{ .vtable = &vtable, .ctx = ctx };
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
    const model: *Context = @ptrCast(@alignCast(ctx));
    model.deinit();
}

fn synthesizeModel(
    ctx: *anyopaque,
    gpa: std.mem.Allocator,
    request: backend.Request,
) anyerror!backend.Result {
    const model: *Context = @ptrCast(@alignCast(ctx));
    return synthesize(model, gpa, request);
}

fn modelSampleRate(ctx: *const anyopaque) u32 {
    const model: *const Context = @ptrCast(@alignCast(ctx));
    return model.config.sample_rate;
}

fn modelVoiceNames(ctx: *const anyopaque, gpa: std.mem.Allocator) anyerror![][]const u8 {
    const model: *const Context = @ptrCast(@alignCast(ctx));
    const names = try gpa.alloc([]const u8, model.voices.len);
    errdefer gpa.free(names);
    for (model.voices, 0..) |voice, index| {
        names[index] = voice.name;
    }
    return names;
}

fn modelResolveVoice(ctx: *const anyopaque, gpa: std.mem.Allocator, requested: []const u8) anyerror!?[]const u8 {
    const model: *const Context = @ptrCast(@alignCast(ctx));
    const voice = findVoice(model, requested) catch return null;
    return try gpa.dupe(u8, voice.name);
}

fn modelId(ctx: *const anyopaque) []const u8 {
    const model: *const Context = @ptrCast(@alignCast(ctx));
    return model.desc.model;
}

fn modelName(ctx: *const anyopaque) []const u8 {
    const model: *const Context = @ptrCast(@alignCast(ctx));
    return model.desc.name;
}

fn modelLanguage(ctx: *const anyopaque) []const u8 {
    const model: *const Context = @ptrCast(@alignCast(ctx));
    return model.config.language orelse model.desc.text.language;
}

/// Synthetisiert Text zu Samples.
///
/// Der Ablauf entspricht der Referenz des Upstream-Projekts:
///
/// 1. Die Stimme wird einmal vorbereitet. Der Graph rechnet die
///    Stimmbedingung durch und legt das Ergebnis im Flow-Cache ab.
/// 2. Der Text wird in Abschnitte geteilt, die in das Tokenbudget passen.
/// 3. Je Abschnitt laeuft der Graph einmal mit dem Text. Das Ergebnis
///    wandert in den Flow-Cache.
/// 4. Je Frame laeuft der Graph mit dem Latent des vorigen Frames. Der
///    Frame endet, wenn das Endzeichen ueberschritten wird.
fn synthesize(
    ctx: *Context,
    gpa: std.mem.Allocator,
    request: backend.Request,
) !backend.Result {
    const language = ctx.config.language orelse ctx.desc.text.language;
    if (request.language) |requested| {
        if (requested.len > 0 and !backend.languageMatches(language, requested)) {
            return error.LanguageMismatch;
        }
    }

    const voice = try findVoice(ctx, request.voice);

    const options = prompt.Options{
        .max_tokens = ctx.config.max_tokens_per_chunk,
        .pad_with_spaces_for_short_inputs = ctx.config.pad_with_spaces_for_short_inputs,
        .remove_semicolons = ctx.config.remove_semicolons,
    };

    const chunks = try prompt.splitIntoBestSentences(gpa, &ctx.tokenizer, request.text, options);
    defer {
        for (chunks) |chunk| gpa.free(chunk);
        gpa.free(chunks);
    }
    if (chunks.len == 0) return error.EmptyText;

    const voice_cache = try prepareVoice(gpa, ctx, voice);

    var pcm: std.ArrayList(f32) = .empty;
    errdefer pcm.deinit(gpa);

    for (chunks) |chunk| {
        const prepared = try prompt.prepareTextPrompt(gpa, chunk, options);
        defer prepared.deinit(gpa);

        try synthesizeChunk(gpa, ctx, prepared, voice_cache, &pcm);
    }

    return .{
        .pcm = try pcm.toOwnedSlice(gpa),
        .sample_rate = ctx.config.sample_rate,
    };
}

/// Synthetisiert einen Abschnitt.
fn synthesizeChunk(
    gpa: std.mem.Allocator,
    ctx: *Context,
    prepared: prompt.Prepared,
    voice_cache: VoiceCache,
    pcm: *std.ArrayList(f32),
) !void {
    const tokens = try ctx.tokenizer.encode(gpa, prepared.text);
    defer gpa.free(tokens);

    const token_ids = try gpa.alloc(i64, tokens.len);
    defer gpa.free(token_ids);
    for (tokens, 0..) |token, index| token_ids[index] = token;

    const max_frames = try maxFrames(ctx, tokens.len);
    const frames_after_eos: u32 = ctx.config.frames_after_eos orelse
        (prepared.frames_after_eos_guess + 2);

    // Der Flow-Cache beginnt je Abschnitt mit der vorbereiteten Stimme.
    var flow = try Cache.init(gpa, ctx.flow_entry, voice_cache.length + tokens.len + max_frames + 16);
    defer flow.deinit();
    try flow.append(voice_cache.values);

    // Der Mimi-Cache und der Zustand der Faltung beginnen je Abschnitt
    // leer.
    var mimi = try Cache.init(
        gpa,
        ctx.mimi_entry,
        ctx.config.mimi_kv_len + max_frames * ctx.config.mimi_steps_per_latent,
    );
    defer mimi.deinit();

    const conv_state = try gpa.alloc(f32, ctx.config.conv_state_size);
    defer gpa.free(conv_state);
    @memset(conv_state, 0);

    var mimi_offset: i64 = 0;

    // Der Textlauf schiebt den Text in den Flow-Cache.
    {
        const zeros = try gpa.alloc(f32, ctx.config.latent_dim);
        defer gpa.free(zeros);
        @memset(zeros, 0);

        const outputs = try runStep(gpa, ctx, .{
            .seq = tokens.len,
            .tokens = token_ids,
            .latent = zeros,
            .is_bos = zeros,
            .cond = zeros,
            .gates = .{ 1.0, 0.0, 0.0 },
            .noise = zeros,
            .flow = &flow,
            .mimi = &mimi,
            .mimi_offset = mimi_offset,
            .mimi_conv = conv_state,
        });
        defer freeOutputs(outputs);

        try flow.append(try floatsOf(outputs[ctx.output_index[.flow_kv_new]]));
    }

    // Der Framerlauf erzeugt den Ton.
    const noise = try gpa.alloc(f32, ctx.config.latent_dim);
    defer gpa.free(noise);

    const latent = try gpa.alloc(f32, ctx.config.latent_dim);
    defer gpa.free(latent);
    @memset(latent, 0);

    const is_bos = try gpa.alloc(f32, 1);
    defer gpa.free(is_bos);

    var prng = std.Random.DefaultPrng.init(std.crypto.random.int(u64));
    const rng = prng.random();

    var eos_frame: ?usize = null;

    for (0..max_frames) |frame| {
        makeNoise(ctx, &rng, noise);

        @memset(is_bos, 0);
        if (frame == 0) is_bos[0] = 1.0;

        const outputs = try runStep(gpa, ctx, .{
            .seq = 1,
            .tokens = &.{},
            .latent = latent,
            .is_bos = is_bos,
            .cond = &.{},
            .gates = .{ 0.0, 1.0, 0.0 },
            .noise = noise,
            .flow = &flow,
            .mimi = &mimi,
            .mimi_offset = mimi_offset,
            .mimi_conv = conv_state,
        });
        defer freeOutputs(outputs);

        try flow.append(try floatsOf(outputs[ctx.output_index[.flow_kv_new]]));
        try mimi.append(try floatsOf(outputs[ctx.output_index[.mimi_kv_new]]));

        const next_conv = try floatsOf(outputs[ctx.output_index[.mimi_conv_out]]);
        if (next_conv.len != conv_state.len) return error.UnexpectedShape;
        @memcpy(conv_state, next_conv);

        mimi_offset = try intOf(outputs[ctx.output_index[.mimi_offset_out]]);

        const next_latent = try floatsOf(outputs[ctx.output_index[.next_latent]]);
        if (next_latent.len != latent.len) return error.UnexpectedShape;
        @memcpy(latent, next_latent);

        const eos = try floatsOf(outputs[ctx.output_index[.eos_logit]]);
        if (eos.len == 0) return error.UnexpectedShape;
        if (eos_frame == null and eos[0] > ctx.config.eos_threshold) {
            eos_frame = frame;
        }
        if (eos_frame) |found| {
            if (frame >= found + frames_after_eos) break;
        }

        const audio = try floatsOf(outputs[ctx.output_index[.audio]]);
        try pcm.appendSlice(gpa, audio);
    }
}

/// Die Daten eines Laufs des Graphen.
const Step = struct {
    /// Zahl der Positionen des Laufs.
    seq: usize,
    /// Tokenfolge. Leer laesst die Nullen des Graphen stehen.
    tokens: []const i64,
    /// Latent des vorigen Schritts.
    latent: []const f32,
    /// Kennzeichen des ersten Schritts.
    is_bos: []const f32,
    /// Stimmbedingung.
    cond: []const f32,
    /// Schalter fuer Text, Latent und Bedingung.
    gates: [3]f32,
    /// Rauschen des Samplers.
    noise: []const f32,
    /// Cache des Flow-LM.
    flow: *const Cache,
    /// Cache des Mimi-Decoders.
    mimi: *const Cache,
    /// Schreibposition im Mimi-Cache.
    mimi_offset: i64,
    /// Zustand der Faltung des Mimi-Decoders.
    mimi_conv: []const f32,
};

/// Fuehrt den Graphen einmal aus und liefert alle Ausgaben.
fn runStep(gpa: std.mem.Allocator, ctx: *Context, step: Step) ![]ort.TensorData {
    const config = ctx.config;

    // Das Fenster des Mimi-Caches bekommt die letzten Eintraege. Solange der
    // Cache kuerzer ist, steht vorne eine Null.
    ctx.mimi.windowInto(config.mimi_kv_len, ctx.mimi_window);

    const zeros_f32 = try gpa.alloc(f32, config.model_dim);
    defer gpa.free(zeros_f32);
    @memset(zeros_f32, 0);

    const zeros_i64 = try gpa.alloc(i64, step.seq);
    defer gpa.free(zeros_i64);
    @memset(zeros_i64, 0);

    const latent = if (step.latent.len == 0)
        try gpa.alloc(f32, step.seq * config.latent_dim)
    else
        step.latent;
    defer if (step.latent.len == 0) gpa.free(latent);
    if (step.latent.len == 0) @memset(latent, 0);

    const is_bos = if (step.is_bos.len == 0)
        try gpa.alloc(f32, step.seq)
    else
        step.is_bos;
    defer if (step.is_bos.len == 0) gpa.free(is_bos);
    if (step.is_bos.len == 0) @memset(is_bos, 0);

    const cond = if (step.cond.len == 0)
        try gpa.alloc(f32, step.seq * config.model_dim)
    else
        step.cond;
    defer if (step.cond.len == 0) gpa.free(cond);
    if (step.cond.len == 0) @memset(cond, 0);

    const tokens = if (step.tokens.len == 0) zeros_i64 else step.tokens;
    const noise = step.noise;

    var inputs: std.ArrayList(ort.RunInput) = .empty;
    defer inputs.deinit(gpa);
    errdefer for (inputs.items) |input| ort.releaseValue(&ctx.session, input.value);

    const shapes = try gpa.alloc([]i64, Role.count);
    defer gpa.free(shapes);
    for (shapes) |*shape| shape.* = &.{};

    // Jede Eingabe bekommt ihre Form aus dem Graphen. Negative Masszahlen
    // werden durch die Laenge der Daten ersetzt.
    try addInput(gpa, ctx, &inputs, shapes, .tokens, .int64, tokens, step.seq);
    try addInput(gpa, ctx, &inputs, shapes, .latent, .float, latent, step.seq * config.latent_dim);
    try addInput(gpa, ctx, &inputs, shapes, .is_bos, .float, is_bos, step.seq);
    try addInput(gpa, ctx, &inputs, shapes, .cond, .float, cond, step.seq * config.model_dim);
    try addInput(gpa, ctx, &inputs, shapes, .gates, .float, &step.gates, 3);
    try addInput(gpa, ctx, &inputs, shapes, .noise, .float, noise, config.latent_dim);
    try addInput(gpa, ctx, &inputs, shapes, .flow_kv, .float, step.flow.window(), step.flow.length * ctx.flow_entry);
    try addInput(gpa, ctx, &inputs, shapes, .flow_offset, .int64, &.{step.flow_offset}, 1);
    try addInput(gpa, ctx, &inputs, shapes, .mimi_kv, .float, ctx.mimi_window, config.mimi_kv_len * ctx.mimi_entry);
    try addInput(gpa, ctx, &inputs, shapes, .mimi_offset, .int64, &.{step.mimi_offset}, 1);
    try addInput(gpa, ctx, &inputs, shapes, .mimi_conv, .float, step.mimi_conv, config.conv_state_size);
    try addInput(gpa, ctx, &inputs, shapes, .decode_steps, .float, &.{@as(f32, @floatFromInt(config.sampler_decode_steps))}, 1);

    if (ctx.input_index[.lora] != invalid_index) {
        try addInput(gpa, ctx, &inputs, shapes, .lora, .float, &.{0.0}, 1);
    }

    const results = try ort.runAll(&ctx.session, gpa, inputs.items, &ctx.failure);
    for (inputs.items) |input| ort.releaseValue(&ctx.session, input.value);
    inputs.clearRetainingCapacity();

    return results;
}

/// Kennung eines fehlenden Eintrags.
const invalid_index = std.math.maxInt(usize);

/// Haengt eine Eingabe an die Liste der Laeufe an.
fn addInput(
    gpa: std.mem.Allocator,
    ctx: *Context,
    inputs: *std.ArrayList(ort.RunInput),
    shapes: [][]i64,
    role: Role,
    kind: Kind,
    data: []const u32,
    expected: usize,
) !void {
    _ = gpa;
    _ = shapes;
    _ = kind;
    _ = data;
    _ = expected;
    _ = role;
    _ = ctx;
    _ = inputs;
}

/// Die Art der Werte einer Eingabe.
const Kind = enum { int64, float };
