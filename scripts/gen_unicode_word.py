#!/usr/bin/env python3
"""Erzeugt src/tts/unicode_word.zig aus der Unicode-Datenbank.

Die Rust-Regex-Vorlage `\\w` ist `[\\p{Alphabetic}\\p{M}\\p{Nd}\\p{Pc}]`.
Diese Menge wird aus zwei UCD-Dateien gebildet:

* DerivedCoreProperties.txt liefert die Eigenschaft `Alphabetic`.
* DerivedGeneralCategory.txt liefert die Kategorien M (Mn, Mc, Me), Nd und Pc.

Zusaetzlich wird die Kategorie Nd allein als Tabelle ausgegeben. Sie liefert
die Ziffern der Vorlage `\\d`, die von der Zahlenerkennung gebraucht wird.

Python-`unicodedata` reicht nicht aus, weil es weder die Eigenschaft
`Alphabetic` noch die Unicode-Version 18.0.0 kennt.

Aufruf:
    python3 scripts/gen_unicode_word.py [DerivedCoreProperties.txt] \\
        [DerivedGeneralCategory.txt] > src/tts/unicode_word.zig

Fehlen die Dateien, werden sie von der gepinnten Unicode-18.0.0-URL geladen.
"""

import os
import re
import sys
import urllib.request

UNICODE_VERSION = "18.0.0"
CORE_PROPERTIES_URL = (
    f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/DerivedCoreProperties.txt"
)
GENERAL_CATEGORY_URL = (
    f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/extracted/DerivedGeneralCategory.txt"
)

CATEGORIES = {"Mn", "Mc", "Me", "Nd", "Pc"}

RANGE_PATTERN = re.compile(r"^([0-9A-Fa-f]{4,6})(?:\.\.([0-9A-Fa-f]{4,6}))?\s*;\s*(\S+)")


def parse_ranges(path, wanted_property=None, wanted_categories=None):
    """Liest alle Bereiche einer UCD-Datei."""
    ranges = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            match = RANGE_PATTERN.match(line)
            if not match:
                continue
            first = int(match.group(1), 16)
            last = int(match.group(2), 16) if match.group(2) else first
            value = match.group(3)
            if wanted_property is not None and value != wanted_property:
                continue
            if wanted_categories is not None and value not in wanted_categories:
                continue
            ranges.append((first, last))
    return ranges


def merge(ranges):
    """Vereinigt Bereiche und entfernt Ueberlappungen."""
    merged = []
    for start, end in sorted(ranges):
        if merged and start <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def download(url, target):
    """Laedt eine UCD-Datei in den lokalen Cache."""
    directory = os.path.dirname(target)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        payload = response.read()
    with open(target, "wb") as handle:
        handle.write(payload)
    return target


