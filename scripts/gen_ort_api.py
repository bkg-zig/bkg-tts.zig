#!/usr/bin/env python3
"""Erzeugt src/tts/ort_api.zig aus dem ONNX-Runtime-C-Header.

Die Datei src/tts/ort_api.zig ist generiert. Sie nicht von Hand aendern,
sondern dieses Skript erneut ausfuehren:

    python3 scripts/gen_ort_api.py \
        --header ~/.local/share/onnxruntime/include/onnxruntime_c_api.h \
        --output src/tts/ort_api.zig

Grund: `struct OrtApi` ist eine flache Folge von 318 Funktionspointern. Die
Reihenfolge ist ABI-relevant, ein Handpflegeversuch waere fehleranfaellig.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Member, die der Server direkt aufruft. Der Index ist die Position in der
# C-Struktur und damit Teil des ABI.
TYPED_MEMBERS: dict[int, str] = {
    0: "?*const fn (code: c_int, msg: ?[*:0]const u8) callconv(.c) ?*OrtStatus",
    1: "?*const fn (status: *const OrtStatus) callconv(.c) c_int",
    2: "?*const fn (status: *const OrtStatus) callconv(.c) ?[*:0]const u8",
    3: "?*const fn (level: c_int, logid: ?[*:0]const u8, out: *?*OrtEnv) callconv(.c) ?*OrtStatus",
    7: (
        "?*const fn (env: *const OrtEnv, model_path: ?[*:0]const u8, "
        "options: *const OrtSessionOptions, out: *?*OrtSession) callconv(.c) ?*OrtStatus"
    ),
    9: (
        "?*const fn (session: *OrtSession, run_options: ?*const OrtRunOptions, "
        "input_names: [*c]const ?[*:0]const u8, inputs: [*c]const *const OrtValue, "
        "input_len: usize, output_names: [*c]const ?[*:0]const u8, "
        "output_names_len: usize, outputs: [*c]?*OrtValue) callconv(.c) ?*OrtStatus"
    ),
    10: "?*const fn (out: *?*OrtSessionOptions) callconv(.c) ?*OrtStatus",
    13: "?*const fn (options: *OrtSessionOptions, mode: c_int) callconv(.c) ?*OrtStatus",
    15: "?*const fn (options: *OrtSessionOptions) callconv(.c) ?*OrtStatus",
    22: "?*const fn (options: *OrtSessionOptions, level: c_int) callconv(.c) ?*OrtStatus",
    23: "?*const fn (options: *OrtSessionOptions, level: c_int) callconv(.c) ?*OrtStatus",
    24: "?*const fn (options: *OrtSessionOptions, threads: c_int) callconv(.c) ?*OrtStatus",
    25: "?*const fn (options: *OrtSessionOptions, threads: c_int) callconv(.c) ?*OrtStatus",
    30: "?*const fn (session: *const OrtSession, out: *usize) callconv(.c) ?*OrtStatus",
    31: "?*const fn (session: *const OrtSession, out: *usize) callconv(.c) ?*OrtStatus",
    33: (
        "?*const fn (session: *const OrtSession, index: usize, "
        "out: *?*OrtTypeInfo) callconv(.c) ?*OrtStatus"
    ),
    34: (
        "?*const fn (session: *const OrtSession, index: usize, "
        "out: *?*OrtTypeInfo) callconv(.c) ?*OrtStatus"
    ),
    36: (
        "?*const fn (session: *const OrtSession, index: usize, allocator: *OrtAllocator, "
        "value: *?[*:0]u8) callconv(.c) ?*OrtStatus"
    ),
    37: (
        "?*const fn (session: *const OrtSession, index: usize, allocator: *OrtAllocator, "
        "value: *?[*:0]u8) callconv(.c) ?*OrtStatus"
    ),
    49: (
        "?*const fn (info: *const OrtMemoryInfo, data: ?*anyopaque, data_len: usize, "
        "shape: [*c]const i64, shape_len: usize, elem_type: c_int, "
        "out: *?*OrtValue) callconv(.c) ?*OrtStatus"
    ),
    55: (
        "?*const fn (type_info: *const OrtTypeInfo, "
        "out: *?*OrtTensorTypeAndShapeInfo) callconv(.c) ?*OrtStatus"
    ),
    56: "?*const fn (type_info: *const OrtTypeInfo, out: *c_int) callconv(.c) ?*OrtStatus",
    51: "?*const fn (value: *OrtValue, out: *?*anyopaque) callconv(.c) ?*OrtStatus",
    60: "?*const fn (info: *const OrtTensorTypeAndShapeInfo, out: *c_int) callconv(.c) ?*OrtStatus",
    61: "?*const fn (info: *const OrtTensorTypeAndShapeInfo, out: *usize) callconv(.c) ?*OrtStatus",
    62: (
        "?*const fn (info: *const OrtTensorTypeAndShapeInfo, dims: [*c]i64, "
        "dims_len: usize) callconv(.c) ?*OrtStatus"
    ),
    64: "?*const fn (info: *const OrtTensorTypeAndShapeInfo, out: *usize) callconv(.c) ?*OrtStatus",
    65: (
        "?*const fn (value: *const OrtValue, out: *?*OrtTensorTypeAndShapeInfo) "
        "callconv(.c) ?*OrtStatus"
    ),
    69: "?*const fn (kind: c_int, mem_type: c_int, out: *?*OrtMemoryInfo) callconv(.c) ?*OrtStatus",
    76: "?*const fn (allocator: *OrtAllocator, ptr: ?*anyopaque) callconv(.c) ?*OrtStatus",
    78: "?*const fn (out: *?*OrtAllocator) callconv(.c) ?*OrtStatus",
    92: "?*const fn (input: ?*OrtEnv) callconv(.c) void",
    93: "?*const fn (input: ?*OrtStatus) callconv(.c) void",
    94: "?*const fn (input: ?*OrtMemoryInfo) callconv(.c) void",
    95: "?*const fn (input: ?*OrtSession) callconv(.c) void",
    96: "?*const fn (input: ?*OrtValue) callconv(.c) void",
    98: "?*const fn (input: ?*OrtTypeInfo) callconv(.c) void",
    99: "?*const fn (input: ?*OrtTensorTypeAndShapeInfo) callconv(.c) void",
    100: "?*const fn (input: ?*OrtSessionOptions) callconv(.c) void",
    111: (
        "?*const fn (session: *const OrtSession, out: *?*OrtModelMetadata) "
        "callconv(.c) ?*OrtStatus"
    ),
    112: (
        "?*const fn (metadata: *const OrtModelMetadata, allocator: *OrtAllocator, "
        "out: *?[*:0]u8) callconv(.c) ?*OrtStatus"
    ),
    113: (
        "?*const fn (metadata: *const OrtModelMetadata, allocator: *OrtAllocator, "
        "out: *?[*:0]u8) callconv(.c) ?*OrtStatus"
    ),
    116: (
        "?*const fn (metadata: *const OrtModelMetadata, allocator: *OrtAllocator, "
        "key: [*:0]const u8, out: *?[*:0]u8) callconv(.c) ?*OrtStatus"
    ),
    118: "?*const fn (input: ?*OrtModelMetadata) callconv(.c) void",
    123: (
        "?*const fn (metadata: *const OrtModelMetadata, allocator: *OrtAllocator, "
        "out_keys: *[*c][*:0]u8, out_count: *i64) callconv(.c) ?*OrtStatus"
    ),
}

# Namen der typisierten Member fuer den Kommentar im generierten Code.
MEMBER_NAMES: dict[int, str] = {
    0: "CreateStatus",
    1: "GetErrorCode",
    2: "GetErrorMessage",
    3: "CreateEnv",
    7: "CreateSession",
    9: "Run",
    10: "CreateSessionOptions",
    13: "SetSessionExecutionMode",
    15: "DisableProfiling",
    22: "SetSessionLogSeverityLevel",
    23: "SetSessionGraphOptimizationLevel",
    24: "SetIntraOpNumThreads",
    25: "SetInterOpNumThreads",
    30: "SessionGetInputCount",
    31: "SessionGetOutputCount",
    33: "SessionGetInputTypeInfo",
    34: "SessionGetOutputTypeInfo",
    36: "SessionGetInputName",
    37: "SessionGetOutputName",
    49: "CreateTensorWithDataAsOrtValue",
    51: "GetTensorMutableData",
    55: "CastTypeInfoToTensorInfo",
    56: "GetOnnxTypeFromTypeInfo",
    60: "GetTensorElementType",
    61: "GetDimensionsCount",
    62: "GetDimensions",
    64: "GetTensorShapeElementCount",
    65: "GetTensorTypeAndShape",
    69: "CreateCpuMemoryInfo",
    76: "AllocatorFree",
    78: "GetAllocatorWithDefaultOptions",
    92: "ReleaseEnv",
    93: "ReleaseStatus",
    94: "ReleaseMemoryInfo",
    95: "ReleaseSession",
    96: "ReleaseValue",
    98: "ReleaseTypeInfo",
    99: "ReleaseTensorTypeAndShapeInfo",
    100: "ReleaseSessionOptions",
    111: "SessionGetModelMetadata",
    112: "ModelMetadataGetProducerName",
    113: "ModelMetadataGetGraphName",
    116: "ModelMetadataLookupCustomMetadataMap",
    118: "ReleaseModelMetadata",
    123: "ModelMetadataGetCustomMetadataMapKeys",
}


def strip_comments(source: str) -> str:
    """Entfernt C-Kommentare, ohne String- oder Char-Literale zu zerstoeren.

    Ein regex allein reicht nicht: ein "//" innerhalb eines Blockkommentars
    und ein "/*" innerhalb eines Zeilenkommentars wuerden die Struktur
    zerlegen.
    """
    out: list[str] = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        if char == "/" and index + 1 < length and source[index + 1] == "*":
            index += 2
            while index + 1 < length and not (source[index] == "*" and source[index + 1] == "/"):
                index += 1
            index += 2
            out.append(" ")
            continue
        if char == "/" and index + 1 < length and source[index + 1] == "/":
            while index < length and source[index] != "\n":
                index += 1
            out.append(" ")
            continue
        if char in ('"', "'"):
            quote = char
            out.append(char)
            index += 1
            while index < length:
                out.append(source[index])
                if source[index] == "\\":
                    if index + 1 < length:
                        out.append(source[index + 1])
                        index += 2
                        continue
                elif source[index] == quote:
                    index += 1
                    break
                index += 1
            continue
        out.append(char)
        index += 1
    return "".join(out)


# Anzahl der Member in `struct OrtApi` der ONNX-Runtime-Version 1.22
# (ORT_API_VERSION 22). Geprueft ueber die Indizes der bekannten Member:
# CreateStatus=0, CreateEnv=3, CreateSession=7, Run=9, ReleaseEnv=92,
# ReleaseStatus=93, ReleaseSessionOptions=100.
EXPECTED_MEMBER_COUNT = 318


def extract_members(source: str) -> list[str]:
    # Kommentare zuerst entfernen: die Doku-Gruppenmarker "/// @{" und
    # "/// @}" enthalten Klammern und wuerden die Klammerzaehlung verschieben.
    source = strip_comments(source)

    start = source.index("struct OrtApi {")
    depth = 0
    end = None
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                end = index
                break
    if end is None:
        raise SystemExit("Klammer von struct OrtApi nicht gefunden")

    block = source[start + len("struct OrtApi {") : end]

    members: list[str] = []
    # Jede Deklaration endet mit ';'. Mehrzeilige Makroaufrufe werden dadurch
    # zu einem Block zusammengefasst.
    for chunk in block.split(";"):
        line = " ".join(chunk.split())
        if not line:
            continue
        if re.match(r"ORT_API2_STATUS\(\s*\w+\s*,", line):
            members.append(re.match(r"ORT_API2_STATUS\(\s*(\w+)", line).group(1))
            continue
        if re.match(r"ORT_CLASS_RELEASE\(\s*\w+\s*\)", line):
            members.append("Release" + re.match(r"ORT_CLASS_RELEASE\(\s*(\w+)", line).group(1))
            continue
        if re.search(r"\(\s*ORT_API_CALL\s*\*\s*\w+\s*\)", line):
            members.append(re.search(r"\(\s*ORT_API_CALL\s*\*\s*(\w+)\s*\)", line).group(1))
            continue
        raise SystemExit(f"Unbekanntes Member in struct OrtApi: {line!r}")

    return members


def render(members: list[str]) -> str:
    lines: list[str] = []
    lines.append("//! Generierte ONNX-Runtime-C-API-Bindung. Nicht von Hand aendern.")
    lines.append("//!")
    lines.append("//! Quelle: scripts/gen_ort_api.py gegen onnxruntime_c_api.h (ORT_API_VERSION 22).")
    lines.append("//! `struct OrtApi` ist eine flache Folge von Funktionspointern, die")
    lines.append("//! Reihenfolge ist ABI-relevant. Der Server ruft nur die kommentierten")
    lines.append("//! Member direkt auf, der Rest bleibt als undurchsichtiger Zeiger erhalten.")
    lines.append("")
    lines.append("const std = @import(\"std\");")
    lines.append("")
    lines.append("pub const ort_api_version: u32 = 22;")
    lines.append("")
    for name in (
        "OrtStatus",
        "OrtEnv",
        "OrtSession",
        "OrtSessionOptions",
        "OrtValue",
        "OrtMemoryInfo",
        "OrtTensorTypeAndShapeInfo",
        "OrtTypeInfo",
        "OrtModelMetadata",
        "OrtAllocator",
        "OrtRunOptions",
    ):
        lines.append(f"pub const {name} = opaque {{}};")
    lines.append("")
    lines.append("pub const OrtApiBase = extern struct {")
    lines.append("    GetApi: ?*const fn (version: u32) callconv(.c) ?*const OrtApi,")
    lines.append("    GetVersionString: ?*const fn () callconv(.c) ?[*:0]const u8,")
    lines.append("};")
    lines.append("")
    lines.append("pub const OrtApi = extern struct {")
    for index, name in enumerate(members):
        if index in TYPED_MEMBERS:
            lines.append(f"    /// {name}")
            lines.append(f"    f{index}: {TYPED_MEMBERS[index]},")
        else:
            lines.append(f"    f{index}: *const anyopaque,")
    lines.append("};")
    lines.append("")
    lines.append("comptime {")
    lines.append(f"    std.debug.assert(@sizeOf(OrtApi) == {len(members)} * @sizeOf(usize));")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--header", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    source = args.header.read_text(encoding="utf-8", errors="replace")
    members = extract_members(source)
    if len(members) != EXPECTED_MEMBER_COUNT:
        print(
            f"Unerwartete Memberzahl: {len(members)} (erwartet {EXPECTED_MEMBER_COUNT})",
            file=sys.stderr,
        )
        return 1
    missing = sorted(set(TYPED_MEMBERS) - set(range(len(members))))
    if missing:
        print(f"Typisierte Indizes ausserhalb der Struktur: {missing}", file=sys.stderr)
        return 1

    args.output.write_text(render(members), encoding="utf-8")
    print(f"{args.output}: {len(members)} Member geschrieben")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
