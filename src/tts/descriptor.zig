//! Deskriptor eines TTS-Modells.
//!
//! Der Deskriptor ist die Datei `config.json` im Modellordner. Sie beschreibt
//! das Modell vollstaendig: den Verarbeitungsweg, die Dateien, die Textpfade,
//! die Stimmenquelle und die Namen der Ein- und Ausgaenge des ONNX-Graphen.
//! Die Engine enthaelt keine Modell-Sonderfaelle, sie liest nur diese Datei.
//!
//! Relative Pfade werden gegen das Verzeichnis des Deskriptors aufgeloest.
//! So kann ein Modellordner unveraendert an einen anderen Ort gestellt werden.
//!
//! Alle Texte des Deskriptors liegen in einer Arena, die der Deskriptor
//! besitzt. Beim Freigeben wird die Arena auf einmal verworfen. Dadurch gibt
//! es keinen Pfad, auf dem ein Text zweimal freigegeben werden koennte.
const std = @import("std");

const tokens = @import("tokens.zig");

/// Obergrenze fuer die Groesse einer Deskriptordatei.
const max_descriptor_bytes = 1024 * 1024;

/// Verarbeitungsweg des Modells.
pub const Backend = enum {
    /// Stimmembedding und Tokenfolge in einem Lauf (Kitten, Kokoro).
    style_tokens,
    /// Phonem-IDs je Satz (Piper).
    phoneme_ids,
    /// Schrittweiser Decoder mit eigenem Tokenizer (Pocket-TTS).
    pocket_step,
};

/// Format der Stimmdatei.
pub const VoicesFormat = enum {
    /// ZIP-Archiv mit NPY-Arrays, je Stimme eine eigene Matrix.
    npz,
    /// Flache Datei mit Float32-Werten, alle Stimmen hintereinander.
    flat,
};

/// Vorverarbeitung des Textes vor der Phonemisierung.
pub const PreprocessMode = enum {
    /// Der Text bleibt unveraendert.
    none,
    /// Zahlen und Waehrungen werden zu Worten.
    numbers,
};

/// Quelle der Token-IDs.
pub const TokenizerMode = enum {
    /// Eingebaute Symboltabelle (Kitten).
    builtin,
    /// Vokabulardatei mit einer Zeile je Symbol (Kokoro).
    vocab,
    /// Phonem-ID-Map aus einer JSON-Datei (Piper).
    phoneme_ids,
};

/// Art der Textaufteilung.
pub const TextMode = enum {
    /// Der gesamte Text wird zu einer Tokenfolge.
    whole,
    /// Jeder Satz aus den espeak-Terminatoren wird einzeln verarbeitet.
    clause,
};

/// Ersetzung im Phonemtext.
///
/// Manche Modelle erwarten ein Wort in einer bestimmten Schreibweise. Die
/// Ersetzung steht im Deskriptor, damit die Engine keine Modelle kennt.
pub const Replacement = struct {
    /// Gesuchter Text.
    from: []const u8,
    /// Ersetzender Text.
    to: []const u8,
};

/// Angaben zur eingebundenen espeak-ng-Bibliothek.
pub const EspeakSpec = struct {
    /// Pfad der Shared Library. Leer bedeutet: die Vorgabe der Engine.
    library_path: ?[]const u8 = null,
    /// Verzeichnis mit den espeak-Daten. Leer bedeutet: die Vorgabe der Engine.
    data_dir: ?[]const u8 = null,
};

/// Werte, mit denen das Modell gerechnet wird.
pub const InferenceSpec = struct {
    /// Zufallsrauschen des Modells.
    noise_scale: f32 = 0.667,
    /// Dehnung des Textes. Groessere Werte sprechen langsamer.
    length_scale: f32 = 1.0,
    /// Zufallsrauschen der Dauer.
    noise_w: f32 = 0.8,
};

/// Normalisierung der erzeugten Samples.
pub const OutputNormalize = enum {
    /// Die Ausgabe bleibt unveraendert.
    none,
    /// Die Ausgabe wird auf den groesten Wert 1.0 gebracht.
    peak,
};

/// Groesse, aus der die Zeile des Stimmembeddings abgeleitet wird.
pub const StyleBasis = enum {
    /// Laenge der vollstaendigen Tokenfolge mit Rahmen.
    tokens,
    /// Laenge der Symbolfolge ohne Rahmen.
    symbols,
};

/// Angaben zur Stimmdatei.
pub const VoicesSpec = struct {
    /// Pfad der Datei.
    file: []const u8 = &.{},
    /// Format der Datei.
    format: VoicesFormat = .npz,
    /// Namen der Stimmen. Beim Format "npz" kommen sie aus dem Archiv.
    names: []const []const u8 = &.{},
    /// Zeilen je Stimme. Beim Format "npz" stehen sie im Archiv.
    rows: usize = 0,
    /// Spalten je Zeile.
    columns: usize = 256,
};

/// Angaben zur Textaufbereitung.
pub const TextSpec = struct {
    /// Sprache des Textes, zugleich die Stimme von espeak-ng.
    language: []const u8 = "en-us",
    /// Vorverarbeitung vor der Phonemisierung.
    preprocess: PreprocessMode = .numbers,
    /// Art der Textaufteilung.
    mode: TextMode = .whole,
    /// Der Text wird vor der Zuordnung in Normalisierungsform D zerlegt.
    normalize_nfd: bool = false,
    /// Maximale Zahl der Tokens im Textkoerper. Null schaltet die Grenze ab.
    max_tokens: usize = 0,
    /// Das Satzzeichen des espeak-Terminators wird an den Phonemtext gehaengt.
    append_terminator: bool = false,
    /// Trenner zwischen den Phonemen der einzelnen Clauses.
    ///
    /// Das Leerzeichen ist der Default, weil ein fehlender Trenner zwei
    /// Wortgruppen zusammenklebt. Das aendert die Zahl der Tokens.
    clause_separator: []const u8 = " ",
    /// Maximale Laenge eines Abschnitts in Byte. Null schaltet die Aufteilung ab.
    chunk_chars: usize = 400,
    /// Ersetzungen im Phonemtext.
    replacements: []const Replacement = &.{},
};

