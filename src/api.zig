//! API dispatcher. Unsupported parity gaps use explicit 501/422 responses, never fake success.
const std = @import("std");
const audio = @import("audio.zig");
const web_request = @import("web_request.zig");
const router = @import("router.zig");
const engine_mod = @import("engine.zig");
const config_mod = @import("config.zig");
const pronunciation_mod = @import("pronunciation.zig");
const limits = @import("limits.zig");

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    engine: *engine_mod.Engine,
    pronunciation: *pronunciation_mod.Store,
    config: config_mod.Config,
    ids: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    log_mutex: std.Io.Mutex = .init,
    logs: [128]LogRecord = [_]LogRecord{.{}} ** 128,
    logs_next: usize = 0,
    logs_count: usize = 0,

    pub fn nextRequestId(self: *Context) u64 {
        return self.ids.fetchAdd(1, .monotonic) + 1;
    }

    pub fn deinit(self: *Context) void {
        _ = self;
    }

    fn record(self: *Context, item: LogRecord) void {
        self.log_mutex.lockUncancelable(self.io);
        defer self.log_mutex.unlock(self.io);
        self.logs[self.logs_next] = item;
        self.logs_next = (self.logs_next + 1) % self.logs.len;
        self.logs_count = @min(self.logs_count + 1, self.logs.len);
    }

    fn logsJson(self: *Context, requested: usize) ![]u8 {
        self.log_mutex.lockUncancelable(self.io);
        defer self.log_mutex.unlock(self.io);
        const count = @min(@min(requested, self.logs_count), self.logs.len);
        var selected: std.ArrayList(LogRecord) = .empty;
        defer selected.deinit(self.gpa);
        try selected.ensureTotalCapacity(self.gpa, count);
        const start = (self.logs_next + self.logs.len - count) % self.logs.len;
        for (0..count) |i| try selected.append(self.gpa, self.logs[(start + i) % self.logs.len]);
        return try std.json.Stringify.valueAlloc(self.gpa, selected.items, .{});
    }
};

pub const Response = struct {
    status: std.http.Status = .ok,
    content_type: []const u8 = "application/json; charset=utf-8",
    body: []const u8,
    owned: bool = false,
    owned_content_type: bool = false,
    request_id: u64 = 0,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.body);
        if (self.owned_content_type) allocator.free(self.content_type);
        self.* = .{ .body = "" };
    }
};

const json_liveness = "{\"status\":\"ok\",\"service\":\"bkg-tts\"}";
const json_ui_not_built = "{\"error\":{\"code\":\"FRONTEND_NOT_BUILT\",\"message\":\"Der React-Build wurde noch nicht in web/dist installiert.\",\"type\":\"service_unavailable\",\"retryable\":true,\"details\":{}}}";
const openapi_document = @embedFile("openapi.json");
const docs_html = "<!doctype html><html lang=\"de\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>BKG TTS API</title><body style=\"font:16px system-ui;max-width:900px;margin:3rem auto;padding:0 1rem;background:#0a0f14;color:#e6edf3\"><h1>BKG TTS API</h1><p>Eigene Zig-Engine fuer ONNX-TTS-Modelle. Das OpenAPI-Dokument liegt unter <a href=\"/openapi.json\">/openapi.json</a>.</p><p>Modelle, Stimmen und Sprachen liest die Engine aus den Deskriptoren der Modelle. Endpunkte, die die Engine nicht bedienen kann, antworten mit einer ausdruecklichen Fehlermeldung.</p><p><a href=\"/\">Zurueck zum Dashboard</a></p></body></html>";
const redoc_html = "<!doctype html><html lang=\"de\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>BKG TTS API Reference</title><body style=\"font:16px system-ui;max-width:900px;margin:3rem auto;padding:0 1rem;background:#0a0f14;color:#e6edf3\"><h1>BKG TTS API Reference</h1><p>Maschinenlesbares API-Schema: <a href=\"/openapi.json\">/openapi.json</a>.</p><p>Die Synthese laeuft auf der CPU und liefert mono PCM oder WAV in der Abtastrate des aktiven Modells. Stimmnamen und Sprachen nennt die Engine aus den Deskriptoren.</p><p><a href=\"/docs\">API-Uebersicht</a> · <a href=\"/\">Dashboard</a></p></body></html>";

