//! Kommandozeile der BKG-TTS-Engine.
//!
//! Die Befehle:
//!
//!   serve   HTTP-Server starten. Das ist die Vorgabe.
//!   synth   Text sprechen und als WAV-Datei speichern.
//!   info    Deskriptor eines Modellordners anzeigen.
//!   fetch   Dateien eines Hugging-Face-Repos laden.
//!   help    Hilfe anzeigen.
//!
//! Die Befehle `synth` und `info` arbeiten mit einem Modellordner, nicht mit
//! der Registry des Servers. Der Ordner muss die Datei `config.json` enthalten.
//! Damit laesst sich ein Modell ohne laufenden Server benutzen.
const std = @import("std");

const audio = @import("audio.zig");
const config_mod = @import("config.zig");
const descriptor = @import("tts/descriptor.zig");
const engine_mod = @import("engine.zig");
const limits = @import("limits.zig");
const registry = @import("engine/registry.zig");

/// Fehler der Kommandozeile.
pub const Error = error{
    /// Der Befehl ist unbekannt.
    UnknownCommand,
    /// Die Option ist unbekannt.
    UnknownOption,
    /// Zu einer Option fehlt der Wert.
    MissingValue,
    /// Das Tempo liegt nicht im erlaubten Bereich.
    InvalidSpeed,
    /// Fuer den Befehl fehlt ein Modellordner.
    MissingModel,
    /// Fuer den Synthese fehlt die Zieldatei.
    MissingOutput,
    /// Fuer den Download fehlt das Repository.
    MissingRepository,
    /// Fuer den Download fehlt das Zielverzeichnis.
    MissingDirectory,
    /// Der Text der Synthese ist leer.
    MissingText,
    /// Der Text der Synthese ist zu lang.
    TextTooLong,
    /// Die Antwort von Hugging Face liess sich nicht lesen.
    InvalidResponse,
    /// Das Repository hat keine Dateien.
    NoFiles,
    /// Das Token enthaelt Zeichen, die die Konfiguration von curl zerstoeren.
    InvalidToken,
};

/// Der gewaehlte Befehl.
pub const Command = enum {
    serve,
    synth,
    info,
    fetch,
    help,
};

/// Die Angaben der Kommandozeile.
pub const Options = struct {
    /// Der Befehl.
    command: Command = .serve,
    /// Modellordner mit der Datei `config.json`.
    model_dir: ?[]const u8 = null,
    /// Name der Stimme.
    voice: []const u8 = "",
    /// Sprache des Textes.
    language: []const u8 = "",
    /// Sprechtempo.
    speed: f32 = 1.0,
    /// Zieldatei der Synthese.
    output: ?[]const u8 = null,
    /// Text, der gesprochen wird.
    text: ?[]const u8 = null,
    /// Datei mit dem Text, der gesprochen wird.
    text_file: ?[]const u8 = null,
    /// Repository bei Hugging Face in der Form `organisation/name`.
    repo: ?[]const u8 = null,
    /// Zielverzeichnis des Downloads.
    dir: ?[]const u8 = null,
    /// Datei mit dem Token fuer Hugging Face.
    token_file: ?[]const u8 = null,
    /// Das Modell beim Befehl `info` wirklich laden.
    load: bool = false,
};

/// Liest die Argumente der Kommandozeile.
///
/// Der erste Wert ohne Bindestrich ist der Befehl. Jede Option hat die Form
/// `--name wert`, nur `--load` ist ein Schalter.
pub fn parse(args: []const []const u8) Error!Options {
    var options = Options{};
    var index: usize = 0;

    if (args.len > 0 and !std.mem.startsWith(u8, args[0], "-")) {
        options.command = std.meta.stringToEnum(Command, args[0]) orelse return error.UnknownCommand;
        index = 1;
    }

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--model")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.model_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--voice")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.voice = args[index];
        } else if (std.mem.eql(u8, arg, "--language")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.language = args[index];
        } else if (std.mem.eql(u8, arg, "--speed")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            const speed = std.fmt.parseFloat(f32, args[index]) catch return error.InvalidSpeed;
            if (!limits.speedAllowed(speed)) return error.InvalidSpeed;
            options.speed = speed;
        } else if (std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.output = args[index];
        } else if (std.mem.eql(u8, arg, "--text")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.text = args[index];
        } else if (std.mem.eql(u8, arg, "--text-file")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.text_file = args[index];
        } else if (std.mem.eql(u8, arg, "--repo")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.repo = args[index];
        } else if (std.mem.eql(u8, arg, "--dir")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.dir = args[index];
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.token_file = args[index];
        } else if (std.mem.eql(u8, arg, "--load")) {
            options.load = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.command = .help;
        } else {
            return error.UnknownOption;
        }
    }

    return options;
}