/// Angaben zum Tokenizer.
pub const TokenizerSpec = struct {
    /// Quelle der Token-IDs.
    mode: TokenizerMode = .builtin,
    /// Datei mit den Symbolen, bei Modus "vocab".
    symbols: ?[]const u8 = null,
    /// JSON-Datei mit der Phonem-ID-Map, bei Modus "phoneme_ids".
    phoneme_id_map: ?[]const u8 = null,
    /// Feld der JSON-Datei, das die Phonem-ID-Map enthaelt.
    phoneme_id_map_field: []const u8 = "phoneme_id_map",
    /// ID vor dem Textkoerper.
    start_id: i64 = 0,
    /// ID nach dem Textkoerper. Null laesst die ID weg.
    end_id: ?i64 = 10,
    /// ID am Ende der Folge.
    pad_id: i64 = 0,
    /// Schluessel des Starttokens in der Phonem-ID-Map.
    ///
    /// Der Rahmen einer Phonem-ID-Folge besteht aus drei Rollen: Start,
    /// Fuellzeichen und Ende. Welcher Schluessel der Map welche Rolle hat,
    /// steht hier. So muss die Engine die Konvention des Modellanbieters
    /// nicht kennen.
    start_key: ?[]const u8 = null,
    /// Schluessel des Fuellzeichens in der Phonem-ID-Map.
    pad_key: ?[]const u8 = null,
    /// Schluessel des Endtokens in der Phonem-ID-Map.
    end_key: ?[]const u8 = null,
    /// Wortzeichen werden zu Woertern gruppiert und mit Leerzeichen getrennt.
    word_split: bool = true,
    /// Regel fuer doppelte Symbole der eingebauten Tabelle.
    symbol_scheme: tokens.SymbolScheme = .first_wins,
};

/// Regel fuer die Wahl der Zeile im Stimmembedding.
///
/// Die Zeilennummer entsteht aus der Laenge des Textes:
///
///     local = clamp(length - offset, min, max oder rows - 1)
///     row   = base + local
///
/// `base` ist null bei einer eigenen Matrix je Stimme und der Index der
/// Stimme mal der Zeilenzahl bei einer flachen Datei.
pub const StyleIndexSpec = struct {
    /// Groesse, aus der die Zeile abgeleitet wird.
    basis: StyleBasis = .tokens,
    /// Wert, der von der Groesse abgezogen wird.
    offset: usize = 0,
    /// Untere Grenze der Zeilennummer.
    min: usize = 0,
    /// Obere Grenze der Zeilennummer. Ohne Angabe gilt die letzte Zeile.
    max: ?usize = null,
};

/// Angaben zur Stimmquelle.
pub const StyleSpec = struct {
    /// Regel fuer die Wahl der Zeile.
    index: StyleIndexSpec = .{},
};

/// Namen der ONNX-Eingaenge nach ihrer Rolle.
pub const InputNames = struct {
    /// Tokenfolge des Textes.
    tokens: []const u8 = "input_ids",
    /// Stimmembedding.
    style: []const u8 = "style",
    /// Sprechtempo.
    speed: []const u8 = "speed",
    /// Laenge der Tokenfolge. Nur bei Modellen, die sie brauchen.
    lengths: ?[]const u8 = null,
    /// Werte der Inference. Nur bei Modellen, die sie brauchen.
    scales: ?[]const u8 = null,
};

/// Angaben zum ONNX-Ausgang.
pub const OutputSpec = struct {
    /// Name des Ausgangs mit den Audiodaten.
    name: []const u8 = "audio",
    /// Anzahl der Samples, die am Ende abgeschnitten werden.
    trim_tail_samples: usize = 5000,
    /// Normalisierung der Samples.
    normalize: OutputNormalize = .none,
};

/// Ein Alias einer Stimme.
pub const VoiceAlias = struct {
    alias: []const u8,
    voice: []const u8,
};

/// Ein Tempoprior einer Stimme.
pub const SpeedPrior = struct {
    voice: []const u8,
    speed: f32,
};

/// Vollstaendige Beschreibung eines Modells.
pub const Descriptor = struct {
    /// Arena, die alle Texte des Deskriptors haelt.
    arena: std.heap.ArenaAllocator,
    /// Anzeigename des Modells.
    name: []const u8,
    /// Version des Modells.
    version: []const u8,
    /// Eindeutige Kennung des Modells.
    model: []const u8,
    /// Verarbeitungsweg des Modells.
    backend: Backend,
    /// Pfad der ONNX-Datei.
    model_file: []const u8,
    /// Abtastrate der Ausgabe in Hertz. Null bedeutet: aus dem Modell lesen.
    sample_rate: ?u32,
    /// Stimmdatei.
    voices: VoicesSpec,
    /// Angaben zur Textaufbereitung.
    text: TextSpec,
    /// Angaben zum Tokenizer.
    tokenizer: TokenizerSpec,
    /// Angaben zur Stimmquelle.
    style: StyleSpec,
    /// Namen der ONNX-Eingaenge.
    inputs: InputNames,
    /// Angaben zum ONNX-Ausgang.
    output: OutputSpec,
    /// Aliase der Stimmen.
    voice_aliases: []const VoiceAlias,
    /// Tempopriors der Stimmen.
    speed_priors: []const SpeedPrior,
    /// Angaben zur espeak-ng-Bibliothek.
    espeak: EspeakSpec,
    /// Werte, mit denen das Modell gerechnet wird.
    inference: InferenceSpec,
    /// Rohe Bytes der Deskriptordatei. Sie erlauben eine eigene Kopie.
    raw: []const u8,
    /// Verzeichnis der Deskriptordatei, gegen das relative Pfade gelten.
    base_dir: []const u8,

    pub fn deinit(self: *Descriptor) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Fingerabdruck der Deskriptordatei.
    ///
    /// Zwei Deskriptoren mit gleichem Fingerabdruck haben denselben Inhalt.
    /// Die Engine nutzt das, um beim Neuladen nur geaenderte Modelle neu zu
    /// laden.
    pub fn fingerprint(self: *const Descriptor) u64 {
        return std.hash.Wyhash.hash(0, self.raw);
    }

    /// Erzeugt eine eigene Kopie des Deskriptors.
    ///
    /// Die Kopie haelt ihren eigenen Speicher. Ein laufendes Backend kann
    /// damit weiterarbeiten, wenn die Registry den Deskriptor austauscht.
    pub fn clone(self: *const Descriptor, gpa: std.mem.Allocator) !Descriptor {
        return parse(gpa, self.raw, self.base_dir);
    }

    /// Loest einen Alias auf.
    ///
    /// Zuerst wird ohne Beachtung der Grossschreibung gesucht, weil die
    /// Anfrage aus dem HTTP-Protokoll stammt. Der Treffer ist der interne
    /// Name der Stimme.
    pub fn aliasTarget(self: *const Descriptor, voice: []const u8) ?[]const u8 {
        for (self.voice_aliases) |alias| {
            if (std.mem.eql(u8, alias.alias, voice)) return alias.voice;
        }
        for (self.voice_aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(alias.alias, voice)) return alias.voice;
        }
        return null;
    }

    /// Liefert den Tempoprior einer Stimme, falls vorhanden.
    pub fn speedPrior(self: *const Descriptor, voice: []const u8) ?f32 {
        for (self.speed_priors) |prior| {
            if (std.mem.eql(u8, prior.voice, voice)) return prior.speed;
        }
        return null;
    }
};