pub fn handle(ctx: *Context, req: web_request.Request) Response {
    _ = ctx.requests.fetchAdd(1, .monotonic);
    const request_id = ctx.nextRequestId();
    const route = router.classify(req.method, req.target);
    const started = std.Io.Clock.awake.now(ctx.io);

    const response = switch (route) {
        .health => jsonResponse(.ok, json_liveness, request_id),
        .ready => if (ctx.engine.isActive())
            readyResponse(ctx, request_id)
        else
            errorResponse(ctx, request_id, .service_unavailable, "MODEL_NOT_READY", "Es ist noch kein Modell geladen.", "service_unavailable", true),
        .system => systemResponse(ctx, request_id),
        .metrics => metricsResponse(ctx, request_id),
        .models => modelList(ctx, request_id),
        .model_detail => modelDetail(ctx, request_id, req.path()),
        .speech => synthesizeOpenAI(ctx, request_id, req.body),
        .native_generate => synthesizeNative(ctx, request_id, req.body),
        .audio_voices, .voices => voiceList(ctx, request_id),
        .languages => languageList(ctx, request_id),
        .profiles => jsonResponse(.ok, "{\"object\":\"list\",\"data\":[{\"id\":\"cpu-default\",\"device\":\"cpu\",\"precision\":\"model-defined\"}],\"current\":\"cpu-default\",\"state\":\"single-profile\"}", request_id),
        .profile_switch => errorResponse(ctx, request_id, .conflict, "PROFILE_SWITCH_UNAVAILABLE", "Die CPU-Engine besitzt aktuell nur ein festes Profil.", "conflict_error", false),
        .cancel => errorResponse(ctx, request_id, .not_implemented, "CANCEL_NOT_IMPLEMENTED", "Der native Engine-Adapter unterstützt noch keinen Abbruch einer laufenden C-ABI-Synthese.", "not_implemented", false),
        .pronunciation_list => pronunciationList(ctx, request_id),
        .pronunciation_upsert => pronunciationUpsert(ctx, request_id, req.body),
        .pronunciation_delete => pronunciationDelete(ctx, request_id, req.target),
        .pronunciation_test => pronunciationTest(ctx, request_id, req.body),
        .selftest => selfTest(ctx, request_id),
        .logs => logsResponse(ctx, request_id, req.target),
        .reload => reloadAll(ctx, request_id),
        .benchmark => benchmark(ctx, request_id, req.body),
        .realtime => errorResponse(ctx, request_id, .upgrade_required, "WEBSOCKET_UPGRADE_REQUIRED", "Dieser Pfad benötigt ein gültiges WebSocket-Upgrade.", "protocol_error", false),
        .openapi => jsonResponse(.ok, openapi_document, request_id),
        .swagger_docs => htmlResponse(docs_html, request_id),
        .redoc => htmlResponse(redoc_html, request_id),
        .frontend => jsonResponse(.service_unavailable, json_ui_not_built, request_id),
        .method_not_allowed => errorResponse(ctx, request_id, .method_not_allowed, "METHOD_NOT_ALLOWED", "Diese HTTP-Methode wird für den Pfad nicht unterstützt.", "invalid_request_error", false),
        .not_found => errorResponse(ctx, request_id, .not_found, "NOT_FOUND", "Der angeforderte Endpunkt existiert nicht.", "not_found", false),
    };
    if (@intFromEnum(response.status) >= 400) _ = ctx.errors.fetchAdd(1, .monotonic);
    const elapsed = @max(@as(i96, 0), started.durationTo(std.Io.Clock.awake.now(ctx.io)).nanoseconds);
    ctx.record(.{
        .request_id = request_id,
        .method = req.method,
        .route = route,
        .status = @intCast(@intFromEnum(response.status)),
        .elapsed_ms = @intCast(@min(@as(i96, std.math.maxInt(u32)), @divTrunc(elapsed, 1_000_000))),
    });
    return response;
}

fn jsonResponse(status: std.http.Status, body: []const u8, request_id: u64) Response {
    return .{ .status = status, .body = body, .request_id = request_id };
}

fn textResponse(status: std.http.Status, body: []const u8, request_id: u64) Response {
    return .{ .status = status, .content_type = "text/plain; charset=utf-8", .body = body, .request_id = request_id };
}

fn htmlResponse(body: []const u8, request_id: u64) Response {
    return .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = body, .request_id = request_id };
}

fn errorResponse(
    ctx: *Context,
    request_id: u64,
    status: std.http.Status,
    code: []const u8,
    message: []const u8,
    kind: []const u8,
    retryable: bool,
) Response {
    const body = std.fmt.allocPrint(
        ctx.gpa,
        "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\",\"type\":\"{s}\",\"request_id\":\"req_{x}\",\"retryable\":{s},\"details\":{{}}}}}}",
        .{ code, message, kind, request_id, if (retryable) "true" else "false" },
    ) catch return .{ .status = .internal_server_error, .body = "{\"error\":{\"code\":\"OUT_OF_MEMORY\"}}", .request_id = request_id };
    return .{ .status = status, .body = body, .owned = true, .request_id = request_id };
}

fn readyResponse(ctx: *Context, request_id: u64) Response {
    const model_id = ctx.engine.activeModelId() orelse "";
    const body = std.fmt.allocPrint(
        ctx.gpa,
        "{{\"status\":\"ready\",\"engine\":\"bkg-tts\",\"model\":\"{s}\",\"sample_rate\":{d}}}",
        .{ model_id, ctx.engine.sampleRate() },
    ) catch return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    return .{ .body = body, .owned = true, .request_id = request_id };
}

fn systemResponse(ctx: *Context, request_id: u64) Response {
    const state_name = @tagName(ctx.engine.getState());
    const request_count = ctx.requests.load(.monotonic);
    const model_id = ctx.engine.activeModelId() orelse "";
    const body = std.fmt.allocPrint(
        ctx.gpa,
        "{{\"status\":\"{s}\",\"server\":{{\"version\":\"0.1.0\",\"name\":\"bkg-tts\"}},\"remote\":false,\"model\":{{\"model_id\":\"{s}\",\"state\":\"{s}\",\"profile\":\"cpu-default\",\"precision\":\"model-defined\",\"device\":\"cpu\",\"revision\":\"onnxruntime\",\"loaded\":{s}}},\"gpu\":{{\"device\":\"cpu\",\"used_mb\":null,\"total_mb\":null,\"utilization\":null}},\"runtime\":{{\"active_sessions\":0,\"queue_depth\":0,\"completed\":0,\"cancelled\":0}},\"stats\":{{\"requests\":{d},\"errors\":{d},\"cancelled\":0}}}}",
        .{ if (ctx.engine.isActive()) "ready" else if (ctx.engine.getState() == .loading) "loading" else "not_ready", model_id, state_name, if (ctx.engine.isActive()) "true" else "false", request_count, ctx.errors.load(.monotonic) },
    ) catch return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    return .{ .body = body, .owned = true, .request_id = request_id };
}

fn metricsResponse(ctx: *Context, request_id: u64) Response {
    const body = std.fmt.allocPrint(
        ctx.gpa,
        "# HELP bkg_tts_requests_total HTTP-Anfragen seit Prozessstart\n# TYPE bkg_tts_requests_total counter\nbkg_tts_requests_total {d}\n# HELP bkg_tts_errors_total HTTP-Fehler seit Prozessstart\n# TYPE bkg_tts_errors_total counter\nbkg_tts_errors_total {d}\n# HELP bkg_tts_model_ready Modell geladen\n# TYPE bkg_tts_model_ready gauge\nbkg_tts_model_ready {d}\n",
        .{ ctx.requests.load(.monotonic), ctx.errors.load(.monotonic), if (ctx.engine.isActive()) @as(u8, 1) else @as(u8, 0) },
    ) catch return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    var response = textResponse(.ok, body, request_id);
    response.owned = true;
    return response;
}

