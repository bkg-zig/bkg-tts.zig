//! Persistent pronunciation dictionary for the native Magpie server.
//! Customer text is not logged; dictionary values are stored only in the configured local JSON file.
const std = @import("std");

pub const Entry = struct {
    word: []const u8,
    language: []const u8 = "en",
    ipa: []const u8,
    enabled: bool = true,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Store {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearEntries();
        self.entries.deinit(self.gpa);
    }

    fn clearEntries(self: *Store) void {
        for (self.entries.items) |entry| {
            self.gpa.free(entry.word);
            self.gpa.free(entry.language);
            self.gpa.free(entry.ipa);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn load(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const raw = std.Io.Dir.readFileAlloc(
            .cwd(),
            self.io,
            self.path,
            self.gpa,
            std.Io.Limit.limited(4 * 1024 * 1024),
        ) catch |err| {
            if (err == error.FileNotFound) {
                self.clearEntries();
                return;
            }
            return error.PronunciationReadFailed;
        };
        defer self.gpa.free(raw);

        const parsed = std.json.parseFromSlice([]Entry, self.gpa, raw, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidPronunciationFile;
        defer parsed.deinit();

        var replacement: std.ArrayList(Entry) = .empty;
        errdefer {
            for (replacement.items) |entry| {
                self.gpa.free(entry.word);
                self.gpa.free(entry.language);
                self.gpa.free(entry.ipa);
            }
            replacement.deinit(self.gpa);
        }

        for (parsed.value) |entry| {
            if (entry.word.len == 0 or entry.language.len == 0) continue;
            try replacement.append(self.gpa, .{
                .word = try self.gpa.dupe(u8, entry.word),
                .language = try self.gpa.dupe(u8, entry.language),
                .ipa = try self.gpa.dupe(u8, entry.ipa),
                .enabled = entry.enabled,
            });
        }

        self.clearEntries();
        self.entries.deinit(self.gpa);
        self.entries = replacement;
    }

    fn persistEntriesLocked(self: *Store, entries: []const Entry) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.gpa, entries, .{});
        defer self.gpa.free(encoded);
        std.Io.Dir.writeFile(.cwd(), self.io, .{
            .sub_path = self.path,
            .data = encoded,
            .flags = .{ .truncate = true },
        }) catch return error.PronunciationWriteFailed;
    }

    pub fn listJson(self: *Store) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return try std.json.Stringify.valueAlloc(self.gpa, self.entries.items, .{});
    }

    pub fn upsert(self: *Store, word: []const u8, language: []const u8, ipa: []const u8, enabled: bool) ![]u8 {
        if (word.len == 0 or language.len == 0 or word.len > 256 or language.len > 32 or ipa.len > 512) return error.InvalidEntry;

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var found: ?usize = null;
        for (self.entries.items, 0..) |entry, index| {
            if (std.ascii.eqlIgnoreCase(entry.word, word) and std.ascii.eqlIgnoreCase(entry.language, language)) {
                found = index;
                break;
            }
        }

        const new_entry = Entry{
            .word = try self.gpa.dupe(u8, word),
            .language = try self.gpa.dupe(u8, language),
            .ipa = try self.gpa.dupe(u8, ipa),
            .enabled = enabled,
        };
        errdefer {
            self.gpa.free(new_entry.word);
            self.gpa.free(new_entry.language);
            self.gpa.free(new_entry.ipa);
        }

        // Persist a candidate snapshot before mutating in-memory state. A disk
        // error must not leave dangling slices or make a failed write look live.
        var candidate: std.ArrayList(Entry) = .empty;
        defer candidate.deinit(self.gpa);
        try candidate.ensureTotalCapacity(self.gpa, self.entries.items.len + @intFromBool(found == null));
        for (self.entries.items, 0..) |entry, index| {
            try candidate.append(self.gpa, if (found != null and found.? == index) new_entry else entry);
        }
        if (found == null) try candidate.append(self.gpa, new_entry);
        if (found == null) try self.entries.ensureTotalCapacity(self.gpa, self.entries.items.len + 1);
        try self.persistEntriesLocked(candidate.items);

        if (found) |index| {
            const old = self.entries.items[index];
            self.entries.items[index] = new_entry;
            self.gpa.free(old.word);
            self.gpa.free(old.language);
            self.gpa.free(old.ipa);
        } else {
            self.entries.appendAssumeCapacity(new_entry);
        }
        return try std.json.Stringify.valueAlloc(self.gpa, new_entry, .{});
    }

    pub fn delete(self: *Store, word: []const u8, language: []const u8) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.entries.items, 0..) |entry, index| {
            if (std.ascii.eqlIgnoreCase(entry.word, word) and std.ascii.eqlIgnoreCase(entry.language, language)) {
                var candidate: std.ArrayList(Entry) = .empty;
                defer candidate.deinit(self.gpa);
                try candidate.ensureTotalCapacity(self.gpa, self.entries.items.len - 1);
                for (self.entries.items, 0..) |item, item_index| {
                    if (item_index != index) try candidate.append(self.gpa, item);
                }
                // Do not remove the live entry unless persistence succeeded.
                try self.persistEntriesLocked(candidate.items);
                const removed = self.entries.orderedRemove(index);
                self.gpa.free(removed.word);
                self.gpa.free(removed.language);
                self.gpa.free(removed.ipa);
                return true;
            }
        }
        return false;
    }

    /// Applies enabled entries using exact-word boundaries and matching language.
    /// UTF-8 bytes >= 0x80 are treated as word bytes so a rule cannot split a UTF-8 character.
    pub fn apply(self: *Store, text: []const u8, language: []const u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var current = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(current);

        for (self.entries.items) |entry| {
            if (!entry.enabled or !(std.ascii.eqlIgnoreCase(entry.language, language) or std.ascii.eqlIgnoreCase(entry.language, "en")) or entry.word.len == 0) continue;
            const ipa_form = try std.fmt.allocPrint(self.gpa, "| {s} |", .{entry.ipa});
            defer self.gpa.free(ipa_form);
            if (std.mem.indexOf(u8, current, ipa_form) != null) continue;
            const next = try replaceWord(self.gpa, current, entry.word, ipa_form);
            self.gpa.free(current);
            current = next;
        }
        return current;
    }
};