/// Liest einen Deskriptor aus einer Datei.
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Descriptor {
    const data = try std.Io.Dir.readFileAlloc(.cwd(), io, path, gpa, .limited(max_descriptor_bytes));
    defer gpa.free(data);

    const base_dir = std.fs.path.dirname(path) orelse ".";
    return parse(gpa, data, base_dir);
}

/// Liest einen Deskriptor aus einem Speicherbereich.
///
/// `base_dir` ist das Verzeichnis, gegen das relative Pfade aufgeloest
/// werden.
pub fn parse(
    gpa: std.mem.Allocator,
    data: []const u8,
    base_dir: []const u8,
) !Descriptor {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const mem = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    // Alle relativen Pfade gelten gegen dieses Verzeichnis. Es wird
    // festgehalten, damit eine Kopie des Deskriptors dieselben Dateien findet.
    const base_dir_absolute = try resolveDir(mem, base_dir);

    const type_text = try jsonString(root, "type");
    const backend = try parseBackend(type_text orelse "ONNX2");

    // Die JSON-Werte werden nur geliehen. Sie stehen im Puffer des Parsers,
    // der am Ende dieser Funktion freigegeben wird. Deshalb landet jeder
    // Text, der laenger lebt, in der Arena des Deskriptors.
    const name = try mem.dupe(u8, try requiredString(root, "name"));

    const version_text = try jsonString(root, "version");
    const version = try mem.dupe(u8, version_text orelse "");

    const model_text = try jsonString(root, "model");
    const model = try mem.dupe(u8, model_text orelse name);

    const model_file_text = try requiredString(root, "model_file");
    const model_file = try resolvePath(mem, base_dir_absolute, model_file_text);

    var descriptor = Descriptor{
        // Der Platzhalter wird unten durch die gefuellte Arena ersetzt.
        .arena = std.heap.ArenaAllocator.init(gpa),
        .name = name,
        .version = version,
        .model = model,
        .backend = backend,
        .model_file = model_file,
        .sample_rate = try parseSampleRate(root),
        .voices = try parseVoices(mem, root, base_dir_absolute),
        .text = try parseText(mem, root),
        .tokenizer = try parseTokenizer(mem, root, base_dir_absolute),
        .style = try parseStyle(root),
        .inputs = try parseInputs(mem, root),
        .output = try parseOutput(mem, root),
        .voice_aliases = try parseVoiceAliases(mem, root),
        .speed_priors = try parseSpeedPriors(mem, root),
        .espeak = try parseEspeak(mem, root),
        .inference = try parseInference(root),
        .raw = try mem.dupe(u8, data),
        .base_dir = base_dir_absolute,
    };

    // Die Arena wird erst nach allen Allokationen kopiert. Sie merkt sich
    // die belegten Bloecke in ihrem eigenen Zustand. Eine frueher Kopie
    // wuerde die nach dem Kopierzeitpunkt belegten Bloecke nicht mehr
    // freigeben.
    descriptor.arena = arena;

    return descriptor;
}

fn parseSampleRate(root: std.json.ObjectMap) !?u32 {
    const value = root.get("sample_rate") orelse return null;
    const number = switch (value) {
        .integer => |number| number,
        .float => |number| @as(i64, @intFromFloat(number)),
        else => return error.ExpectedInteger,
    };
    if (number <= 0) return error.InvalidSampleRate;
    return @intCast(number);
}

fn parseVoices(mem: std.mem.Allocator, root: std.json.ObjectMap, base_dir: []const u8) !VoicesSpec {
    // Modelle ohne Stimmtabelle brauchen keine Angabe. Sie haben eine
    // einzige Stimme, die der Anzeigename des Modells benennt.
    const value = root.get("voices") orelse return .{};

    switch (value) {
        // Der einfache Fall: ein NPZ-Archiv mit den Stimmen.
        .string => |file| {
            return .{
                .file = try resolvePath(mem, base_dir, file),
            };
        },
        .object => |object| {
            const file = try requiredString(object, "file");
            const format_text = try jsonString(object, "format");
            const format = try parseVoicesFormat(format_text orelse "npz");

            const spec = VoicesSpec{
                .file = try resolvePath(mem, base_dir, file),
                .format = format,
                .names = try stringArray(mem, object, "names"),
                .rows = @intCast(try optionalInt(object, "rows") orelse 0),
                .columns = @intCast(try optionalInt(object, "columns") orelse 256),
            };

            if (spec.format == .flat) {
                if (spec.names.len == 0) return error.MissingVoiceNames;
                if (spec.rows == 0) return error.MissingVoiceRows;
            }
            return spec;
        },
        else => return error.ExpectedStringOrObject,
    }
}