/// Schreibt die Hilfe auf die Standardausgabe.
pub fn printHelp(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    defer stdout.interface.flush() catch {};

    try stdout.interface.writeAll(
        \\bkg-tts: Sprachausgabe mit lokalen ONNX-Modellen
        \\
        \\Aufruf:
        \\  bkg-tts [serve] [Optionen]
        \\  bkg-tts synth --model <ordner> --output <datei> [Optionen]
        \\  bkg-tts info --model <ordner> [--load]
        \\  bkg-tts fetch --repo <organisation/name> --dir <ordner> [--token-file <datei>]
        \\  bkg-tts help
        \\
        \\Optionen:
        \\  --model <ordner>      Modellordner mit der Datei config.json
        \\  --voice <name>        Stimme des Modells
        \\  --language <sprache>  Sprache des Textes
        \\  --speed <zahl>        Sprechtempo zwischen 0.25 und 4.0
        \\  --output <datei>      WAV-Datei der Synthese
        \\  --text <text>         Text, der gesprochen wird
        \\  --text-file <datei>   Datei mit dem Text
        \\  --repo <name>         Repository bei Hugging Face
        \\  --dir <ordner>        Zielverzeichnis des Downloads
        \\  --token-file <datei>  Datei mit dem Token fuer Hugging Face
        \\  --load                Modell beim Befehl info wirklich laden
        \\
        \\Ohne --text und --text-file liest der Befehl synth den Text von der
        \\Standardeingabe.
        \\
    );
}

/// Spricht einen Text und speichert ihn als WAV-Datei.
pub fn synth(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
) !void {
    const model_dir = options.model_dir orelse return error.MissingModel;
    const output = options.output orelse return error.MissingOutput;

    const text = try readText(gpa, io, options);
    defer gpa.free(text);
    if (text.len == 0) return error.MissingText;
    if (text.len > limits.max_text_chars) return error.TextTooLong;

    const cfg = config_mod.fromEnviron(environ);
    var engine = engine_mod.Engine.init(gpa, io, .{
        .model_dir = model_dir,
        .ort_library = cfg.ort_library,
        .espeak_library = cfg.espeak_library,
        .espeak_data = cfg.espeak_data,
    });
    defer engine.deinit();

    engine.load() catch |err| {
        std.log.err(
            "Modell {s} liess sich nicht laden: {s}",
            .{ model_dir, engine.lastError() orelse @errorName(err) },
        );
        return err;
    };

    const result = try engine.synthesizeFor(gpa, text, options.language, options.voice, options.speed);
    defer gpa.free(result.pcm);

    const wav = try audio.encodeWav(gpa, result.pcm, result.sample_rate);
    defer gpa.free(wav);

    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = output, .data = wav });

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    defer stdout.interface.flush() catch {};

    const seconds = @as(f64, @floatFromInt(result.pcm.len)) / @as(f64, @floatFromInt(result.sample_rate));
    try stdout.interface.print(
        "{s}: {d} Hz, {d} Samples, {d:.2} s\n",
        .{ output, result.sample_rate, result.pcm.len, seconds },
    );
}

