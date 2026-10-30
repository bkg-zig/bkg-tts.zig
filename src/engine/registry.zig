//! Registry der verfuegbaren Modelle.
//!
//! Die Registry liest ein Verzeichnis mit einer JSON-Datei je Modell. Jede
//! Datei ist ein Deskriptor und nennt ueber das Feld "model" die Kennung des
//! Modells. Zusaetzlich kann eine Datei `registry.json` die benutzten Modelle
//! benennen, ihre Reihenfolge festlegen und das Vorgabemodell benennen.
//!
//! Die Registry kennt keine Modellfamilie. Sie sammelt Deskriptoren, vergleicht
//! deren Fingerabdruecke und meldet, welche Modelle sich geaendert haben.
const std = @import("std");

const descriptor = @import("../tts/descriptor.zig");

/// Name der Datei, die die Liste der Modelle enthaelt.
pub const list_file = "registry.json";

/// Hoechstgroesse der Datei mit der Modelliste.
const max_list_bytes = 1024 * 1024;

/// Ein Modell der Registry.
pub const Entry = struct {
    /// Kennung des Modells. Sie steht im Feld "model" des Deskriptors.
    id: []const u8,
    /// Pfad der Deskriptordatei.
    path: []const u8,
    /// Der gelesene Deskriptor.
    descriptor: descriptor.Descriptor,
};

/// Aenderungen, die ein Neuladen gefunden hat.
pub const Changes = struct {
    gpa: std.mem.Allocator,
    /// Modelle, die neu hinzugekommen sind.
    added: []const []const u8,
    /// Modelle, deren Deskriptor sich geaendert hat.
    changed: []const []const u8,
    /// Modelle, die nicht mehr vorhanden sind.
    removed: []const []const u8,

    pub fn deinit(self: *Changes) void {
        for (self.added) |id| self.gpa.free(id);
        self.gpa.free(self.added);
        for (self.changed) |id| self.gpa.free(id);
        self.gpa.free(self.changed);
        for (self.removed) |id| self.gpa.free(id);
        self.gpa.free(self.removed);
        self.* = undefined;
    }

    /// true, wenn sich nichts geaendert hat.
    pub fn isEmpty(self: *const Changes) bool {
        return self.added.len == 0 and self.changed.len == 0 and self.removed.len == 0;
    }
};

