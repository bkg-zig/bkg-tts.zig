//! Generische TTS-Engine.
//!
//! Die Engine kennt keine Modellfamilie. Sie liest die Deskriptoren der
//! Modelle aus einem Verzeichnis, laedt das gewaehlte Modell ueber das
//! passende Backend und synthetisiert Text. Welches Backend zu einem Modell
//! gehoert, steht im Deskriptor.
//!
//! Die Engine haelt zwei Sperren:
//!
//! - `load_mutex` serialisiert das Laden, den Wechsel des Modells und das
//!   Neuladen der Registry.
//! - `mutex` schuetzt die Synthese und den aktiven Zustand.
//!
//! Die Reihenfolge ist immer `load_mutex` vor `mutex`. Ein Thread, der nur
//! synthetisiert, braucht nur `mutex`.
//!
//! Beim Wechsel des Modells laedt die Engine zuerst das neue Backend und
//! setzt es danach unter `mutex` an die Stelle des alten. Laeuft gerade eine
//! Synthese, wartet der Wechsel auf ihr Ende. Der Wechsel blockiert also die
//! Synthese, bricht sie aber nicht ab.
const std = @import("std");

const backend = @import("engine/backend.zig");
const descriptor = @import("tts/descriptor.zig");
const loader = @import("engine/loader.zig");
const ort = @import("tts/ort.zig");
const phoneme_ids = @import("engine/phoneme_ids.zig");
const registry = @import("engine/registry.zig");
const style_tokens = @import("engine/style_tokens.zig");

/// Zustand der Engine.
pub const State = enum(u8) {
    /// Noch kein Modell geladen.
    unloaded,
    /// Ein Modell wird geladen.
    loading,
    /// Ein Modell ist geladen und benutzbar.
    active,
    /// Das Laden ist fehlgeschlagen.
    failed,
};

/// Fehler der Engine.
pub const Error = error{
    /// Die ONNX-Runtime liess sich nicht laden.
    RuntimeUnavailable,
    /// Die Registry liess sich nicht lesen.
    RegistryUnavailable,
    /// Es gibt kein Modell.
    NoModel,
    /// Das angeforderte Modell gibt es nicht.
    UnknownModel,
    /// Das Modell liess sich nicht laden.
    ModelLoadFailed,
    /// Es ist kein Modell geladen.
    ModelNotReady,
    /// Der Deskriptor verlangt einen Verarbeitungsweg, den es noch nicht gibt.
    UnsupportedBackend,
    /// Der Speicher reichte nicht.
    OutOfMemory,
};

/// Orte, an denen die ONNX-Runtime gesucht wird, wenn kein Pfad angegeben ist.
pub const default_ort_libraries = [_][]const u8{
    "/opt/onnxruntime/lib/libonnxruntime.so",
    "/usr/lib/libonnxruntime.so",
    "/usr/lib/x86_64-linux-gnu/libonnxruntime.so",
};

/// Vorgaben der Engine, die nicht aus dem Deskriptor kommen.
pub const Options = struct {
    /// Verzeichnis mit den Deskriptoren der Modelle.
    models_dir: []const u8 = "",
    /// Pfad zu einem Modellordner mit der Datei `config.json`.
    ///
    /// Ist der Pfad gesetzt, laeuft genau dieses Modell. Die Registry wird
    /// dann nicht gebraucht und nicht gelesen.
    model_dir: ?[]const u8 = null,
    /// Pfad der ONNX-Runtime. Leer heisst: die Standardorte werden gesucht.
    ort_library: []const u8 = "",
    /// Pfad der espeak-ng-Bibliothek.
    espeak_library: []const u8 = "/usr/lib/x86_64-linux-gnu/libespeak-ng.so.1",
    /// Verzeichnis mit den espeak-Daten.
    espeak_data: []const u8 = "/usr/lib/x86_64-linux-gnu/espeak-ng-data",
    /// Modell, das beim Start benutzt wird. Null heisst: das Vorgabemodell.
    model: ?[]const u8 = null,
    /// Sprache, wenn die Anfrage keine nennt. Leer heisst: die Sprache des
    /// Modells.
    language: []const u8 = "",
    /// Stimme, wenn die Anfrage keine nennt. Leer heisst: die erste Stimme.
    voice: []const u8 = "",
    /// Optionen der ONNX-Session.
    session: ort.SessionOptions = .{},
    /// Abtastrate, wenn weder Deskriptor noch Modell sie nennen.
    default_sample_rate: u32 = 24000,
};

