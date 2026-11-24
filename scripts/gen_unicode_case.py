#!/usr/bin/env python3
"""Erzeugt src/tts/unicode_case.zig aus der Unicode-Datenbank.

Die Textaufbereitung des PocketTTS-Laufs folgt Python. Python beantwortet
`str.isalnum()`, `str.isupper()` und `str.upper()` nach den Regeln der
Unicode-Datenbank:

* `isalnum()` ist wahr fuer die Kategorien L* und N*.
* `isupper()` ist wahr fuer die Kategorie Lu und die Eigenschaft
  Other_Uppercase.
* `upper()` nutzt die einfache Zuordnung aus Feld 12 von UnicodeData.txt und
  die unbedingten Eintraege aus SpecialCasing.txt. Unbedingte Eintraege
  ersetzen die einfache Zuordnung, wenn beide vorhanden sind.
* `str.isdigit()` ist wahr fuer Nd und fuer die Numeric_Type-Eigenschaft
  Digit.

Aufruf:
    python3 scripts/gen_unicode_case.py [cache-verzeichnis] > src/tts/unicode_case.zig

Fehlt eine Datei im Cache, wird sie von der gepinnten Unicode-18.0.0-URL
geladen.
"""

import os
import re
import sys
import urllib.request

UNICODE_VERSION = "18.0.0"
BASE_URL = f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd"

FILES = {
    "general_category": f"{BASE_URL}/extracted/DerivedGeneralCategory.txt",
    "numeric_type": f"{BASE_URL}/extracted/DerivedNumericType.txt",
    "prop_list": f"{BASE_URL}/PropList.txt",
    "unicode_data": f"{BASE_URL}/UnicodeData.txt",
    "special_casing": f"{BASE_URL}/SpecialCasing.txt",
}

LOCAL_NAMES = {
    "general_category": "extracted-DerivedGeneralCategory.txt",
    "numeric_type": "extracted-DerivedNumericType.txt",
    "prop_list": "PropList.txt",
    "unicode_data": "UnicodeData.txt",
    "special_casing": "SpecialCasing.txt",
}

RANGE_PATTERN = re.compile(r"^([0-9A-Fa-f]{4,6})(?:\.\.([0-9A-Fa-f]{4,6}))?\s*;\s*(\S+)")


def parse_ranges(path, wanted_property=None, wanted_categories=None, wanted_values=None):
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
            if wanted_values is not None and value not in wanted_values:
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


def ensure_file(cache, key):
    """Liefert den Pfad einer UCD-Datei und laedt sie bei Bedarf."""
    path = os.path.join(cache, LOCAL_NAMES[key])
    if not os.path.exists(path):
        os.makedirs(cache, exist_ok=True)
        print(f"lade {FILES[key]}", file=sys.stderr)
        with urllib.request.urlopen(FILES[key], timeout=120) as response:
            payload = response.read()
        with open(path, "wb") as handle:
            handle.write(payload)
    return path


def read_uppercase_mapping(unicode_data, special_casing):
    """Liest die Grossschreibung aus UnicodeData und SpecialCasing."""
    mapping = {}
    with open(unicode_data, "r", encoding="utf-8") as handle:
        for line in handle:
            fields = line.rstrip("\n").split(";")
            if len(fields) < 15:
                continue
            codepoint = int(fields[0], 16)
            upper = fields[12].strip()
            if upper:
                mapping[codepoint] = [int(part, 16) for part in upper.split()]

    with open(special_casing, "r", encoding="utf-8") as handle:
        for line in handle:
            raw = line.split("#", 1)[0].strip()
            if not raw:
                continue
            fields = [field.strip() for field in raw.split(";")]
            if len(fields) < 5:
                continue
            # Bedingte Eintraege gelten nur im jeweiligen Kontext.
            if fields[4]:
                continue
            codepoint = int(fields[0], 16)
            mapping[codepoint] = [int(part, 16) for part in fields[3].split()]
    return mapping


def zig_string(codepoints):
    """Baut eine Zig-Zeichenkette aus Codepoints."""
    return '"' + "".join(f"\\u{{{codepoint:X}}}" for codepoint in codepoints) + '"'


