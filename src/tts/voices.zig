//! Stimmdaten aus `voices.npz` lesen.
//!
//! Die Kitten-Modelle liefern ihre Stimmembeddings als ZIP-Archiv mit
//! eingebetteten NPY-Dateien. Die Eintraege sind unkomprimiert gespeichert,
//! deshalb reicht ein eigener ZIP-Leser ohne Inflate-Implementierung.
const std = @import("std");

const max_archive_bytes = 256 * 1024 * 1024;
const max_entries = 256;

const signature_eocd: u32 = 0x06054b50;
const signature_central: u32 = 0x02014b50;
const signature_local: u32 = 0x04034b50;

/// Eine Stimme mit Their Style-Embeddings.
pub const Voice = struct {
    name: []const u8,
    /// Zeilenweise Embeddings: eine Zeile je Laenge des Eingabetextes.
    rows: usize,
    columns: usize,
    embeddings: []f32,

    /// Liefert die Zeile fuer eine bestimmte Textlaenge.
    pub fn row(self: *const Voice, length: usize) []const f32 {
        const index = @min(length, self.rows - 1);
        const start = index * self.columns;
        return self.embeddings[start .. start + self.columns];
    }
};

pub const Voices = struct {
    gpa: std.mem.Allocator,
    entries: []Voice,

    pub fn deinit(self: *Voices) void {
        for (self.entries) |entry| {
            self.gpa.free(entry.name);
            self.gpa.free(entry.embeddings);
        }
        self.gpa.free(self.entries);
        self.* = undefined;
    }

    pub fn find(self: *const Voices, name: []const u8) ?*const Voice {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// Alle Stimmnamen in der Reihenfolge des Archivs.
    pub fn names(self: *const Voices, gpa: std.mem.Allocator) ![][]const u8 {
        const result = try gpa.alloc([]const u8, self.entries.len);
        for (self.entries, 0..) |entry, index| result[index] = entry.name;
        return result;
    }
};

/// Liest alle Stimmembeddings aus einem NPZ-Archiv.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Voices {
    const data = try std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .limited(max_archive_bytes));
    defer gpa.free(data);

    const count = try countEntries(data);
    const entries = try gpa.alloc(Voice, count);
    errdefer gpa.free(entries);
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.embeddings);
        }
    }

    var offset = try centralDirectoryOffset(data);
    for (0..count) |index| {
        const header = try readCentralHeader(data, offset);
        offset = header.next_offset;

        const file_name = data[header.name_offset..][0..header.name_len];
        if (!std.mem.endsWith(u8, file_name, ".npy")) continue;

        const local = try readLocalHeader(data, header.local_offset);
        if (local.method != 0) return error.CompressedArchiveUnsupported;

        const payload = data[local.data_offset..][0..header.compressed_size];
        const parsed = try parseNpy(payload);
        if (parsed.descr[0] == '>' or parsed.descr[0] == '!') return error.UnsupportedByteOrder;
        if (!std.mem.eql(u8, parsed.descr[1..], "f4")) return error.UnsupportedDtype;
        if (parsed.fortran_order) return error.UnsupportedFortranOrder;
        if (parsed.shape.len != 2) return error.UnsupportedShape;

        const rows = parsed.shape[0];
        const columns = parsed.shape[1];
        const count_floats = std.math.mul(usize, rows, columns) catch return error.AudioTooLarge;
        if (parsed.data.len < count_floats * @sizeOf(f32)) return error.TruncatedArray;

        const embeddings = try gpa.alloc(f32, count_floats);
        errdefer gpa.free(embeddings);
        const raw: [*]const f32 = @ptrCast(@alignCast(parsed.data.ptr));
        @memcpy(embeddings, raw[0..count_floats]);

        const name = try gpa.dupe(u8, file_name[0 .. file_name.len - 4]);
        errdefer gpa.free(name);

        entries[filled] = .{
            .name = name,
            .rows = rows,
            .columns = columns,
            .embeddings = embeddings,
        };
        filled += 1;
    }

    return .{ .gpa = gpa, .entries = entries[0..filled] };
}

const CentralHeader = struct {
    name_offset: usize,
    name_len: usize,
    method: u16,
    compressed_size: usize,
    local_offset: usize,
    next_offset: usize,
};

const LocalHeader = struct {
    method: u16,
    data_offset: usize,
};

fn findEndOfCentralDirectory(data: []const u8) !usize {
    // Der EOCD liegt am Dateiende, gefolgt von einem optionalen Kommentar.
    const max_back = @min(data.len, 22 + 0xffff);
    var index = data.len - max_back;
    while (index < data.len) : (index += 1) {
        if (readU32(data, index) == signature_eocd) return index;
    }
    return error.MissingEndOfCentralDirectory;
}

fn countEntries(data: []const u8) !usize {
    const eocd = try findEndOfCentralDirectory(data);
    const count = readU16(data, eocd + 10);
    if (count == 0 or count > max_entries) return error.InvalidEntryCount;
    return count;
}

