//! Realtime WebSocket event loop. The audio comes from the active model of
//! the engine. Voices, languages and the sample rate are read from the
//! engine, never from a fixed list.
const std = @import("std");
const api_mod = @import("api.zig");
const audio_mod = @import("audio.zig");
const limits = @import("limits.zig");

const chunk_ms = 200;

/// The state of one realtime session.
///
/// The names of the voice and the language belong to the session. They are
/// copied from the engine, because the engine can swap its model while the
/// session lives.
const Session = struct {
    id: u64,
    /// Name of the voice. Empty means: the first voice of the model.
    voice: []u8,
    /// Language of the session. Empty means: the language of the model.
    language: []u8,
    format: []const u8 = "pcm",
    sample_rate: u32 = 0,
    speed: f32 = 1.0,

    fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        gpa.free(self.voice);
        gpa.free(self.language);
        self.* = undefined;
    }

    /// Replaces the voice of the session.
    fn setVoice(self: *Session, gpa: std.mem.Allocator, value: []const u8) !void {
        const owned = try gpa.dupe(u8, value);
        gpa.free(self.voice);
        self.voice = owned;
    }

    /// Replaces the language of the session.
    fn setLanguage(self: *Session, gpa: std.mem.Allocator, value: []const u8) !void {
        const owned = try gpa.dupe(u8, value);
        gpa.free(self.language);
        self.language = owned;
    }
};

pub fn serve(ws: *std.http.Server.WebSocket, ctx: *api_mod.Context) !void {
    const session_id = ctx.nextRequestId();
    var session = Session{
        .id = session_id,
        .voice = try ctx.gpa.dupe(u8, ""),
        .language = try ctx.gpa.dupe(u8, ""),
    };
    defer session.deinit(ctx.gpa);
    try applyModelDefaults(ctx, &session);

    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(ctx.gpa);

    try sendFmt(ws, ctx.gpa, "{{\"type\":\"session.created\",\"session_id\":\"sess_{x}\",\"request_id\":\"req_{x}\",\"voice\":\"{s}\",\"language\":\"{s}\",\"format\":\"{s}\",\"sample_rate\":{d}}}", .{ session.id, session.id, session.voice, session.language, session.format, session.sample_rate });

    while (true) {
        const message = ws.readSmallMessage() catch return;
        if (message.opcode == .ping) {
            try ws.writeMessage(message.data, .pong);
            continue;
        }
        if (message.opcode != .text) {
            try sendError(ws, ctx.gpa, session.id, "WEBSOCKET_PROTOCOL_ERROR", "Realtime erwartet JSON-Textnachrichten.");
            continue;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, message.data, .{}) catch {
            try sendError(ws, ctx.gpa, session.id, "WEBSOCKET_PROTOCOL_ERROR", "Ungültiges JSON-Ereignis.");
            continue;
        };
        defer parsed.deinit();

        const event = parsed.value;
        const event_type = stringField(event, "type", "");
        if (std.mem.eql(u8, event_type, "session.update")) {
            if (applySession(ctx, &session, field(event, "session"))) |err_code| {
                try sendError(ws, ctx.gpa, session.id, err_code, errorText(err_code));
                continue;
            }
            try sendFmt(ws, ctx.gpa, "{{\"type\":\"session.updated\",\"session_id\":\"sess_{x}\",\"session\":{{\"voice\":\"{s}\",\"language\":\"{s}\",\"format\":\"{s}\",\"sample_rate\":{d},\"speed\":{d:.2},\"text_normalization\":false,\"cfg_enabled\":false}}}}", .{ session.id, session.voice, session.language, session.format, session.sample_rate, session.speed });
        } else if (std.mem.eql(u8, event_type, "input_text.append")) {
            const fragment = stringField(event, "text", "");
            if (fragment.len == 0) {
                try sendError(ws, ctx.gpa, session.id, "INVALID_REQUEST", "Leere Textfragmente sind nicht zulässig.");
                continue;
            }
            if (pending.items.len + fragment.len > limits.max_text_chars) {
                pending.clearRetainingCapacity();
                try sendError(ws, ctx.gpa, session.id, "INPUT_TOO_LONG", "Der Realtime-Text überschreitet " ++ limits.max_text_text ++ " Bytes.");
                continue;
            }
            try pending.appendSlice(ctx.gpa, fragment);
            if (hasPhraseBoundary(fragment)) try synthesizePending(ws, ctx, &session, &pending);
        } else if (std.mem.eql(u8, event_type, "input_text.commit")) {
            try synthesizePending(ws, ctx, &session, &pending);
        } else if (std.mem.eql(u8, event_type, "response.cancel")) {
            const was_buffered = pending.items.len > 0;
            pending.clearRetainingCapacity();
            try sendFmt(ws, ctx.gpa, "{{\"type\":\"response.cancelled\",\"session_id\":\"sess_{x}\",\"cancelled_jobs\":{d}}}", .{ session.id, if (was_buffered) @as(u8, 1) else @as(u8, 0) });
        } else if (std.mem.eql(u8, event_type, "ping")) {
            try sendFmt(ws, ctx.gpa, "{{\"type\":\"pong\",\"session_id\":\"sess_{x}\"}}", .{session.id});
        } else {
            try sendError(ws, ctx.gpa, session.id, "WEBSOCKET_PROTOCOL_ERROR", "Unbekannter Realtime-Ereignistyp.");
        }
    }
}

