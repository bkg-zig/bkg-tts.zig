//! ONNX-Runtime-Anbindung ueber die C-API.
//!
//! Die Bibliothek wird zur Laufzeit per dlopen geladen. Damit braucht das
//! Projekt keine Build-Zeit-Abhaengigkeit zur ONNX-Runtime, und ein Server
//! ohne installierte Runtime startet mit einer klaren Fehlermeldung statt
//! mit einem Linkerfehler.
//!
//! Die Bindung kennt keine Modellfamilie. Sie liefert Typinformation,
//! Metadaten und rohe Tensorbytes. Die Interpretation liegt beim Backend.
const std = @import("std");
const api = @import("ort_api.zig");

/// Elementtypen der ONNX-Tensoren (ONNXTensorElementDataType).
pub const ElementType = enum(c_int) {
    undefined_ = 0,
    float = 1,
    uint8 = 2,
    int8 = 3,
    uint16 = 4,
    int16 = 5,
    int32 = 6,
    int64 = 7,
    string = 8,
    bool = 9,
    float16 = 10,
    double = 11,
    uint32 = 12,
    uint64 = 13,
    complex64 = 14,
    complex128 = 15,
    bfloat16 = 16,
    float8e4m3fn = 17,
    float8e4m3fnuz = 18,
    float8e5m2 = 19,
    float8e5m2fnuz = 20,
    uint4 = 21,
    int4 = 22,
    _,

    /// Bytegroesse eines Elements. Feste Breiten sind bei ONNX fest.
    pub fn byteSize(self: ElementType) usize {
        return switch (self) {
            .uint8, .int8, .bool, .float8e4m3fn, .float8e4m3fnuz, .float8e5m2, .float8e5m2fnuz => 1,
            .uint16, .int16, .float16, .bfloat16 => 2,
            .int32, .uint32, .float => 4,
            .int64, .uint64, .double => 8,
            .complex64 => 8,
            .complex128 => 16,
            else => 0,
        };
    }
};

/// ONNXType der Runtime: 1 steht fuer Tensor.
const onnx_type_tensor: c_int = 1;

pub const execution_mode_sequential: c_int = 0;
pub const graph_optimization_enable_all: c_int = 99;

/// Logstufe der Runtime-Umgebung: 0 verbose, 1 info, 2 warning, 3 error, 4 fatal.
pub const log_level_error: c_int = 3;

/// Details eines fehlgeschlagenen ONNX-Runtime-Aufrufs.
///
/// Die Runtime haelt Fehlermeldungen nur im `OrtStatus`-Objekt. Der Text wird
/// deshalb direkt nach dem Aufruf kopiert, bevor der Status freigegeben wird.
pub const Failure = struct {
    code: c_int = 0,
    buffer: [1024]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Failure) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn set(self: *Failure, code: c_int, text: []const u8) void {
        self.code = code;
        const clipped = text[0..@min(text.len, self.buffer.len)];
        @memcpy(self.buffer[0..clipped.len], clipped);
        self.len = clipped.len;
    }
};

/// Prueft einen `OrtStatus` und uebertraegt dessen Meldung in `failure`.
fn check(ort: *const api.OrtApi, status: ?*api.OrtStatus, failure: *Failure) !void {
    const state = status orelse return;
    defer ort.f93.?(state);
    const code = ort.f1.?(state);
    const text = ort.f2.?(state);
    const message = if (text) |ptr| std.mem.span(ptr) else "unbekannter ONNX-Runtime-Fehler";
    failure.set(code, message);
    return error.OnnxRuntimeError;
}

/// Laufzeitumgebung mit geladener ONNX-Runtime.
pub const Runtime = struct {
    lib: std.DynLib,
    ort: *const api.OrtApi,
    env: *api.OrtEnv,
    version: []const u8,

    /// Laedt die ONNX-Runtime und erzeugt eine Umgebung.
    pub fn open(lib_path: []const u8, failure: *Failure) !Runtime {
        var lib = std.DynLib.open(lib_path) catch |err| {
            failure.set(0, @errorName(err));
            return error.LibraryLoadFailed;
        };
        errdefer lib.close();

        const base_fn = lib.lookup(
            *const fn () callconv(.c) *const api.OrtApiBase,
            "OrtGetApiBase",
        ) orelse {
            failure.set(0, "OrtGetApiBase fehlt in der geladenen Bibliothek");
            return error.SymbolMissing;
        };
        const base = base_fn();

        const get_api = base.GetApi orelse {
            failure.set(0, "GetApi fehlt in OrtApiBase");
            return error.SymbolMissing;
        };
        const ort = get_api(api.ort_api_version) orelse {
            failure.set(0, "ONNX-Runtime unterstuetzt die API-Version 22 nicht");
            return error.UnsupportedApiVersion;
        };

        const version = if (base.GetVersionString) |get_version|
            std.mem.span(get_version() orelse "unbekannt")
        else
            "unbekannt";

        var env: ?*api.OrtEnv = null;
        try check(ort, ort.f3.?(log_level_error, "bkg-tts", &env), failure);
        const env_handle = env orelse {
            failure.set(0, "CreateEnv lieferte keine Umgebung");
            return error.MissingHandle;
        };

        return .{ .lib = lib, .ort = ort, .env = env_handle, .version = version };
    }

    pub fn deinit(self: *Runtime) void {
        self.ort.f92.?(self.env);
        self.lib.close();
    }
};