fn isWordByte(c: u8) bool {
    return c >= 0x80 or std.ascii.isAlphanumeric(c) or c == '_';
}

fn replaceWord(gpa: std.mem.Allocator, source: []const u8, word: []const u8, replacement: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);

    var start: usize = 0;
    while (start < source.len) {
        const relative = std.mem.indexOf(u8, source[start..], word) orelse {
            try result.appendSlice(gpa, source[start..]);
            break;
        };
        const at = start + relative;
        const end = at + word.len;
        const left_ok = at == 0 or !isWordByte(source[at - 1]);
        const right_ok = end == source.len or !isWordByte(source[end]);
        if (left_ok and right_ok) {
            try result.appendSlice(gpa, source[start..at]);
            try result.appendSlice(gpa, replacement);
            start = end;
        } else {
            const advance = at + @max(@as(usize, 1), word.len);
            try result.appendSlice(gpa, source[start..advance]);
            start = advance;
        }
    }
    return try result.toOwnedSlice(gpa);
}

test "pronunciation replacement respects word boundaries and UTF-8 bytes" {
    const gpa = std.testing.allocator;
    const input = "GST and GSTIN, plus Café GST.";
    const output = try replaceWord(gpa, input, "GST", "gee ess tee");
    defer gpa.free(output);
    try std.testing.expectEqualStrings("gee ess tee and GSTIN, plus Café gee ess tee.", output);
}

test "disabled rule is not applied" {
    const gpa = std.testing.allocator;
    const input = "BKG is spoken.";
    const output = try replaceWord(gpa, input, "BKG", "bee kay gee");
    defer gpa.free(output);
    try std.testing.expectEqualStrings("bee kay gee is spoken.", output);
}
