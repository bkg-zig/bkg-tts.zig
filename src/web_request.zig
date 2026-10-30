//! HTTP-Request-Struktur und Header-Zugriff fuer den nativen Server.
//!
//! Das Projekt ist bewusst ohne externes BKG-Framework-Paket baubar. Die
//! vorherige `bkg-web`-Abhaengigkeit lieferte nur diese beiden Helfer.
const std = @import("std");

/// Eingehender Request, wie ihn der API-Dispatcher sieht.
pub const Request = struct {
    method: std.http.Method,
    target: []const u8,
    authorization: ?[]const u8,
    body: []const u8,

    /// Pfad ohne Query-String.
    pub fn path(self: Request) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.target, '?') orelse self.target.len;
        return self.target[0..end];
    }
};

/// Sucht einen Header-Wert im rohen HTTP-Head. Der Wert wird getrimmt.
pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next() orelse return null;
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0) return null;
        return value;
    }
    return null;
}

test "path strips the query string" {
    const request = Request{
        .method = .GET,
        .target = "/api/models?limit=3",
        .authorization = null,
        .body = "",
    };
    try std.testing.expectEqualStrings("/api/models", request.path());
}

test "headerValue finds a header case-insensitively" {
    const head = "POST /v1/audio/speech HTTP/1.1\r\nAuthorization: Bearer abc\r\nContent-Type: application/json\r\n\r\n";
    try std.testing.expectEqualStrings("Bearer abc", headerValue(head, "authorization").?);
    try std.testing.expectEqualStrings("application/json", headerValue(head, "content-type").?);
    try std.testing.expect(headerValue(head, "x-missing") == null);
}