/// Ein Modell in der Antwort von `/v1/models`.
const ModelItem = struct {
    id: []const u8,
    object: []const u8 = "model",
    owned_by: []const u8 = "bkg-tts",
    name: []const u8,
    version: []const u8,
    language: []const u8,
    sample_rate: u32,
    loaded: bool,
    state: []const u8,
};

fn modelList(ctx: *Context, request_id: u64) Response {
    const infos = ctx.engine.modelInfos(ctx.gpa) catch |err| {
        return engineError(ctx, request_id, err);
    };
    defer engine_mod.freeModelInfos(ctx.gpa, infos);

    const items = ctx.gpa.alloc(ModelItem, infos.len) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    defer ctx.gpa.free(items);

    for (infos, 0..) |info, index| {
        items[index] = .{
            .id = info.id,
            .name = info.name,
            .version = info.version,
            .language = info.language,
            .sample_rate = info.sample_rate,
            .loaded = info.active,
            .state = if (info.active) "active" else "available",
        };
    }

    const body = std.json.Stringify.valueAlloc(ctx.gpa, .{ .object = "list", .data = items }, .{}) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .body = body, .owned = true, .request_id = request_id };
}

fn modelDetail(ctx: *Context, request_id: u64, path: []const u8) Response {
    const id = path["/v1/models/".len..];
    const infos = ctx.engine.modelInfos(ctx.gpa) catch |err| {
        return engineError(ctx, request_id, err);
    };
    defer engine_mod.freeModelInfos(ctx.gpa, infos);

    for (infos) |info| {
        if (!std.mem.eql(u8, info.id, id)) continue;
        const item = ModelItem{
            .id = info.id,
            .name = info.name,
            .version = info.version,
            .language = info.language,
            .sample_rate = info.sample_rate,
            .loaded = info.active,
            .state = if (info.active) "active" else "available",
        };
        const body = std.json.Stringify.valueAlloc(ctx.gpa, item, .{}) catch {
            return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
        };
        return .{ .body = body, .owned = true, .request_id = request_id };
    }

    return errorResponse(ctx, request_id, .not_found, "MODEL_NOT_FOUND", "Das angeforderte Modell ist unbekannt.", "not_found", false);
}

/// Eine Stimme in der Antwort der Stimmendpunkte.
const VoiceItem = struct {
    id: []const u8,
    object: []const u8 = "voice",
    name: []const u8,
    aliases: []const []const u8,
    default: bool,
};

fn voiceList(ctx: *Context, request_id: u64) Response {
    const voices = ctx.engine.voiceInfos(ctx.gpa) catch |err| {
        return engineError(ctx, request_id, err);
    };
    defer engine_mod.freeVoiceInfos(ctx.gpa, voices);

    const items = ctx.gpa.alloc(VoiceItem, voices.len) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    defer ctx.gpa.free(items);

    for (voices, 0..) |voice, index| {
        items[index] = .{
            .id = voice.name,
            .name = voice.name,
            .aliases = voice.aliases,
            .default = index == 0,
        };
    }

    const body = std.json.Stringify.valueAlloc(ctx.gpa, .{ .object = "list", .data = items }, .{}) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .body = body, .owned = true, .request_id = request_id };
}

/// Eine Sprache in der Antwort des Sprachenendpunkts.
const LanguageItem = struct {
    id: []const u8,
    object: []const u8 = "language",
    name: []const u8,
};

fn languageList(ctx: *Context, request_id: u64) Response {
    const languages = ctx.engine.languages(ctx.gpa) catch |err| {
        return engineError(ctx, request_id, err);
    };
    defer engine_mod.freeStrings(ctx.gpa, languages);

    const items = ctx.gpa.alloc(LanguageItem, languages.len) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    defer ctx.gpa.free(items);

    for (languages, 0..) |language, index| {
        items[index] = .{ .id = language, .name = language };
    }

    const body = std.json.Stringify.valueAlloc(ctx.gpa, .{ .object = "list", .data = items }, .{}) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .body = body, .owned = true, .request_id = request_id };
}

/// Bildet einen Fehler der Engine auf eine HTTP-Antwort ab.
fn engineError(ctx: *Context, request_id: u64, err: anyerror) Response {
    return switch (err) {
        error.UnknownModel => errorResponse(ctx, request_id, .not_found, "MODEL_NOT_FOUND", "Das angeforderte Modell ist unbekannt.", "not_found", false),
        error.ModelNotReady, error.NoModel => errorResponse(ctx, request_id, .service_unavailable, "MODEL_NOT_READY", "Es ist noch kein Modell geladen.", "service_unavailable", true),
        error.ModelLoadFailed, error.RuntimeUnavailable, error.RegistryUnavailable => errorResponse(ctx, request_id, .service_unavailable, "MODEL_LOAD_FAILED", "Das Modell liess sich nicht laden.", "service_unavailable", true),
        error.UnsupportedBackend => errorResponse(ctx, request_id, .not_implemented, "UNSUPPORTED_BACKEND", "Der Verarbeitungsweg des Modells ist noch nicht umgesetzt.", "not_implemented", false),
        error.OutOfMemory => errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false),
        else => errorResponse(ctx, request_id, .internal_server_error, "ENGINE_ERROR", "Die Engine meldet einen Fehler.", "server_error", false),
    };
}

const LogRecord = struct {
    request_id: u64 = 0,
    method: std.http.Method = .GET,
    route: router.Route = .health,
    status: u16 = 0,
    elapsed_ms: u32 = 0,
};