fn parseVoicesFormat(text: []const u8) !VoicesFormat {
    if (std.mem.eql(u8, text, "npz")) return .npz;
    if (std.mem.eql(u8, text, "flat")) return .flat;
    return error.UnknownVoicesFormat;
}

fn parseText(mem: std.mem.Allocator, root: std.json.ObjectMap) !TextSpec {
    var spec = TextSpec{};

    const value = root.get("text") orelse return spec;
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    if (try jsonString(object, "language")) |language| {
        spec.language = try mem.dupe(u8, language);
    }

    spec.preprocess = try parsePreprocessMode(object);

    if (try jsonString(object, "mode")) |mode| {
        spec.mode = try parseTextMode(mode);
    }

    if (try optionalBool(object, "normalize_nfd")) |flag| {
        spec.normalize_nfd = flag;
    }

    if (try optionalInt(object, "max_tokens")) |number| {
        if (number < 0) return error.InvalidTokenLimit;
        spec.max_tokens = @intCast(number);
    }

    if (try optionalBool(object, "append_terminator")) |flag| {
        spec.append_terminator = flag;
    }

    if (try jsonString(object, "clause_separator")) |separator| {
        spec.clause_separator = try mem.dupe(u8, separator);
    }

    if (try optionalInt(object, "chunk_chars")) |number| {
        if (number < 0) return error.InvalidChunkSize;
        spec.chunk_chars = @intCast(number);
    }

    spec.replacements = try parseReplacements(mem, object);

    return spec;
}

fn parseTextMode(text: []const u8) !TextMode {
    if (std.mem.eql(u8, text, "whole")) return .whole;
    if (std.mem.eql(u8, text, "clause")) return .clause;
    return error.UnknownTextMode;
}

fn parseReplacements(mem: std.mem.Allocator, object: std.json.ObjectMap) ![]const Replacement {
    const value = object.get("replacements") orelse return &.{};
    const array = switch (value) {
        .array => |array| array,
        else => return error.ExpectedArray,
    };

    const result = try mem.alloc(Replacement, array.items.len);
    for (array.items, 0..) |item, index| {
        const fields = switch (item) {
            .object => |fields| fields,
            else => return error.ExpectedObject,
        };
        result[index] = .{
            .from = try mem.dupe(u8, try requiredString(fields, "from")),
            .to = try mem.dupe(u8, try requiredString(fields, "to")),
        };
    }
    return result;
}

fn parsePreprocessMode(object: std.json.ObjectMap) !PreprocessMode {
    const value = object.get("preprocess") orelse return .numbers;
    const text = switch (value) {
        .string => |name| name,
        else => return error.ExpectedString,
    };
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "numbers")) return .numbers;
    return error.UnknownPreprocessMode;
}

fn parseTokenizer(mem: std.mem.Allocator, root: std.json.ObjectMap, base_dir: []const u8) !TokenizerSpec {
    var spec = TokenizerSpec{};

    const value = root.get("tokenizer") orelse return spec;
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    if (try jsonString(object, "mode")) |mode| {
        spec.mode = try parseTokenizerMode(mode);
    }

    // Ohne Angabe folgt die Worttrennung dem Modus. Die eingebaute Tabelle
    // gruppiert Wortzeichen, ein Vokabular ordnet jedes Zeichen einzeln zu.
    spec.word_split = spec.mode == .builtin;

    if (try jsonString(object, "symbols")) |file| {
        spec.symbols = try resolvePath(mem, base_dir, file);
    }
    if (try jsonString(object, "phoneme_id_map")) |file| {
        spec.phoneme_id_map = try resolvePath(mem, base_dir, file);
    }
    if (try jsonString(object, "phoneme_id_map_field")) |field| {
        spec.phoneme_id_map_field = try mem.dupe(u8, field);
    }

    if (try optionalInt(object, "start_id")) |number| spec.start_id = number;
    if (object.get("end_id")) |end_value| {
        spec.end_id = switch (end_value) {
            .null => null,
            .integer => |number| number,
            .float => |number| @as(i64, @intFromFloat(number)),
            else => return error.ExpectedInteger,
        };
    }
    if (try optionalInt(object, "pad_id")) |number| spec.pad_id = number;
    if (try optionalBool(object, "word_split")) |flag| spec.word_split = flag;

    if (try jsonString(object, "start_key")) |key| spec.start_key = try mem.dupe(u8, key);
    if (try jsonString(object, "pad_key")) |key| spec.pad_key = try mem.dupe(u8, key);
    if (try jsonString(object, "end_key")) |key| spec.end_key = try mem.dupe(u8, key);

    if (try jsonString(object, "symbol_scheme")) |scheme| {
        spec.symbol_scheme = try parseSymbolScheme(scheme);
    }

    if (spec.mode == .vocab and spec.symbols == null) return error.MissingSymbolFile;
    if (spec.mode == .phoneme_ids and spec.phoneme_id_map == null) return error.MissingPhonemeIdMap;

    return spec;
}

fn parseTokenizerMode(text: []const u8) !TokenizerMode {
    if (std.mem.eql(u8, text, "builtin")) return .builtin;
    if (std.mem.eql(u8, text, "vocab")) return .vocab;
    if (std.mem.eql(u8, text, "phoneme_ids")) return .phoneme_ids;
    return error.UnknownTokenizerMode;
}

fn parseSymbolScheme(text: []const u8) !tokens.SymbolScheme {
    if (std.mem.eql(u8, text, "first_wins")) return .first_wins;
    if (std.mem.eql(u8, text, "last_wins")) return .last_wins;
    return error.UnknownSymbolScheme;
}