/// Die Registry mit allen bekannten Modellen.
pub const Registry = struct {
    gpa: std.mem.Allocator,
    /// Verzeichnis, in dem die Deskriptoren liegen.
    dir: []const u8,
    /// Die Modelle in der Reihenfolge der Dateinamen.
    entries: std.ArrayList(Entry) = .empty,
    /// Die Reihenfolge, in der die Modelle benutzt werden sollen. Die Werte
    /// sind Indizes in `entries`.
    order: std.ArrayList(usize) = .empty,
    /// Modell, das beim Start benutzt wird.
    default_id: ?[]const u8 = null,
    /// Modell, das gerade benutzt wird.
    active_id: ?[]const u8 = null,

    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |*entry| {
            entry.descriptor.deinit();
            self.gpa.free(entry.path);
        }
        self.entries.deinit(self.gpa);
        self.order.deinit(self.gpa);
        if (self.default_id) |id| self.gpa.free(id);
        if (self.active_id) |id| self.gpa.free(id);
        self.gpa.free(self.dir);
        self.* = undefined;
    }

    /// Liest alle Modelle aus einem Verzeichnis.
    ///
    /// Ohne `registry.json` werden alle JSON-Dateien des Verzeichnisses als
    /// Deskriptoren gelesen. Mit `registry.json` benennt die Datei die Modelle,
    /// die benutzt werden sollen, und kann ein Vorgabemodell festlegen.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !Registry {
        var registry = Registry{
            .gpa = gpa,
            .dir = try gpa.dupe(u8, dir),
        };
        errdefer registry.deinit();

        var scan = try registry.readAll(io);

        // Die Registry uebernimmt die gelesenen Deskriptoren.
        registry.entries = scan.entries;
        registry.order = scan.order;
        registry.default_id = scan.default_id;
        scan.entries = .empty;
        scan.order = .empty;
        scan.default_id = null;
        scan.deinit(gpa);

        if (registry.default_id) |id| registry.active_id = try gpa.dupe(u8, id);

        return registry;
    }

    /// Sucht ein Modell nach seiner Kennung.
    pub fn find(self: *const Registry, id: []const u8) ?*const Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }

    /// Das gerade benutzte Modell.
    pub fn active(self: *const Registry) ?*const Entry {
        const id = self.active_id orelse return null;
        return self.find(id);
    }

    /// Alle Kennungen in der Reihenfolge der Registry.
    pub fn ids(self: *const Registry, gpa: std.mem.Allocator) ![][]const u8 {
        const result = try gpa.alloc([]const u8, self.order.items.len);
        for (self.order.items, 0..) |index, position| {
            result[position] = try gpa.dupe(u8, self.entries.items[index].id);
        }
        return result;
    }

    /// Waehlt das Modell, das benutzt wird.
    pub fn setActive(self: *Registry, id: []const u8) !void {
        if (self.find(id) == null) return error.UnknownModel;

        const copy = try self.gpa.dupe(u8, id);
        if (self.active_id) |old| self.gpa.free(old);
        self.active_id = copy;
    }

    /// Liest alle Deskriptoren neu ein.
    ///
    /// Die Aenderungen werden gemeldet, damit die Engine nur die betroffenen
    /// Modelle neu laden muss. Unveraenderte Modelle behalten ihren Deskriptor
    /// und damit ihren Platz in der Registry.
    pub fn reload(self: *Registry, io: std.Io) !Changes {
        var scan = try self.readAll(io);
        defer scan.deinit(self.gpa);

        var added = std.ArrayList([]const u8).empty;
        defer added.deinit(self.gpa);
        var changed = std.ArrayList([]const u8).empty;
        defer changed.deinit(self.gpa);
        var removed = std.ArrayList([]const u8).empty;
        defer removed.deinit(self.gpa);

        // Fuer jedes alte Modell merken wir, ob sein Deskriptor unveraendert in
        // die neue Liste uebernommen wurde. Nur dann darf der alte Deskriptor
        // nicht freigegeben werden.
        const kept = try self.gpa.alloc(bool, self.entries.items.len);
        defer self.gpa.free(kept);
        @memset(kept, false);

        // Fuer jedes alte Modell merken wir, ob es ueberhaupt noch gibt.
        const present = try self.gpa.alloc(bool, self.entries.items.len);
        defer self.gpa.free(present);
        @memset(present, false);

        for (scan.entries.items) |*new_entry| {
            const old_index = self.indexOf(new_entry.id) orelse {
                try added.append(self.gpa, try self.gpa.dupe(u8, new_entry.id));
                continue;
            };
            present[old_index] = true;

            const old_entry = &self.entries.items[old_index];
            if (old_entry.descriptor.fingerprint() == new_entry.descriptor.fingerprint()) {
                // Unveraendert. Der alte Deskriptor bleibt in der Registry.
                new_entry.descriptor.deinit();
                self.gpa.free(new_entry.path);
                new_entry.descriptor = old_entry.descriptor;
                new_entry.path = old_entry.path;
                kept[old_index] = true;
                continue;
            }

            try changed.append(self.gpa, try self.gpa.dupe(u8, new_entry.id));
        }

        for (self.entries.items, 0..) |*old_entry, index| {
            if (!present[index]) {
                try removed.append(self.gpa, try self.gpa.dupe(u8, old_entry.id));
            }
            if (kept[index]) continue;
            old_entry.descriptor.deinit();
            self.gpa.free(old_entry.path);
        }

        self.entries.deinit(self.gpa);
        self.entries = scan.entries;
        self.order.deinit(self.gpa);
        self.order = scan.order;
        scan.entries = .empty;
        scan.order = .empty;

        // Das Vorgabemodell kann sich mit der Datei registry.json geaendert
        // haben.
        if (self.default_id) |old| self.gpa.free(old);
        self.default_id = scan.default_id;
        scan.default_id = null;

        // Faellt das aktive Modell weg, wird das Vorgabemodell benutzt.
        if (self.active_id) |current| {
            if (self.find(current) == null) {
                self.gpa.free(current);
                self.active_id = null;
                if (self.default_id) |fallback| {
                    self.active_id = try self.gpa.dupe(u8, fallback);
                }
            }
        } else if (self.default_id) |fallback| {
            self.active_id = try self.gpa.dupe(u8, fallback);
        }

        return .{
            .gpa = self.gpa,
            .added = try added.toOwnedSlice(self.gpa),
            .changed = try changed.toOwnedSlice(self.gpa),
            .removed = try removed.toOwnedSlice(self.gpa),
        };
    }

    fn indexOf(self: *const Registry, id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id, id)) return index;
        }
        return null;
    }

    /// Liest alle Deskriptoren und die Modelliste des Verzeichnisses.
    fn readAll(self: *Registry, io: std.Io) !Scan {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const mem = arena.allocator();

        var files = std.ArrayList([]const u8).empty;
        defer files.deinit(mem);
        try self.collectFiles(io, mem, &files);

        var entries = try self.parseEntries(io, files.items);
        errdefer {
            for (entries.items) |*entry| {
                entry.descriptor.deinit();
                self.gpa.free(entry.path);
            }
            entries.deinit(self.gpa);
        }

        const list = try self.readList(io, mem);

        // Die Reihenfolge folgt der Modellliste, wenn es eine gibt. Modelle,
        // die nicht in der Liste stehen, bleiben erhalten und kommen hinten.
        var order = std.ArrayList(usize).empty;
        defer order.deinit(mem);

        if (list.models) |models| {
            for (models) |id| {
                const index = findIndex(entries.items, id) orelse return error.UnknownModel;
                try order.append(mem, index);
            }
            for (entries.items, 0..) |entry, index| {
                var listed = false;
                for (models) |id| {
                    if (std.mem.eql(u8, entry.id, id)) {
                        listed = true;
                        break;
                    }
                }
                if (!listed) try order.append(mem, index);
            }
        } else {
            for (entries.items, 0..) |_, index| try order.append(mem, index);
        }

        var default_id: ?[]const u8 = null;
        if (list.default_id) |id| {
            if (findIndex(entries.items, id) == null) return error.UnknownModel;
            default_id = try self.gpa.dupe(u8, id);
        } else if (entries.items.len > 0) {
            default_id = try self.gpa.dupe(u8, entries.items[0].id);
        }

        const order_copy = try self.gpa.dupe(usize, order.items);

        return .{
            .entries = entries,
            .order = .{ .items = order_copy, .capacity = order_copy.len },
            .default_id = default_id,
        };
    }

    /// Liest jeden Deskriptor und prueft, dass die Kennungen verschieden sind.
    fn parseEntries(self: *Registry, io: std.Io, files: []const []const u8) !std.ArrayList(Entry) {
        var entries = std.ArrayList(Entry).empty;
        errdefer {
            for (entries.items) |*entry| {
                entry.descriptor.deinit();
                self.gpa.free(entry.path);
            }
            entries.deinit(self.gpa);
        }

        for (files) |path| {
            var parsed = try descriptor.load(self.gpa, io, path);
            errdefer parsed.deinit();

            for (entries.items) |existing| {
                if (std.mem.eql(u8, existing.id, parsed.model)) return error.DuplicateModel;
            }

            try entries.append(self.gpa, .{
                .id = parsed.model,
                .path = try self.gpa.dupe(u8, path),
                .descriptor = parsed,
            });
        }

        return entries;
    }

    /// Sammelt die Pfade aller Deskriptoren im Verzeichnis.
    fn collectFiles(
        self: *Registry,
        io: std.Io,
        mem: std.mem.Allocator,
        files: *std.ArrayList([]const u8),
    ) !void {
        const dir = std.Io.Dir.cwd().openDir(io, self.dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return error.RegistryDirNotFound,
            else => return err,
        };
        defer dir.close(io);

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            if (std.mem.eql(u8, entry.name, list_file)) continue;

            const path = try std.fs.path.join(mem, &.{ self.dir, entry.name });
            try files.append(mem, path);
        }

        std.mem.sort([]const u8, files.items, {}, lessThanPath);
    }

    /// Liest die Datei `registry.json`, falls sie vorhanden ist.
    fn readList(self: *Registry, io: std.Io, mem: std.mem.Allocator) !List {
        const path = try std.fs.path.join(mem, &.{ self.dir, list_file });

        const data = std.Io.Dir.cwd().readFileAlloc(io, path, mem, .limited(max_list_bytes)) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };

        const parsed = try std.json.parseFromSlice(std.json.Value, mem, data, .{});
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => return error.ExpectedObject,
        };

        var list = List{};

        if (root.get("default")) |value| {
            list.default_id = switch (value) {
                .string => |text| text,
                else => return error.ExpectedString,
            };
        }

        if (root.get("models")) |value| {
            const array = switch (value) {
                .array => |array| array,
                else => return error.ExpectedArray,
            };

            const models = try mem.alloc([]const u8, array.items.len);
            for (array.items, 0..) |item, index| {
                models[index] = switch (item) {
                    .string => |text| text,
                    else => return error.ExpectedString,
                };
            }
            list.models = models;
        }

        return list;
    }
};

