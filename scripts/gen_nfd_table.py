#!/usr/bin/env python3
"""Erzeugt src/tts/nfd_table.zig aus den kanonischen Unicode-Daten.

Die TTS-Textpfade von Piper und Kokoro zerlegen ihre Phoneme in NFD, bevor
sie einzelne Codepoints gegen das jeweilige Vokabular prüfen. Python holt
die Zerlegungsregeln aus unicodedata, damit die Tabelle dem Unicode-Stand
des Systems entspricht.

Aufruf:
    python3 scripts/gen_nfd_table.py > src/tts/nfd_table.zig
"""

import sys
import unicodedata

MAX_CODEPOINT = 0x110000


def main() -> int:
    decompositions = []
    combining_classes = []

    for codepoint in range(MAX_CODEPOINT):
        char = chr(codepoint)
        combining_class = unicodedata.combining(char)
        if combining_class:
            combining_classes.append((codepoint, combining_class))
        # Nur kanonische Zerlegungen, keine Kompatibilitaetsformen.
        decomposition = unicodedata.decomposition(char)
        if decomposition and not decomposition.startswith("<"):
            parts = [int(part, 16) for part in decomposition.split()]
            if parts != [codepoint]:
                decompositions.append((codepoint, parts))

    out = sys.stdout
    out.write("//! Kanonische Unicode-Zerlegung. Erzeugt von scripts/gen_nfd_table.py.\n")
    out.write("//!\n")
    out.write(f"//! Unicode-Stand: {unicodedata.unidata_version}\n")
    out.write("//!\n")
    out.write("//! Die Datei nicht von Hand aendern. Nach Unicode-Aktualisierung neu erzeugen.\n")
    out.write("\n")
    out.write("/// Ein Codepoint mit seiner kanonischen Zerlegung.\n")
    out.write("pub const Decomposition = struct {\n")
    out.write("    codepoint: u21,\n")
    out.write("    parts: []const u21,\n")
    out.write("};\n")
    out.write("\n")
    out.write("/// Kanonische Zerlegungen, aufsteigend nach Codepoint sortiert.\n")
    out.write("pub const decompositions = [_]Decomposition{\n")
    for codepoint, parts in decompositions:
        joined = ", ".join(f"0x{part:X}" for part in parts)
        out.write(f"    .{{ .codepoint = 0x{codepoint:X}, .parts = &[_]u21{{ {joined} }} }},\n")
    out.write("};\n")
    out.write("\n")
    out.write("/// Combining Class eines Codepoints, aufsteigend nach Codepoint sortiert.\n")
    out.write("pub const CombiningClass = struct {\n")
    out.write("    codepoint: u21,\n")
    out.write("    class: u8,\n")
    out.write("};\n")
    out.write("\n")
    out.write("pub const combining_classes = [_]CombiningClass{\n")
    for codepoint, combining_class in combining_classes:
        out.write(f"    .{{ .codepoint = 0x{codepoint:X}, .class = {combining_class} }},\n")
    out.write("};\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