fn parseStyle(root: std.json.ObjectMap) !StyleSpec {
    var spec = StyleSpec{};

    const value = root.get("style") orelse return spec;
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    const index_value = object.get("index") orelse return spec;
    const index = switch (index_value) {
        .object => |fields| fields,
        else => return error.ExpectedObject,
    };

    if (index.get("basis")) |basis_value| {
        const basis_text = switch (basis_value) {
            .string => |text| text,
            else => return error.ExpectedString,
        };
        spec.index.basis = try parseStyleBasis(basis_text);
    }

    if (try optionalInt(index, "offset")) |number| {
        if (number < 0) return error.InvalidStyleOffset;
        spec.index.offset = @intCast(number);
    }

    if (try optionalInt(index, "min")) |number| {
        if (number < 0) return error.InvalidStyleBound;
        spec.index.min = @intCast(number);
    }

    if (try optionalInt(index, "max")) |number| {
        if (number < 0) return error.InvalidStyleBound;
        spec.index.max = @intCast(number);
    }

    return spec;
}

fn parseStyleBasis(text: []const u8) !StyleBasis {
    if (std.mem.eql(u8, text, "tokens")) return .tokens;
    if (std.mem.eql(u8, text, "symbols")) return .symbols;
    return error.UnknownStyleBasis;
}

fn parseInputs(mem: std.mem.Allocator, root: std.json.ObjectMap) !InputNames {
    var names = InputNames{};

    const value = root.get("inputs") orelse return names;
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    if (try jsonString(object, "tokens")) |name| {
        names.tokens = try mem.dupe(u8, name);
    }
    if (try jsonString(object, "style")) |name| {
        names.style = try mem.dupe(u8, name);
    }
    if (try jsonString(object, "speed")) |name| {
        names.speed = try mem.dupe(u8, name);
    }
    if (try jsonString(object, "lengths")) |name| {
        names.lengths = try mem.dupe(u8, name);
    }
    if (try jsonString(object, "scales")) |name| {
        names.scales = try mem.dupe(u8, name);
    }

    return names;
}

fn parseOutput(mem: std.mem.Allocator, root: std.json.ObjectMap) !OutputSpec {
    var spec = OutputSpec{};

    const value = root.get("output") orelse return spec;
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    if (try jsonString(object, "name")) |name| {
        spec.name = try mem.dupe(u8, name);
    }

    if (try optionalInt(object, "trim_tail_samples")) |number| {
        if (number < 0) return error.InvalidTrimSize;
        spec.trim_tail_samples = @intCast(number);
    }

    if (try jsonString(object, "normalize")) |name| {
        spec.normalize = try parseOutputNormalize(name);
    }

    return spec;
}

fn parseOutputNormalize(text: []const u8) !OutputNormalize {
    if (std.mem.eql(u8, text, "none")) return .none;
    if (std.mem.eql(u8, text, "peak")) return .peak;
    return error.UnknownNormalizeMode;
}

/// Liest die Angaben zur espeak-ng-Bibliothek.
fn parseEspeak(mem: std.mem.Allocator, root: std.json.ObjectMap) !EspeakSpec {
    var spec = EspeakSpec{};

    const value = root.get("espeak") orelse return spec;
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    if (try jsonString(object, "library_path")) |path| {
        spec.library_path = try mem.dupe(u8, path);
    }
    if (try jsonString(object, "data_dir")) |path| {
        spec.data_dir = try mem.dupe(u8, path);
    }

    return spec;
}

/// Liest die Werte, mit denen das Modell gerechnet wird.
fn parseInference(root: std.json.ObjectMap) !InferenceSpec {
    var spec = InferenceSpec{};

    const value = root.get("inference") orelse return spec;
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    if (try optionalFloat(object, "noise_scale")) |number| spec.noise_scale = number;
    if (try optionalFloat(object, "length_scale")) |number| spec.length_scale = number;
    if (try optionalFloat(object, "noise_w")) |number| spec.noise_w = number;

    return spec;
}

fn parseVoiceAliases(mem: std.mem.Allocator, root: std.json.ObjectMap) ![]const VoiceAlias {
    const value = root.get("voice_aliases") orelse return &.{};
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    var list: std.ArrayList(VoiceAlias) = .empty;
    defer list.deinit(mem);

    var iterator = object.iterator();
    while (iterator.next()) |pair| {
        const voice = switch (pair.value_ptr.*) {
            .string => |text| text,
            else => return error.ExpectedString,
        };
        try list.append(mem, .{
            .alias = try mem.dupe(u8, pair.key_ptr.*),
            .voice = try mem.dupe(u8, voice),
        });
    }

    return try list.toOwnedSlice(mem);
}

fn parseSpeedPriors(mem: std.mem.Allocator, root: std.json.ObjectMap) ![]const SpeedPrior {
    const value = root.get("speed_priors") orelse return &.{};
    const object = switch (value) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };

    var list: std.ArrayList(SpeedPrior) = .empty;
    defer list.deinit(mem);

    var iterator = object.iterator();
    while (iterator.next()) |pair| {
        const speed: f32 = switch (pair.value_ptr.*) {
            .float => |number| @floatCast(number),
            .integer => |number| @floatFromInt(number),
            else => return error.ExpectedNumber,
        };
        try list.append(mem, .{
            .voice = try mem.dupe(u8, pair.key_ptr.*),
            .speed = speed,
        });
    }

    return try list.toOwnedSlice(mem);
}

fn parseBackend(text: []const u8) !Backend {
    if (std.mem.eql(u8, text, "ONNX2")) return .style_tokens;
    if (std.mem.eql(u8, text, "onnx2")) return .style_tokens;
    if (std.mem.eql(u8, text, "onnx_ar")) return .style_tokens;
    if (std.mem.eql(u8, text, "style_tokens")) return .style_tokens;
    if (std.mem.eql(u8, text, "phoneme_ids")) return .phoneme_ids;
    if (std.mem.eql(u8, text, "pocket_step")) return .pocket_step;
    return error.UnknownBackend;
}

/// Liest ein Pflichtfeld vom Typ Text.
fn requiredString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return (try jsonString(object, name)) orelse error.MissingField;
}

/// Liest ein optionales Feld vom Typ Text.
fn jsonString(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => error.ExpectedString,
    };
}