def main(argv):
    cache = argv[1] if len(argv) > 1 else os.path.expanduser("~/.cache/unicode")
    paths = {key: ensure_file(cache, key) for key in FILES}

    letters = {"Lu", "Ll", "Lt", "Lm", "Lo"}
    numbers = {"Nd", "Nl", "No"}
    alnum = merge(
        parse_ranges(paths["general_category"], wanted_categories=letters | numbers)
    )
    upper = merge(
        parse_ranges(paths["general_category"], wanted_categories={"Lu"})
        + parse_ranges(paths["prop_list"], wanted_property="Other_Uppercase")
    )
    digits = merge(
        parse_ranges(paths["general_category"], wanted_categories={"Nd"})
        + parse_ranges(paths["numeric_type"], wanted_values={"Digit"})
    )
    mapping = read_uppercase_mapping(paths["unicode_data"], paths["special_casing"])
    entries = [
        (codepoint, upper)
        for codepoint, upper in sorted(mapping.items())
        if upper != [codepoint]
    ]

    def count(ranges):
        return sum(end - start + 1 for start, end in ranges)

    print(f"// Erzeugt von scripts/gen_unicode_case.py aus Unicode {UNICODE_VERSION}.")
    print(
        f"// Alphanumerisch: L* + N*, {len(alnum)} Bereiche, {count(alnum)} Codepoints."
    )
    print(
        f"// Grossbuchstaben: Lu + Other_Uppercase, {len(upper)} Bereiche, "
        f"{count(upper)} Codepoints."
    )
    print(f"// Ziffern: Nd + Numeric_Type=Digit, {len(digits)} Bereiche, {count(digits)} Codepoints.")
    print(f"// Grossschreibung: {len(entries)} Zuordnungen.")
    print('const std = @import("std");')
    print()
    print("/// Halb offener Bereich [start, end] eines Zeichens.")
    print("pub const Range = struct {")
    print("    start: u21,")
    print("    end: u21,")
    print("};")
    print()
    print("/// Ein Codepoint mit seiner Grossschreibung.")
    print("pub const UpperMapping = struct {")
    print("    codepoint: u21,")
    print("    mapped: []const u8,")
    print("};")
    print()
    print("/// Bereiche der alphanumerischen Zeichen, aufsteigend sortiert.")
    print("pub const alnum_ranges = [_]Range{")
    for start, end in alnum:
        print(f"    .{{ .start = 0x{start:04X}, .end = 0x{end:04X} }},")
    print("};")
    print()
    print("/// Bereiche der Grossbuchstaben, aufsteigend sortiert.")
    print("pub const upper_ranges = [_]Range{")
    for start, end in upper:
        print(f"    .{{ .start = 0x{start:04X}, .end = 0x{end:04X} }},")
    print("};")
    print()
    print("/// Bereiche der Ziffern, aufsteigend sortiert.")
    print("pub const digit_ranges = [_]Range{")
    for start, end in digits:
        print(f"    .{{ .start = 0x{start:04X}, .end = 0x{end:04X} }},")
    print("};")
    print()
    print("/// Grossschreibung der Zeichen, aufsteigend nach Codepoint sortiert.")
    print("pub const upper_mappings = [_]UpperMapping{")
    for codepoint, upper in entries:
        print(
            f"    .{{ .codepoint = 0x{codepoint:04X}, .mapped = {zig_string(upper)} }},"
        )
    print("};")
    print()
    print("/// Prueft, ob ein Codepoint Buchstabe oder Ziffer ist.")
    print("pub fn isAlphanumeric(codepoint: u21) bool {")
    print("    if (codepoint < 0x80) {")
    print("        return std.ascii.isAlphanumeric(@intCast(codepoint));")
    print("    }")
    print("    return inRanges(&alnum_ranges, codepoint);")
    print("}")
    print()
    print("/// Prueft, ob ein Codepoint ein Grossbuchstabe ist.")
    print("pub fn isUpperCase(codepoint: u21) bool {")
    print("    if (codepoint < 0x80) {")
    print("        return std.ascii.isUpper(@intCast(codepoint));")
    print("    }")
    print("    return inRanges(&upper_ranges, codepoint);")
    print("}")
    print()
    print("/// Prueft, ob ein Codepoint eine Ziffer ist.")
    print("pub fn isDigit(codepoint: u21) bool {")
    print("    if (codepoint < 0x80) {")
    print("        return codepoint >= '0' and codepoint <= '9';")
    print("    }")
    print("    return inRanges(&digit_ranges, codepoint);")
    print("}")
    print()
    print("/// Liefert die Grossschreibung eines Codepoints.")
    print("///")
    print("/// Null bedeutet: der Codepoint bleibt unveraendert.")
    print("pub fn upperMapping(codepoint: u21) ?[]const u8 {")
    print("    var low: usize = 0;")
    print("    var high: usize = upper_mappings.len;")
    print("    while (low < high) {")
    print("        const middle = low + (high - low) / 2;")
    print("        const entry = upper_mappings[middle];")
    print("        if (codepoint < entry.codepoint) {")
    print("            high = middle;")
    print("        } else if (codepoint > entry.codepoint) {")
    print("            low = middle + 1;")
    print("        } else {")
    print("            return entry.mapped;")
    print("        }")
    print("    }")
    print("    return null;")
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
    print('test "Alphanumerisch folgt den Kategorien L und N" {')
    print("    try std.testing.expect(isAlphanumeric('a'));")
    print("    try std.testing.expect(isAlphanumeric('7'));")
    print("    try std.testing.expect(isAlphanumeric(0x00E9)); // e mit Akzent, Ll")
    print("    try std.testing.expect(isAlphanumeric(0x4E00)); // CJK, Lo")
    print("    try std.testing.expect(isAlphanumeric(0x2160)); // Römische Ziffer, Nl")
    print("    try std.testing.expect(!isAlphanumeric(' '));")
    print("    try std.testing.expect(!isAlphanumeric(0x2019)); // typografisches Apostroph, Pf")
    print("}")
    print()
    print('test "Grossbuchstaben folgen Lu und Other_Uppercase" {')
    print("    try std.testing.expect(isUpperCase('A'));")
    print("    try std.testing.expect(isUpperCase(0x00C4)); // Ä, Lu")
    print("    try std.testing.expect(isUpperCase(0x2160)); // Römische Ziffer, Other_Uppercase")
    print("    try std.testing.expect(isUpperCase(0x24B6)); // eingekreister Buchstabe, Other_Uppercase")
    print("    try std.testing.expect(!isUpperCase('a'));")
    print("    try std.testing.expect(!isUpperCase(0x01C5)); // Dž, Lt")
    print("}")
    print()
    print('test "Ziffern folgen Nd und Numeric_Type Digit" {')
    print("    try std.testing.expect(isDigit('0'));")
    print("    try std.testing.expect(isDigit(0x0660)); // Arabic-Indic Digit Zero, Nd")
    print("    try std.testing.expect(isDigit(0x00B2)); // Quadrat zwei, Numeric_Type Digit")
    print("    try std.testing.expect(isDigit(0x2460)); // eingekreiste Eins, Numeric_Type Digit")
    print("    try std.testing.expect(!isDigit(0x2167)); // Römische Ziffer, Nl")
    print("    try std.testing.expect(!isDigit('a'));")
    print("}")
    print()
    print('test "Grossschreibung nutzt einfache und unbedingte Zuordnung" {')
    print('    try std.testing.expectEqualStrings("\\u{00C4}", upperMapping(0x00E4).?);')
    print('    try std.testing.expectEqualStrings("SS", upperMapping(0x00DF).?);')
    print('    try std.testing.expectEqualStrings("\\u{01C4}", upperMapping(0x01C5).?);')
    print('    try std.testing.expectEqualStrings("FFI", upperMapping(0xFB03).?);')
    print("    try std.testing.expectEqualStrings(\"A\", upperMapping('a').?);")
    print("    try std.testing.expect(upperMapping('A') == null);")
    print("}")


if __name__ == "__main__":
    main(sys.argv)
