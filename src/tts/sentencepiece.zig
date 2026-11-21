//! Unigram-Tokenizer im SentencePiece-Format.
//!
//! Das Modell wird als Protobuf im ONNX-Metadaten geliefert. Dieser Parser
//! liest die Stuecke, die Trainer-Angaben und die Normalisierungsflags und
//! bildet daraus den Unigram-Viterbi, den die Python- und die
//! TypeScript-Laufzeit verwenden.
//!
//! Unterstuetzt wird der Identity-Normalizer ohne Zeichentabelle. Eine
//! gefuellte Zeichentabelle braucht die Darts-Clauselbibliothek; statt sie
//! zu uebergehen, meldet der Parser einen klaren Fehler.
const std = @import("std");

/// Fehler des Parsers und des Tokenizers.
pub const Error = error{
    /// Das Protobuf endet mitten in einem Feld.
    TruncatedProto,
    /// Das Protobuf enthaelt ein Feld, das die Struktur nicht kennt.
    InvalidProto,
    /// Die Zeichentabelle des Normalizers ist nicht leer.
    UnsupportedNormalizer,
    /// Das Stueckverzeichnis ist leer.
    EmptyVocabulary,
    /// Die Normalisierung liess keinen verwertbaren Text uebrig.
    EmptyText,
};

/// Typ eines Stuecks aus dem SentencePiece-Format.
pub const PieceType = enum(u8) {
    normal = 1,
    unknown = 2,
    control = 3,
    user_defined = 4,
    unused = 5,
    byte = 6,
    _,
};

/// Ein Stueck des Vokabulars.
pub const Piece = struct {
    /// Der Text des Stuecks. Zeigt in den Puffer des Modells.
    text: []const u8,
    /// Die Gewichtung des Stuecks im Unigram-Modell.
    score: f32,
    /// Die Rolle des Stuecks.
    kind: PieceType,
};

/// Abstand fuer unbekannte Zeichen im Unigram-Modell.
const unk_penalty = 10.0;

/// Das Leerzeichen des SentencePiece-Formats.
pub const space_marker = "\u{2581}";