pub const SessionOptions = struct {
    intra_op_threads: c_int = 1,
    inter_op_threads: c_int = 1,
    log_severity: c_int = log_level_error,
};

/// Form und Elementtyp eines Ein- oder Ausgangs.
pub const TensorInfo = struct {
    element_type: ElementType,
    shape: []i64,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *TensorInfo) void {
        self.gpa.free(self.shape);
        self.shape = &.{};
    }

    /// Anzahl der Elemente, wenn alle Dimensionen bekannt sind.
    pub fn elementCount(self: *const TensorInfo) ?usize {
        var count: usize = 1;
        for (self.shape) |dim| {
            if (dim < 0) return null;
            count = std.math.mul(usize, count, @intCast(dim)) catch return null;
        }
        return count;
    }
};

/// Rohdaten eines Ausgangs. Die Bytes liegen im Speicher der Runtime und
/// werden hier kopiert.
pub const TensorData = struct {
    bytes: []u8,
    shape: []i64,
    element_type: ElementType,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *TensorData) void {
        self.gpa.free(self.bytes);
        self.gpa.free(self.shape);
        self.bytes = &.{};
        self.shape = &.{};
    }

    /// Liefert die Bytes als Float-Samples. Setzt voraus, dass der Tensor
    /// Float32 enthaelt.
    pub fn asFloats(self: *const TensorData) ![]const f32 {
        if (self.element_type != .float) return error.UnexpectedElementType;
        if (self.bytes.len % @sizeOf(f32) != 0) return error.InvalidTensorSize;
        const aligned = self.bytes.ptr;
        const source: [*]const f32 = @ptrCast(@alignCast(aligned));
        return source[0 .. self.bytes.len / @sizeOf(f32)];
    }
};