fn optionalInt(object: std.json.ObjectMap, name: []const u8) !?i64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @as(i64, @intFromFloat(number)),
        .null => null,
        else => error.ExpectedInteger,
    };
}

fn optionalBool(object: std.json.ObjectMap, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => error.ExpectedBool,
    };
}

fn optionalFloat(object: std.json.ObjectMap, name: []const u8) !?f32 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .float => |number| @floatCast(number),
        .integer => |number| @floatFromInt(number),
        else => error.ExpectedNumber,
    };
}

fn stringArray(mem: std.mem.Allocator, object: std.json.ObjectMap, name: []const u8) ![]const []const u8 {
    const value = object.get(name) orelse return &.{};
    const array = switch (value) {
        .array => |array| array,
        else => return error.ExpectedArray,
    };

    if (array.items.len == 0) return &.{};

    const result = try mem.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, index| {
        result[index] = switch (item) {
            .string => |text| try mem.dupe(u8, text),
            else => return error.ExpectedString,
        };
    }
    return result;
}

/// Loest einen Pfad gegen das Verzeichnis des Deskriptors auf.
fn resolvePath(mem: std.mem.Allocator, base_dir: []const u8, path: []const u8) ![]const u8 {
    if (path.len == 0) return error.EmptyPath;
    if (std.fs.path.isAbsolute(path)) return mem.dupe(u8, path);
    return std.fs.path.resolve(mem, &.{ base_dir, path });
}

/// Macht ein Verzeichnis absolut.
fn resolveDir(mem: std.mem.Allocator, dir: []const u8) ![]const u8 {
    if (dir.len == 0) return std.fs.path.resolve(mem, &.{"."});
    return std.fs.path.resolve(mem, &.{dir});
}

const testing = std.testing;

/// Inhalt der echten Datei `config.json` des Modells kitten-tts-nano.
const kitten_config =
    \\{
    \\  "name": "Kitten TTS Nano",
    \\  "version": "0.8",
    \\  "type": "ONNX2",
    \\  "model": "kitten-tts-nano-0.8",
    \\  "voices" : "voices.npz",
    \\  "model_file": "kitten_tts_nano_v0_8.onnx",
    \\  "speed_priors": {
    \\    "expr-voice-2-f": 0.8,
    \\    "expr-voice-2-m": 0.8,
    \\    "expr-voice-3-m": 0.8,
    \\    "expr-voice-3-f": 0.8,
    \\    "expr-voice-4-m": 0.9,
    \\    "expr-voice-4-f": 0.8,
    \\    "expr-voice-5-m": 0.8,
    \\    "expr-voice-5-f": 0.8
    \\  },
    \\  "voice_aliases": {
    \\    "Bella": "expr-voice-2-f",
    \\    "Jasper": "expr-voice-2-m",
    \\    "Luna": "expr-voice-3-f",
    \\    "Bruno": "expr-voice-3-m",
    \\    "Rosie": "expr-voice-4-f",
    \\    "Hugo": "expr-voice-4-m",
    \\    "Kiki": "expr-voice-5-f",
    \\    "Leo": "expr-voice-5-m"
    \\ }
    \\}
;

/// Deskriptor eines Kokoro-artigen Modells mit flacher Stimmdatei.
const kokoro_config =
    \\{
    \\  "name": "Kokoro English",
    \\  "version": "0.19",
    \\  "type": "onnx_ar",
    \\  "model": "kokoro-en-v0_19",
    \\  "model_file": "model.onnx",
    \\  "sample_rate": 24000,
    \\  "voices": {
    \\    "file": "voices.bin",
    \\    "format": "flat",
    \\    "names": ["af", "af_bella", "am_adam"],
    \\    "rows": 511,
    \\    "columns": 256
    \\  },
    \\  "text": {
    \\    "language": "en-us",
    \\    "preprocess": "none",
    \\    "chunk_chars": 0
    \\  },
    \\  "tokenizer": {
    \\    "mode": "vocab",
    \\    "symbols": "tokens.txt",
    \\    "start_id": 0,
    \\    "end_id": null,
    \\    "pad_id": 0
    \\  },
    \\  "style": {
    \\    "index": {
    \\      "basis": "symbols",
    \\      "offset": 2,
    \\      "min": 0,
    \\      "max": 509
    \\    }
    \\  },
    \\  "inputs": {
    \\    "tokens": "tokens",
    \\    "style": "style",
    \\    "speed": "speed"
    \\  },
    \\  "output": {
    \\    "name": "audio",
    \\    "trim_tail_samples": 0
    \\  }
    \\}
;

test "Deskriptor liest die Kitten-Konfiguration mit den Vorgabewerten" {
    const gpa = testing.allocator;
    var descriptor = try parse(gpa, kitten_config, "/model/kitten-tts-nano");
    defer descriptor.deinit();

    try testing.expectEqualStrings("Kitten TTS Nano", descriptor.name);
    try testing.expectEqualStrings("0.8", descriptor.version);
    try testing.expectEqualStrings("kitten-tts-nano-0.8", descriptor.model);
    try testing.expectEqual(Backend.style_tokens, descriptor.backend);

    // Relative Pfade werden gegen das Verzeichnis der Datei aufgeloest.
    try testing.expectEqualStrings("/model/kitten-tts-nano/kitten_tts_nano_v0_8.onnx", descriptor.model_file);
    try testing.expectEqualStrings("/model/kitten-tts-nano/voices.npz", descriptor.voices.file);

    // Ohne Angabe liest die Engine die Abtastrate aus dem Modell.
    try testing.expectEqual(@as(?u32, null), descriptor.sample_rate);

    try testing.expectEqualStrings("en-us", descriptor.text.language);
    try testing.expectEqual(PreprocessMode.numbers, descriptor.text.preprocess);
    try testing.expectEqual(@as(usize, 400), descriptor.text.chunk_chars);
    try testing.expectEqualStrings(" ", descriptor.text.clause_separator);

    try testing.expectEqual(TokenizerMode.builtin, descriptor.tokenizer.mode);
    try testing.expectEqual(@as(i64, 0), descriptor.tokenizer.start_id);
    try testing.expectEqual(@as(?i64, 10), descriptor.tokenizer.end_id);
    try testing.expectEqual(@as(i64, 0), descriptor.tokenizer.pad_id);
    try testing.expect(descriptor.tokenizer.word_split);
    try testing.expectEqual(tokens.SymbolScheme.first_wins, descriptor.tokenizer.symbol_scheme);

    try testing.expectEqual(StyleBasis.tokens, descriptor.style.index.basis);
    try testing.expectEqual(@as(usize, 0), descriptor.style.index.offset);
    try testing.expectEqual(@as(usize, 0), descriptor.style.index.min);
    try testing.expectEqual(@as(?usize, null), descriptor.style.index.max);

    try testing.expectEqualStrings("input_ids", descriptor.inputs.tokens);
    try testing.expectEqualStrings("style", descriptor.inputs.style);
    try testing.expectEqualStrings("speed", descriptor.inputs.speed);

    try testing.expectEqualStrings("audio", descriptor.output.name);
    try testing.expectEqual(@as(usize, 5000), descriptor.output.trim_tail_samples);
}