/// Angaben zu einem Modell der Registry.
///
/// Die Texte gehoeren dem Aufrufer. Er gibt sie mit `deinit` wieder frei.
pub const ModelInfo = struct {
    /// Kennung des Modells.
    id: []u8,
    /// Anzeigename des Modells.
    name: []u8,
    /// Version des Modells.
    version: []u8,
    /// Sprache des Modells.
    language: []u8,
    /// Abtastrate der Ausgabe in Hertz.
    sample_rate: u32,
    /// true, wenn das Modell gerade benutzt wird.
    active: bool,

    pub fn deinit(self: *ModelInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.version);
        gpa.free(self.language);
        self.* = undefined;
    }
};

/// Eine Stimme des aktiven Modells mit ihren Aliasen.
pub const VoiceInfo = struct {
    /// Interner Name der Stimme.
    name: []u8,
    /// Namen, unter denen dieselbe Stimme erreichbar ist.
    aliases: [][]u8,

    pub fn deinit(self: *VoiceInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        for (self.aliases) |alias| gpa.free(alias);
        gpa.free(self.aliases);
        self.* = undefined;
    }
};

/// Ein Alias und der interne Name, auf den er zeigt.
const AliasPair = struct {
    alias: []const u8,
    target: []const u8,
};

/// Die Engine mit Registry, Runtime und aktuellem Modell.
pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    /// Serialisiert Laden, Modellwechsel und Neuladen.
    load_mutex: std.Io.Mutex = .init,
    /// Schuetzt die Synthese und den aktiven Zustand.
    mutex: std.Io.Mutex = .init,
    /// Zustand fuer Abfragen ohne Sperre.
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.unloaded),
    /// Die geladene ONNX-Runtime. Sie lebt laenger als jedes Backend.
    runtime: ?*ort.Runtime = null,
    /// Die Registry der Modelle.
    registry: ?*registry.Registry = null,
    /// Deskriptor des Modells, das ohne Registry geladen wurde.
    ///
    /// Das Feld ist nur gesetzt, wenn `Options.model_dir` benutzt wurde. Der
    /// Deskriptor liefert die Aliase der Stimmen, die es sonst nur in der
    /// Registry gibt.
    standalone: ?descriptor.Descriptor = null,
    /// Das geladene Backend des aktiven Modells.
    active: ?backend.Backend = null,
    /// Fingerabdruck des Deskriptors des aktiven Modells.
    active_fingerprint: ?u64 = null,
    /// Text des letzten Fehlers. Er gehoert der Engine.
    last_error: ?[]u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) Engine {
        return .{ .gpa = gpa, .io = io, .opts = opts };
    }

    /// Gibt alle Mittel frei.
    ///
    /// Das Backend wird vor der Runtime freigegeben, weil die ONNX-Session in
    /// der Umgebung der Runtime liegt.
    pub fn deinit(self: *Engine) void {
        self.load_mutex.lockUncancelable(self.io);
        defer self.load_mutex.unlock(self.io);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.active) |*active| active.deinit();
        self.active = null;
        self.active_fingerprint = null;

        if (self.registry) |reg| {
            reg.deinit();
            self.gpa.destroy(reg);
        }
        self.registry = null;

        if (self.standalone) |*desc| {
            desc.deinit();
        }
        self.standalone = null;

        if (self.runtime) |runtime| {
            runtime.deinit();
            self.gpa.destroy(runtime);
        }
        self.runtime = null;

        if (self.last_error) |message| {
            self.gpa.free(message);
            self.last_error = null;
        }
        self.state.store(.unloaded, .release);
    }

    /// Laedt die Registry und das aktive Modell.
    ///
    /// Die Runtime und die Registry werden nur einmal aufgebaut. Danach laedt
    /// die Engine das Modell, das in `opts.model` steht, sonst das
    /// Vorgabemodell der Registry.
    pub fn load(self: *Engine) Error!void {
        self.load_mutex.lockUncancelable(self.io);
        defer self.load_mutex.unlock(self.io);

        self.state.store(.loading, .release);

        // Ohne Registry laeuft genau ein Modell aus einem Modellordner. Das
        // ist der Weg der Kommandozeile.
        if (self.opts.model_dir) |dir| {
            if (self.runtime == null) {
                const runtime = self.openRuntime() catch |err| {
                    self.state.store(.failed, .release);
                    return err;
                };
                self.runtime = runtime;
            }

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.activateStandalone(dir) catch |err| {
                self.state.store(.failed, .release);
                return err;
            };
            return;
        }

        // Die Registry kommt zuerst. Fehlt das Verzeichnis der Modelle, ist
        // das ein klarer Fehler, unabhaengig von der ONNX-Runtime.
        if (self.registry == null) {
            const reg = self.gpa.create(registry.Registry) catch {
                self.state.store(.failed, .release);
                return error.OutOfMemory;
            };
            reg.* = registry.Registry.load(self.gpa, self.io, self.opts.models_dir) catch |err| {
                self.gpa.destroy(reg);
                self.setError(@errorName(err));
                self.state.store(.failed, .release);
                return error.RegistryUnavailable;
            };
            self.registry = reg;
        }

        const reg = self.registry.?;

        var wanted: []const u8 = reg.default_id orelse {
            self.setError("Die Registry enthaelt kein Modell.");
            self.state.store(.failed, .release);
            return error.NoModel;
        };

        if (self.opts.model) |model| {
            if (reg.find(model) == null) {
                self.setError("Das gewaehlte Modell steht nicht in der Registry.");
                self.state.store(.failed, .release);
                return error.UnknownModel;
            }
            wanted = model;
        }

        if (self.runtime == null) {
            const runtime = self.openRuntime() catch |err| {
                self.state.store(.failed, .release);
                return err;
            };
            self.runtime = runtime;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.activateLocked(reg, wanted) catch |err| {
            self.state.store(.failed, .release);
            return err;
        };
    }

    /// Wechselt das aktive Modell.
    ///
    /// Das neue Modell wird zuerst geladen. Bleibt das alte Model aktiv,
    /// wenn das Laden fehlschlaegt.
    pub fn setActive(self: *Engine, id: []const u8) Error!void {
        self.load_mutex.lockUncancelable(self.io);
        defer self.load_mutex.unlock(self.io);

        const reg = self.registry orelse return error.RegistryUnavailable;
        if (reg.find(id) == null) return error.UnknownModel;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.activateLocked(reg, id) catch |err| {
            // Das alte Modell bleibt benutzbar, wenn das neue nicht laedt.
            if (self.active == null) self.state.store(.failed, .release);
            return err;
        };
    }

    /// Liest die Deskriptoren neu ein.
    ///
    /// Aendert sich das aktive Modell, wird es neu geladen. Die Aenderungen
    /// werden gemeldet, damit der Aufrufer sie anzeigen kann.
    pub fn reload(self: *Engine) !registry.Changes {
        self.load_mutex.lockUncancelable(self.io);
        defer self.load_mutex.unlock(self.io);

        const reg = self.registry orelse return error.RegistryUnavailable;
        const changes = try reg.reload(self.io);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const wanted = reg.active_id orelse return changes;
        const entry = reg.find(wanted) orelse return changes;

        const current_id: ?[]const u8 = if (self.active) |*active| active.modelId() else null;
        const needs_reload = current_id == null or
            !std.mem.eql(u8, current_id.?, wanted) or
            self.active_fingerprint != entry.descriptor.fingerprint();

        if (needs_reload) try self.activateLocked(reg, wanted);

        return changes;
    }

    /// true, wenn ein Modell geladen ist und benutzt werden kann.
    pub fn isActive(self: *const Engine) bool {
        return self.state.load(.acquire) == .active;
    }

    /// Der Zustand der Engine.
    pub fn getState(self: *const Engine) State {
        return self.state.load(.acquire);
    }

    /// Der Text des letzten Fehlers.
    pub fn lastError(self: *const Engine) ?[]const u8 {
        return self.last_error;
    }

    /// Die Kennung des aktiven Modells.
    pub fn activeModelId(self: *Engine) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const active = self.active orelse return null;
        return active.modelId();
    }

    /// Die Abtastrate des aktiven Modells.
    pub fn sampleRate(self: *Engine) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const active = self.active orelse return self.opts.default_sample_rate;
        return active.sampleRate();
    }

    /// Die Kennungen aller Modelle der Registry.
    ///
    /// Die Liste und ihre Texte gehoeren dem Aufrufer.
    pub fn models(self: *Engine, gpa: std.mem.Allocator) ![][]const u8 {
        self.load_mutex.lockUncancelable(self.io);
        defer self.load_mutex.unlock(self.io);

        const reg = self.registry orelse return error.RegistryUnavailable;
        return reg.ids(gpa);
    }

    /// Die Namen der Stimmen des aktiven Modells.
    ///
    /// Die Liste und ihre Texte gehoeren dem Aufrufer.
    pub fn voices(self: *Engine, gpa: std.mem.Allocator) ![][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.active orelse return error.ModelNotReady;
        const names = try active.voiceNames(gpa);
        defer gpa.free(names);
        return copyStrings(gpa, names);
    }

    /// Die Sprachen des aktiven Modells.
    ///
    /// Die Liste und ihre Texte gehoeren dem Aufrufer.
    pub fn languages(self: *Engine, gpa: std.mem.Allocator) ![][]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.active orelse return error.ModelNotReady;
        const result = try gpa.alloc([]const u8, 1);
        errdefer gpa.free(result);
        result[0] = try gpa.dupe(u8, active.language());
        return result;
    }

    /// Die Sprache des aktiven Modells.
    ///
    /// Der Text liegt in eigenem Speicher und wird vom Aufrufer freigegeben.
    pub fn activeLanguage(self: *Engine, gpa: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.active orelse return error.ModelNotReady;
        return gpa.dupe(u8, active.language());
    }

    /// Passt eine Sprache zum aktiven Modell?
    ///
    /// Ohne Angabe gilt die Sprache des Modells.
    pub fn languageMatches(self: *Engine, requested: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.active orelse return false;
        return backend.languageMatches(active.language(), requested);
    }

    /// Loest einen Stimmnamen auf den internen Namen auf.
    ///
    /// Der Name liegt in eigenem Speicher und wird vom Aufrufer freigegeben.
    /// Null bedeutet: die Stimme gibt es nicht.
    pub fn resolveVoice(self: *Engine, gpa: std.mem.Allocator, requested: []const u8) !?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.active orelse return error.ModelNotReady;
        return active.resolveVoice(gpa, requested);
    }

    /// true, wenn die Registry ein Modell mit dieser Kennung kennt.
    pub fn hasModel(self: *Engine, id: []const u8) bool {
        self.load_mutex.lockUncancelable(self.io);
        defer self.load_mutex.unlock(self.io);

        const reg = self.registry orelse return false;
        return reg.find(id) != null;
    }

    /// Die Stimmen des aktiven Modells mit ihren Aliasen.
    ///
    /// Die Liste und ihre Texte gehoeren dem Aufrufer.
    pub fn voiceInfos(self: *Engine, gpa: std.mem.Allocator) ![]VoiceInfo {
        self.load_mutex.lockUncancelable(self.io);
        defer self.load_mutex.unlock(self.io);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.active orelse return error.ModelNotReady;
        const names = try active.voiceNames(gpa);
        defer gpa.free(names);

        // Die Aliase stehen im Deskriptor des aktiven Modells. Sie zeigen auf
        // den internen Namen einer Stimme.
        var aliases: std.ArrayList(AliasPair) = .empty;
        defer aliases.deinit(gpa);

        if (self.registry) |reg| {
            if (reg.active_id) |id| {
                if (reg.find(id)) |entry| {
                    for (entry.descriptor.voice_aliases) |alias| {
                        try aliases.append(gpa, .{ .alias = alias.alias, .target = alias.voice });
                    }
                }
            }
        } else if (self.standalone) |*desc| {
            // Ohne Registry stehen die Aliase im Deskriptor des Modells.
            for (desc.voice_aliases) |alias| {
                try aliases.append(gpa, .{ .alias = alias.alias, .target = alias.voice });
            }
        }

        var result: std.ArrayList(VoiceInfo) = .empty;
        errdefer {
            for (result.items) |*info| info.deinit(gpa);
            result.deinit(gpa);
        }

        for (names) |name| {
            // Die Aliase werden kopiert. Der Deskriptor kann beim Neuladen
            // der Registry ausgetauscht werden.
            var voice_aliases: std.ArrayList([]u8) = .empty;
            errdefer {
                for (voice_aliases.items) |alias| gpa.free(alias);
                voice_aliases.deinit(gpa);
            }

            for (aliases.items) |pair| {
                if (std.mem.eql(u8, pair.target, name)) {
                    try voice_aliases.append(gpa, try gpa.dupe(u8, pair.alias));
                }
            }

            const alias_slice = try voice_aliases.toOwnedSlice(gpa);
            errdefer {
                for (alias_slice) |alias| gpa.free(alias);
                gpa.free(alias_slice);
            }

            const owned_name = try gpa.dupe(u8, name);
            errdefer gpa.free(owned_name);

            try result.append(gpa, .{ .name = owned_name, .aliases = alias_slice });
        }

        return result.toOwnedSlice(gpa);
    }

    /// Die Angaben zu allen Modellen der Registry.
    ///
    /// Die Liste und ihre Texte gehoeren dem Aufrufer.
    pub fn modelInfos(self: *Engine, gpa: std.mem.Allocator) ![]ModelInfo {
        self.load_mutex.lockUncancelable(self.io);
        defer self.load_mutex.unlock(self.io);

        const reg = self.registry orelse return error.RegistryUnavailable;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var result: std.ArrayList(ModelInfo) = .empty;
        errdefer {
            for (result.items) |*info| info.deinit(gpa);
            result.deinit(gpa);
        }

        for (reg.order.items) |index| {
            const entry = &reg.entries.items[index];

            const id = try gpa.dupe(u8, entry.id);
            errdefer gpa.free(id);
            const name = try gpa.dupe(u8, entry.descriptor.name);
            errdefer gpa.free(name);
            const version = try gpa.dupe(u8, entry.descriptor.version);
            errdefer gpa.free(version);
            const language = try gpa.dupe(u8, entry.descriptor.text.language);
            errdefer gpa.free(language);

            const active = reg.active_id != null and std.mem.eql(u8, reg.active_id.?, entry.id);
            const sample_rate = if (active)
                self.sampleRateLocked()
            else
                entry.descriptor.sample_rate orelse self.opts.default_sample_rate;

            try result.append(gpa, .{
                .id = id,
                .name = name,
                .version = version,
                .language = language,
                .sample_rate = sample_rate,
                .active = active,
            });
        }

        return result.toOwnedSlice(gpa);
    }

    /// Synthetisiert Text mit dem aktiven Modell.
    ///
    /// Die Samples gehoeren dem Aufrufer.
    pub fn synthesize(
        self: *Engine,
        gpa: std.mem.Allocator,
        request: backend.Request,
    ) anyerror!backend.Result {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const active = self.active orelse return error.ModelNotReady;
        return active.synthesize(gpa, request);
    }

    /// Synthetisiert Text mit Sprache und Stimme.
    ///
    /// Eine leere Sprache oder Stimme nimmt die Vorgabe der Engine. Ohne
    /// Vorgabe gilt die Sprache des Modells und dessen erste Stimme.
    pub fn synthesizeFor(
        self: *Engine,
        gpa: std.mem.Allocator,
        text: []const u8,
        language: []const u8,
        voice: []const u8,
        speed: f32,
    ) anyerror!backend.Result {
        const chosen_language: ?[]const u8 = if (language.len > 0)
            language
        else if (self.opts.language.len > 0)
            self.opts.language
        else
            null;

        const chosen_voice: []const u8 = if (voice.len > 0) voice else self.opts.voice;

        return self.synthesize(gpa, .{
            .text = text,
            .voice = chosen_voice,
            .language = chosen_language,
            .speed = speed,
        });
    }

    /// Laedt ein Backend fuer den Deskriptor und setzt es als aktives Modell.
    ///
    /// Der Aufrufer muss `mutex` halten.
    fn activateLocked(self: *Engine, reg: *registry.Registry, id: []const u8) Error!void {
        const entry = reg.find(id) orelse return error.UnknownModel;

        const created = try self.createBackend(&entry.descriptor);

        if (self.active) |*old| old.deinit();
        self.active = created;
        self.active_fingerprint = entry.descriptor.fingerprint();

        reg.setActive(id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownModel => return error.UnknownModel,
        };

        self.state.store(.active, .release);
    }

    /// Laedt ein Modell aus einem Modellordner.
    ///
    /// Der Ordner muss die Datei `config.json` enthalten. Eine Registry gibt
    /// es dabei nicht, das Modell ist das einzige der Engine.
    ///
    /// Der Aufrufer muss `mutex` halten.
    fn activateStandalone(self: *Engine, dir: []const u8) Error!void {
        const path = try std.fs.path.join(self.gpa, &.{ dir, registry.descriptor_file });
        defer self.gpa.free(path);

        var desc = descriptor.load(self.gpa, self.io, path) catch |err| {
            self.setError(@errorName(err));
            std.log.err("Deskriptor {s} liess sich nicht lesen: {s}", .{ path, @errorName(err) });
            return error.ModelLoadFailed;
        };
        var moved = false;
        errdefer if (!moved) desc.deinit();

        const created = try self.createBackend(&desc);

        if (self.active) |*old| old.deinit();
        self.active = created;

        if (self.standalone) |*old| old.deinit();
        self.standalone = desc;
        moved = true;
        self.active_fingerprint = self.standalone.?.fingerprint();

        self.state.store(.active, .release);
    }

    /// Erzeugt das Backend, das zum Deskriptor gehoert.
    fn createBackend(self: *Engine, desc: *const descriptor.Descriptor) Error!backend.Backend {
        const runtime = self.runtime orelse return error.RuntimeUnavailable;

        const options: loader.Options = .{
            .espeak_library = self.opts.espeak_library,
            .espeak_data = self.opts.espeak_data,
            .session = self.opts.session,
            .default_sample_rate = self.opts.default_sample_rate,
        };

        switch (desc.backend) {
            .style_tokens => {
                return style_tokens.create(
                    self.gpa,
                    self.io,
                    runtime,
                    desc,
                    options,
                ) catch |err| {
                    self.setError(@errorName(err));
                    std.log.err(
                        "Modell {s} liess sich nicht laden: {s}",
                        .{ desc.model, @errorName(err) },
                    );
                    return switch (err) {
                        error.UnsupportedBackend => error.UnsupportedBackend,
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.ModelLoadFailed,
                    };
                };
            },
            .phoneme_ids => {
                return phoneme_ids.create(
                    self.gpa,
                    self.io,
                    runtime,
                    desc,
                    options,
                ) catch |err| {
                    self.setError(@errorName(err));
                    std.log.err(
                        "Modell {s} liess sich nicht laden: {s}",
                        .{ desc.model, @errorName(err) },
                    );
                    return switch (err) {
                        error.UnsupportedBackend => error.UnsupportedBackend,
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.ModelLoadFailed,
                    };
                };
            },
            .pocket_step => return error.UnsupportedBackend,
        }
    }

    /// Laedt die ONNX-Runtime.
    ///
    /// Ohne angegebenen Pfad werden die Standardorte geprueft. Ein Pfad, der
    /// nicht gefunden wird, liefert `error.RuntimeUnavailable`.
    fn openRuntime(self: *Engine) Error!*ort.Runtime {
        const gpa = self.gpa;
        const runtime = try gpa.create(ort.Runtime);
        errdefer gpa.destroy(runtime);

        if (self.opts.ort_library.len > 0) {
            var failure: ort.Failure = .{};
            runtime.* = ort.Runtime.open(self.opts.ort_library, &failure) catch {
                const message = std.fmt.allocPrint(
                    gpa,
                    "Die ONNX-Runtime aus {s} liess sich nicht laden: {s}",
                    .{ self.opts.ort_library, failure.message() },
                ) catch {
                    self.setError(failure.message());
                    return error.RuntimeUnavailable;
                };
                defer gpa.free(message);
                self.setError(message);
                return error.RuntimeUnavailable;
            };
            return runtime;
        }

        var failure: ort.Failure = .{};
        for (default_ort_libraries) |path| {
            runtime.* = ort.Runtime.open(path, &failure) catch continue;
            return runtime;
        }

        var message = std.ArrayList(u8).empty;
        defer message.deinit(gpa);
        message.appendSlice(gpa, "Keine ONNX-Runtime gefunden. Gesucht wurde in: ") catch
            return error.RuntimeUnavailable;
        for (default_ort_libraries, 0..) |path, index| {
            if (index > 0) message.appendSlice(gpa, ", ") catch {};
            message.appendSlice(gpa, path) catch {};
        }
        message.appendSlice(gpa, ". Setze BKG_TTS_ORT_LIBRARY auf den Pfad der Bibliothek.") catch {};
        self.setError(message.items);
        return error.RuntimeUnavailable;
    }

    /// Die Abtastrate des aktiven Modells. Der Aufrufer haelt `mutex`.
    fn sampleRateLocked(self: *const Engine) u32 {
        const active = self.active orelse return self.opts.default_sample_rate;
        return active.sampleRate();
    }

    /// Merkt sich den Text des letzten Fehlers.
    fn setError(self: *Engine, message: []const u8) void {
        if (self.last_error) |old| self.gpa.free(old);
        self.last_error = self.gpa.dupe(u8, message) catch null;
    }
};