fn pronunciationList(ctx: *Context, request_id: u64) Response {
    const entries = ctx.pronunciation.listJson() catch {
        return errorResponse(ctx, request_id, .internal_server_error, "PRONUNCIATION_READ_FAILED", "Das Aussprachewörterbuch konnte nicht gelesen werden.", "server_error", false);
    };
    defer ctx.gpa.free(entries);
    const body = std.fmt.allocPrint(ctx.gpa, "{{\"object\":\"list\",\"data\":{s}}}", .{entries}) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .body = body, .owned = true, .request_id = request_id };
}

fn pronunciationUpsert(ctx: *Context, request_id: u64, body: []const u8) Response {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch {
        return errorResponse(ctx, request_id, .bad_request, "INVALID_JSON", "Der Request-Body ist kein gültiges JSON.", "validation_error", false);
    };
    defer parsed.deinit();

    const word = stringField(parsed.value, "word", "");
    const language = stringField(parsed.value, "language", "en");
    const ipa = stringField(parsed.value, "ipa", "");
    const enabled = boolField(parsed.value, "enabled", true);
    if (word.len == 0 or ipa.len == 0) {
        return errorResponse(ctx, request_id, .unprocessable_entity, "INVALID_PRONUNCIATION", "Die Felder word und ipa sind erforderlich.", "validation_error", false);
    }
    const result = ctx.pronunciation.upsert(word, language, ipa, enabled) catch |err| {
        return errorResponse(ctx, request_id, .unprocessable_entity, "INVALID_PRONUNCIATION", if (err == error.InvalidEntry) "Der Wörterbucheintrag überschreitet die Feldgrenzen." else "Der Wörterbucheintrag konnte nicht gespeichert werden.", "validation_error", false);
    };
    return .{ .body = result, .owned = true, .request_id = request_id };
}

fn pronunciationDelete(ctx: *Context, request_id: u64, target: []const u8) Response {
    const path = pathOnly(target);
    const prefix = "/api/tts/pronunciation/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        return errorResponse(ctx, request_id, .bad_request, "INVALID_PRONUNCIATION_PATH", "Das Wort im Pfad fehlt.", "validation_error", false);
    }
    const encoded_word = path[prefix.len..];
    const word = urlDecode(ctx.gpa, encoded_word) catch {
        return errorResponse(ctx, request_id, .bad_request, "INVALID_PATH_ENCODING", "Der Pfad enthält eine ungültige Prozentkodierung.", "validation_error", false);
    };
    defer ctx.gpa.free(word);
    const language = queryValue(target, "language") orelse "en";
    const deleted = ctx.pronunciation.delete(word, language) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "PRONUNCIATION_WRITE_FAILED", "Das Aussprachewörterbuch konnte nicht gespeichert werden.", "server_error", false);
    };
    if (!deleted) return errorResponse(ctx, request_id, .not_found, "PRONUNCIATION_NOT_FOUND", "Für dieses Wort und diese Sprache existiert kein Eintrag.", "not_found", false);
    const response_body = std.json.Stringify.valueAlloc(ctx.gpa, .{ .status = "deleted", .word = word, .language = language }, .{}) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .body = response_body, .owned = true, .request_id = request_id };
}

fn pronunciationTest(ctx: *Context, request_id: u64, body: []const u8) Response {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch {
        return errorResponse(ctx, request_id, .bad_request, "INVALID_JSON", "Der Request-Body ist kein gültiges JSON.", "validation_error", false);
    };
    defer parsed.deinit();
    const word = stringField(parsed.value, "word", "");
    const language = stringField(parsed.value, "language", "");
    if (word.len == 0) return errorResponse(ctx, request_id, .unprocessable_entity, "EMPTY_WORD", "Das Feld word darf nicht leer sein.", "validation_error", false);
    if (field(parsed.value, "ipa") == .string and field(parsed.value, "ipa").string.len > 0) {
        const ipa = field(parsed.value, "ipa").string;
        const target_language = if (language.len > 0) language else ctx.engine.activeLanguage(ctx.gpa) catch "";
        const saved = ctx.pronunciation.upsert(word, target_language, ipa, true) catch {
            return errorResponse(ctx, request_id, .unprocessable_entity, "INVALID_PRONUNCIATION", "Der Ausspracheeintrag konnte nicht gespeichert werden.", "validation_error", false);
        };
        ctx.gpa.free(saved);
    }
    return synthesize(ctx, request_id, word, language, "", "wav", 1.0);
}

