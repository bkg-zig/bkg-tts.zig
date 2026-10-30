//! Realtime WebSocket event loop. Emits audio only from real Magpie inference.
const std = @import("std");
const api_mod = @import("api.zig");

const max_text_bytes = 5000;
const chunk_ms = 200;

const Session = struct {
    id: u64,
    voice: []const u8 = "Aria",
    language: []const u8 = "en",
    format: []const u8 = "pcm",
    sample_rate: u32 = 22050,
};

pub fn serve(ws: *std.http.Server.WebSocket, ctx: *api_mod.Context) !void {
    const session_id = ctx.nextRequestId();
    var session = Session{ .id = session_id };
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(ctx.gpa);

    try sendFmt(ws, ctx.gpa,
        "{{\"type\":\"session.created\",\"session_id\":\"sess_{x}\",\"request_id\":\"req_{x}\"}}",
        .{ session.id, session.id });

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
            if (applySession(&session, field(event, "session"))) |err_code| {
                try sendError(ws, ctx.gpa, session.id, err_code, "Die Session-Konfiguration enthält eine nicht unterstützte Option.");
                continue;
            }
            try sendFmt(ws, ctx.gpa,
                "{{\"type\":\"session.updated\",\"session_id\":\"sess_{x}\",\"session\":{{\"voice\":\"{s}\",\"language\":\"{s}\",\"format\":\"{s}\",\"sample_rate\":{d},\"speed\":1.0,\"text_normalization\":false,\"cfg_enabled\":true,\"cfg_scale\":2.5}}}}",
                .{ session.id, session.voice, session.language, session.format, session.sample_rate });
        } else if (std.mem.eql(u8, event_type, "input_text.append")) {
            const fragment = stringField(event, "text", "");
            if (fragment.len == 0) {
                try sendError(ws, ctx.gpa, session.id, "INVALID_REQUEST", "Leere Textfragmente sind nicht zulässig.");
                continue;
            }
            if (pending.items.len + fragment.len > max_text_bytes) {
                pending.clearRetainingCapacity();
                try sendError(ws, ctx.gpa, session.id, "INPUT_TOO_LONG", "Der Realtime-Text überschreitet 5000 Bytes.");
                continue;
            }
            try pending.appendSlice(ctx.gpa, fragment);
            if (hasPhraseBoundary(fragment)) try synthesizePending(ws, ctx, &session, &pending);
        } else if (std.mem.eql(u8, event_type, "input_text.commit")) {
            try synthesizePending(ws, ctx, &session, &pending);
        } else if (std.mem.eql(u8, event_type, "response.cancel")) {
            const was_buffered = pending.items.len > 0;
            pending.clearRetainingCapacity();
            try sendFmt(ws, ctx.gpa,
                "{{\"type\":\"response.cancelled\",\"session_id\":\"sess_{x}\",\"cancelled_jobs\":{d}}}",
                .{ session.id, if (was_buffered) @as(u8, 1) else @as(u8, 0) });
        } else if (std.mem.eql(u8, event_type, "ping")) {
            try sendFmt(ws, ctx.gpa, "{{\"type\":\"pong\",\"session_id\":\"sess_{x}\"}}", .{session.id});
        } else {
            try sendError(ws, ctx.gpa, session.id, "WEBSOCKET_PROTOCOL_ERROR", "Unbekannter Realtime-Ereignistyp.");
        }
    }
}