/// Kopiert eine Liste von Texten in eigenen Speicher.
fn copyStrings(gpa: std.mem.Allocator, names: []const []const u8) ![][]const u8 {
    const result = try gpa.alloc([]const u8, names.len);
    errdefer {
        for (result) |item| gpa.free(item);
        gpa.free(result);
    }
    for (names, 0..) |name, index| {
        result[index] = try gpa.dupe(u8, name);
    }
    return result;
}

/// Gibt eine Liste von Texten frei, die die Engine geliefert hat.
pub fn freeStrings(gpa: std.mem.Allocator, items: [][]const u8) void {
    for (items) |item| gpa.free(item);
    gpa.free(items);
}

/// Gibt die Angaben zu den Modellen frei.
pub fn freeModelInfos(gpa: std.mem.Allocator, items: []ModelInfo) void {
    for (items) |*info| info.deinit(gpa);
    gpa.free(items);
}

/// Gibt die Angaben zu den Stimmen frei.
pub fn freeVoiceInfos(gpa: std.mem.Allocator, items: []VoiceInfo) void {
    for (items) |*info| info.deinit(gpa);
    gpa.free(items);
}

const testing = std.testing;

const test_config =
    \\{
    \\  "name": "Testmodell",
    \\  "model": "a",
    \\  "model_file": "a.onnx",
    \\  "voices": "a.npz"
    \\}