fn selfTest(ctx: *Context, request_id: u64) Response {
    if (!ctx.engine.isActive()) return errorResponse(ctx, request_id, .service_unavailable, "MODEL_NOT_READY", "Der Selbsttest benötigt ein geladenes Modell.", "service_unavailable", true);
    const language = ctx.engine.activeLanguage(ctx.gpa) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "MODEL_LANGUAGE_UNKNOWN", "Die Sprache des aktiven Modells ist unbekannt.", "server_error", false);
    };
    defer ctx.gpa.free(language);

    const started = std.Io.Clock.awake.now(ctx.io);
    const result = ctx.engine.synthesizeFor(ctx.gpa, testText(language), language, "", 1.0) catch |err| {
        const message = std.fmt.allocPrint(ctx.gpa, "Der Selftest-Aufruf zur Sprachsynthese ist fehlgeschlagen: {s}.", .{@errorName(err)}) catch {
            return errorResponse(ctx, request_id, .internal_server_error, "SELFTEST_SYNTHESIS_FAILED", "Der Selftest-Aufruf zur Sprachsynthese ist fehlgeschlagen.", "server_error", false);
        };
        defer ctx.gpa.free(message);
        return errorResponse(ctx, request_id, .internal_server_error, "SELFTEST_SYNTHESIS_FAILED", message, "server_error", false);
    };
    defer ctx.gpa.free(result.pcm);
    var nonzero: usize = 0;
    var peak: f32 = 0;
    var sum_squares: f64 = 0;
    for (result.pcm) |sample| {
        if (sample != 0) nonzero += 1;
        peak = @max(peak, @abs(sample));
        const value: f64 = sample;
        sum_squares += value * value;
    }
    const rms = if (result.pcm.len == 0) 0 else @sqrt(sum_squares / @as(f64, @floatFromInt(result.pcm.len)));
    const elapsed_ns = @max(@as(i96, 0), started.durationTo(std.Io.Clock.awake.now(ctx.io)).nanoseconds);
    const passed = result.pcm.len >= result.sample_rate / 10 and nonzero > 0 and peak > 0.001 and rms > 0.0001;
    const duration_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const message = std.fmt.allocPrint(ctx.gpa, "Das Modell {s} erzeugte {d} mono Samples bei {d} Hz; nonzero={d}, peak={d:.5}, RMS={d:.5}", .{ ctx.engine.activeModelId() orelse "", result.pcm.len, result.sample_rate, nonzero, peak, rms }) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    defer ctx.gpa.free(message);
    const body = std.json.Stringify.valueAlloc(ctx.gpa, .{
        .status = if (passed) "passed" else "failed",
        .passed = if (passed) @as(usize, 1) else 0,
        .total = @as(usize, 1),
        .failed = if (passed) @as(usize, 0) else 1,
        .results = .{.{
            .name = "test_native_generation",
            .passed = passed,
            .message = message,
            .duration_ms = duration_ms,
        }},
        .engine = "bkg-tts",
        .device = "cpu",
        .sample_rate = result.sample_rate,
        .samples = result.pcm.len,
        .duration_s = @as(f64, @floatFromInt(result.pcm.len)) / @as(f64, @floatFromInt(result.sample_rate)),
        .nonzero_samples = nonzero,
        .peak = peak,
        .rms = rms,
        .generation_ms = duration_ms,
    }, .{}) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .status = if (passed) .ok else .internal_server_error, .body = body, .owned = true, .request_id = request_id };
}

fn logsResponse(ctx: *Context, request_id: u64, target: []const u8) Response {
    var limit: usize = 200;
    if (queryValue(target, "lines")) |raw| {
        limit = std.fmt.parseInt(usize, raw, 10) catch 200;
    }
    limit = @min(@max(limit, 1), 128);
    const records = ctx.logsJson(limit) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "LOG_READ_FAILED", "Die Request-Logs konnten nicht gelesen werden.", "server_error", false);
    };
    const body = std.fmt.allocPrint(ctx.gpa, "{{\"lines\":{s}}}", .{records}) catch {
        ctx.gpa.free(records);
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    ctx.gpa.free(records);
    return .{ .body = body, .owned = true, .request_id = request_id };
}

/// Lädt das Aussprachewörterbuch und die Modell-Registry neu.
///
/// Die Registry meldet, welche Modelle hinzugekommen, sich geändert oder
/// verschwunden sind. Ein geändertes aktives Modell wird dabei neu geladen.
fn reloadAll(ctx: *Context, request_id: u64) Response {
    ctx.pronunciation.load() catch {
        return errorResponse(ctx, request_id, .internal_server_error, "PRONUNCIATION_RELOAD_FAILED", "Das Aussprachewörterbuch ist ungültig oder nicht lesbar.", "server_error", false);
    };

    var changes = ctx.engine.reload() catch |err| {
        const message = std.fmt.allocPrint(ctx.gpa, "Die Modell-Registry konnte nicht neu gelesen werden: {s}.", .{@errorName(err)}) catch {
            return errorResponse(ctx, request_id, .internal_server_error, "MODEL_RELOAD_FAILED", "Die Modell-Registry konnte nicht neu gelesen werden.", "server_error", false);
        };
        defer ctx.gpa.free(message);
        return errorResponse(ctx, request_id, .internal_server_error, "MODEL_RELOAD_FAILED", message, "server_error", false);
    };
    defer changes.deinit();

    // Die Kennungen der Modelle stehen in Deskriptoren. Der JSON-Writer
    // escaped sie, falls ein Deskriptor ein unerwartetes Zeichen benutzt.
    const summary = ReloadSummary{
        .status = "reloaded",
        .scope = "models_and_pronunciation_dictionary",
        .added = changes.added,
        .changed = changes.changed,
        .removed = changes.removed,
        .active_model = ctx.engine.activeModelId(),
    };
    const body = std.json.Stringify.valueAlloc(ctx.gpa, summary, .{}) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .body = body, .owned = true, .request_id = request_id };
}

/// Antwort auf `/api/reload`.
const ReloadSummary = struct {
    status: []const u8,
    scope: []const u8,
    added: []const []const u8,
    changed: []const []const u8,
    removed: []const []const u8,
    active_model: ?[]const u8,
};