/// Takes the voice, the language and the sample rate from the active model.
///
/// Without a model the session stays empty. The first request then reports
/// that no model is ready.
fn applyModelDefaults(ctx: *api_mod.Context, session: *Session) !void {
    if (!ctx.engine.isActive()) return;

    session.sample_rate = ctx.engine.sampleRate();

    const language = ctx.engine.activeLanguage(ctx.gpa) catch return;
    defer ctx.gpa.free(language);
    try session.setLanguage(ctx.gpa, language);

    const voice = ctx.engine.resolveVoice(ctx.gpa, "") catch return;
    const resolved = voice orelse return;
    defer ctx.gpa.free(resolved);
    try session.setVoice(ctx.gpa, resolved);
}

/// Applies the configuration of a session update.
///
/// The voice and the language are checked against the active model. A name
/// that the model does not know is an error, not a silent fallback.
fn applySession(ctx: *api_mod.Context, session: *Session, value: std.json.Value) ?[]const u8 {
    const requested_voice = stringField(value, "voice", session.voice);
    const requested_language = stringField(value, "language", session.language);

    // Der aufgeloeste Name bleibt bis zum Ende der Funktion gueltig. Wird er
    // vorher freigegeben, zeigt `voice` auf freigegebenen Speicher. Der
    // Allokator kann dann denselben Block fuer die Kopie vergeben, und die
    // Kopie liest und schreibt denselben Speicher.
    var resolved_voice: ?[]const u8 = null;
    defer if (resolved_voice) |name| ctx.gpa.free(name);

    var voice: []const u8 = session.voice;
    if (requested_voice.len > 0) {
        const resolved = ctx.engine.resolveVoice(ctx.gpa, requested_voice) catch return "INVALID_VOICE";
        const name = resolved orelse return "INVALID_VOICE";
        resolved_voice = name;
        voice = name;
    }

    if (requested_language.len > 0 and !ctx.engine.languageMatches(requested_language)) {
        return "UNSUPPORTED_LANGUAGE";
    }

    const format = stringField(value, "format", session.format);
    if (!std.mem.eql(u8, format, "pcm")) return "UNSUPPORTED_FORMAT";

    const model_sample_rate = ctx.engine.sampleRate();
    if (numberField(value, "sample_rate", model_sample_rate) != model_sample_rate) return "INVALID_SAMPLE_RATE";

    const speed = numberField(value, "speed", session.speed);
    if (!limits.realtimeSpeedAllowed(@floatCast(speed))) return "UNSUPPORTED_SETTING";
    if (numberField(value, "cfg_scale", 0) != 0) return "UNSUPPORTED_SETTING";
    if (boolField(value, "cfg_enabled", false)) return "UNSUPPORTED_SETTING";
    if (boolField(value, "text_normalization", false)) return "UNSUPPORTED_SETTING";

    session.setVoice(ctx.gpa, voice) catch return "INVALID_VOICE";
    if (requested_language.len > 0) {
        session.setLanguage(ctx.gpa, requested_language) catch return "UNSUPPORTED_LANGUAGE";
    }
    session.format = "pcm";
    session.sample_rate = model_sample_rate;
    session.speed = @floatCast(speed);
    return null;
}

/// The German text of an error code.
fn errorText(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "INVALID_VOICE")) return "Das Modell kennt die angeforderte Stimme nicht.";
    if (std.mem.eql(u8, code, "UNSUPPORTED_LANGUAGE")) return "Das Modell versteht die angeforderte Sprache nicht.";
    if (std.mem.eql(u8, code, "UNSUPPORTED_FORMAT")) return "Der Realtime-Weg liefert nur rohes PCM.";
    if (std.mem.eql(u8, code, "INVALID_SAMPLE_RATE")) return "Die Abtastrate des Modells kann nicht geändert werden.";
    return "Die Session-Konfiguration enthält eine nicht unterstützte Option.";
}