/// Die Modellliste aus `registry.json`.
const List = struct {
    /// Vorgabemodell.
    default_id: ?[]const u8 = null,
    /// Modelle in der gewuenschten Reihenfolge.
    models: ?[]const []const u8 = null,
};

/// Das Ergebnis eines Durchlaufs durch das Verzeichnis.
const Scan = struct {
    entries: std.ArrayList(Entry),
    order: std.ArrayList(usize),
    default_id: ?[]const u8,

    fn deinit(self: *Scan, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            entry.descriptor.deinit();
            gpa.free(entry.path);
        }
        self.entries.deinit(gpa);
        self.order.deinit(gpa);
        if (self.default_id) |id| gpa.free(id);
        self.* = undefined;
    }
};

fn lessThanPath(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Sucht einen Eintrag nach seiner Kennung.
fn findIndex(entries: []const Entry, id: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.id, id)) return index;
    }
    return null;
}

const testing = std.testing;

const model_a =
    \\{
    \\  "name": "Modell A",
    \\  "model": "a",
    \\  "model_file": "a.onnx",
    \\  "voices": "a.npz"
    \\}
;

const model_b =
    \\{
    \\  "name": "Modell B",
    \\  "model": "b",
    \\  "model_file": "b.onnx",
    \\  "voices": "b.npz"
    \\}