/// Zeigt den Deskriptor eines Modellordners.
///
/// Mit `--load` laedt der Befehl das Modell und zeigt zusaetzlich die Stimmen,
/// die das geladene Modell anbietet.
pub fn info(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
) !void {
    const model_dir = options.model_dir orelse return error.MissingModel;

    const path = try std.fs.path.join(gpa, &.{ model_dir, registry.descriptor_file });
    defer gpa.free(path);

    var desc = descriptor.load(gpa, io, path) catch |err| {
        std.log.err("Deskriptor {s} liess sich nicht lesen: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer desc.deinit();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    defer stdout.interface.flush() catch {};

    try stdout.interface.print("Modell: {s}\n", .{desc.model});
    try stdout.interface.print("Name: {s}\n", .{desc.name});
    try stdout.interface.print("Version: {s}\n", .{desc.version});
    try stdout.interface.print("Verarbeitungsweg: {s}\n", .{@tagName(desc.backend)});
    try stdout.interface.print("Sprache: {s}\n", .{desc.text.language});
    if (desc.sample_rate) |rate| {
        try stdout.interface.print("Abtastrate: {d} Hz\n", .{rate});
    }
    try stdout.interface.print("Datei: {s}\n", .{desc.model_file});
    try stdout.interface.print("Stimmen: {s} ({s})\n", .{ desc.voices.file, @tagName(desc.voices.format) });
    for (desc.voices.names) |name| {
        try stdout.interface.print("Stimme: {s}\n", .{name});
    }
    try stdout.interface.print("Tokenisierung: {s}\n", .{@tagName(desc.tokenizer.mode)});
    try stdout.interface.print("Ausgang: {s}\n", .{desc.output.name});
    try stdout.interface.print("Abschneiden am Ende: {d} Samples\n", .{desc.output.trim_tail_samples});
    for (desc.voice_aliases) |alias| {
        try stdout.interface.print("Alias: {s} -> {s}\n", .{ alias.alias, alias.voice });
    }
    for (desc.speed_priors) |prior| {
        try stdout.interface.print("Tempoprior: {s} {d}\n", .{ prior.voice, prior.speed });
    }

    if (!options.load) return;

    const cfg = config_mod.fromEnviron(environ);
    var engine = engine_mod.Engine.init(gpa, io, .{
        .model_dir = model_dir,
        .ort_library = cfg.ort_library,
        .espeak_library = cfg.espeak_library,
        .espeak_data = cfg.espeak_data,
    });
    defer engine.deinit();

    engine.load() catch |err| {
        std.log.err(
            "Modell {s} liess sich nicht laden: {s}",
            .{ model_dir, engine.lastError() orelse @errorName(err) },
        );
        return err;
    };

    try stdout.interface.print("Geladen: {s}\n", .{engine.activeModelId() orelse "unbekannt"});
    try stdout.interface.print("Abtastrate: {d} Hz\n", .{engine.sampleRate()});

    const voices = try engine.voices(gpa);
    defer engine_mod.freeStrings(gpa, voices);
    for (voices) |voice| {
        try stdout.interface.print("Stimme: {s}\n", .{voice});
    }
}

/// Laedt die Dateien eines Hugging-Face-Repos in ein Verzeichnis.
///
/// Das Token kommt aus der Datei, die `--token-file` nennt, sonst aus der
/// Umgebungsvariablen `BKG_TTS_HF_TOKEN_FILE`. Ohne Token werden nur
/// oeffentliche Repositories geladen.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    options: Options,
) !void {
    const repo = options.repo orelse return error.MissingRepository;
    const dir = options.dir orelse return error.MissingDirectory;

    const token = try readToken(gpa, io, environ, options.token_file);
    defer if (token) |value| gpa.free(value);

    var files = try listRepoFiles(gpa, io, repo, token);
    defer {
        for (files.items) |file| gpa.free(file);
        files.deinit(gpa);
    }

    try std.Io.Dir.createDirPath(.cwd(), io, dir);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    defer stdout.interface.flush() catch {};

    for (files.items) |file| {
        const target = try std.fs.path.join(gpa, &.{ dir, file });
        defer gpa.free(target);

        try stdout.interface.print("laedt {s}\n", .{file});
        stdout.interface.flush() catch {};

        try downloadFile(gpa, io, repo, file, target, token);
    }

    try stdout.interface.print("{d} Dateien in {s}\n", .{ files.items.len, dir });
}

/// Liest den Text der Synthese.
///
/// Ohne `--text` und `--text-file` kommt der Text von der Standardeingabe.
fn readText(gpa: std.mem.Allocator, io: std.Io, options: Options) ![]u8 {
    if (options.text) |text| return gpa.dupe(u8, text);

    if (options.text_file) |path| {
        return std.Io.Dir.readFileAlloc(
            .cwd(),
            io,
            path,
            gpa,
            .limited(limits.max_text_chars + 1),
        );
    }

    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buffer);
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(gpa);
    try reader.interface.appendRemaining(gpa, &list, .limited(limits.max_text_chars + 1));
    return list.toOwnedSlice(gpa);
}