fn benchmark(ctx: *Context, request_id: u64, body: []const u8) Response {
    if (!ctx.engine.isActive()) return errorResponse(ctx, request_id, .service_unavailable, "MODEL_NOT_READY", "Der Benchmark benötigt ein geladenes Modell.", "service_unavailable", true);

    const model_language = ctx.engine.activeLanguage(ctx.gpa) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "MODEL_LANGUAGE_UNKNOWN", "Die Sprache des aktiven Modells ist unbekannt.", "server_error", false);
    };
    defer ctx.gpa.free(model_language);

    var text: []const u8 = testText(model_language);
    var language: []const u8 = model_language;
    var voice: []const u8 = "";
    var iterations: usize = 1;

    if (body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch {
            return errorResponse(ctx, request_id, .bad_request, "INVALID_JSON", "Der Request-Body ist kein gültiges JSON.", "validation_error", false);
        };
        defer parsed.deinit();
        if (stringField(parsed.value, "text", "").len > 0) text = stringField(parsed.value, "text", text);
        if (stringField(parsed.value, "language", "").len > 0) language = stringField(parsed.value, "language", language);
        voice = stringField(parsed.value, "voice", voice);
        const requested = numberField(parsed.value, "iterations", 1);
        if (requested < 1 or requested > 10 or @floor(requested) != requested) {
            return errorResponse(ctx, request_id, .unprocessable_entity, "INVALID_ITERATIONS", "iterations muss eine ganze Zahl zwischen 1 und 10 sein.", "validation_error", false);
        }
        iterations = @intFromFloat(requested);

        const profile = stringField(parsed.value, "profile", "cpu-default");
        if (!std.mem.eql(u8, profile, "cpu-default")) return errorResponse(ctx, request_id, .conflict, "PROFILE_SWITCH_UNAVAILABLE", "Die Engine besitzt nur das Profil cpu-default.", "conflict_error", false);
        if (numberField(parsed.value, "concurrent_users", 1) != 1) return errorResponse(ctx, request_id, .unprocessable_entity, "CPU_BENCHMARK_SERIAL_ONLY", "Der Benchmark serialisiert die Anfragen absichtlich über den einzigen Modellkontext; concurrent_users muss 1 sein.", "validation_error", false);
        if (boolField(parsed.value, "streaming", false)) return errorResponse(ctx, request_id, .unprocessable_entity, "STREAMING_BENCHMARK_UNAVAILABLE", "Tokenweises Inferenz-Streaming wird von der Engine nicht angeboten.", "validation_error", false);
    }

    var generation_ms: f64 = 0;
    var audio_seconds: f64 = 0;
    var successful: usize = 0;
    var timings: std.ArrayList(f64) = .empty;
    defer timings.deinit(ctx.gpa);
    for (0..iterations) |_| {
        const started = std.Io.Clock.awake.now(ctx.io);
        const result = ctx.engine.synthesizeFor(ctx.gpa, text, language, voice, 1.0) catch |err| {
            return switch (err) {
                error.VoiceNotFound => errorResponse(ctx, request_id, .unprocessable_entity, "INVALID_VOICE", "Das Modell kennt die angeforderte Stimme nicht.", "validation_error", false),
                error.LanguageMismatch => errorResponse(ctx, request_id, .unprocessable_entity, "UNSUPPORTED_LANGUAGE", "Das Modell versteht die angeforderte Sprache nicht.", "validation_error", false),
                else => errorResponse(ctx, request_id, .internal_server_error, "BENCHMARK_SYNTHESIS_FAILED", "Eine echte Synthese im Benchmark ist fehlgeschlagen.", "server_error", false),
            };
        };
        const elapsed_ns = @max(@as(i96, 0), started.durationTo(std.Io.Clock.awake.now(ctx.io)).nanoseconds);
        const sample_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        generation_ms += sample_ms;
        timings.append(ctx.gpa, sample_ms) catch {
            ctx.gpa.free(result.pcm);
            return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler beim Benchmark.", "server_error", false);
        };
        audio_seconds += @as(f64, @floatFromInt(result.pcm.len)) / @as(f64, @floatFromInt(result.sample_rate));
        if (result.pcm.len > 0) successful += 1;
        ctx.gpa.free(result.pcm);
    }
    std.mem.sort(f64, timings.items, {}, comptime std.sort.asc(f64));
    const p50 = percentile(timings.items, 0.50);
    const p95 = percentile(timings.items, 0.95);
    const p99 = percentile(timings.items, 0.99);
    const total_runtime_s = generation_ms / 1000.0;
    const body_json = std.json.Stringify.valueAlloc(ctx.gpa, .{
        .status = "completed",
        .profile = "cpu-default",
        .language = language,
        .concurrent_users = 1,
        .iterations = iterations,
        .streaming = false,
        .generation_p50_ms = p50,
        .generation_p95_ms = p95,
        .generation_p99_ms = p99,
        .generation_ms_total = generation_ms,
        .generation_ms_average = generation_ms / @as(f64, @floatFromInt(iterations)),
        .audio_duration_s = audio_seconds,
        .rtf = if (audio_seconds > 0) generation_ms / 1000.0 / audio_seconds else 0.0,
        .requests_per_sec = if (total_runtime_s > 0) @as(f64, @floatFromInt(successful)) / total_runtime_s else 0.0,
        .peak_vram_mb = @as(?f64, null),
        .avg_vram_mb = @as(?f64, null),
        .gpu_util_pct = @as(?f64, null),
        .gpu_temp_c = @as(?f64, null),
        .failures = iterations - successful,
        .error_codes = [_][]const u8{},
    }, .{}) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .body = body_json, .owned = true, .request_id = request_id };
}

fn percentile(values: []const f64, p: f64) f64 {
    if (values.len == 0) return 0;
    const index = @min(values.len - 1, @as(usize, @intFromFloat(@ceil(p * @as(f64, @floatFromInt(values.len))) - 1)));
    return values[index];
}

fn pathOnly(target: []const u8) []const u8 {
    return target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
}

fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const query_start = (std.mem.indexOfScalar(u8, target, '?') orelse return null) + 1;
    var iter = std.mem.splitScalar(u8, target[query_start..], '&');
    while (iter.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], name)) return part[eq + 1 ..];
    }
    return null;
}

fn urlDecode(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '%') {
            if (i + 2 >= value.len) return error.InvalidPercentEncoding;
            const hi = std.fmt.charToDigit(value[i + 1], 16) catch return error.InvalidPercentEncoding;
            const lo = std.fmt.charToDigit(value[i + 2], 16) catch return error.InvalidPercentEncoding;
            try output.append(gpa, @intCast(hi * 16 + lo));
            i += 2;
        } else if (value[i] == '+') {
            try output.append(gpa, ' ');
        } else {
            try output.append(gpa, value[i]);
        }
    }
    return try output.toOwnedSlice(gpa);
}

pub fn applyPronunciations(ctx: *Context, text: []const u8, language: []const u8) ![]u8 {
    return ctx.pronunciation.apply(text, language);
}