fn applySession(session: *Session, value: std.json.Value) ?[]const u8 {
    const voice = canonicalVoice(stringField(value, "voice", session.voice)) orelse return "INVALID_VOICE";
    const language = canonicalLanguage(stringField(value, "language", session.language)) orelse return "UNSUPPORTED_LANGUAGE";
    const format = stringField(value, "format", session.format);
    if (!std.mem.eql(u8, format, "pcm")) return "UNSUPPORTED_FORMAT";
    if (numberField(value, "sample_rate", 22050) != 22050) return "INVALID_SAMPLE_RATE";
    if (numberField(value, "speed", 1) != 1) return "UNSUPPORTED_SETTING";
    if (numberField(value, "cfg_scale", 2.5) != 2.5) return "UNSUPPORTED_SETTING";
    if (!boolField(value, "cfg_enabled", true)) return "UNSUPPORTED_SETTING";
    if (boolField(value, "text_normalization", false)) return "UNSUPPORTED_SETTING";
    session.voice = voice;
    session.language = language;
    session.format = "pcm";
    session.sample_rate = 22050;
    return null;
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
        try sendError(ws, ctx.gpa, session.id, "MODEL_NOT_READY", "Die Magpie-Engine ist nicht bereit.");
        return;
    }

    try sendFmt(ws, ctx.gpa, "{{\"type\":\"response.created\",\"session_id\":\"sess_{x}\"}}", .{session.id});
    const started = std.Io.Clock.awake.now(ctx.io);
    const result = ctx.engine.synthesizeFor(text, session.language, session.voice) catch {
        try sendError(ws, ctx.gpa, session.id, "SYNTHESIS_FAILED", "Die native Magpie-Synthese ist fehlgeschlagen.");
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
            const clamped = @max(-1.0, @min(1.0, sample));
            const value: i16 = @intFromFloat(clamped * 32767.0);
            std.mem.writeInt(i16, pcm_bytes[i * 2 ..][0..2], value, .little);
        }
        try sendAudioChunk(ws, ctx.gpa, session, pcm_bytes, chunk_index);
        offset = end;
    }

    const elapsed_ns = @max(@as(i96, 0), started.durationTo(std.Io.Clock.awake.now(ctx.io)).nanoseconds);
    const ttfa_ms: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const duration: f64 = @as(f64, @floatFromInt(result.pcm.len)) / @as(f64, @floatFromInt(result.sample_rate));
    try sendFmt(ws, ctx.gpa,
        "{{\"type\":\"response.completed\",\"session_id\":\"sess_{x}\",\"duration_s\":{d:.3},\"ttfa_ms\":{d:.1}}}",
        .{ session.id, duration, ttfa_ms });
}

fn sendAudioChunk(
    ws: *std.http.Server.WebSocket,
    gpa: std.mem.Allocator,
    session: *const Session,
    pcm: []const u8,
    index: usize,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(pcm.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, pcm);
    const message = try std.fmt.allocPrint(
        gpa,
        "{{\"type\":\"audio.chunk\",\"session_id\":\"sess_{x}\",\"data\":\"{s}\",\"format\":\"{s}\",\"sample_rate\":{d},\"chunk_index\":{d}}}",
        .{ session.id, encoded, session.format, session.sample_rate, index },
    );
    defer gpa.free(message);
    try ws.writeMessage(message, .text);
}

fn sendError(ws: *std.http.Server.WebSocket, gpa: std.mem.Allocator, session_id: u64, code: []const u8, message: []const u8) !void {
    try sendFmt(ws, gpa,
        "{{\"type\":\"error\",\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"retryable\":false,\"session_id\":\"sess_{x}\"}}}}",
        .{ code, message, session_id });
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
fn canonicalVoice(value: []const u8) ?[]const u8 {
    const voices = [_][]const u8{ "Aria", "Jason", "John", "Leo", "Sofia" };
    for (voices) |voice| if (std.ascii.eqlIgnoreCase(value, voice)) return voice;
    return null;
}
fn canonicalLanguage(value: []const u8) ?[]const u8 {
    const languages = [_][]const u8{ "en", "de", "es", "fr", "it", "pt-BR", "hi", "vi", "ko", "ar-AE", "ar-SA", "ar-MSA" };
    for (languages) |language| if (std.ascii.eqlIgnoreCase(value, language)) return language;
    if (std.ascii.eqlIgnoreCase(value, "pt")) return "pt-BR";
    if (std.ascii.eqlIgnoreCase(value, "ar")) return "ar-MSA";
    return null;
}