/// Eine geladene ONNX-Session mit Namen und Speicherinfo fuer Tensoren.
pub const Session = struct {
    ort: *const api.OrtApi,
    env: *api.OrtEnv,
    handle: *api.OrtSession,
    allocator: *api.OrtAllocator,
    memory_info: *api.OrtMemoryInfo,
    input_names: [][:0]u8,
    output_names: [][:0]u8,
    metadata_keys: [][]u8,

    pub fn create(
        runtime: *const Runtime,
        gpa: std.mem.Allocator,
        model_path: [:0]const u8,
        options: SessionOptions,
        failure: *Failure,
    ) !Session {
        const ort = runtime.ort;

        var session_options: ?*api.OrtSessionOptions = null;
        try check(ort, ort.f10.?(&session_options), failure);
        const opts = session_options orelse {
            failure.set(0, "CreateSessionOptions lieferte keine Optionen");
            return error.MissingHandle;
        };
        defer ort.f100.?(opts);

        try check(ort, ort.f13.?(opts, execution_mode_sequential), failure);
        try check(ort, ort.f15.?(opts), failure);
        try check(ort, ort.f22.?(opts, options.log_severity), failure);
        try check(ort, ort.f23.?(opts, graph_optimization_enable_all), failure);
        try check(ort, ort.f24.?(opts, options.intra_op_threads), failure);
        try check(ort, ort.f25.?(opts, options.inter_op_threads), failure);

        var handle: ?*api.OrtSession = null;
        try check(ort, ort.f7.?(runtime.env, model_path.ptr, opts, &handle), failure);
        const session_handle = handle orelse {
            failure.set(0, "CreateSession lieferte keine Session");
            return error.MissingHandle;
        };
        errdefer ort.f95.?(session_handle);

        var allocator: ?*api.OrtAllocator = null;
        try check(ort, ort.f78.?(&allocator), failure);
        const allocator_handle = allocator orelse {
            failure.set(0, "GetAllocatorWithDefaultOptions lieferte keinen Allokator");
            return error.MissingHandle;
        };

        var memory_info: ?*api.OrtMemoryInfo = null;
        try check(ort, ort.f69.?(0, 0, &memory_info), failure);
        const memory_handle = memory_info orelse {
            failure.set(0, "CreateCpuMemoryInfo lieferte keine Speicherinfo");
            return error.MissingHandle;
        };
        errdefer ort.f94.?(memory_handle);

        const input_names = try readNames(ort, session_handle, allocator_handle, true, gpa, failure);
        errdefer freeNames(gpa, input_names);
        const output_names = try readNames(ort, session_handle, allocator_handle, false, gpa, failure);
        errdefer freeNames(gpa, output_names);

        const metadata_keys = try readMetadataKeys(ort, session_handle, allocator_handle, gpa, failure);
        errdefer freeMetadataKeys(gpa, metadata_keys);

        return .{
            .ort = ort,
            .env = runtime.env,
            .handle = session_handle,
            .allocator = allocator_handle,
            .memory_info = memory_handle,
            .input_names = input_names,
            .output_names = output_names,
            .metadata_keys = metadata_keys,
        };
    }

    pub fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        freeNames(gpa, self.input_names);
        freeNames(gpa, self.output_names);
        freeMetadataKeys(gpa, self.metadata_keys);
        self.ort.f94.?(self.memory_info);
        self.ort.f95.?(self.handle);
        self.* = undefined;
    }

    /// Sucht den Eingang mit diesem Namen und liefert seinen Index.
    ///
    /// Der Deskriptor nennt die Ein- und Ausgaenge des Graphen beim Namen.
    /// Die Reihenfolge im Graphen darf sich deshalb nicht im Code stehen.
    pub fn inputIndexByName(self: *const Session, name: []const u8) ?usize {
        for (self.input_names, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) return index;
        }
        return null;
    }

    /// Sucht den Ausgang mit diesem Namen und liefert seinen Index.
    pub fn outputIndexByName(self: *const Session, name: []const u8) ?usize {
        for (self.output_names, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) return index;
        }
        return null;
    }

    /// Liefert Form und Elementtyp eines Eingangs.
    pub fn inputInfo(
        self: *const Session,
        gpa: std.mem.Allocator,
        index: usize,
        failure: *Failure,
    ) !TensorInfo {
        return self.readTypeInfo(gpa, index, true, failure);
    }

    /// Liefert Form und Elementtyp eines Ausgangs.
    pub fn outputInfo(
        self: *const Session,
        gpa: std.mem.Allocator,
        index: usize,
        failure: *Failure,
    ) !TensorInfo {
        return self.readTypeInfo(gpa, index, false, failure);
    }

    fn readTypeInfo(
        self: *const Session,
        gpa: std.mem.Allocator,
        index: usize,
        inputs: bool,
        failure: *Failure,
    ) !TensorInfo {
        const ort = self.ort;
        var type_info: ?*api.OrtTypeInfo = null;
        if (inputs) {
            try check(ort, ort.f33.?(self.handle, index, &type_info), failure);
        } else {
            try check(ort, ort.f34.?(self.handle, index, &type_info), failure);
        }
        const info = type_info orelse {
            failure.set(0, "Session lieferte keine Typinformation");
            return error.MissingHandle;
        };

        var onnx_type: c_int = 0;
        try check(ort, ort.f56.?(info, &onnx_type), failure);
        if (onnx_type != onnx_type_tensor) {
            ort.f98.?(info);
            failure.set(0, "Ein- oder Ausgang ist kein Tensor");
            return error.UnsupportedType;
        }

        // CastTypeInfoToTensorInfo legt kein zweites Objekt an, sondern
        // liefert denselben Speicher zurueck. Deshalb wird der Typinfo-
        // Handle nach dem Cast nicht zusaetzlich freigegeben.
        var shape_info: ?*api.OrtTensorTypeAndShapeInfo = null;
        try check(ort, ort.f55.?(info, &shape_info), failure);
        const tensor_info = shape_info orelse {
            ort.f98.?(info);
            failure.set(0, "CastTypeInfoToTensorInfo lieferte keine Forminfo");
            return error.MissingHandle;
        };
        defer ort.f99.?(tensor_info);

        var element_type: c_int = 0;
        try check(ort, ort.f60.?(tensor_info, &element_type), failure);

        var dims_len: usize = 0;
        try check(ort, ort.f61.?(tensor_info, &dims_len), failure);
        const shape = try gpa.alloc(i64, dims_len);
        errdefer gpa.free(shape);
        if (dims_len > 0) try check(ort, ort.f62.?(tensor_info, shape.ptr, dims_len), failure);

        return .{
            .element_type = @enumFromInt(element_type),
            .shape = shape,
            .gpa = gpa,
        };
    }

    /// Liest einen Wert aus der benutzerdefinierten Modellmetadatenliste.
    /// Fehlt der Schluessel, liefert die Funktion null.
    pub fn metadataValue(
        self: *const Session,
        gpa: std.mem.Allocator,
        key: []const u8,
        failure: *Failure,
    ) !?[]u8 {
        var found = false;
        for (self.metadata_keys) |candidate| {
            if (std.mem.eql(u8, candidate, key)) {
                found = true;
                break;
            }
        }
        if (!found) return null;

        const ort = self.ort;
        var metadata: ?*api.OrtModelMetadata = null;
        try check(ort, ort.f111.?(self.handle, &metadata), failure);
        const handle = metadata orelse {
            failure.set(0, "SessionGetModelMetadata lieferte keine Metadaten");
            return error.MissingHandle;
        };
        defer ort.f118.?(handle);

        const key_z = try gpa.allocSentinel(u8, key.len, 0);
        defer gpa.free(key_z);
        @memcpy(key_z[0..key.len], key);

        var raw: ?[*:0]u8 = null;
        try check(ort, ort.f116.?(handle, self.allocator, key_z.ptr, &raw), failure);
        const text = raw orelse {
            failure.set(0, "ModelMetadataLookupCustomMetadataMap lieferte keinen Wert");
            return error.MissingHandle;
        };
        defer _ = ort.f76.?(self.allocator, @ptrCast(text));

        const source = std.mem.span(text);
        const copy = try gpa.alloc(u8, source.len);
        @memcpy(copy, source);
        return copy;
    }

    /// Erzeugt einen Tensor aus 64-Bit-Ganzzahlen.
    pub fn createInt64Tensor(
        self: *const Session,
        data: []const i64,
        shape: []const i64,
        failure: *Failure,
    ) !*api.OrtValue {
        return self.createTensor(.int64, std.mem.sliceAsBytes(data), shape, failure);
    }

    /// Erzeugt einen Tensor aus 32-Bit-Ganzzahlen.
    pub fn createInt32Tensor(
        self: *const Session,
        data: []const i32,
        shape: []const i64,
        failure: *Failure,
    ) !*api.OrtValue {
        return self.createTensor(.int32, std.mem.sliceAsBytes(data), shape, failure);
    }

    /// Erzeugt einen Tensor aus 32-Bit-Fliesskommazahlen.
    pub fn createFloatTensor(
        self: *const Session,
        data: []const f32,
        shape: []const i64,
        failure: *Failure,
    ) !*api.OrtValue {
        return self.createTensor(.float, std.mem.sliceAsBytes(data), shape, failure);
    }

    /// Erzeugt einen Tensor aus beliebigen Rohbytes, zum Beispiel Float16.
    pub fn createRawTensor(
        self: *const Session,
        element_type: ElementType,
        data: []const u8,
        shape: []const i64,
        failure: *Failure,
    ) !*api.OrtValue {
        return self.createTensor(element_type, data, shape, failure);
    }

    fn createTensor(
        self: *const Session,
        element_type: ElementType,
        data: []const u8,
        shape: []const i64,
        failure: *Failure,
    ) !*api.OrtValue {
        var value: ?*api.OrtValue = null;
        const raw: *anyopaque = @ptrCast(@constCast(data.ptr));
        try check(self.ort, self.ort.f49.?(
            self.memory_info,
            raw,
            data.len,
            shape.ptr,
            shape.len,
            @intFromEnum(element_type),
            &value,
        ), failure);
        return value orelse {
            failure.set(0, "CreateTensorWithDataAsOrtValue lieferte keinen Wert");
            return error.MissingHandle;
        };
    }
};

