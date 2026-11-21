//! BKG TTS — native Zig HTTP/Realtime server und Kommandozeile.
const std = @import("std");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const engine_mod = @import("engine.zig");
const pronunciation_mod = @import("pronunciation.zig");
const router = @import("router.zig");
const api = @import("api.zig");
const realtime = @import("realtime.zig");
const web_request = @import("web_request.zig");

const max_request_body = 1024 * 1024;
const max_http_head = 16 * 1024;

test {
    std.testing.refAllDecls(@This());
    _ = router;
    _ = api;
    _ = realtime;
    _ = cli;
    _ = config_mod;
    _ = engine_mod;
    _ = pronunciation_mod;
    _ = web_request;
}

/// Startet die Kommandozeile.
///
/// Ohne Befehl startet der HTTP-Server. Die Befehle `synth`, `info` und
/// `fetch` arbeiten mit einem Modellordner bzw. einem Repository und
/// brauchen keinen laufenden Server.
pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;
    // Die Umgebung wird durchgereicht, damit die Suche nach Programmen wie
    // curl den PATH der aufrufenden Shell benutzt.
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = init.environ });
    const io = threaded.io();

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(gpa);

    var iterator = init.args.iterate();
    _ = iterator.skip();
    while (iterator.next()) |arg| {
        try args.append(gpa, arg);
    }

    const options = cli.parse(args.items) catch |err| {
        std.log.err("Die Kommandozeile liess sich nicht lesen: {s}", .{@errorName(err)});
        cli.printHelp(io) catch {};
        std.process.exit(2);
    };

    switch (options.command) {
        .serve => serve(init, gpa, io) catch |err| {
            std.log.err("Der Server endete mit einem Fehler: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
        .synth => cli.synth(gpa, io, init.environ, options) catch |err| {
            std.log.err("Die Synthese ist fehlgeschlagen: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
        .info => cli.info(gpa, io, init.environ, options) catch |err| {
            std.log.err("Die Modellinformation liess sich nicht lesen: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
        .fetch => cli.fetch(gpa, io, init.environ, options) catch |err| {
            std.log.err("Der Download ist fehlgeschlagen: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
        .help => cli.printHelp(io) catch |err| {
            std.log.err("Die Hilfe liess sich nicht schreiben: {s}", .{@errorName(err)});
            std.process.exit(1);
        },
    }
}

/// Startet den HTTP-Server.
fn serve(init: std.process.Init.Minimal, gpa: std.mem.Allocator, io: std.Io) !void {
    const cfg = config_mod.fromEnviron(init.environ);
    const models_dir = try cfg.modelsDir(gpa);
    defer gpa.free(models_dir);

    var engine = engine_mod.Engine.init(gpa, io, .{
        .models_dir = models_dir,
        .ort_library = cfg.ort_library,
        .espeak_library = cfg.espeak_library,
        .espeak_data = cfg.espeak_data,
        .model = cfg.model,
        .language = cfg.language,
        .voice = cfg.voice,
    });
    defer engine.deinit();

    var pronunciation = pronunciation_mod.Store.init(gpa, io, cfg.pronunciation_path);
    defer pronunciation.deinit();
    try pronunciation.load();

    var context = api.Context{
        .gpa = gpa,
        .io = io,
        .engine = &engine,
        .config = cfg,
        .pronunciation = &pronunciation,
    };
    defer context.deinit();

    const address = std.Io.net.IpAddress.parse(cfg.host, cfg.port) catch
        try std.Io.net.IpAddress.resolve(io, cfg.host, cfg.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print("bkg-tts lauscht auf {s}:{d} (nur CPU, eigenes Zig-Backend)\n", .{ cfg.host, cfg.port });

    {
        const loader = try std.Thread.spawn(.{}, loadModel, .{&engine});
        loader.detach();
    }

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept failed: {s}\n", .{@errorName(err)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, serveConnection, .{ &context, io, stream }) catch {
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn loadModel(engine: *engine_mod.Engine) void {
    engine.load() catch {
        std.debug.print("Modell nicht verfuegbar: {s}\n", .{engine.lastError() orelse "unbekannter Fehler"});
        return;
    };
    if (!engine.isActive()) {
        std.debug.print("Modell nicht verfuegbar: {s}\n", .{engine.lastError() orelse "unbekannter Fehler"});
        return;
    }
    std.debug.print("Modell {s} geladen; der Ready-Endpunkt antwortet mit 200.\n", .{engine.activeModelId() orelse "unbekannt"});
}

fn serveConnection(ctx: *api.Context, io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    handleConnection(ctx, io, stream) catch |err| {
        std.debug.print("request connection failed: {s}\n", .{@errorName(err)});
    };
}

fn handleConnection(ctx: *api.Context, io: std.Io, stream: std.Io.net.Stream) !void {
    var input_buffer: [max_http_head]u8 = undefined;
    var output_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &input_buffer);
    var writer = stream.writer(io, &output_buffer);
    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var request = http.receiveHead() catch return;

    const method = request.head.method;
    const target = try ctx.gpa.dupe(u8, request.head.target);
    defer ctx.gpa.free(target);
    const route = router.classify(method, target);

    if (method == .OPTIONS) {
        const headers = [_]std.http.Header{
            .{ .name = "access-control-allow-origin", .value = "*" },
            .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "authorization, content-type" },
            .{ .name = "access-control-max-age", .value = "600" },
        };
        try request.respond("", .{ .status = .no_content, .keep_alive = false, .extra_headers = &headers });
        return;
    }

    if (route == .frontend and method == .GET) {
        try serveStatic(&request, ctx.gpa, io, ctx.config.web_dist, target);
        return;
    }

    if (route == .realtime) {
        switch (request.upgradeRequested()) {
            .websocket => |maybe_key| {
                if (maybe_key) |key| {
                    var ws = try request.respondWebSocket(.{ .key = key });
                    try ws.flush();
                    try realtime.serve(&ws, ctx);
                    return;
                }
            },
            else => {},
        }
    }

    const authorization = if (web_request.headerValue(request.head_buffer, "authorization")) |value|
        try ctx.gpa.dupe(u8, value)
    else
        null;
    defer if (authorization) |value| ctx.gpa.free(value);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(ctx.gpa);

    if (method.requestHasBody()) {
        // Die Laenge des Bodies muss bekannt sein, bevor gelesen wird. Ohne
        // Content-Length und ohne Chunked-Transfer wartet der Reader sonst
        // bis zum Ende der Verbindung, und die Antwort kommt nicht.
        const body_length_known = request.head.content_length != null or
            request.head.transfer_encoding == .chunked;

        var body_buffer: [4096]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_buffer) catch |err| switch (err) {
            error.HttpExpectationFailed => {
                try sendRawError(&request, .expectation_failed, "application/json; charset=utf-8", "{\"error\":{\"code\":\"EXPECTATION_FAILED\",\"message\":\"Der Expect-Header wird nicht unterstützt.\"}}");
                return;
            },
            error.WriteFailed => return err,
        };

        if (body_length_known) {
            body_reader.appendRemaining(ctx.gpa, &body, .limited(max_request_body)) catch {
                try sendRawError(&request, .payload_too_large, "application/json; charset=utf-8", "{\"error\":{\"code\":\"BODY_TOO_LARGE\",\"message\":\"Der Request-Body ist zu groß.\"}}");
                return;
            };
        }
    }

    var response = api.handle(ctx, .{
        .method = method,
        .target = target,
        .authorization = authorization,
        .body = body.items,
    });
    defer response.deinit(ctx.gpa);

    var request_id_buf: [32]u8 = undefined;
    const request_id = try std.fmt.bufPrint(&request_id_buf, "req_{x}", .{response.request_id});
    const extra_headers = [_]std.http.Header{
        .{ .name = "content-type", .value = response.content_type },
        .{ .name = "access-control-allow-origin", .value = "*" },
        .{ .name = "x-request-id", .value = request_id },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(response.body, .{
        .status = response.status,
        .keep_alive = false,
        .extra_headers = &extra_headers,
    });
}

fn sendRawError(request: *std.http.Server.Request, status: std.http.Status, content_type: []const u8, body: []const u8) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "access-control-allow-origin", .value = "*" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    try request.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &headers });
}

/// Serves built React files without Node/JS backend glue.
fn serveStatic(
    request: *std.http.Server.Request,
    gpa: std.mem.Allocator,
    io: std.Io,
    web_dist: []const u8,
    target: []const u8,
) !void {
    const query = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const raw_path = target[0..query];
    const relative = if (std.mem.startsWith(u8, raw_path, "/")) raw_path[1..] else raw_path;
    if (std.mem.indexOf(u8, relative, "..") != null or std.mem.indexOfScalar(u8, relative, '\\') != null or
        std.mem.indexOfScalar(u8, relative, 0) != null)
    {
        try sendRawError(request, .forbidden, "application/json; charset=utf-8", "{\"error\":{\"code\":\"INVALID_STATIC_PATH\"}}");
        return;
    }

    const requested = if (relative.len == 0) "index.html" else relative;
    const requested_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ web_dist, requested });
    defer gpa.free(requested_path);

    const body = std.Io.Dir.readFileAlloc(.cwd(), io, requested_path, gpa, std.Io.Limit.limited(16 * 1024 * 1024)) catch {
        const last_slash = std.mem.lastIndexOfScalar(u8, requested, '/') orelse 0;
        const tail = if (last_slash == 0) requested else requested[last_slash + 1 ..];
        if (std.mem.indexOfScalar(u8, tail, '.') != null) {
            try sendRawError(request, .not_found, "application/json; charset=utf-8", "{\"error\":{\"code\":\"STATIC_NOT_FOUND\"}}");
            return;
        }
        const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{web_dist});
        defer gpa.free(index_path);
        const index = std.Io.Dir.readFileAlloc(.cwd(), io, index_path, gpa, std.Io.Limit.limited(4 * 1024 * 1024)) catch {
            try sendRawError(request, .service_unavailable, "application/json; charset=utf-8", "{\"error\":{\"code\":\"FRONTEND_NOT_BUILT\"}}");
            return;
        };
        defer gpa.free(index);
        try respondStaticBytes(request, index, "text/html; charset=utf-8");
        return;
    };
    defer gpa.free(body);
    try respondStaticBytes(request, body, contentType(requested));
}

fn contentType(path: []const u8) []const u8 {
    const ext = if (std.mem.lastIndexOfScalar(u8, path, '.')) |idx| path[idx..] else "";
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs")) return "text/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    return "application/octet-stream";
}

fn respondStaticBytes(request: *std.http.Server.Request, body: []const u8, mime: []const u8) !void {
    const extra = [_]std.http.Header{
        .{ .name = "content-type", .value = mime },
        .{ .name = "access-control-allow-origin", .value = "*" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "cache-control", .value = if (std.mem.eql(u8, mime, "text/html; charset=utf-8")) "no-cache" else "public, max-age=31536000, immutable" },
    };
    try request.respond(body, .{ .status = .ok, .keep_alive = false, .extra_headers = &extra });
}