/// Liest das Token fuer Hugging Face.
///
/// Fehlt die Datei, wird ohne Token gearbeitet. Das reicht bei oeffentlichen
/// Repositories.
fn readToken(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    token_file: ?[]const u8,
) !?[]u8 {
    const path = token_file orelse envValue(environ, "BKG_TTS_HF_TOKEN_FILE") orelse return null;

    const data = std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .limited(4096)) catch |err| {
        std.log.err("Token-Datei {s} liess sich nicht lesen: {s}", .{ path, @errorName(err) });
        return err;
    };
    defer gpa.free(data);

    const token = std.mem.trim(u8, data, " \t\r\n");
    if (token.len == 0) return null;
    if (std.mem.indexOfAny(u8, token, "\"\r\n") != null) return error.InvalidToken;

    return try gpa.dupe(u8, token);
}

/// Fragt Hugging Face nach den Dateien des Repositories.
fn listRepoFiles(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    token: ?[]const u8,
) !std.ArrayList([]u8) {
    const url = try std.fmt.allocPrint(gpa, "https://huggingface.co/api/models/{s}", .{repo});
    defer gpa.free(url);

    const body = try curlJson(gpa, io, url, token);
    defer gpa.free(body);


    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch {
        std.log.err("Die Antwort von Hugging Face ist kein gueltiges JSON.", .{});
        return error.InvalidResponse;
    };
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const siblings = parsed.value.object.get("siblings") orelse return error.InvalidResponse;
    if (siblings != .array) return error.InvalidResponse;

    var files = std.ArrayList([]u8).empty;
    errdefer {
        for (files.items) |file| gpa.free(file);
        files.deinit(gpa);
    }

    for (siblings.array.items) |item| {
        if (item != .object) continue;
        const name = item.object.get("rfilename") orelse continue;
        if (name != .string) continue;
        if (name.string.len == 0) continue;
        try files.append(gpa, try gpa.dupe(u8, name.string));
    }

    if (files.items.len == 0) return error.NoFiles;
    return files;
}

/// Laedt eine Datei des Repositories.
fn downloadFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    file: []const u8,
    target: []const u8,
    token: ?[]const u8,
) !void {
    const url = try std.fmt.allocPrint(gpa, "https://huggingface.co/{s}/resolve/main/{s}", .{ repo, file });
    defer gpa.free(url);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "curl");
    try argv.append(gpa, "-fL");
    try argv.append(gpa, "--retry");
    try argv.append(gpa, "3");
    try argv.append(gpa, "--create-dirs");
    try argv.append(gpa, "--silent");
    try argv.append(gpa, "--show-error");
    try argv.append(gpa, "-o");
    try argv.append(gpa, target);
    try appendTokenConfig(gpa, &argv, token);
    try argv.append(gpa, url);

    _ = try runCurl(gpa, io, argv.items, token, false);
}

/// Holt eine JSON-Antwort von Hugging Face.
fn curlJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    token: ?[]const u8,
) ![]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "curl");
    try argv.append(gpa, "-fsSL");
    try argv.append(gpa, "--retry");
    try argv.append(gpa, "3");
    try appendTokenConfig(gpa, &argv, token);
    try argv.append(gpa, url);

    return try runCurl(gpa, io, argv.items, token, true) orelse error.InvalidResponse;
}

/// Haengt die Konfiguration mit dem Token an die Argumente von curl.
///
/// Das Token geht ueber die Standardeingabe von curl, nicht ueber die
/// Argumente. So steht es nicht in der Prozessliste.
fn appendTokenConfig(
    gpa: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    token: ?[]const u8,
) !void {
    if (token == null) return;
    try argv.append(gpa, "--config");
    try argv.append(gpa, "-");
}