test "Deskriptor loest Aliase und Tempopriors auf" {
    const gpa = testing.allocator;
    var descriptor = try parse(gpa, kitten_config, "/model");
    defer descriptor.deinit();

    try testing.expectEqualStrings("expr-voice-3-m", descriptor.aliasTarget("Bruno").?);
    try testing.expectEqualStrings("expr-voice-3-m", descriptor.aliasTarget("bruno").?);
    try testing.expectEqualStrings("expr-voice-2-f", descriptor.aliasTarget("BELLA").?);
    try testing.expect(descriptor.aliasTarget("Unbekannt") == null);

    try testing.expectEqual(@as(f32, 0.8), descriptor.speedPrior("expr-voice-2-f").?);
    try testing.expectEqual(@as(f32, 0.9), descriptor.speedPrior("expr-voice-4-m").?);
    try testing.expect(descriptor.speedPrior("expr-voice-9-m") == null);
}

test "Deskriptor liest eine flache Stimmdatei mit Namen und Zeilenzahl" {
    const gpa = testing.allocator;
    var descriptor = try parse(gpa, kokoro_config, "/model/kokoro");
    defer descriptor.deinit();

    try testing.expectEqual(Backend.style_tokens, descriptor.backend);
    try testing.expectEqual(@as(?u32, 24000), descriptor.sample_rate);
    try testing.expectEqual(VoicesFormat.flat, descriptor.voices.format);
    try testing.expectEqualStrings("/model/kokoro/voices.bin", descriptor.voices.file);
    try testing.expectEqual(@as(usize, 3), descriptor.voices.names.len);
    try testing.expectEqualStrings("af_bella", descriptor.voices.names[1]);
    try testing.expectEqual(@as(usize, 511), descriptor.voices.rows);
    try testing.expectEqual(@as(usize, 256), descriptor.voices.columns);

    try testing.expectEqual(PreprocessMode.none, descriptor.text.preprocess);
    try testing.expectEqual(@as(usize, 0), descriptor.text.chunk_chars);

    try testing.expectEqual(TokenizerMode.vocab, descriptor.tokenizer.mode);
    try testing.expectEqualStrings("/model/kokoro/tokens.txt", descriptor.tokenizer.symbols.?);
    try testing.expectEqual(@as(?i64, null), descriptor.tokenizer.end_id);
    try testing.expect(!descriptor.tokenizer.word_split);

    try testing.expectEqual(StyleBasis.symbols, descriptor.style.index.basis);
    try testing.expectEqual(@as(usize, 2), descriptor.style.index.offset);
    try testing.expectEqual(@as(?usize, 509), descriptor.style.index.max);

    try testing.expectEqualStrings("tokens", descriptor.inputs.tokens);
    try testing.expectEqual(@as(usize, 0), descriptor.output.trim_tail_samples);
}

test "Deskriptor meldet fehlende Pflichtfelder" {
    const gpa = testing.allocator;
    try testing.expectError(
        error.MissingField,
        parse(gpa, "{\"model_file\": \"m.onnx\", \"voices\": \"v.npz\"}", "/model"),
    );
    try testing.expectError(
        error.MissingField,
        parse(gpa, "{\"name\": \"M\", \"voices\": \"v.npz\"}", "/model"),
    );
}

test "Deskriptor ohne Stimmtabelle nutzt eine einzige Stimme" {
    const gpa = testing.allocator;
    var descriptor = try parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\"}", "/model");
    defer descriptor.deinit();

    try testing.expectEqualStrings("", descriptor.voices.file);
    try testing.expectEqual(VoicesFormat.npz, descriptor.voices.format);
    try testing.expectEqual(@as(usize, 0), descriptor.voices.names.len);
}

test "Deskriptor lehnt unbekannte Verarbeitungswege ab" {
    const gpa = testing.allocator;
    try testing.expectError(
        error.UnknownBackend,
        parse(gpa, "{\"name\": \"M\", \"type\": \"WASM\", \"model_file\": \"m.onnx\", \"voices\": \"v.npz\"}", "/model"),
    );
    try testing.expectError(
        error.UnknownVoicesFormat,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": {\"file\": \"v.bin\", \"format\": \"tar\"}}", "/model"),
    );
    try testing.expectError(
        error.UnknownTokenizerMode,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": \"v.npz\", \"tokenizer\": {\"mode\": \"bpe\"}}", "/model"),
    );
    try testing.expectError(
        error.UnknownStyleBasis,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": \"v.npz\", \"style\": {\"index\": {\"basis\": \"chars\"}}}", "/model"),
    );
}

test "Deskriptor verlangt Namen und Zeilenzahl fuer flache Stimmdateien" {
    const gpa = testing.allocator;
    try testing.expectError(
        error.MissingVoiceNames,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": {\"file\": \"v.bin\", \"format\": \"flat\", \"rows\": 10}}", "/model"),
    );
    try testing.expectError(
        error.MissingVoiceRows,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": {\"file\": \"v.bin\", \"format\": \"flat\", \"names\": [\"a\"]}}", "/model"),
    );
}