/// Ein gepartes SentencePiece-Modell.
pub const Model = struct {
    gpa: std.mem.Allocator,
    /// Der Protobuffer. Die Stuecktexte zeigen hinein.
    raw: []u8,
    /// Alle Stuecke in ihrer Reihenfolge. Die Nummer ist die Token-ID.
    pieces: []Piece,
    /// Zuordnung Stuecktext zu Token-ID. Nur normale und selbstdefinierte
    /// Stuecke sind hier enthalten.
    ids: std.StringHashMap(i32),
    /// Zuordnung Byte zu Token-ID fuer den Byte-Fallback.
    byte_ids: [256]?i32,
    /// ID des unbekannten Stuecks.
    unk_id: i32 = 0,
    /// ID des Anfangstuecks.
    bos_id: i32 = 1,
    /// ID des Endstuecks.
    eos_id: i32 = 2,
    /// ID des Fuellstuecks.
    pad_id: i32 = 3,
    /// Unbekannte Zeichen werden als Byte-Stuecke geschrieben.
    byte_fallback: bool = false,
    /// Der Text bekommt ein Leerzeichen als Praefix.
    add_dummy_prefix: bool = true,
    /// Leerraum wird zusammengefasst.
    remove_extra_whitespaces: bool = true,
    /// Leerzeichen werden als SentencePiece-Marker geschrieben.
    escape_whitespaces: bool = true,
    /// Gewichtung eines unbekannten Zeichens.
    unk_score: f32 = 0,
    /// Laengste Stuecklaenge in Codepoints.
    max_piece_len: usize = 1,

    /// Liest ein SentencePiece-Modell aus einem Protobuffer.
    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Model {
        const raw = try gpa.dupe(u8, bytes);
        errdefer gpa.free(raw);

        var piece_list: std.ArrayList(Piece) = .empty;
        defer piece_list.deinit(gpa);

        var trainer = Trainer{};
        var normalizer = Normalizer{};

        var reader = Reader{ .bytes = raw };
        while (!reader.done()) {
            const tag = try reader.varint();
            const field = tag >> 3;
            const wire: u3 = @truncate(tag & 7);
            switch (field) {
                1 => {
                    if (wire != 2) return error.InvalidProto;
                    const payload = try reader.blob();
                    try piece_list.append(gpa, try parsePiece(payload));
                },
                2 => {
                    if (wire != 2) return error.InvalidProto;
                    try trainer.parse(try reader.blob());
                },
                3 => {
                    if (wire != 2) return error.InvalidProto;
                    try normalizer.parse(try reader.blob());
                },
                else => try reader.skip(wire),
            }
        }

        if (piece_list.items.len == 0) return error.EmptyVocabulary;
        if (normalizer.charsmap_len != 0) return error.UnsupportedNormalizer;

        const pieces = try piece_list.toOwnedSlice(gpa);
        errdefer gpa.free(pieces);

        var ids = std.StringHashMap(i32).init(gpa);
        errdefer ids.deinit();

        var byte_ids: [256]?i32 = @splat(null);
        var min_score: f32 = std.math.inf(f32);
        var max_piece_len: usize = 1;

        for (pieces, 0..) |piece, index| {
            switch (piece.kind) {
                .normal, .user_defined => {
                    try ids.put(piece.text, @intCast(index));
                    min_score = @min(min_score, piece.score);
                    max_piece_len = @max(max_piece_len, std.unicode.utf8CountCodepoints(piece.text) catch 1);
                },
                .byte => {
                    if (piece.text.len == 6 and std.mem.startsWith(u8, piece.text, "<0x") and piece.text[5] == '>') {
                        const value = std.fmt.parseInt(u8, piece.text[3..5], 16) catch continue;
                        byte_ids[value] = @intCast(index);
                    }
                },
                else => {},
            }
        }

        if (!std.math.isFinite(min_score)) min_score = 0;

        return .{
            .gpa = gpa,
            .raw = raw,
            .pieces = pieces,
            .ids = ids,
            .byte_ids = byte_ids,
            .unk_id = trainer.unk_id,
            .bos_id = trainer.bos_id,
            .eos_id = trainer.eos_id,
            .pad_id = trainer.pad_id,
            .byte_fallback = trainer.byte_fallback,
            .add_dummy_prefix = normalizer.add_dummy_prefix,
            .remove_extra_whitespaces = normalizer.remove_extra_whitespaces,
            .escape_whitespaces = normalizer.escape_whitespaces,
            .unk_score = min_score - unk_penalty,
            .max_piece_len = max_piece_len,
        };
    }

    /// Gibt den Speicher des Modells frei.
    pub fn deinit(self: *Model) void {
        self.ids.deinit();
        self.gpa.free(self.pieces);
        self.gpa.free(self.raw);
        self.* = undefined;
    }

    /// Liefert den Text eines Stuecks.
    pub fn pieceText(self: *const Model, id: i32) ?[]const u8 {
        if (id < 0 or id >= self.pieces.len) return null;
        return self.pieces[@intCast(id)].text;
    }

    /// Liefert die ID eines Stuecks. Unbekannte Stuecke ergeben die
    /// ID des unbekannten Stuecks.
    pub fn pieceToId(self: *const Model, text: []const u8) i32 {
        return self.ids.get(text) orelse self.unk_id;
    }

    /// Zerlegt Text in Token-IDs.
    pub fn encode(self: *const Model, gpa: std.mem.Allocator, text: []const u8) ![]i32 {
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(gpa);
        try self.normalize(gpa, &normalized, text);

        if (normalized.items.len == 0) return gpa.alloc(i32, 0);

        var boundaries: std.ArrayList(usize) = .empty;
        defer boundaries.deinit(gpa);
        try boundaries.append(gpa, 0);
        var iterator = std.unicode.Utf8Iterator{ .bytes = normalized.items, .i = 0 };
        while (iterator.nextCodepoint()) |_| {
            try boundaries.append(gpa, iterator.i);
        }
        const count = boundaries.items.len - 1;

        const neg_inf = -std.math.inf(f64);
        var best = try gpa.alloc(f64, count + 1);
        defer gpa.free(best);
        @memset(best, neg_inf);
        best[0] = 0;

        var back_start = try gpa.alloc(i32, count + 1);
        defer gpa.free(back_start);
        @memset(back_start, -1);
        var back_id = try gpa.alloc(i32, count + 1);
        defer gpa.free(back_id);
        @memset(back_id, -1);
        var back_unknown = try gpa.alloc(bool, count + 1);
        defer gpa.free(back_unknown);
        @memset(back_unknown, false);

        // Vorwaerts-Viterbi. An jeder Position starten alle passenden
        // Stuecke eine Kante. Findet sich dort kein Stueck, traegt ein
        // unbekanntes Zeichen die Kante weiter.
        var position: usize = 0;
        while (position < count) : (position += 1) {
            if (best[position] == neg_inf) continue;
            var matched = false;
            var length: usize = 1;
            while (length <= self.max_piece_len and position + length <= count) : (length += 1) {
                const candidate = normalized.items[boundaries.items[position]..boundaries.items[position + length]];
                const id = self.ids.get(candidate) orelse continue;
                matched = true;
                const score = best[position] + @as(f64, self.pieces[@intCast(id)].score);
                const end = position + length;
                if (score > best[end]) {
                    best[end] = score;
                    back_start[end] = @intCast(position);
                    back_id[end] = id;
                    back_unknown[end] = false;
                }
            }
            if (!matched) {
                const score = best[position] + @as(f64, self.unk_score);
                const end = position + 1;
                if (score > best[end]) {
                    best[end] = score;
                    back_start[end] = @intCast(position);
                    back_id[end] = self.unk_id;
                    back_unknown[end] = true;
                }
            }
        }

        // Der Pfad wird von hinten verfolgt und dann in Leserichtung
        // ausgegeben.
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(gpa);
        var cursor = count;
        while (cursor > 0) {
            const start = back_start[cursor];
            if (start < 0) return error.InvalidProto;
            try spans.append(gpa, .{
                .start = @intCast(start),
                .end = cursor,
                .id = back_id[cursor],
                .unknown = back_unknown[cursor],
            });
            cursor = @intCast(start);
        }
        std.mem.reverse(Span, spans.items);

        var result: std.ArrayList(i32) = .empty;
        errdefer result.deinit(gpa);
        for (spans.items) |span| {
            if (!span.unknown) {
                try result.append(gpa, span.id);
                continue;
            }
            const surface = normalized.items[boundaries.items[span.start]..boundaries.items[span.end]];
            if (self.byte_fallback) {
                var spelled = true;
                for (surface) |byte| {
                    if (self.byte_ids[byte] == null) {
                        spelled = false;
                        break;
                    }
                }
                if (spelled) {
                    for (surface) |byte| {
                        try result.append(gpa, self.byte_ids[byte].?);
                    }
                    continue;
                }
            }
            try result.append(gpa, self.unk_id);
        }
        return result.toOwnedSlice(gpa);
    }

    /// Setzt Token-IDs zu Text zusammen.
    pub fn decode(self: *const Model, gpa: std.mem.Allocator, ids: []const i32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(gpa);

        for (ids) |id| {
            if (id < 0 or id >= self.pieces.len) continue;
            const piece = self.pieces[@intCast(id)];
            switch (piece.kind) {
                .byte => {
                    const value = std.fmt.parseInt(u8, piece.text[3..5], 16) catch continue;
                    try pending.append(gpa, value);
                },
                .normal, .user_defined => {
                    try flushBytes(gpa, &out, &pending);
                    try out.appendSlice(gpa, piece.text);
                },
                else => {},
            }
        }
        try flushBytes(gpa, &out, &pending);

        // Der Leerraum-Marker wird zu einem echten Leerzeichen. Das erste
        // Leerzeichen stammt aus dem Dummy-Praefix und wird entfernt.
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(gpa);
        var index: usize = 0;
        while (index < out.items.len) {
            if (std.mem.startsWith(u8, out.items[index..], space_marker)) {
                try result.append(gpa, ' ');
                index += space_marker.len;
                continue;
            }
            try result.append(gpa, out.items[index]);
            index += 1;
        }
        if (result.items.len > 0 and result.items[0] == ' ') {
            // Der Pufferanfang bleibt stehen, damit die Freigabe passt.
            std.mem.copyForwards(u8, result.items[0 .. result.items.len - 1], result.items[1..]);
            result.items.len -= 1;
        }
        return result.toOwnedSlice(gpa);
    }

    /// Schreibt den Text in die Normalisierungsform des Modells.
    fn normalize(
        self: *const Model,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
        text: []const u8,
    ) !void {
        var source = text;
        if (self.remove_extra_whitespaces) {
            var collapsed: std.ArrayList(u8) = .empty;
            defer collapsed.deinit(gpa);
            var previous_space = false;
            for (source) |char| {
                const is_space = char == ' ' or char == '\t' or char == '\n' or char == '\r';
                if (is_space) {
                    if (previous_space) continue;
                    previous_space = true;
                } else {
                    previous_space = false;
                }
                try collapsed.append(gpa, char);
            }
            source = collapsed.items;
            source = std.mem.trim(u8, source, " \t\n\r");
        }

        if (self.add_dummy_prefix) try out.appendSlice(gpa, space_marker);
        for (source) |char| {
            if (char == ' ' and self.escape_whitespaces) {
                try out.appendSlice(gpa, space_marker);
            } else {
                try out.append(gpa, char);
            }
        }
    }
};