/// Baut die Konfigurationszeile fuer curl.
fn tokenConfig(gpa: std.mem.Allocator, token: ?[]const u8) !?[]u8 {
    const value = token orelse return null;
    return try std.fmt.allocPrint(gpa, "header = \"Authorization: Bearer {s}\"\n", .{value});
}

/// Startet curl und wartet auf das Ende.
///
/// Ist `capture` gesetzt, kommt die Standardausgabe als Text zurueck. Sonst
/// gibt es keinen Text zurueck, weil curl direkt in die Zieldatei schreibt.
fn runCurl(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    token: ?[]const u8,
    capture: bool,
) !?[]u8 {
    const config = try tokenConfig(gpa, token);
    defer if (config) |value| gpa.free(value);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (config != null) .pipe else .ignore,
        .stdout = if (capture) .pipe else .inherit,
        .stderr = .inherit,
    });

    if (config) |value| {
        const stdin = child.stdin orelse return error.SpawnFailed;
        try stdin.writeStreamingAll(io, value);
        stdin.close(io);
        child.stdin = null;
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(gpa);

    if (capture) {
        const stdout = child.stdout orelse return error.SpawnFailed;
        var buffer: [4096]u8 = undefined;
        var reader = stdout.reader(io, &buffer);
        try reader.interface.appendRemaining(gpa, &output, .limited(16 * 1024 * 1024));
    }

    const term = try std.process.Child.wait(&child, io);
    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.log.err("curl endete mit Code {d}.", .{code});
                return error.CurlFailed;
            }
        },
        else => {
            std.log.err("curl wurde abgebrochen.", .{});
            return error.CurlFailed;
        },
    }

    if (!capture) return null;
    return try output.toOwnedSlice(gpa);
}

/// Liest eine Variable aus der Umgebung.
fn envValue(environ: std.process.Environ, key: []const u8) ?[]const u8 {
    const value = std.process.Environ.getPosix(environ, key) orelse return null;
    if (value.len == 0) return null;
    return value;
}

test "der Befehl wird gelesen" {
    const options = try parse(&.{"synth", "--model", "/tmp/modell"});
    try std.testing.expectEqual(Command.synth, options.command);
    try std.testing.expectEqualStrings("/tmp/modell", options.model_dir.?);
}

test "ohne Befehl startet der Server" {
    const options = try parse(&.{});
    try std.testing.expectEqual(Command.serve, options.command);
}

test "die Optionen werden gelesen" {
    const options = try parse(&.{
        "synth",     "--model",  "/tmp/modell", "--voice", "bella", "--speed", "1.25",
        "--output",  "/tmp/aus.wav",         "--text",  "Hallo", "--language", "de",
    });
    try std.testing.expectEqualStrings("bella", options.voice);
    try std.testing.expectEqual(@as(f32, 1.25), options.speed);
    try std.testing.expectEqualStrings("/tmp/aus.wav", options.output.?);
    try std.testing.expectEqualStrings("Hallo", options.text.?);
    try std.testing.expectEqualStrings("de", options.language);
}

test "ein Tempo ausserhalb der Grenzen wird abgelehnt" {
    try std.testing.expectError(error.InvalidSpeed, parse(&.{ "synth", "--speed", "0.1" }));
    try std.testing.expectError(error.InvalidSpeed, parse(&.{ "synth", "--speed", "5" }));
    try std.testing.expectError(error.InvalidSpeed, parse(&.{ "synth", "--speed", "schnell" }));
}

test "unbekannte Optionen und Befehle werden abgelehnt" {
    try std.testing.expectError(error.UnknownOption, parse(&.{"synth", "--unbekannt"}));
    try std.testing.expectError(error.UnknownCommand, parse(&.{"singen"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"synth", "--model"}));
}

test "--load setzt den Schalter" {
    const options = try parse(&.{"info", "--model", "/tmp/modell", "--load"});
    try std.testing.expect(options.load);
}