/// Deskriptor mit allen Feldern, die die Textpfade der Engine brauchen.
const full_config =
    \\{
    \\  "name": "Voller Deskriptor",
    \\  "type": "phoneme_ids",
    \\  "model": "voll",
    \\  "model_file": "m.onnx",
    \\  "voices": {
    \\    "file": "v.bin",
    \\    "format": "flat",
    \\    "names": ["a"],
    \\    "rows": 10,
    \\    "columns": 256
    \\  },
    \\  "text": {
    \\    "language": "de",
    \\    "mode": "clause",
    \\    "normalize_nfd": true,
    \\    "max_tokens": 510,
    \\    "append_terminator": true,
    \\    "clause_separator": "\n",
    \\    "chunk_chars": 0,
    \\    "replacements": [
    \\      {"from": "alt", "to": "neu"}
    \\    ]
    \\  },
    \\  "inputs": {
    \\    "tokens": "input",
    \\    "lengths": "input_lengths",
    \\    "scales": "scales"
    \\  },
    \\  "output": {
    \\    "name": "output",
    \\    "trim_tail_samples": 0,
    \\    "normalize": "peak"
    \\  },
    \\  "espeak": {
    \\    "library_path": "/lib/libespeak-ng.so.1",
    \\    "data_dir": "/share/espeak-ng-data"
    \\  },
    \\  "inference": {
    \\    "noise_scale": 0.5,
    \\    "length_scale": 1.25,
    \\    "noise_w": 0.75
    \\  }
    \\}
;

test "Deskriptor liest Textmodus, espeak, Inference und Ein- Ausgaben" {
    const gpa = testing.allocator;
    var descriptor = try parse(gpa, full_config, "/model");
    defer descriptor.deinit();

    try testing.expectEqual(Backend.phoneme_ids, descriptor.backend);
    try testing.expectEqual(TextMode.clause, descriptor.text.mode);
    try testing.expect(descriptor.text.normalize_nfd);
    try testing.expectEqual(@as(usize, 510), descriptor.text.max_tokens);
    try testing.expect(descriptor.text.append_terminator);
    try testing.expectEqualStrings("\n", descriptor.text.clause_separator);
    try testing.expectEqual(@as(usize, 0), descriptor.text.chunk_chars);

    try testing.expectEqual(@as(usize, 1), descriptor.text.replacements.len);
    try testing.expectEqualStrings("alt", descriptor.text.replacements[0].from);
    try testing.expectEqualStrings("neu", descriptor.text.replacements[0].to);

    try testing.expectEqualStrings("input", descriptor.inputs.tokens);
    try testing.expectEqualStrings("input_lengths", descriptor.inputs.lengths.?);
    try testing.expectEqualStrings("scales", descriptor.inputs.scales.?);

    try testing.expectEqualStrings("output", descriptor.output.name);
    try testing.expectEqual(OutputNormalize.peak, descriptor.output.normalize);

    try testing.expectEqualStrings("/lib/libespeak-ng.so.1", descriptor.espeak.library_path.?);
    try testing.expectEqualStrings("/share/espeak-ng-data", descriptor.espeak.data_dir.?);

    try testing.expectEqual(@as(f32, 0.5), descriptor.inference.noise_scale);
    try testing.expectEqual(@as(f32, 1.25), descriptor.inference.length_scale);
    try testing.expectEqual(@as(f32, 0.75), descriptor.inference.noise_w);
}

test "Deskriptor meldet unbekannte Werte der neuen Felder" {
    const gpa = testing.allocator;

    try testing.expectError(
        error.UnknownTextMode,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": \"v.npz\", \"text\": {\"mode\": \"satzz\"}}", "/model"),
    );
    try testing.expectError(
        error.UnknownNormalizeMode,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": \"v.npz\", \"output\": {\"normalize\": \"loud\"}}", "/model"),
    );
    try testing.expectError(
        error.ExpectedBool,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": \"v.npz\", \"text\": {\"normalize_nfd\": \"ja\"}}", "/model"),
    );
    try testing.expectError(
        error.ExpectedNumber,
        parse(gpa, "{\"name\": \"M\", \"model_file\": \"m.onnx\", \"voices\": \"v.npz\", \"inference\": {\"noise_scale\": \"loud\"}}", "/model"),
    );
}

test "Kopie des Deskriptors traegt eigene Texte und denselben Fingerabdruck" {
    const gpa = testing.allocator;
    var descriptor = try parse(gpa, full_config, "/model");
    defer descriptor.deinit();

    var copy = try descriptor.clone(gpa);
    defer copy.deinit();

    try testing.expectEqual(descriptor.fingerprint(), copy.fingerprint());
    try testing.expectEqualStrings(descriptor.model_file, copy.model_file);
    try testing.expectEqualStrings(descriptor.text.clause_separator, copy.text.clause_separator);

    // Die Kopie haelt ihren eigenen Speicher. Der Deskriptor darf unveraendert
    // weiterleben, wenn die Registry ihn austauscht.
    try testing.expect(copy.raw.ptr != descriptor.raw.ptr);
    try testing.expectEqualStrings(descriptor.raw, copy.raw);
}

test "Deskriptor liest die echte Kitten-Datei, wenn sie vorhanden ist" {
    const path = "/home/openchamber/dump/coding/tts/models/kitten-tts-nano/config.json";
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return;

    const gpa = testing.allocator;
    var descriptor = try load(gpa, std.testing.io, path);
    defer descriptor.deinit();

    try testing.expectEqualStrings("Kitten TTS Nano", descriptor.name);
    try testing.expectEqual(Backend.style_tokens, descriptor.backend);
    try testing.expectEqualStrings("voices.npz", std.fs.path.basename(descriptor.voices.file));
    try testing.expectEqualStrings("kitten_tts_nano_v0_8.onnx", std.fs.path.basename(descriptor.model_file));
}