;

fn writeFile(dir: std.Io.Dir, io: std.Io, name: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

fn tmpPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]const u8 {
    return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

test "Registry liest alle Deskriptoren eines Verzeichnisses" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "a.json", model_a);
    try writeFile(tmp.dir, io, "b.json", model_b);

    const dir_path = try tmpPath(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);

    var registry = try Registry.load(testing.allocator, io, dir_path);
    defer registry.deinit();

    try testing.expectEqual(@as(usize, 2), registry.entries.items.len);
    try testing.expectEqualStrings("a", registry.entries.items[0].id);
    try testing.expectEqualStrings("b", registry.entries.items[1].id);
    try testing.expectEqualStrings("a", registry.default_id.?);
    try testing.expectEqualStrings("a", registry.active_id.?);

    try testing.expect(registry.find("b") != null);
    try testing.expect(registry.find("c") == null);
}

test "Registry befolgt die Modelliste und ihre Reihenfolge" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "a.json", model_a);
    try writeFile(tmp.dir, io, "b.json", model_b);
    try writeFile(tmp.dir, io, "registry.json",
        \\{
        \\  "default": "b",
        \\  "models": ["b", "a"]
        \\}
    );

    const dir_path = try tmpPath(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);

    var registry = try Registry.load(testing.allocator, io, dir_path);
    defer registry.deinit();

    try testing.expectEqual(@as(usize, 2), registry.entries.items.len);
    try testing.expectEqualStrings("b", registry.default_id.?);
    try testing.expectEqualStrings("b", registry.active_id.?);

    const ids = try registry.ids(testing.allocator);
    defer {
        for (ids) |id| testing.allocator.free(id);
        testing.allocator.free(ids);
    }
    try testing.expectEqualStrings("b", ids[0]);
    try testing.expectEqualStrings("a", ids[1]);
}