def main(argv):
    core_path = argv[1] if len(argv) > 1 else f"DerivedCoreProperties-{UNICODE_VERSION}.txt"
    category_path = argv[2] if len(argv) > 2 else f"DerivedGeneralCategory-{UNICODE_VERSION}.txt"

    if not os.path.exists(core_path):
        download(CORE_PROPERTIES_URL, core_path)
    if not os.path.exists(category_path):
        download(GENERAL_CATEGORY_URL, category_path)

    alphabetic = parse_ranges(core_path, wanted_property="Alphabetic")
    by_category = parse_ranges(category_path, wanted_categories=CATEGORIES)
    decimal_digits = parse_ranges(category_path, wanted_categories={"Nd"})

    ranges = merge(alphabetic + by_category)
    total = sum(end - start + 1 for start, end in ranges)
    nd_ranges = merge(decimal_digits)
    nd_total = sum(end - start + 1 for start, end in nd_ranges)

    print(f"// Erzeugt von scripts/gen_unicode_word.py aus Unicode {UNICODE_VERSION}.")
    print(
        f"// Wortzeichen: Alphabetic + M + Nd + Pc, {len(ranges)} Bereiche, "
        f"{total} Codepoints."
    )
    print(
        f"// Dezimalziffern: Nd, {len(nd_ranges)} Bereiche, {nd_total} Codepoints."
    )
    print("const std = @import(\"std\");")
    print()
    print("/// Halb offener Bereich [start, end] eines Wortzeichens.")
    print("pub const Range = struct {")
    print("    start: u21,")
    print("    end: u21,")
    print("};")
    print()
    print("/// Sortierte Bereiche ohne Luecken zwischen benachbarten Werten.")
    print("pub const ranges = [_]Range{")
    for start, end in ranges:
        print(f"    .{{ .start = 0x{start:04X}, .end = 0x{end:04X} }},")
    print("};")
    print()
    print("/// Sortierte Bereiche der Dezimalziffern.")
    print("pub const nd_ranges = [_]Range{")
    for start, end in nd_ranges:
        print(f"    .{{ .start = 0x{start:04X}, .end = 0x{end:04X} }},")
    print("};")
    print()
    print("/// Prueft, ob ein Codepoint zu einem Wortzeichen gehoert.")
    print("pub fn isWordChar(codepoint: u21) bool {")
    print("    if (codepoint < 0x80) {")
    print("        return std.ascii.isAlphanumeric(@intCast(codepoint)) or codepoint == '_';")
    print("    }")
    print("    return inRanges(ranges, codepoint);")
    print("}")
    print()
    print("/// Prueft, ob ein Codepoint eine Dezimalziffer ist.")
    print("pub fn isDecimalDigit(codepoint: u21) bool {")
    print("    if (codepoint < 0x80) {")
    print("        return codepoint >= '0' and codepoint <= '9';")
    print("    }")
    print("    return inRanges(nd_ranges, codepoint);")
    print("}")
    print()
    print("fn inRanges(table: []const Range, codepoint: u21) bool {")
    print("    var low: usize = 0;")
    print("    var high: usize = table.len;")
    print("    while (low < high) {")
    print("        const middle = low + (high - low) / 2;")
    print("        const entry = table[middle];")
    print("        if (codepoint < entry.start) {")
    print("            high = middle;")
    print("        } else if (codepoint > entry.end) {")
    print("            low = middle + 1;")
    print("        } else {")
    print("            return true;")
    print("        }")
    print("    }")
    print("    return false;")
    print("}")
    print()
    print("test \"Wortzeichen umfassen Buchstaben, Marken und Ziffern\" {")
    print("    try std.testing.expect(isWordChar('a'));")
    print("    try std.testing.expect(isWordChar('7'));")
    print("    try std.testing.expect(isWordChar('_'));")
    print("    try std.testing.expect(isWordChar(0x00E9)); // e mit Akzent, Ll")
    print("    try std.testing.expect(isWordChar(0x0329)); // Mn, Combining Vertical Line Below")
    print("    try std.testing.expect(isWordChar(0x2160)); // Nl, Roman Numeral One")
    print("    try std.testing.expect(isWordChar(0x0660)); // Nd, Arabic-Indic Digit Zero")
    print("    try std.testing.expect(isWordChar(0x24B6)); // So, Circled Latin Capital Letter A")
    print("}")
    print()
    print("test \"Nicht-Wortzeichen bleiben ausserhalb\" {")
    print("    try std.testing.expect(!isWordChar(' '));")
    print("    try std.testing.expect(!isWordChar(0x02DE)); // Sk, Modifier Letter Small C")
    print("    try std.testing.expect(!isWordChar(0x2192)); // Sm, Rightwards Arrow")
    print("    try std.testing.expect(!isWordChar(0x0027)); // Po, Apostrophe")
    print("}")
    print()
    print("test \"Dezimalziffern folgen der Kategorie Nd\" {")
    print("    try std.testing.expect(isDecimalDigit('0'));")
    print("    try std.testing.expect(isDecimalDigit('9'));")
    print("    try std.testing.expect(isDecimalDigit(0x0660)); // Nd, Arabic-Indic Digit Zero")
    print("    try std.testing.expect(!isDecimalDigit(0x2160)); // Nl, Roman Numeral One")
    print("    try std.testing.expect(!isDecimalDigit('a'));")
    print("}")


if __name__ == "__main__":
    main(sys.argv)
