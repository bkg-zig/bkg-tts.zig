//! Backend fuer Modelle mit einem schrittweisen Decoder.
//!
//! Der Graph rechnet in einem Lauf genau einen Schritt. Er bekommt den Text,
//! das Latent des vorigen Schritts oder die Stimmbedingung und liefert ein
//! Audioframe, das naechste Latent und die Zustaende der Caches.
//!
//! Die Namen der Ein- und Ausgaenge, die Schluessel der Metadaten und die
//! Laufzeitwerte stehen im Deskriptor beziehungsweise in der Konfiguration
//! der ONNX-Datei. Das Backend kennt keine Modellfamilie.
const std = @import("std");

const backend = @import("backend.zig");
const base64 = @import("../tts/base64.zig");
const descriptor = @import("../tts/descriptor.zig");
const loader = @import("loader.zig");
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
};

const role_count = @typeInfo(Role).@"enum".fields.len;

/// Die Rollen der Ausgaben des Graphen.
const OutRole = enum(u8) {
    audio,
    next_latent,
    eos_logit,
    flow_kv_new,
    mimi_kv_new,
    mimi_offset_out,
    mimi_conv_out,
};

const output_role_count = @typeInfo(OutRole).@"enum".fields.len;

/// Form einer Stimme in der Konfiguration des Modells.
pub const VoiceShape = struct {
    /// Name der Stimme.
    name: []u8,
    /// Zahl der Frames des Conditionings.
    frames: usize,
    /// Groesse des Conditionings je Frame.
    model_dim: usize,
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
    sampler_decode_steps: usize,
    /// Groesste zulaessige Zahl der Schritte des Samplers.
    max_decode_steps: usize,
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
    language: ?[]u8,
    /// Formen der Stimmen.
    voices: []VoiceShape,

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        if (self.language) |language| gpa.free(language);
        for (self.voices) |voice| gpa.free(voice.name);
        gpa.free(self.voices);
        self.* = undefined;
    }
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
    name: []const u8,
    /// Die Werte des Flow-Caches nach der Vorbereitung.
    values: []f32,
    /// Zahl der Eintraege im Cache.
    length: usize,
};

