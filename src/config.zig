//! Server-Konfiguration aus ENV; keine Secret- oder Request-Inhalte hier speichern.
const std = @import("std");

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 8092,
    model_path: ?[]const u8 = null,
    lib_path: ?[]const u8 = null,
    web_dist: []const u8 = "/srv/magpie/web/dist",
    pronunciation_path: []const u8 = "/srv/magpie/data/pronunciation.json",
    log_level: []const u8 = "info",
    workers: u8 = 1,
};

pub fn fromEnviron(environ: std.process.Environ) Config {
    var cfg = Config{};
    if (std.process.Environ.getPosix(environ, "MAGPIE_HOST")) |v| cfg.host = v;
    if (std.process.Environ.getPosix(environ, "MAGPIE_PORT")) |v| {
        cfg.port = std.fmt.parseInt(u16, v, 10) catch cfg.port;
    }
    if (std.process.Environ.getPosix(environ, "BKG_MAGPIE_MODEL")) |v| cfg.model_path = v;
    if (std.process.Environ.getPosix(environ, "BKG_MAGPIE_LIB_PATH")) |v| cfg.lib_path = v;
    if (std.process.Environ.getPosix(environ, "MAGPIE_WEB_DIST")) |v| cfg.web_dist = v;
    if (std.process.Environ.getPosix(environ, "MAGPIE_PRONUNCIATION_PATH")) |v| cfg.pronunciation_path = v;
    if (std.process.Environ.getPosix(environ, "MAGPIE_LOG_LEVEL")) |v| cfg.log_level = v;
    return cfg;
}

test "fromEnviron defaults" {
    const cfg = fromEnviron(std.process.Environ.empty);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
    try std.testing.expectEqual(@as(u16, 8092), cfg.port);
    try std.testing.expect(cfg.model_path == null);
    try std.testing.expectEqualStrings("/srv/magpie/data/pronunciation.json", cfg.pronunciation_path);
}