const Span = struct {
    start: usize,
    end: usize,
    id: i32,
    unknown: bool,
};

/// Angaben der Trainer-Sektion.
const Trainer = struct {
    byte_fallback: bool = false,
    unk_id: i32 = 0,
    bos_id: i32 = 1,
    eos_id: i32 = 2,
    pad_id: i32 = 3,

    fn parse(self: *Trainer, payload: []const u8) !void {
        var reader = Reader{ .bytes = payload };
        while (!reader.done()) {
            const tag = try reader.varint();
            const field = tag >> 3;
            const wire: u3 = @truncate(tag & 7);
            switch (field) {
                35 => self.byte_fallback = (try reader.varint()) != 0,
                40 => self.unk_id = @intCast(try reader.varint()),
                41 => self.bos_id = @intCast(try reader.varint()),
                42 => self.eos_id = @intCast(try reader.varint()),
                43 => self.pad_id = @intCast(try reader.varint()),
                else => try reader.skip(wire),
            }
        }
    }
};

/// Angaben der Normalisierungssektion.
const Normalizer = struct {
    charsmap_len: usize = 0,
    add_dummy_prefix: bool = true,
    remove_extra_whitespaces: bool = true,
    escape_whitespaces: bool = true,

    fn parse(self: *Normalizer, payload: []const u8) !void {
        var reader = Reader{ .bytes = payload };
        while (!reader.done()) {
            const tag = try reader.varint();
            const field = tag >> 3;
            const wire: u3 = @truncate(tag & 7);
            switch (field) {
                2 => self.charsmap_len = (try reader.blob()).len,
                3 => self.add_dummy_prefix = (try reader.varint()) != 0,
                4 => self.remove_extra_whitespaces = (try reader.varint()) != 0,
                5 => self.escape_whitespaces = (try reader.varint()) != 0,
                else => try reader.skip(wire),
            }
        }
    }
};