fn synthesizePending(
    ws: *std.http.Server.WebSocket,
    ctx: *api_mod.Context,
    session: *Session,
    pending: *std.ArrayList(u8),
) !void {
    if (pending.items.len == 0) return;
    const raw_text = try ctx.gpa.dupe(u8, pending.items);
    pending.clearRetainingCapacity();
    defer ctx.gpa.free(raw_text);
    const text = api_mod.applyPronunciations(ctx, raw_text, session.language) catch {
        try sendError(ws, ctx.gpa, session.id, "PRONUNCIATION_APPLY_FAILED", "Aussprache-Regeln konnten nicht angewendet werden.");
        return;
    };
    defer ctx.gpa.free(text);
    if (!ctx.engine.isActive()) {
        try sendError(ws, ctx.gpa, session.id, "MODEL_NOT_READY", "Die Engine hat kein geladenes Modell.");
        return;
    }

    try sendFmt(ws, ctx.gpa, "{{\"type\":\"response.created\",\"session_id\":\"sess_{x}\"}}", .{session.id});
    const started = std.Io.Clock.awake.now(ctx.io);
    const result = ctx.engine.synthesizeFor(ctx.gpa, text, session.language, session.voice, session.speed) catch |err| {
        const message = std.fmt.allocPrint(ctx.gpa, "Die Sprachsynthese ist fehlgeschlagen: {s}.", .{@errorName(err)}) catch {
            try sendError(ws, ctx.gpa, session.id, "SYNTHESIS_FAILED", "Die Sprachsynthese ist fehlgeschlagen.");
            return;
        };
        defer ctx.gpa.free(message);
        try sendError(ws, ctx.gpa, session.id, "SYNTHESIS_FAILED", message);
        return;
    };
    defer ctx.gpa.free(result.pcm);

    const samples_per_chunk = @max(1, @as(usize, result.sample_rate) * chunk_ms / 1000);
    var chunk_index: usize = 0;
    var offset: usize = 0;
    while (offset < result.pcm.len) : (chunk_index += 1) {
        const end = @min(result.pcm.len, offset + samples_per_chunk);
        const pcm_bytes = try ctx.gpa.alloc(u8, (end - offset) * 2);
        defer ctx.gpa.free(pcm_bytes);
        for (result.pcm[offset..end], 0..) |sample, i| {
            std.mem.writeInt(i16, pcm_bytes[i * 2 ..][0..2], audio_mod.quantize(sample), .little);
        }
        try sendAudioChunk(ws, ctx.gpa, session, pcm_bytes, chunk_index, result.sample_rate);
        offset = end;
    }

    const elapsed_ns = @max(@as(i96, 0), started.durationTo(std.Io.Clock.awake.now(ctx.io)).nanoseconds);
    const ttfa_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const duration: f64 = @as(f64, @floatFromInt(result.pcm.len)) / @as(f64, @floatFromInt(result.sample_rate));
    try sendFmt(ws, ctx.gpa, "{{\"type\":\"response.completed\",\"session_id\":\"sess_{x}\",\"duration_s\":{d:.3},\"ttfa_ms\":{d:.1}}}", .{ session.id, duration, ttfa_ms });
}

fn sendAudioChunk(
    ws: *std.http.Server.WebSocket,
    gpa: std.mem.Allocator,
    session: *const Session,
    pcm: []const u8,
    index: usize,
    sample_rate: u32,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(pcm.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, pcm);
    const message = try std.fmt.allocPrint(
        gpa,
        "{{\"type\":\"audio.chunk\",\"session_id\":\"sess_{x}\",\"data\":\"{s}\",\"format\":\"{s}\",\"sample_rate\":{d},\"chunk_index\":{d}}}",
        .{ session.id, encoded, session.format, sample_rate, index },
    );
    defer gpa.free(message);
    try ws.writeMessage(message, .text);
}

fn sendError(ws: *std.http.Server.WebSocket, gpa: std.mem.Allocator, session_id: u64, code: []const u8, message: []const u8) !void {
    try sendFmt(ws, gpa, "{{\"type\":\"error\",\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"retryable\":false,\"session_id\":\"sess_{x}\"}}}}", .{ code, message, session_id });
}

fn sendFmt(ws: *std.http.Server.WebSocket, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const message = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(message);
    try ws.writeMessage(message, .text);
}

fn hasPhraseBoundary(text: []const u8) bool {
    for (text) |c| {
        if (c == '.' or c == '?' or c == '!' or c == ';' or c == ':' or c == '\n' or c == ',') return true;
    }
    return false;
}

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    if (value != .object) return .null;
    return value.object.get(name) orelse .null;
}
fn stringField(value: std.json.Value, name: []const u8, default: []const u8) []const u8 {
    const item = field(value, name);
    return if (item == .string) item.string else default;
}
fn boolField(value: std.json.Value, name: []const u8, default: bool) bool {
    const item = field(value, name);
    return if (item == .bool) item.bool else default;
}
fn numberField(value: std.json.Value, name: []const u8, default: f64) f64 {
    const item = field(value, name);
    return switch (item) {
        .integer => @floatFromInt(item.integer),
        .float => item.float,
        else => default,
    };
}
