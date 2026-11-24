//! Server-Konfiguration aus ENV; keine Secret- oder Request-Inhalte hier speichern.
//!
//! Alle Variablen beginnen mit `BKG_TTS_`. Die Pfade beschreiben, wo die
//! Modelle liegen und welche Bibliotheken die Engine benutzt. Die Engine
//! selbst liest keine Umgebungsvariablen.
const std = @import("std");

/// Pfad unterhalb des Home-Verzeichnisses, in dem die Modelle liegen.
pub const default_models_subdir = ".config/openchamber/speech-models";

/// Pfad, an dem die Modelle liegen, wenn weder `BKG_TTS_MODELS_DIR` noch
/// `HOME` bekannt sind.
pub const fallback_models_dir = "/var/lib/bkg-tts/models";

pub const Config = struct {
    /// Adresse, auf der der Server lauscht.
    host: []const u8 = "0.0.0.0",
    /// Port des Servers.
    port: u16 = 8092,
    /// Verzeichnis mit den Modellordnern und der Datei `registry.json`.
    /// Null heisst: der Pfad wird aus dem Home-Verzeichnis gebildet.
    models_dir: ?[]const u8 = null,
    /// Home-Verzeichnis des Benutzers.
    home: ?[]const u8 = null,
    /// Modell, das beim Start benutzt wird. Null heisst: das Vorgabemodell der
    /// Registry.
    model: ?[]const u8 = null,
    /// Pfad der ONNX-Runtime. Leer heisst: die Standardorte werden gesucht.
    ort_library: []const u8 = "",
    /// Pfad der espeak-ng-Bibliothek.
    espeak_library: []const u8 = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1",
    /// Verzeichnis mit den espeak-Daten.
    espeak_data: []const u8 = "/usr/lib/x86_64-linux-gnu/espeak-ng-data",
    /// Sprache, wenn die Anfrage keine nennt. Leer heisst: die Sprache des
    /// aktiven Modells.
    language: []const u8 = "",
    /// Stimme, wenn die Anfrage keine nennt. Leer heisst: die erste Stimme.
    voice: []const u8 = "",
    /// Verzeichnis mit der Weboberflaeche.
    web_dist: []const u8 = "/srv/bkg-tts/web/dist",
    /// Datei mit dem Aussprachewoerterbuch.
    pronunciation_path: []const u8 = "/srv/bkg-tts/data/pronunciation.json",
    /// Stufe der Protokollierung.
    log_level: []const u8 = "info",
    /// Zahl der gleichzeitigen Anfragen.
    workers: u8 = 1,

    /// Liefert das Verzeichnis der Modelle in eigenem Speicher.
    ///
    /// Der Aufrufer gibt die Liste wieder frei.
    pub fn modelsDir(self: Config, gpa: std.mem.Allocator) ![]u8 {
        if (self.models_dir) |dir| return gpa.dupe(u8, dir);
        if (self.home) |home| return std.fs.path.join(gpa, &.{ home, default_models_subdir });
        return gpa.dupe(u8, fallback_models_dir);
    }
};

pub fn fromEnviron(environ: std.process.Environ) Config {
    var cfg = Config{};

    if (envValue(environ, "BKG_TTS_HOST")) |v| cfg.host = v;
    if (envValue(environ, "BKG_TTS_PORT")) |v| {
        cfg.port = std.fmt.parseInt(u16, v, 10) catch cfg.port;
    }
    if (envValue(environ, "BKG_TTS_MODELS_DIR")) |v| cfg.models_dir = v;
    if (envValue(environ, "HOME")) |v| cfg.home = v;
    if (envValue(environ, "BKG_TTS_MODEL")) |v| cfg.model = v;
    if (envValue(environ, "BKG_TTS_ORT_LIBRARY")) |v| cfg.ort_library = v;
    if (envValue(environ, "BKG_TTS_ESPEAK_LIBRARY")) |v| cfg.espeak_library = v;
    if (envValue(environ, "BKG_TTS_ESPEAK_DATA")) |v| cfg.espeak_data = v;
    if (envValue(environ, "BKG_TTS_LANGUAGE")) |v| cfg.language = v;
    if (envValue(environ, "BKG_TTS_VOICE")) |v| cfg.voice = v;
    if (envValue(environ, "BKG_TTS_WEB_DIST")) |v| cfg.web_dist = v;
    if (envValue(environ, "BKG_TTS_PRONUNCIATION_PATH")) |v| cfg.pronunciation_path = v;
    if (envValue(environ, "BKG_TTS_LOG_LEVEL")) |v| cfg.log_level = v;

    return cfg;
}

/// Liest eine Variable. Ein leerer Wert gilt wie eine nicht gesetzte Variable,
/// damit ein leerer Compose-Wert keine leere Modellkennung erzeugt.
fn envValue(environ: std.process.Environ, key: []const u8) ?[]const u8 {
    const value = std.process.Environ.getPosix(environ, key) orelse return null;
    if (value.len == 0) return null;
    return value;
}

test "fromEnviron defaults" {
    const cfg = fromEnviron(std.process.Environ.empty);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
    try std.testing.expectEqual(@as(u16, 8092), cfg.port);
    try std.testing.expect(cfg.model == null);
    try std.testing.expectEqualStrings("/srv/bkg-tts/data/pronunciation.json", cfg.pronunciation_path);

    const dir = try cfg.modelsDir(std.testing.allocator);
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings(fallback_models_dir, dir);
}

test "modelsDir folgt dem Home-Verzeichnis" {
    const cfg = Config{ .home = "/home/toni" };
    const dir = try cfg.modelsDir(std.testing.allocator);
    defer std.testing.allocator.free(dir);
    try std.testing.expectEqualStrings("/home/toni/" ++ default_models_subdir, dir);
}

test "ein leerer Wert gilt wie nicht gesetzt" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var model_value: [14:0]u8 = "BKG_TTS_MODEL=".*;
    var entries = [_]?[*:0]const u8{ @as(?[*:0]const u8, @ptrCast(&model_value)), null };
    const environ = std.process.Environ{
        .block = .{ .slice = entries[0..1 :null] },
    };

    const cfg = fromEnviron(environ);
    try std.testing.expect(cfg.model == null);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
}