fn parsePiece(payload: []const u8) !Piece {
    var piece = Piece{ .text = "", .score = 0, .kind = .normal };
    var reader = Reader{ .bytes = payload };
    while (!reader.done()) {
        const tag = try reader.varint();
        const field = tag >> 3;
        const wire: u3 = @truncate(tag & 7);
        switch (field) {
            1 => piece.text = try reader.blob(),
            2 => piece.score = @bitCast(try reader.fixed32()),
            3 => piece.kind = @enumFromInt(try reader.varint()),
            else => try reader.skip(wire),
        }
    }
    return piece;
}

fn flushBytes(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pending: *std.ArrayList(u8),
) !void {
    if (pending.items.len == 0) return;
    if (std.unicode.utf8ValidateSlice(pending.items)) {
        try out.appendSlice(gpa, pending.items);
    } else {
        // Ungueltige Bytesequenzen werden als Ersatzzeichen geschrieben.
        var iterator = std.unicode.Utf8Iterator{ .bytes = pending.items, .i = 0 };
        while (iterator.nextCodepoint()) |codepoint| {
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(codepoint, &buffer) catch 0;
            try out.appendSlice(gpa, buffer[0..length]);
        }
    }
    pending.clearRetainingCapacity();
}

/// Minimaler Protobuf-Leser fuer die Felder dieses Modells.
const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn done(self: *const Reader) bool {
        return self.offset >= self.bytes.len;
    }

    fn varint(self: *Reader) !u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.offset >= self.bytes.len) return error.TruncatedProto;
            const byte = self.bytes[self.offset];
            self.offset += 1;
            result |= @as(u64, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) return result;
            if (shift >= 63) return error.InvalidProto;
            shift += 7;
        }
    }

    fn blob(self: *Reader) ![]const u8 {
        const length = try self.varint();
        if (length > self.bytes.len - self.offset) return error.TruncatedProto;
        const out = self.bytes[self.offset .. self.offset + @as(usize, @intCast(length))];
        self.offset += @intCast(length);
        return out;
    }

    fn fixed32(self: *Reader) !u32 {
        if (self.bytes.len - self.offset < 4) return error.TruncatedProto;
        const out = std.mem.readInt(u32, self.bytes[self.offset..][0..4], .little);
        self.offset += 4;
        return out;
    }

    fn fixed64(self: *Reader) !void {
        if (self.bytes.len - self.offset < 8) return error.TruncatedProto;
        self.offset += 8;
    }

    fn skip(self: *Reader, wire: u3) !void {
        switch (wire) {
            0 => _ = try self.varint(),
            1 => try self.fixed64(),
            2 => _ = try self.blob(),
            5 => {
                if (self.bytes.len - self.offset < 4) return error.TruncatedProto;
                self.offset += 4;
            },
            else => return error.InvalidProto,
        }
    }
};

test "Proto-Leser liest Varints und Felder" {
    var reader = Reader{ .bytes = &[_]u8{ 0x08, 0x96, 0x01, 0x12, 0x03, 1, 2, 3 } };
    const tag = try reader.varint();
    try std.testing.expectEqual(@as(u64, 8), tag);
    try std.testing.expectEqual(@as(u64, 150), try reader.varint());
    const tag2 = try reader.varint();
    try std.testing.expectEqual(@as(u64, 0x12), tag2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, try reader.blob());
    try std.testing.expect(reader.done());
}

test "Proto-Leser meldet abgeschnittene Daten" {
    var reader = Reader{ .bytes = &[_]u8{ 0x12, 0x05, 1, 2 } };
    const tag = try reader.varint();
    try std.testing.expectEqual(@as(u64, 0x12), tag);
    try std.testing.expectError(error.TruncatedProto, reader.blob());
}
