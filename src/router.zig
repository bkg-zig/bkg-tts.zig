//! HTTP route classification for the existing TTS API contract.
const std = @import("std");
const web_request = @import("web_request.zig");

pub const Route = enum {
    health,
    ready,
    system,
    metrics,
    models,
    model_detail,
    speech,
    cancel,
    audio_voices,
    voices,
    languages,
    native_generate,
    pronunciation_list,
    pronunciation_upsert,
    pronunciation_delete,
    pronunciation_test,
    profiles,
    profile_switch,
    selftest,
    logs,
    reload,
    benchmark,
    realtime,
    openapi,
    swagger_docs,
    redoc,
    frontend,
    not_found,
    method_not_allowed,
};

pub fn classify(method: std.http.Method, target: []const u8) Route {
    const path = (web_request.Request{
        .method = method,
        .target = target,
        .authorization = null,
        .body = "",
    }).path();

    if (std.mem.eql(u8, path, "/health")) return methodIs(method, .GET, .health);
    if (std.mem.eql(u8, path, "/ready")) return methodIs(method, .GET, .ready);
    if (std.mem.eql(u8, path, "/api/system")) return methodIs(method, .GET, .system);
    if (std.mem.eql(u8, path, "/metrics")) return methodIs(method, .GET, .metrics);
    if (std.mem.eql(u8, path, "/v1/models")) return methodIs(method, .GET, .models);
    if (std.mem.startsWith(u8, path, "/v1/models/")) return methodIs(method, .GET, .model_detail);
    if (std.mem.eql(u8, path, "/v1/audio/speech")) return methodIs(method, .POST, .speech);
    if (std.mem.eql(u8, path, "/v1/audio/cancel")) return methodIs(method, .POST, .cancel);
    if (std.mem.eql(u8, path, "/v1/audio/voices") or std.mem.eql(u8, path, "/v1/audio/list_voices")) return methodIs(method, .GET, .audio_voices);
    if (std.mem.eql(u8, path, "/api/voices") or std.mem.eql(u8, path, "/v1/voices")) return methodIs(method, .GET, .voices);
    if (std.mem.eql(u8, path, "/v1/languages") or std.mem.eql(u8, path, "/api/languages")) return methodIs(method, .GET, .languages);
    if (std.mem.eql(u8, path, "/api/tts/generate")) return methodIs(method, .POST, .native_generate);
    if (std.mem.eql(u8, path, "/api/tts/pronunciation")) {
        return switch (method) {
            .GET => .pronunciation_list,
            .POST => .pronunciation_upsert,
            else => .method_not_allowed,
        };
    }
    if (std.mem.startsWith(u8, path, "/api/tts/pronunciation/") and
        !std.mem.eql(u8, path, "/api/tts/pronunciation/test"))
    {
        return methodIs(method, .DELETE, .pronunciation_delete);
    }
    if (std.mem.eql(u8, path, "/api/tts/pronunciation/test")) return methodIs(method, .POST, .pronunciation_test);
    if (std.mem.eql(u8, path, "/api/profiles")) return methodIs(method, .GET, .profiles);
    if (std.mem.eql(u8, path, "/api/profiles/switch")) return methodIs(method, .POST, .profile_switch);
    if (std.mem.eql(u8, path, "/api/selftest")) return methodIs(method, .POST, .selftest);
    if (std.mem.eql(u8, path, "/api/logs")) return methodIs(method, .GET, .logs);
    if (std.mem.eql(u8, path, "/api/reload")) return methodIs(method, .POST, .reload);
    if (std.mem.eql(u8, path, "/api/benchmark")) return methodIs(method, .POST, .benchmark);
    if (std.mem.eql(u8, path, "/v1/realtime")) return methodIs(method, .GET, .realtime);
    if (std.mem.eql(u8, path, "/openapi.json")) return methodIs(method, .GET, .openapi);
    if (std.mem.eql(u8, path, "/docs")) return methodIs(method, .GET, .swagger_docs);
    if (std.mem.eql(u8, path, "/redoc")) return methodIs(method, .GET, .redoc);
    if (method == .GET and (std.mem.eql(u8, path, "/") or std.mem.startsWith(u8, path, "/assets/"))) return .frontend;
    if (method == .GET and !std.mem.startsWith(u8, path, "/api/") and !std.mem.startsWith(u8, path, "/v1/") and
        !std.mem.eql(u8, path, "/health") and !std.mem.eql(u8, path, "/ready") and !std.mem.eql(u8, path, "/metrics")) return .frontend;
    return .not_found;
}

fn methodIs(got: std.http.Method, expected: std.http.Method, route: Route) Route {
    return if (got == expected) route else .method_not_allowed;
}

test "path classification strips query and finds service endpoints" {
    try std.testing.expectEqual(Route.health, classify(.GET, "/health"));
    try std.testing.expectEqual(Route.realtime, classify(.GET, "/v1/realtime?intent=synthesize"));
    try std.testing.expectEqual(Route.speech, classify(.POST, "/v1/audio/speech"));
    try std.testing.expectEqual(Route.method_not_allowed, classify(.GET, "/v1/audio/speech"));
    try std.testing.expectEqual(Route.pronunciation_delete, classify(.DELETE, "/api/tts/pronunciation/GST?language=en"));
    try std.testing.expectEqual(Route.not_found, classify(.GET, "/api/no-such-route"));
    try std.testing.expectEqual(Route.frontend, classify(.GET, "/playground/realtime"));
}