/// Ein Eingangstensor fuer einen Lauf.
pub const RunInput = struct {
    name: [:0]const u8,
    value: *api.OrtValue,
};

/// Fuehrt die Session aus und kopiert alle Ausgaben in den Zig-Allocator.
pub fn runAll(
    session: *const Session,
    gpa: std.mem.Allocator,
    inputs: []const RunInput,
    failure: *Failure,
) ![]TensorData {
    const ort = session.ort;

    const input_names = try gpa.alloc(?[*:0]const u8, inputs.len);
    defer gpa.free(input_names);
    const input_values = try gpa.alloc(*const api.OrtValue, inputs.len);
    defer gpa.free(input_values);
    for (inputs, 0..) |input, index| {
        input_names[index] = @ptrCast(input.name.ptr);
        input_values[index] = input.value;
    }

    const output_names = try gpa.alloc(?[*:0]const u8, session.output_names.len);
    defer gpa.free(output_names);
    for (session.output_names, 0..) |name, index| {
        output_names[index] = @ptrCast(name.ptr);
    }

    const output_values = try gpa.alloc(?*api.OrtValue, session.output_names.len);
    defer {
        for (output_values) |value| {
            if (value) |handle| ort.f96.?(handle);
        }
        gpa.free(output_values);
    }
    @memset(output_values, null);

    try check(ort, ort.f9.?(
        session.handle,
        null,
        input_names.ptr,
        input_values.ptr,
        inputs.len,
        output_names.ptr,
        output_names.len,
        output_values.ptr,
    ), failure);

    const results = try gpa.alloc(TensorData, output_values.len);
    var filled: usize = 0;
    errdefer {
        for (results[0..filled]) |*result| result.deinit();
        gpa.free(results);
    }

    for (output_values) |maybe_value| {
        const value = maybe_value orelse {
            failure.set(0, "ONNX-Runtime lieferte keinen Ausgabewert");
            return error.MissingHandle;
        };
        results[filled] = try readTensor(session, gpa, value, failure);
        filled += 1;
    }
    return results;
}