fn centralDirectoryOffset(data: []const u8) !usize {
    const eocd = try findEndOfCentralDirectory(data);
    return readU32(data, eocd + 16);
}

fn readCentralHeader(data: []const u8, offset: usize) !CentralHeader {
    if (offset + 46 > data.len) return error.TruncatedArchive;
    if (readU32(data, offset) != signature_central) return error.InvalidCentralHeader;
    const method = readU16(data, offset + 10);
    const compressed_size = readU32(data, offset + 20);
    const name_len = readU16(data, offset + 28);
    const extra_len = readU16(data, offset + 30);
    const comment_len = readU16(data, offset + 32);
    const local_offset = readU32(data, offset + 42);
    const name_offset = offset + 46;
    const next_offset = name_offset + name_len + extra_len + comment_len;
    if (next_offset > data.len) return error.TruncatedArchive;
    return .{
        .name_offset = name_offset,
        .name_len = name_len,
        .method = method,
        .compressed_size = compressed_size,
        .local_offset = local_offset,
        .next_offset = next_offset,
    };
}

fn readLocalHeader(data: []const u8, offset: usize) !LocalHeader {
    if (offset + 30 > data.len) return error.TruncatedArchive;
    if (readU32(data, offset) != signature_local) return error.InvalidLocalHeader;
    const method = readU16(data, offset + 8);
    const name_len = readU16(data, offset + 26);
    const extra_len = readU16(data, offset + 28);
    const data_offset = offset + 30 + name_len + extra_len;
    if (data_offset > data.len) return error.TruncatedArchive;
    return .{ .method = method, .data_offset = data_offset };
}

const NpyHeader = struct {
    descr: []const u8,
    fortran_order: bool,
    shape: []const usize,
    data: []const u8,
};

fn parseNpy(payload: []const u8) !NpyHeader {
    const magic = "\x93NUMPY";
    if (payload.len < magic.len + 2) return error.InvalidNpy;
    if (!std.mem.eql(u8, payload[0..magic.len], magic)) return error.InvalidNpy;

    const major = payload[6];
    const header_len: usize = switch (major) {
        1 => readU16(payload, 8),
        2, 3 => readU32(payload, 8),
        else => return error.UnsupportedNpyVersion,
    };
    const header_start: usize = if (major == 1) 10 else 12;
    if (header_start + header_len > payload.len) return error.TruncatedNpy;

    const header = payload[header_start..][0..header_len];
    const descr = try quotedField(header, "descr");
    const fortran = try boolField(header, "fortran_order");
    const shape = try parseShape(header);

    return .{
        .descr = descr,
        .fortran_order = fortran,
        .shape = shape,
        .data = payload[header_start + header_len ..],
    };
}

fn quotedField(header: []const u8, key: []const u8) ![]const u8 {
    const position = std.mem.indexOf(u8, header, key) orelse return error.MissingNpyField;
    var rest = header[position + key.len ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.MissingNpyField;
    rest = rest[colon + 1 ..];
    const quote = std.mem.indexOfScalar(u8, rest, '\'') orelse
        std.mem.indexOfScalar(u8, rest, '"') orelse return error.MissingNpyField;
    const marker = rest[quote];
    rest = rest[quote + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, marker) orelse return error.MissingNpyField;
    return rest[0..end];
}

fn boolField(header: []const u8, key: []const u8) !bool {
    const position = std.mem.indexOf(u8, header, key) orelse return error.MissingNpyField;
    var rest = header[position + key.len ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.MissingNpyField;
    rest = rest[colon + 1 ..];
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (std.mem.startsWith(u8, trimmed, "True")) return true;
    if (std.mem.startsWith(u8, trimmed, "False")) return false;
    return error.MissingNpyField;
}

fn parseShape(header: []const u8) ![]const usize {
    const position = std.mem.indexOf(u8, header, "'shape'") orelse return error.MissingNpyField;
    var rest = header[position + 7 ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return error.MissingNpyField;
    rest = rest[colon + 1 ..];
    const open = std.mem.indexOfScalar(u8, rest, '(') orelse return error.MissingNpyField;
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return error.MissingNpyField;
    const inner = rest[open + 1 .. close];

    var dims: [4]usize = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        if (count >= dims.len) return error.UnsupportedShape;
        dims[count] = try std.fmt.parseInt(usize, trimmed, 10);
        count += 1;
    }
    if (count == 0) return error.UnsupportedShape;
    return dims[0..count];
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

test "NPY-Header wird gelesen" {
    const header = "{'descr': '<f4', 'fortran_order': False, 'shape': (2, 3), }";
    const payload = "\x93NUMPY\x01\x00" ++ [_]u8{ @truncate(header.len), 0 } ++ header ++
        "\x00\x00\x00\x00" ** 6;
    const parsed = try parseNpy(payload);
    try std.testing.expectEqualStrings("<f4", parsed.descr);
    try std.testing.expect(!parsed.fortran_order);
    try std.testing.expectEqual(@as(usize, 2), parsed.shape[0]);
    try std.testing.expectEqual(@as(usize, 3), parsed.shape[1]);
}