;

/// Legt ein Verzeichnis mit einem Deskriptor an und gibt seinen Pfad frei.
fn testModelsDir(gpa: std.mem.Allocator, tmp: *const testing.TmpDir) ![]u8 {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.json", .data = test_config });
    const dir_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    return dir_path;
}

test "Engine meldet ein fehlendes Modellverzeichnis" {
    const gpa = testing.allocator;
    var engine = Engine.init(gpa, testing.io, .{
        .models_dir = ".zig-cache/tmp/gibt-es-nicht-12345",
    });
    defer engine.deinit();

    try testing.expectError(error.RegistryUnavailable, engine.load());
    try testing.expectEqual(State.failed, engine.getState());
    try testing.expect(!engine.isActive());
}

test "Engine meldet ein unbekanntes Modell" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try testModelsDir(gpa, &tmp);
    defer gpa.free(dir_path);

    var engine = Engine.init(gpa, testing.io, .{
        .models_dir = dir_path,
        .model = "gibt-es-nicht",
    });
    defer engine.deinit();

    try testing.expectError(error.UnknownModel, engine.load());
    try testing.expectEqual(State.failed, engine.getState());
}

test "Engine meldet eine fehlende ONNX-Runtime" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try testModelsDir(gpa, &tmp);
    defer gpa.free(dir_path);

    var engine = Engine.init(gpa, testing.io, .{
        .models_dir = dir_path,
        .ort_library = "/gibt-es-nicht/libonnxruntime.so",
    });
    defer engine.deinit();

    try testing.expectError(error.RuntimeUnavailable, engine.load());
    try testing.expectEqual(State.failed, engine.getState());
    try testing.expect(engine.lastError() != null);
}