/// Fuehrt die Session aus und liefert genau eine Ausgabe.
pub fn run(
    session: *const Session,
    gpa: std.mem.Allocator,
    inputs: []const RunInput,
    output_index: usize,
    failure: *Failure,
) !TensorData {
    const results = try runAll(session, gpa, inputs, failure);
    defer {
        for (results) |*result| result.deinit();
        gpa.free(results);
    }
    if (output_index >= results.len) {
        failure.set(0, "Ausgabeindex liegt ausserhalb der Modellausgaben");
        return error.InvalidOutputIndex;
    }
    const selected = results[output_index];
    results[output_index] = .{ .bytes = &.{}, .shape = &.{}, .element_type = .undefined_, .gpa = gpa };
    return selected;
}

/// Liest Form, Elementtyp und Bytes eines Ausgangs.
fn readTensor(
    session: *const Session,
    gpa: std.mem.Allocator,
    value: *api.OrtValue,
    failure: *Failure,
) !TensorData {
    const ort = session.ort;

    var info: ?*api.OrtTensorTypeAndShapeInfo = null;
    try check(ort, ort.f65.?(value, &info), failure);
    const shape_info = info orelse {
        failure.set(0, "GetTensorTypeAndShape lieferte keine Forminfo");
        return error.MissingHandle;
    };
    defer ort.f99.?(shape_info);

    var element_type: c_int = 0;
    try check(ort, ort.f60.?(shape_info, &element_type), failure);

    var element_count: usize = 0;
    try check(ort, ort.f64.?(shape_info, &element_count), failure);
    var dims_len: usize = 0;
    try check(ort, ort.f61.?(shape_info, &dims_len), failure);

    const shape = try gpa.alloc(i64, dims_len);
    errdefer gpa.free(shape);
    if (dims_len > 0) try check(ort, ort.f62.?(shape_info, shape.ptr, dims_len), failure);

    var data_ptr: ?*anyopaque = null;
    try check(ort, ort.f51.?(value, &data_ptr), failure);
    const raw = data_ptr orelse {
        failure.set(0, "GetTensorMutableData lieferte keinen Zeiger");
        return error.MissingHandle;
    };

    const width = @intFromEnum(@as(ElementType, @enumFromInt(element_type))).byteSize();
    if (width == 0) {
        failure.set(0, "Der Ausgabetyp hat keine feste Bytebreite");
        return error.UnsupportedType;
    }
    const byte_len = std.math.mul(usize, element_count, width) catch {
        failure.set(0, "Der Ausgabetensor ist zu gross");
        return error.AudioTooLarge;
    };

    const bytes = try gpa.alloc(u8, byte_len);
    errdefer gpa.free(bytes);
    const source: [*]const u8 = @ptrCast(@alignCast(raw));
    @memcpy(bytes, source[0..byte_len]);

    return .{
        .bytes = bytes,
        .shape = shape,
        .element_type = @enumFromInt(element_type),
        .gpa = gpa,
    };
}

