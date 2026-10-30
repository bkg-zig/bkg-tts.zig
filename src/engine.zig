//! Thread-sicherer Lebenszyklus für den vorhandenen BKG-Magpie-C-ABI-Adapter.
const std = @import("std");
const bkg_tts = @import("bkg-tts");

pub const State = enum(u8) { unloaded, loading, active, failed };

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    state: std.atomic.Value(State) = .init(.unloaded),
    handle: ?bkg_tts.magpie.Handle = null,
    opts: bkg_tts.magpie.Options,
    last_error: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: bkg_tts.magpie.Options) Engine {
        return .{ .gpa = gpa, .io = io, .opts = opts };
    }

    /// Lädt das Modell einmal und hält den Kontext für alle Requests offen.
    pub fn load(self: *Engine) void {
        const current = self.state.load(.acquire);
        if (current == .active or current == .loading) return;
        self.state.store(.loading, .release);
        const handle = bkg_tts.magpie.Handle.open(self.gpa, self.opts) catch |e| {
            self.last_error = @errorName(e);
            self.state.store(.failed, .release);
            return;
        };
        self.mutex.lockUncancelable(self.io);
        self.handle = handle;
        self.last_error = null;
        self.mutex.unlock(self.io);
        self.state.store(.active, .release);
    }

    /// Synthetisiert mit dem konfigurierten Standardsprecher und der Standardsprache.
    pub fn synthesize(self: *Engine, text: []const u8) bkg_tts.magpie.Error!bkg_tts.magpie.Result {
        return self.synthesizeFor(text, self.opts.language, self.opts.speaker);
    }

    /// Request-Optionen werden lokal kopiert. Der Engine-Default wird nicht mutiert.
    pub fn synthesizeFor(
        self: *Engine,
        text: []const u8,
        language: []const u8,
        speaker: []const u8,
    ) bkg_tts.magpie.Error!bkg_tts.magpie.Result {
        if (self.state.load(.acquire) != .active) return error.ModelLoadFailed;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state.load(.acquire) != .active or self.handle == null) return error.ModelLoadFailed;
        var opts = self.opts;
        opts.language = language;
        opts.speaker = speaker;
        return self.handle.?.synthesize(self.gpa, opts, text);
    }

    pub fn getState(self: *const Engine) State {
        return self.state.load(.acquire);
    }

    pub fn isActive(self: *const Engine) bool {
        return self.getState() == .active;
    }

    pub fn deinit(self: *Engine) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state.store(.unloaded, .release);
        if (self.handle) |*handle| {
            handle.close();
            self.handle = null;
        }
    }
};

test "Engine init state is unloaded" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    const io = threaded.io();
    const engine = Engine.init(gpa, io, .{ .gpa = gpa, .model_path = "/nonexistent.gguf" });
    try std.testing.expectEqual(State.unloaded, engine.getState());
}