/// Das geladene Modell mit allem, was die Synthese braucht.
pub const Context = struct {
    /// Allocator fuer alle Puffer des Modells.
    gpa: std.mem.Allocator,
    /// Io-Kontext fuer Entropie aus dem Laufzeitsystem.
    io: std.Io,
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
    input_names: [role_count][:0]const u8,
    /// Die Indices der Eingaben im Graphen.
    input_index: [role_count]usize,
    /// Die Formen der Eingaben im Graphen.
    input_dims: [role_count][]i64,
    /// Die Elementtypen der Eingaben im Graphen.
    input_types: [role_count]ort.ElementType,
    /// Die Indices der Ausgaben im Graphen.
    output_index: [output_role_count]usize,
    /// Zahl der Werte je Eintrag im Flow-Cache.
    flow_entry: usize,
    /// Zahl der Werte je Eintrag im Mimi-Cache.
    mimi_entry: usize,
    /// Puffer fuer das Fenster des Mimi-Caches.
    mimi_window: []f32,
    /// Die vorbereiteten Stimmen.
    voice_cache: std.ArrayList(VoiceCache),

    pub fn deinit(self: *Context) void {
        self.session.deinit(self.gpa);
        self.tokenizer.deinit();
        self.config.deinit(self.gpa);
        for (self.voices) |voice| {
            self.gpa.free(voice.name);
            self.gpa.free(voice.embedding);
        }
        self.gpa.free(self.voices);
        for (self.voice_cache.items) |cache| self.gpa.free(cache.values);
        self.voice_cache.deinit(self.gpa);
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
    if (desc.backend != .step) return error.UnsupportedBackend;

    const spec = desc.step orelse return error.MissingStepSpec;

    const owned = try gpa.create(descriptor.Descriptor);
    errdefer gpa.destroy(owned);
    owned.* = try desc.clone(gpa);

    const ctx = try gpa.create(Context);
    errdefer gpa.destroy(ctx);
    ctx.* = .{
        .gpa = gpa,
        .io = io,
        .desc = owned,
        .session = undefined,
        .failure = .{},
        .config = undefined,
        .tokenizer = undefined,
        .voices = &.{},
        .input_names = [_][:0]const u8{""} ** role_count,
        .input_index = [_]usize{invalid_index} ** role_count,
        .input_dims = [_][]i64{&.{}} ** role_count,
        .input_types = [_]ort.ElementType{.undefined_} ** role_count,
        .output_index = [_]usize{invalid_index} ** output_role_count,
        .flow_entry = 0,
        .mimi_entry = 0,
        .mimi_window = &.{},
        .voice_cache = .empty,
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
    errdefer ctx.config.deinit(gpa);
    try readTokenizer(gpa, ctx, spec);
    errdefer ctx.tokenizer.deinit();
    try readVoices(gpa, ctx, spec);
    errdefer deinitVoices(gpa, ctx.voices);
    try resolveGraph(gpa, ctx, spec);
    errdefer freeGraph(gpa, ctx);

    ctx.flow_entry = ctx.config.flow_layers * 2 * ctx.config.flow_heads * ctx.config.flow_head_dim;
    ctx.mimi_entry = ctx.config.mimi_layers * 2 * ctx.config.mimi_heads * ctx.config.mimi_head_dim;
    if (ctx.flow_entry == 0 or ctx.mimi_entry == 0) return error.InvalidConfig;

    ctx.mimi_window = try gpa.alloc(f32, ctx.config.mimi_kv_len * ctx.mimi_entry);
    errdefer gpa.free(ctx.mimi_window);
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
    if (model.desc.text.language.len > 0) return model.desc.text.language;
    return model.config.language orelse "";
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
    const language = if (ctx.desc.text.language.len > 0)
        ctx.desc.text.language
    else
        ctx.config.language orelse "";
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
    if (tokens.len == 0) return error.EmptyText;

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
        defer freeOutputs(gpa, outputs);

        try flow.append(try floatsOf(&outputs[ctx.output_index[@intFromEnum(OutRole.flow_kv_new)]]));
    }

    // Der Framerlauf erzeugt den Ton.
    const noise = try gpa.alloc(f32, ctx.config.latent_dim);
    defer gpa.free(noise);

    const latent = try gpa.alloc(f32, ctx.config.latent_dim);
    defer gpa.free(latent);
    @memset(latent, 0);

    const is_bos = try gpa.alloc(f32, 1);
    defer gpa.free(is_bos);

    var seed_bytes: [8]u8 = undefined;
    ctx.io.random(&seed_bytes);
    const seed = std.mem.readInt(u64, &seed_bytes, .little);
    var prng = std.Random.DefaultPrng.init(seed);
    var rng = prng.random();

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
        defer freeOutputs(gpa, outputs);

        try flow.append(try floatsOf(&outputs[ctx.output_index[@intFromEnum(OutRole.flow_kv_new)]]));
        try mimi.append(try floatsOf(&outputs[ctx.output_index[@intFromEnum(OutRole.mimi_kv_new)]]));

        const next_conv = try floatsOf(&outputs[ctx.output_index[@intFromEnum(OutRole.mimi_conv_out)]]);
        if (next_conv.len != conv_state.len) return error.UnexpectedShape;
        @memcpy(conv_state, next_conv);

        mimi_offset = try intOf(&outputs[ctx.output_index[@intFromEnum(OutRole.mimi_offset_out)]]);

        const next_latent = try floatsOf(&outputs[ctx.output_index[@intFromEnum(OutRole.next_latent)]]);
        if (next_latent.len != latent.len) return error.UnexpectedShape;
        @memcpy(latent, next_latent);

        const eos = try floatsOf(&outputs[ctx.output_index[@intFromEnum(OutRole.eos_logit)]]);
        if (eos.len == 0) return error.UnexpectedShape;
        if (eos_frame == null and eos[0] > ctx.config.eos_threshold) {
            eos_frame = frame;
        }
        if (eos_frame) |found| {
            if (frame >= found + frames_after_eos) break;
        }

        const audio = try floatsOf(&outputs[ctx.output_index[@intFromEnum(OutRole.audio)]]);
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
    step.mimi.windowInto(config.mimi_kv_len, ctx.mimi_window);

    const zeros_i64 = try gpa.alloc(i64, step.seq);
    defer gpa.free(zeros_i64);
    @memset(zeros_i64, 0);

    var latent_owned: ?[]f32 = null;
    defer if (latent_owned) |buffer| gpa.free(buffer);
    const latent: []const f32 = if (step.latent.len == 0) blk: {
        const buffer = try gpa.alloc(f32, step.seq * config.latent_dim);
        latent_owned = buffer;
        @memset(buffer, 0);
        break :blk buffer;
    } else step.latent;

    var is_bos_owned: ?[]f32 = null;
    defer if (is_bos_owned) |buffer| gpa.free(buffer);
    const is_bos: []const f32 = if (step.is_bos.len == 0) blk: {
        const buffer = try gpa.alloc(f32, step.seq);
        is_bos_owned = buffer;
        @memset(buffer, 0);
        break :blk buffer;
    } else step.is_bos;

    var cond_owned: ?[]f32 = null;
    defer if (cond_owned) |buffer| gpa.free(buffer);
    const cond: []const f32 = if (step.cond.len == 0) blk: {
        const buffer = try gpa.alloc(f32, step.seq * config.model_dim);
        cond_owned = buffer;
        @memset(buffer, 0);
        break :blk buffer;
    } else step.cond;

    const tokens = if (step.tokens.len == 0) zeros_i64 else step.tokens;
    const gates = step.gates;
    const flow_offset: i64 = @intCast(step.flow.length);
    const mimi_offset = step.mimi_offset;
    const decode_steps: f32 = @floatFromInt(config.sampler_decode_steps);
    const lora: f32 = 0.0;

    var inputs: std.ArrayList(ort.RunInput) = .empty;
    defer inputs.deinit(gpa);
    errdefer for (inputs.items) |input| ort.releaseValue(&ctx.session, input.value);

    try addInput(i64, gpa, ctx, &inputs, .tokens, tokens);
    try addInput(f32, gpa, ctx, &inputs, .latent, latent);
    try addInput(f32, gpa, ctx, &inputs, .is_bos, is_bos);
    try addInput(f32, gpa, ctx, &inputs, .cond, cond);
    try addInput(f32, gpa, ctx, &inputs, .gates, &gates);
    try addInput(f32, gpa, ctx, &inputs, .noise, step.noise);
    try addInput(f32, gpa, ctx, &inputs, .flow_kv, step.flow.window());
    try addInput(i64, gpa, ctx, &inputs, .flow_offset, &.{flow_offset});
    try addInput(f32, gpa, ctx, &inputs, .mimi_kv, ctx.mimi_window);
    try addInput(i64, gpa, ctx, &inputs, .mimi_offset, &.{mimi_offset});
    try addInput(f32, gpa, ctx, &inputs, .mimi_conv, step.mimi_conv);
    try addInput(f32, gpa, ctx, &inputs, .decode_steps, &.{decode_steps});

    if (ctx.input_index[@intFromEnum(Role.lora)] != invalid_index) {
        try addInput(f32, gpa, ctx, &inputs, .lora, &.{lora});
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
    comptime T: type,
    gpa: std.mem.Allocator,
    ctx: *Context,
    inputs: *std.ArrayList(ort.RunInput),
    role: Role,
    data: []const T,
) !void {
    const expected_type: ort.ElementType = if (T == i64) .int64 else .float;
    const role_index = @intFromEnum(role);
    if (ctx.input_types[role_index] != expected_type) return error.UnexpectedShape;

    const shape = try resolveShape(gpa, ctx.input_dims[role_index], data.len);
    defer gpa.free(shape);

    try inputs.ensureTotalCapacity(gpa, inputs.items.len + 1);
    const value = if (T == i64)
        try ctx.session.createInt64Tensor(data, shape, &ctx.failure)
    else
        try ctx.session.createFloatTensor(data, shape, &ctx.failure);
    inputs.appendAssumeCapacity(.{
        .name = ctx.input_names[role_index],
        .value = value,
    });
}

/// Loest eine Form mit dynamischer Groesse auf.
///
/// Bei genau einer negativen Dimension ergibt sich deren Wert aus der Zahl
/// der Elemente. Alle anderen Dimensionen muessen bekannt sein.
fn resolveShape(gpa: std.mem.Allocator, dims: []const i64, elements: usize) ![]i64 {
    var dynamic: ?usize = null;
    var known_product: usize = 1;

    for (dims, 0..) |dim, index| {
        if (dim < 0) {
            if (dynamic != null) return error.UnexpectedShape;
            dynamic = index;
            continue;
        }
        if (dim == 0) {
            known_product = 0;
            continue;
        }
        if (known_product == 0) continue;
        known_product = std.math.mul(usize, known_product, @intCast(dim)) catch
            return error.UnexpectedShape;
    }

    var resolved = try gpa.dupe(i64, dims);
    errdefer gpa.free(resolved);

    if (dynamic) |index| {
        const value: usize = if (known_product == 0) blk: {
            if (elements != 0) return error.UnexpectedShape;
            break :blk 0;
        } else blk: {
            if (elements % known_product != 0) return error.UnexpectedShape;
            break :blk elements / known_product;
        };
        resolved[index] = @intCast(value);
    } else if (known_product != elements) {
        return error.UnexpectedShape;
    }

    return resolved;
}

/// Liest die Laufzeitwerte aus den Metadaten der ONNX-Datei.
fn readConfig(gpa: std.mem.Allocator, ctx: *Context, spec: descriptor.StepSpec) !void {
    const raw = (try ctx.session.metadataValue(gpa, spec.config_key, &ctx.failure)) orelse
        return error.MissingMetadata;
    defer gpa.free(raw);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };

    var language: ?[]u8 = null;
    errdefer if (language) |text| gpa.free(text);
    if (root.get("language")) |value| {
        if (value != .null) language = try gpa.dupe(u8, try jsonStringValue(value));
    }

    var shapes: std.ArrayList(VoiceShape) = .empty;
    defer shapes.deinit(gpa);
    errdefer for (shapes.items) |shape| gpa.free(shape.name);

    const voices_value = root.get("voices") orelse return error.InvalidConfig;
    const voices_object = switch (voices_value) {
        .object => |object| object,
        else => return error.InvalidConfig,
    };
    var iterator = voices_object.iterator();
    while (iterator.next()) |entry| {
        const dimensions = switch (entry.value_ptr.*) {
            .array => |array| array.items,
            else => return error.InvalidConfig,
        };
        if (dimensions.len != 2) return error.InvalidConfig;
        const frames = try jsonInt(dimensions[0]);
        const model_dim = try jsonInt(dimensions[1]);
        if (frames <= 0 or model_dim <= 0) return error.InvalidConfig;
        try shapes.append(gpa, .{
            .name = try gpa.dupe(u8, entry.key_ptr.*),
            .frames = @intCast(frames),
            .model_dim = @intCast(model_dim),
        });
    }
    if (shapes.items.len == 0) return error.InvalidConfig;

    const voice_shapes = try shapes.toOwnedSlice(gpa);
    errdefer {
        for (voice_shapes) |shape| gpa.free(shape.name);
        gpa.free(voice_shapes);
    }

    const model_dim: usize = try requiredPositiveInt(root, "model_dim");
    for (voice_shapes) |shape| {
        if (shape.model_dim != model_dim) return error.InvalidConfig;
    }

    const noise_clamp_value = root.get("noise_clamp");
    const noise_clamp: ?f32 = if (noise_clamp_value) |value| blk: {
        if (value == .null) break :blk null;
        const number = try jsonFloat(value);
        if (!std.math.isFinite(number) or number <= 0) return error.InvalidConfig;
        break :blk @floatCast(number);
    } else null;

    const frames_after_eos_value = root.get("frames_after_eos");
    const frames_after_eos: ?u32 = if (frames_after_eos_value) |value| blk: {
        if (value == .null) break :blk null;
        const number = try jsonInt(value);
        if (number < 0) return error.InvalidConfig;
        break :blk @intCast(number);
    } else null;

    const sampler_decode_steps: usize = try requiredPositiveInt(root, "sampler_decode_steps");
    const max_decode_steps: usize = try requiredPositiveInt(root, "max_decode_steps");
    if (sampler_decode_steps > max_decode_steps) return error.InvalidConfig;

    const config = Config{
        .sample_rate = try requiredPositiveU32(root, "sample_rate"),
        .frame_rate = try requiredFloat(root, "frame_rate"),
        .frame_size = try requiredPositiveInt(root, "frame_size"),
        .latent_dim = try requiredPositiveInt(root, "latent_dim"),
        .model_dim = model_dim,
        .flow_layers = try requiredPositiveInt(root, "flow_layers"),
        .flow_heads = try requiredPositiveInt(root, "flow_heads"),
        .flow_head_dim = try requiredPositiveInt(root, "flow_head_dim"),
        .mimi_layers = try requiredPositiveInt(root, "mimi_layers"),
        .mimi_heads = try requiredPositiveInt(root, "mimi_heads"),
        .mimi_head_dim = try requiredPositiveInt(root, "mimi_head_dim"),
        .mimi_kv_len = try requiredPositiveInt(root, "mimi_kv_len"),
        .mimi_steps_per_latent = try requiredPositiveInt(root, "mimi_steps_per_latent"),
        .conv_state_size = try requiredPositiveInt(root, "conv_state_size"),
        .sampler_decode_steps = sampler_decode_steps,
        .max_decode_steps = max_decode_steps,
        .temperature = try requiredFloat(root, "temperature"),
        .noise_clamp = noise_clamp,
        .eos_threshold = try requiredFloat(root, "eos_threshold"),
        .max_tokens_per_chunk = try requiredPositiveInt(root, "max_tokens_per_chunk"),
        .pad_with_spaces_for_short_inputs = try requiredBool(root, "pad_with_spaces_for_short_inputs"),
        .remove_semicolons = try requiredBool(root, "remove_semicolons"),
        .frames_after_eos = frames_after_eos,
        .tokens_per_second_estimate = try requiredFloat(root, "tokens_per_second_estimate"),
        .gen_seconds_padding = try requiredFloat(root, "gen_seconds_padding"),
        .language = language,
        .voices = voice_shapes,
    };
    if (config.frame_rate <= 0 or config.temperature < 0) return error.InvalidConfig;
    if (config.tokens_per_second_estimate <= 0 or config.gen_seconds_padding < 0) {
        return error.InvalidConfig;
    }

    ctx.config = config;
}

/// Liest den Tokenizer aus den Metadaten der ONNX-Datei.
fn readTokenizer(gpa: std.mem.Allocator, ctx: *Context, spec: descriptor.StepSpec) !void {
    const encoded = (try ctx.session.metadataValue(gpa, spec.tokenizer_key, &ctx.failure)) orelse
        return error.MissingMetadata;
    defer gpa.free(encoded);

    const raw = try base64.decode(gpa, encoded);
    defer gpa.free(raw);
    ctx.tokenizer = try sentencepiece.Model.parse(gpa, raw);
}

/// Liest die Stimmen aus den Metadaten der ONNX-Datei.
fn readVoices(gpa: std.mem.Allocator, ctx: *Context, spec: descriptor.StepSpec) !void {
    var voices: std.ArrayList(Voice) = .empty;
    defer voices.deinit(gpa);
    errdefer {
        for (voices.items) |voice| {
            gpa.free(voice.name);
            gpa.free(voice.embedding);
        }
    }

    for (ctx.config.voices) |shape| {
        const key = try std.mem.concat(gpa, u8, &.{ spec.voice_prefix, shape.name });
        defer gpa.free(key);

        const encoded = (try ctx.session.metadataValue(gpa, key, &ctx.failure)) orelse
            return error.MissingMetadata;
        defer gpa.free(encoded);

        const raw = try base64.decode(gpa, encoded);
        defer gpa.free(raw);

        const count = std.math.mul(usize, shape.frames, shape.model_dim) catch
            return error.InvalidConfig;
        const expected = std.math.mul(usize, count, 2) catch return error.InvalidConfig;
        if (raw.len != expected) return error.UnexpectedShape;

        const embedding = try gpa.alloc(f32, count);
        errdefer gpa.free(embedding);
        for (embedding, 0..) |*value, index| {
            const bytes = raw[index * 2 ..][0..2];
            const bits = std.mem.readInt(u16, bytes, .little);
            const half: f16 = @bitCast(bits);
            value.* = @floatCast(half);
        }

        try voices.append(gpa, .{
            .name = try gpa.dupe(u8, shape.name),
            .frames = shape.frames,
            .embedding = embedding,
        });
    }

    std.mem.sort(Voice, voices.items, {}, voiceLessThan);
    ctx.voices = try voices.toOwnedSlice(gpa);
}

fn voiceLessThan(_: void, left: Voice, right: Voice) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn deinitVoices(gpa: std.mem.Allocator, voices: []Voice) void {
    for (voices) |voice| {
        gpa.free(voice.name);
        gpa.free(voice.embedding);
    }
    gpa.free(voices);
}

/// Sucht die Ein- und Ausgaenge des Graphen beim Namen.
fn resolveGraph(gpa: std.mem.Allocator, ctx: *Context, spec: descriptor.StepSpec) !void {
    errdefer freeGraph(gpa, ctx);

    inline for (0..role_count) |role_value| {
        const role: Role = @enumFromInt(role_value);
        if (comptime role == .lora) continue;
        const name = inputName(spec, role) orelse return error.MissingGraphInput;

        const index = ctx.session.inputIndexByName(name) orelse return error.MissingGraphInput;
        var info = try ctx.session.inputInfo(gpa, index, &ctx.failure);
        defer info.deinit();

        const role_index = @intFromEnum(role);
        ctx.input_index[role_index] = index;
        ctx.input_types[role_index] = info.element_type;
        ctx.input_dims[role_index] = try gpa.dupe(i64, info.shape);
        ctx.input_names[role_index] = try gpa.dupeZ(u8, name);
    }

    inline for (0..output_role_count) |role_value| {
        const role: OutRole = @enumFromInt(role_value);
        const name = outputName(spec, role);
        const index = ctx.session.outputIndexByName(name) orelse return error.MissingGraphOutput;
        ctx.output_index[@intFromEnum(role)] = index;
    }
}

fn freeGraph(gpa: std.mem.Allocator, ctx: *Context) void {
    for (ctx.input_names) |name| gpa.free(name);
    for (ctx.input_dims) |dims| gpa.free(dims);
}

fn inputName(spec: descriptor.StepSpec, role: Role) ?[]const u8 {
    return switch (role) {
        .tokens => spec.inputs.tokens,
        .latent => spec.inputs.latent,
        .is_bos => spec.inputs.is_bos,
        .cond => spec.inputs.cond,
        .gates => spec.inputs.gates,
        .noise => spec.inputs.noise,
        .flow_kv => spec.inputs.flow_kv,
        .flow_offset => spec.inputs.flow_offset,
        .mimi_kv => spec.inputs.mimi_kv,
        .mimi_offset => spec.inputs.mimi_offset,
        .mimi_conv => spec.inputs.mimi_conv,
        .decode_steps => spec.inputs.decode_steps,
        .lora => spec.inputs.lora,
    };
}

fn outputName(spec: descriptor.StepSpec, role: OutRole) []const u8 {
    return switch (role) {
        .audio => spec.outputs.audio,
        .next_latent => spec.outputs.next_latent,
        .eos_logit => spec.outputs.eos_logit,
        .flow_kv_new => spec.outputs.flow_kv_new,
        .mimi_kv_new => spec.outputs.mimi_kv_new,
        .mimi_offset_out => spec.outputs.mimi_offset_out,
        .mimi_conv_out => spec.outputs.mimi_conv_out,
    };
}

/// Bereitet den Flow-Cache einer Stimme vor.
fn prepareVoice(gpa: std.mem.Allocator, ctx: *Context, voice: *const Voice) !VoiceCache {
    for (ctx.voice_cache.items) |cache| {
        if (std.mem.eql(u8, cache.name, voice.name)) return cache;
    }

    var flow = try Cache.init(gpa, ctx.flow_entry, voice.frames + 1);
    defer flow.deinit();
    var mimi = try Cache.init(gpa, ctx.mimi_entry, ctx.config.mimi_kv_len);
    defer mimi.deinit();

    const conv_state = try gpa.alloc(f32, ctx.config.conv_state_size);
    defer gpa.free(conv_state);
    @memset(conv_state, 0);

    const noise = try gpa.alloc(f32, ctx.config.latent_dim);
    defer gpa.free(noise);
    @memset(noise, 0);

    const outputs = try runStep(gpa, ctx, .{
        .seq = voice.frames,
        .tokens = &.{},
        .latent = &.{},
        .is_bos = &.{},
        .cond = voice.embedding,
        .gates = .{ 0.0, 0.0, 1.0 },
        .noise = noise,
        .flow = &flow,
        .mimi = &mimi,
        .mimi_offset = 0,
        .mimi_conv = conv_state,
    });
    defer freeOutputs(gpa, outputs);

    const values = try floatsOf(&outputs[ctx.output_index[@intFromEnum(OutRole.flow_kv_new)]]);
    const expected = std.math.mul(usize, voice.frames, ctx.flow_entry) catch
        return error.UnexpectedShape;
    if (values.len != expected) return error.UnexpectedShape;

    const owned = try gpa.dupe(f32, values);
    errdefer gpa.free(owned);
    const cache = VoiceCache{
        .name = voice.name,
        .values = owned,
        .length = voice.frames,
    };
    try ctx.voice_cache.append(gpa, cache);
    return cache;
}

/// Loest eine Anfrage auf eine Stimme der Tabelle auf.
fn findVoice(ctx: *const Context, requested: []const u8) !*const Voice {
    var wanted = requested;
    if (ctx.desc.aliasTarget(wanted)) |target| wanted = target;

    if (wanted.len == 0) {
        if (ctx.voices.len == 0) return error.VoiceNotFound;
        return &ctx.voices[0];
    }

    for (ctx.voices) |*voice| {
        if (std.mem.eql(u8, voice.name, wanted)) return voice;
    }
    for (ctx.voices) |*voice| {
        if (std.ascii.eqlIgnoreCase(voice.name, wanted)) return voice;
    }
    return error.VoiceNotFound;
}

/// Berechnet die groesste Zahl der Frames eines Abschnitts.
fn maxFrames(ctx: *Context, token_count: usize) !usize {
    const seconds = @as(f64, @floatFromInt(token_count)) /
        @as(f64, ctx.config.tokens_per_second_estimate) +
        @as(f64, ctx.config.gen_seconds_padding);
    const frames = std.math.ceil(seconds * @as(f64, ctx.config.frame_rate));
    if (!std.math.isFinite(frames) or frames <= 0) return error.InvalidConfig;
    return @intFromFloat(frames);
}

/// Fuellt den Rauschpuffer mit normalverteilten Werten.
fn makeNoise(ctx: *Context, rng: *std.Random, noise: []f32) void {
    const deviation = @sqrt(ctx.config.temperature);
    for (noise) |*value| {
        value.* = rng.floatNorm(f32) * deviation;
    }

    const clamp = ctx.config.noise_clamp orelse return;
    var changed = true;
    while (changed) {
        changed = false;
        for (noise) |*value| {
            if (@abs(value.*) > clamp) {
                value.* = rng.floatNorm(f32) * deviation;
                changed = true;
            }
        }
    }
}

/// Liest die Floatdaten eines Tensors.
fn floatsOf(data: *const ort.TensorData) ![]const f32 {
    return data.asFloats();
}

/// Liest den skalaren Ganzzahlwert eines Tensors.
fn intOf(data: *const ort.TensorData) !i64 {
    if (data.element_type != .int64) return error.UnexpectedShape;
    if (data.bytes.len != @sizeOf(i64)) return error.UnexpectedShape;
    return std.mem.readInt(i64, data.bytes[0..@sizeOf(i64)], .little);
}

/// Gibt die Ausgaben eines Laufs frei.
fn freeOutputs(gpa: std.mem.Allocator, outputs: []ort.TensorData) void {
    for (outputs) |*output| output.deinit();
    gpa.free(outputs);
}

/// Ein wachsender Cache aus hintereinanderliegenden Eintraegen.
const Cache = struct {
    gpa: std.mem.Allocator,
    entry_size: usize,
    values: []f32,
    length: usize,

    fn init(gpa: std.mem.Allocator, entry_size: usize, capacity: usize) !Cache {
        const values = try gpa.alloc(f32, capacity * entry_size);
        return .{
            .gpa = gpa,
            .entry_size = entry_size,
            .values = values,
            .length = 0,
        };
    }

    fn deinit(self: *Cache) void {
        self.gpa.free(self.values);
        self.values = &.{};
        self.length = 0;
    }

    fn reserve(self: *Cache, extra: usize) !void {
        const needed = self.length + extra;
        const capacity = self.values.len / self.entry_size;
        if (needed <= capacity) return;

        const grown_capacity = @max(needed, @max(capacity * 2, 1));
        const grown = try self.gpa.alloc(f32, grown_capacity * self.entry_size);
        @memcpy(grown[0 .. self.length * self.entry_size], self.values[0 .. self.length * self.entry_size]);
        self.gpa.free(self.values);
        self.values = grown;
    }

    fn append(self: *Cache, values: []const f32) !void {
        if (values.len % self.entry_size != 0) return error.UnexpectedShape;
        const count = values.len / self.entry_size;
        try self.reserve(count);
        @memcpy(
            self.values[self.length * self.entry_size ..][0..values.len],
            values,
        );
        self.length += count;
    }

    /// Liefert alle gueltigen Eintraege.
    fn window(self: *const Cache) []const f32 {
        return self.values[0 .. self.length * self.entry_size];
    }

    /// Schreibt die letzten Eintraege in einen Puffer und polstert vorne auf.
    fn windowInto(self: *const Cache, size: usize, out: []f32) void {
        std.debug.assert(out.len == size * self.entry_size);
        @memset(out, 0);
        if (self.length >= size) {
            const start = (self.length - size) * self.entry_size;
            @memcpy(out, self.values[start..][0 .. size * self.entry_size]);
        } else if (self.length > 0) {
            const start = (size - self.length) * self.entry_size;
            @memcpy(out[start..], self.values[0 .. self.length * self.entry_size]);
        }
    }
};

/// Liest eine ganzzahlige JSON-Zahl.
fn jsonInt(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| if (std.math.isFinite(number) and @trunc(number) == number)
            @intFromFloat(number)
        else
            return error.InvalidConfig,
        else => return error.InvalidConfig,
    };
}

/// Liest eine Flieskommazahl aus JSON.
fn jsonFloat(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => return error.InvalidConfig,
    };
}

fn jsonStringValue(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => return error.InvalidConfig,
    };
}

fn requiredPositiveU32(root: std.json.ObjectMap, name: []const u8) !u32 {
    const value = try requiredPositiveInt(root, name);
    if (value > std.math.maxInt(u32)) return error.InvalidConfig;
    return @intCast(value);
}

fn requiredPositiveInt(root: std.json.ObjectMap, name: []const u8) !usize {
    const value = root.get(name) orelse return error.InvalidConfig;
    const number = try jsonInt(value);
    if (number <= 0) return error.InvalidConfig;
    return @intCast(number);
}

fn requiredFloat(root: std.json.ObjectMap, name: []const u8) !f32 {
    const value = root.get(name) orelse return error.InvalidConfig;
    const number = try jsonFloat(value);
    if (!std.math.isFinite(number)) return error.InvalidConfig;
    return @floatCast(number);
}

fn requiredBool(root: std.json.ObjectMap, name: []const u8) !bool {
    const value = root.get(name) orelse return error.InvalidConfig;
    return switch (value) {
        .bool => |flag| flag,
        else => return error.InvalidConfig,
    };
}