test "Registry meldet unbekanntes Modell in der Modelliste" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "a.json", model_a);
    try writeFile(tmp.dir, io, "registry.json",
        \\{
        \\  "models": ["a", "fehlt"]
        \\}
    );

    const dir_path = try tmpPath(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);

    try testing.expectError(
        error.UnknownModel,
        Registry.load(testing.allocator, io, dir_path),
    );
}

test "Registry meldet ein Modell mit doppelter Kennung" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "a.json", model_a);
    try writeFile(tmp.dir, io, "b.json", model_a);

    const dir_path = try tmpPath(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);

    try testing.expectError(
        error.DuplicateModel,
        Registry.load(testing.allocator, io, dir_path),
    );
}

test "Neuladen meldet geaenderte, neue und entfallene Modelle" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "a.json", model_a);
    try writeFile(tmp.dir, io, "b.json", model_b);

    const dir_path = try tmpPath(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);

    var registry = try Registry.load(testing.allocator, io, dir_path);
    defer registry.deinit();

    // Modell a wird geaendert, Modell b entfaellt, Modell c kommt hinzu.
    try writeFile(tmp.dir, io, "a.json",
        \\{
        \\  "name": "Modell A neu",
        \\  "model": "a",
        \\  "model_file": "a.onnx",
        \\  "voices": "a.npz"
        \\}
    );
    try tmp.dir.deleteFile(io, "b.json");
    try writeFile(tmp.dir, io, "c.json",
        \\{
        \\  "name": "Modell C",
        \\  "model": "c",
        \\  "model_file": "c.onnx",
        \\  "voices": "c.npz"
        \\}
    );

    var changes = try registry.reload(io);
    defer changes.deinit();

    try testing.expectEqual(@as(usize, 1), changes.added.len);
    try testing.expectEqualStrings("c", changes.added[0]);
    try testing.expectEqual(@as(usize, 1), changes.changed.len);
    try testing.expectEqualStrings("a", changes.changed[0]);
    try testing.expectEqual(@as(usize, 1), changes.removed.len);
    try testing.expectEqualStrings("b", changes.removed[0]);

    try testing.expectEqual(@as(usize, 2), registry.entries.items.len);
    try testing.expectEqualStrings("Modell A neu", registry.find("a").?.descriptor.name);
    try testing.expect(registry.find("b") == null);
    try testing.expect(registry.find("c") != null);

    // Das aktive Modell ist weiterhin vorhanden.
    try testing.expectEqualStrings("a", registry.active_id.?);
}

test "Neuladen ohne Aenderung meldet nichts" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, io, "a.json", model_a);

    const dir_path = try tmpPath(testing.allocator, &tmp);
    defer testing.allocator.free(dir_path);

    var registry = try Registry.load(testing.allocator, io, dir_path);
    defer registry.deinit();

    var changes = try registry.reload(io);
    defer changes.deinit();

    try testing.expect(changes.isEmpty());
    try testing.expectEqual(@as(usize, 1), registry.entries.items.len);
}

test "Registry meldet ein fehlendes Verzeichnis" {
    try testing.expectError(
        error.RegistryDirNotFound,
        Registry.load(testing.allocator, testing.io, ".zig-cache/tmp/gibt-es-nicht-12345"),
    );
}