fn synthesizeOpenAI(ctx: *Context, request_id: u64, body: []const u8) Response {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch {
        return errorResponse(ctx, request_id, .bad_request, "INVALID_JSON", "Der Request-Body ist kein gültiges JSON.", "validation_error", false);
    };
    defer parsed.deinit();
    const root = parsed.value;
    const input = stringField(root, "input", "");
    if (input.len == 0) return errorResponse(ctx, request_id, .unprocessable_entity, "EMPTY_INPUT", "Das Feld input darf nicht leer sein.", "validation_error", false);
    if (input.len > limits.max_text_chars) return errorResponse(ctx, request_id, .unprocessable_entity, "INPUT_TOO_LONG", "Der Text überschreitet " ++ limits.max_text_text ++ " Zeichen.", "validation_error", false);
    if (boolField(root, "stream", false)) return errorResponse(ctx, request_id, .not_implemented, "HTTP_STREAM_NOT_IMPLEMENTED", "HTTP-Audio-Streaming wird noch portiert; nutze vorerst die synchronen WAV/PCM-Antworten.", "not_implemented", false);

    const model = stringField(root, "model", "");
    if (selectModel(ctx, request_id, model)) |failure| return failure;

    const speed = numberField(root, "speed", 1.0);
    if (!limits.speedAllowed(@floatCast(speed))) {
        return errorResponse(ctx, request_id, .unprocessable_entity, "INVALID_SPEED", "Das Feld speed muss " ++ limits.speed_range_text ++ " liegen.", "validation_error", false);
    }
    if (field(root, "sample_rate") != .null) {
        const requested = numberField(root, "sample_rate", 0);
        if (@abs(requested - @as(f64, @floatFromInt(ctx.engine.sampleRate()))) > 0.0001) {
            return unsupportedSetting(ctx, request_id, "sample_rate");
        }
    }
    if (!boolField(root, "cfg_enabled", true) or @abs(numberField(root, "cfg_scale", 2.5) - 2.5) > 0.0001) return unsupportedSetting(ctx, request_id, "CFG");
    if (boolField(root, "text_normalization", false)) return unsupportedSetting(ctx, request_id, "text_normalization");

    const format = stringField(root, "response_format", "wav");
    return synthesize(ctx, request_id, input, stringField(root, "language", ""), stringField(root, "voice", ""), format, @floatCast(speed));
}

fn synthesizeNative(ctx: *Context, request_id: u64, body: []const u8) Response {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.gpa, body, .{}) catch {
        return errorResponse(ctx, request_id, .bad_request, "INVALID_JSON", "Der Request-Body ist kein gültiges JSON.", "validation_error", false);
    };
    defer parsed.deinit();
    const root = parsed.value;
    const input = stringField(root, "text", "");
    if (input.len == 0) return errorResponse(ctx, request_id, .unprocessable_entity, "EMPTY_INPUT", "Das Feld text darf nicht leer sein.", "validation_error", false);
    if (input.len > limits.max_text_chars) return errorResponse(ctx, request_id, .unprocessable_entity, "INPUT_TOO_LONG", "Der Text überschreitet " ++ limits.max_text_text ++ " Zeichen.", "validation_error", false);

    const model = stringField(root, "model", "");
    if (selectModel(ctx, request_id, model)) |failure| return failure;

    const speed = numberField(root, "speed", 1.0);
    if (!limits.speedAllowed(@floatCast(speed))) {
        return errorResponse(ctx, request_id, .unprocessable_entity, "INVALID_SPEED", "Das Feld speed muss " ++ limits.speed_range_text ++ " liegen.", "validation_error", false);
    }

    const audio_field = field(root, "audio");
    const format = stringField(audio_field, "format", "wav");
    if (field(audio_field, "sample_rate") != .null) {
        const requested = numberField(audio_field, "sample_rate", 0);
        if (@abs(requested - @as(f64, @floatFromInt(ctx.engine.sampleRate()))) > 0.0001) {
            return unsupportedSetting(ctx, request_id, "audio.sample_rate");
        }
    }
    const cfg = field(root, "cfg");
    if (field(cfg, "enabled") != .null and !boolField(cfg, "enabled", true)) return unsupportedSetting(ctx, request_id, "cfg.enabled");
    if (@abs(numberField(cfg, "scale", 2.5) - 2.5) > 0.0001) return unsupportedSetting(ctx, request_id, "cfg.scale");
    if (boolField(root, "text_normalization", false)) return unsupportedSetting(ctx, request_id, "text_normalization");
    if (boolField(root, "stream", false)) return errorResponse(ctx, request_id, .not_implemented, "HTTP_STREAM_NOT_IMPLEMENTED", "HTTP-Audio-Streaming wird noch portiert.", "not_implemented", false);

    return synthesize(ctx, request_id, input, stringField(root, "language", ""), stringField(root, "speaker", ""), format, @floatCast(speed));
}

/// Wechselt das aktive Modell, wenn die Anfrage ein anderes nennt.
///
/// Ohne Angabe bleibt das aktive Modell aktiv.
fn selectModel(ctx: *Context, request_id: u64, model: []const u8) ?Response {
    if (model.len == 0) return null;
    if (ctx.engine.activeModelId()) |current| {
        if (std.mem.eql(u8, current, model)) return null;
    }
    ctx.engine.setActive(model) catch |err| {
        return engineError(ctx, request_id, err);
    };
    return null;
}