/// Loest die Tensorwerte einer Session auf.
pub fn releaseValue(session: *const Session, value: *api.OrtValue) void {
    session.ort.f96.?(value);
}

/// Liest die Namen der Ein- und Ausgaenge einer Session.
fn readNames(
    ort: *const api.OrtApi,
    handle: *api.OrtSession,
    allocator: *api.OrtAllocator,
    inputs: bool,
    gpa: std.mem.Allocator,
    failure: *Failure,
) ![][:0]u8 {
    var count: usize = 0;
    if (inputs) {
        try check(ort, ort.f30.?(handle, &count), failure);
    } else {
        try check(ort, ort.f31.?(handle, &count), failure);
    }

    const names = try gpa.alloc([:0]u8, count);
    errdefer gpa.free(names);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |name| gpa.free(name);
    }

    for (0..count) |index| {
        var raw: ?[*:0]u8 = null;
        if (inputs) {
            try check(ort, ort.f36.?(handle, index, allocator, &raw), failure);
        } else {
            try check(ort, ort.f37.?(handle, index, allocator, &raw), failure);
        }
        const text = raw orelse {
            failure.set(0, "Session lieferte keinen Namen");
            return error.MissingHandle;
        };
        defer _ = ort.f76.?(allocator, @ptrCast(text));

        const source = std.mem.span(text);
        const name = try gpa.allocSentinel(u8, source.len, 0);
        @memcpy(name[0..source.len], source);
        names[filled] = name;
        filled += 1;
    }
    return names;
}

fn freeNames(gpa: std.mem.Allocator, names: [][:0]u8) void {
    for (names) |name| gpa.free(name);
    gpa.free(names);
}

/// Liest die Schluessel der benutzerdefinierten Modellmetadaten.
fn readMetadataKeys(
    ort: *const api.OrtApi,
    handle: *api.OrtSession,
    allocator: *api.OrtAllocator,
    gpa: std.mem.Allocator,
    failure: *Failure,
) ![][]u8 {
    var metadata: ?*api.OrtModelMetadata = null;
    try check(ort, ort.f111.?(handle, &metadata), failure);
    const metadata_handle = metadata orelse {
        failure.set(0, "SessionGetModelMetadata lieferte keine Metadaten");
        return error.MissingHandle;
    };
    defer ort.f118.?(metadata_handle);

    // `char***` ist ein Zeiger auf ein Array. Ein optionales Many-Pointer
    // waere 16 Byte breit, deshalb nimmt die API hier einen nackten Zeiger.
    var raw_keys: [*c][*:0]u8 = undefined;
    var count: i64 = 0;
    try check(ort, ort.f123.?(metadata_handle, allocator, &raw_keys, &count), failure);
    if (count <= 0) return gpa.alloc([]u8, 0);

    const keys = try gpa.alloc([]u8, @intCast(count));
    errdefer gpa.free(keys);
    var filled: usize = 0;
    errdefer {
        for (keys[0..filled]) |key| gpa.free(key);
    }

    for (raw_keys[0..@intCast(count)]) |key| {
        defer _ = ort.f76.?(allocator, @ptrCast(key));
        const source = std.mem.span(key);
        const copy = try gpa.alloc(u8, source.len);
        @memcpy(copy, source);
        keys[filled] = copy;
        filled += 1;
    }
    return keys;
}

fn freeMetadataKeys(gpa: std.mem.Allocator, keys: [][]u8) void {
    for (keys) |key| gpa.free(key);
    gpa.free(keys);
}

test "Failure speichert Meldung und Code" {
    var failure = Failure{};
    failure.set(7, "Beispiel");
    try std.testing.expectEqual(@as(c_int, 7), failure.code);
    try std.testing.expectEqualStrings("Beispiel", failure.message());
}

test "Failure kuerzt lange Meldungen" {
    var failure = Failure{};
    const long = "x" ** 2048;
    failure.set(1, long);
    try std.testing.expectEqual(failure.buffer.len, failure.len);
}

test "Elementtypen tragen feste Bytebreiten" {
    try std.testing.expectEqual(@as(usize, 4), ElementType.float.byteSize());
    try std.testing.expectEqual(@as(usize, 2), ElementType.float16.byteSize());
    try std.testing.expectEqual(@as(usize, 8), ElementType.int64.byteSize());
    try std.testing.expectEqual(@as(usize, 0), ElementType.string.byteSize());
}
