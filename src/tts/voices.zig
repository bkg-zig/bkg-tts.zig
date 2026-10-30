//! Stimmdaten aus `voices.npz` und `voices.bin` lesen.
//!
//! Die Kitten-Modelle liefern ihre Stimmembeddings als ZIP-Archiv mit
//! eingebetteten NPY-Dateien. Die Eintraege sind unkomprimiert gespeichert,
//! deshalb reicht ein eigener ZIP-Leser ohne Inflate-Implementierung.
//!
//! Die Kokoro-Modelle liefern dieselben Daten ohne Kopf als flache Datei mit
//! little-endian Float32-Werten. Namen der Stimmen und Groesse des
//! Embeddings liefert dort der Aufrufer.
const std = @import("std");

/// Obergrenze fuer geladene Stimmdaten in Byte.
const max_voice_bytes = 256 * 1024 * 1024;
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
    const data = try std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .limited(max_voice_bytes));
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
    for (0..count) |_| {
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

/// Liest Stimmembeddings aus einer flachen Datei mit little-endian Float32-Werten.
///
/// Die Datei hat keinen Kopf. Die Werte stehen hintereinander in der Reihenfolge
/// der Stimmen, jede Stimme belegt `rows` Zeilen mit je `columns` Werten.
///
/// Die Dateigroesse muss exakt zu den Stimmen passen. Eine zu kleine Datei
/// ergibt `error.TruncatedArray`, eine zu grosse `error.InvalidFileSize`.
pub fn loadFlatBin(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    speakers: []const []const u8,
    rows: usize,
    columns: usize,
) !Voices {
    if (speakers.len == 0) return error.NoSpeakers;
    if (rows == 0 or columns == 0) return error.UnsupportedShape;

    const values_per_voice = std.math.mul(usize, rows, columns) catch return error.AudioTooLarge;
    const bytes_per_voice = std.math.mul(usize, values_per_voice, @sizeOf(f32)) catch return error.AudioTooLarge;
    const expected = std.math.mul(usize, bytes_per_voice, speakers.len) catch return error.AudioTooLarge;
    if (expected > max_voice_bytes) return error.AudioTooLarge;

    // Ein Byte mehr erlaubt, eine zu kleine Datei von einer zu grossen zu
    // unterscheiden, ohne die ganze Datei im Speicher zu halten.
    const data = std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .limited(expected + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidFileSize,
        else => return err,
    };
    defer gpa.free(data);
    if (data.len < expected) return error.TruncatedArray;
    if (data.len > expected) return error.InvalidFileSize;

    const entries = try gpa.alloc(Voice, speakers.len);
    errdefer gpa.free(entries);
    var filled: usize = 0;
    errdefer {
        for (entries[0..filled]) |entry| {
            gpa.free(entry.name);
            gpa.free(entry.embeddings);
        }
    }

    for (speakers, 0..) |speaker, index| {
        const start = index * bytes_per_voice;
        const embeddings = try gpa.alloc(f32, values_per_voice);
        errdefer gpa.free(embeddings);
        for (embeddings, 0..) |*value, offset| {
            const byte_offset = start + offset * @sizeOf(f32);
            const bits = std.mem.readInt(u32, data[byte_offset..][0..@sizeOf(f32)], .little);
            value.* = @bitCast(bits);
        }

        const name = try gpa.dupe(u8, speaker);
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

/// Liest genau eine Stimme aus einer flachen Datei mit little-endian Float32-Werten.
///
/// Die Datei muss genau `rows` Zeilen mit je `columns` Werten enthalten.
pub fn loadFlatBinSingle(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    name: []const u8,
    rows: usize,
    columns: usize,
) !Voices {
    const speakers = [_][]const u8{name};
    return loadFlatBin(gpa, io, path, &speakers, rows, columns);
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

/// Kodiert Werte als little-endian Float32-Bytes.
fn encodeFlat(gpa: std.mem.Allocator, values: []const f32) ![]u8 {
    const bytes = try gpa.alloc(u8, values.len * @sizeOf(f32));
    errdefer gpa.free(bytes);
    for (values, 0..) |value, index| {
        const offset = index * @sizeOf(f32);
        std.mem.writeInt(u32, bytes[offset..][0..@sizeOf(f32)], @bitCast(value), .little);
    }
    return bytes;
}

/// Legt eine Datei mit little-endian Float32-Werten in ein temporaeres Verzeichnis.
fn writeFlatFile(dir: std.Io.Dir, io: std.Io, sub_path: []const u8, values: []const f32) !void {
    const bytes = try encodeFlat(std.testing.allocator, values);
    defer std.testing.allocator.free(bytes);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
}

/// Liefert den absoluten Pfad einer Datei im temporaeren Verzeichnis.
fn flatFilePath(dir: std.Io.Dir, io: std.Io, sub_path: []const u8, buffer: []u8) ![]const u8 {
    var dir_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = try dir.realPath(io, &dir_buffer);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ dir_buffer[0..dir_len], sub_path });
}

test "Flache Float32-Datei liefert Stimmembeddings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const rows = 2;
    const columns = 3;
    const values = [_]f32{
        0.5,  -1.25,  2.0,
        3.75, -0.125, 100.0,
        -0.5, 0.25,   -2.0,
        0.0,  7.5,    -7.5,
    };
    try writeFlatFile(tmp.dir, io, "voices.bin", &values);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try flatFilePath(tmp.dir, io, "voices.bin", &path_buffer);

    const speakers = [_][]const u8{ "af", "bf_emma" };
    var voices = try loadFlatBin(std.testing.allocator, io, path, &speakers, rows, columns);
    defer voices.deinit();

    try std.testing.expectEqual(@as(usize, 2), voices.entries.len);
    try std.testing.expectEqualStrings("af", voices.entries[0].name);
    try std.testing.expectEqualStrings("bf_emma", voices.entries[1].name);
    try std.testing.expectEqual(@as(usize, rows), voices.entries[0].rows);
    try std.testing.expectEqual(@as(usize, columns), voices.entries[0].columns);
    try std.testing.expectEqualSlices(f32, values[0..6], voices.entries[0].embeddings);
    try std.testing.expectEqualSlices(f32, values[6..12], voices.entries[1].embeddings);
}

test "Flache Float32-Datei meldet abweichende Dateigroesse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const rows = 1;
    const columns = 2;
    const speakers = [_][]const u8{"af"};
    const values = [_]f32{ 1.0, 2.0 };

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try flatFilePath(tmp.dir, io, "voices.bin", &path_buffer);

    // Zu kleine Datei.
    const bytes = try encodeFlat(std.testing.allocator, &values);
    defer std.testing.allocator.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "voices.bin", .data = bytes[0 .. bytes.len - 1] });
    try std.testing.expectError(
        error.TruncatedArray,
        loadFlatBin(std.testing.allocator, io, path, &speakers, rows, columns),
    );

    // Zu grosse Datei.
    const too_large = try std.testing.allocator.alloc(u8, bytes.len + 1);
    defer std.testing.allocator.free(too_large);
    @memcpy(too_large[0..bytes.len], bytes);
    too_large[bytes.len] = 0;
    try tmp.dir.writeFile(io, .{ .sub_path = "voices.bin", .data = too_large });
    try std.testing.expectError(
        error.InvalidFileSize,
        loadFlatBin(std.testing.allocator, io, path, &speakers, rows, columns),
    );
}

test "Leere Stimmliste und leere Form werden abgelehnt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const values = [_]f32{ 1.0, 2.0 };
    try writeFlatFile(tmp.dir, io, "voices.bin", &values);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try flatFilePath(tmp.dir, io, "voices.bin", &path_buffer);

    const no_speakers = [_][]const u8{};
    try std.testing.expectError(
        error.NoSpeakers,
        loadFlatBin(std.testing.allocator, io, path, &no_speakers, 1, 2),
    );

    const speakers = [_][]const u8{"af"};
    try std.testing.expectError(
        error.UnsupportedShape,
        loadFlatBin(std.testing.allocator, io, path, &speakers, 0, 2),
    );
    try std.testing.expectError(
        error.UnsupportedShape,
        loadFlatBin(std.testing.allocator, io, path, &speakers, 1, 0),
    );
}