fn synthesize(
    ctx: *Context,
    request_id: u64,
    text: []const u8,
    language: []const u8,
    voice: []const u8,
    format: []const u8,
    speed: f32,
) Response {
    if (!ctx.engine.isActive()) return errorResponse(ctx, request_id, .service_unavailable, "MODEL_NOT_READY", "Es ist noch kein Modell geladen.", "service_unavailable", true);
    if (!std.mem.eql(u8, format, "wav") and !std.mem.eql(u8, format, "pcm")) {
        return errorResponse(ctx, request_id, .unprocessable_entity, "UNSUPPORTED_FORMAT", "Aktuell sind nur wav und pcm verfügbar; mp3/opus/flac/aac benötigen noch einen nativen Encoder.", "validation_error", false);
    }

    // Ohne Angabe gilt die Sprache des aktiven Modells.
    const effective_language = resolveLanguage(ctx, language) catch {
        return errorResponse(ctx, request_id, .service_unavailable, "MODEL_NOT_READY", "Die Sprache des aktiven Modells ist unbekannt.", "service_unavailable", true);
    };
    defer ctx.gpa.free(effective_language);

    const spoken_text = ctx.pronunciation.apply(text, effective_language) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "PRONUNCIATION_APPLY_FAILED", "Die Aussprache-Regeln konnten nicht angewendet werden.", "server_error", false);
    };
    defer ctx.gpa.free(spoken_text);

    const result = ctx.engine.synthesizeFor(ctx.gpa, spoken_text, effective_language, voice, speed) catch |err| {
        return switch (err) {
            error.VoiceNotFound => errorResponse(ctx, request_id, .unprocessable_entity, "INVALID_VOICE", "Das Modell kennt die angeforderte Stimme nicht.", "validation_error", false),
            error.LanguageMismatch => errorResponse(ctx, request_id, .unprocessable_entity, "UNSUPPORTED_LANGUAGE", "Das Modell versteht die angeforderte Sprache nicht.", "validation_error", false),
            error.ModelNotReady => errorResponse(ctx, request_id, .service_unavailable, "MODEL_NOT_READY", "Es ist noch kein Modell geladen.", "service_unavailable", true),
            error.OutOfMemory => errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false),
            else => errorResponse(ctx, request_id, .internal_server_error, "SYNTHESIS_FAILED", "Die Synthese ist fehlgeschlagen.", "server_error", true),
        };
    };
    defer ctx.gpa.free(result.pcm);

    if (std.mem.eql(u8, format, "wav")) {
        const data = audio.encodeWav(ctx.gpa, result.pcm, result.sample_rate) catch {
            return errorResponse(ctx, request_id, .internal_server_error, "AUDIO_ENCODING_FAILED", "Die WAV-Kodierung ist fehlgeschlagen.", "server_error", false);
        };
        return .{ .status = .ok, .content_type = "audio/wav", .body = data, .owned = true, .request_id = request_id };
    }

    const bytes = audio.encodePcm16(ctx.gpa, result.pcm) catch {
        return errorResponse(ctx, request_id, .internal_server_error, "AUDIO_ENCODING_FAILED", "Die PCM-Kodierung ist fehlgeschlagen.", "server_error", false);
    };
    const content_type = std.fmt.allocPrint(ctx.gpa, "audio/pcm;rate={d};channels=1", .{result.sample_rate}) catch {
        ctx.gpa.free(bytes);
        return errorResponse(ctx, request_id, .internal_server_error, "OUT_OF_MEMORY", "Speicherfehler.", "server_error", false);
    };
    return .{ .status = .ok, .content_type = content_type, .owned_content_type = true, .body = bytes, .owned = true, .request_id = request_id };
}

/// Die Sprache einer Anfrage. Ohne Angabe gilt die Sprache des Modells.
///
/// Der Aufrufer gibt den Text wieder frei.
fn resolveLanguage(ctx: *Context, requested: []const u8) ![]u8 {
    if (requested.len > 0) return ctx.gpa.dupe(u8, requested);
    return ctx.engine.activeLanguage(ctx.gpa);
}

fn unsupportedSetting(ctx: *Context, request_id: u64, name: []const u8) Response {
    const body = std.fmt.allocPrint(
        ctx.gpa,
        "{{\"error\":{{\"code\":\"UNSUPPORTED_SETTING\",\"message\":\"Die Einstellung {s} ist mit der vorhandenen C-ABI noch nicht verfügbar.\",\"type\":\"validation_error\",\"request_id\":\"req_{x}\",\"retryable\":false,\"details\":{{}}}}}}",
        .{ name, request_id },
    ) catch return .{ .status = .internal_server_error, .body = "{\"error\":{\"code\":\"OUT_OF_MEMORY\"}}", .request_id = request_id };
    return .{ .status = .unprocessable_entity, .body = body, .owned = true, .request_id = request_id };
}

/// Ein kurzer Text in der Sprache des Modells.
///
/// Der Text dient dem Selbsttest und dem Benchmark. Er nennt keine Stimme
/// und keine Modellfamilie.
fn testText(language: []const u8) []const u8 {
    const primary = primarySubtag(language);
    if (std.mem.eql(u8, primary, "de")) return "Guten Tag.";
    if (std.mem.eql(u8, primary, "fr")) return "Bonjour.";
    if (std.mem.eql(u8, primary, "es")) return "Buenos dias.";
    if (std.mem.eql(u8, primary, "it")) return "Buongiorno.";
    if (std.mem.eql(u8, primary, "pt")) return "Bom dia.";
    return "Hello world.";
}

/// Der erste Teil einer Sprachkennung, etwa "de" aus "de-DE".
fn primarySubtag(language: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, language, "-_") orelse language.len;
    return language[0..end];
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

test "test text follows the language of the model" {
    try std.testing.expectEqualStrings("Guten Tag.", testText("de"));
    try std.testing.expectEqualStrings("Guten Tag.", testText("de-DE"));
    try std.testing.expectEqualStrings("Hello world.", testText("en"));
    try std.testing.expectEqualStrings("Hello world.", testText(""));
}

test "primary subtag ignores the region" {
    try std.testing.expectEqualStrings("pt", primarySubtag("pt-BR"));
    try std.testing.expectEqualStrings("ar", primarySubtag("ar_msa"));
    try std.testing.expectEqualStrings("en", primarySubtag("en"));
}
