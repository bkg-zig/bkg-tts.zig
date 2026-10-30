#!/usr/bin/env python3
"""Prueft die generierte ORT-Bindung gegen den echten C-Header.

`struct OrtApi` ist eine flache Folge von Funktionspointern. Jede Abweichung
in der Reihenfolge verschiebt alle folgenden Zeiger. Dieser Check vergleicht
den Byte-Offset jedes im Generator typisierten Members aus dem C-Header mit
dem Index, den die generierte Zig-Datei an der gleichen Stelle benutzt.

    python3 scripts/verify_ort_abi.py \
        --header ~/.local/share/onnxruntime/include/onnxruntime_c_api.h \
        --zig src/tts/ort_api.zig
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_ort_api import MEMBER_NAMES, TYPED_MEMBERS  # noqa: E402


def zig_members(path: Path) -> tuple[dict[int, str], int]:
    """Liest aus der generierten Zig-Datei Index -> Membername und Memberzahl."""
    text = path.read_text(encoding="utf-8")
    found: dict[int, str] = {}
    for match in re.finditer(r"/// (\w+)\n\s*f(\d+):", text):
        found[int(match.group(2))] = match.group(1)
    total = len(re.findall(r"^\s*f\d+:", text, re.MULTILINE))
    return found, total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--header", required=True, type=Path)
    parser.add_argument("--zig", required=True, type=Path)
    parser.add_argument(
        "--workdir",
        type=Path,
        default=Path(".zig-cache/verify"),
        help="Verzeichnis fuer das gepruefte Binary. /tmp ist auf diesem Host noexec.",
    )
    args = parser.parse_args()

    source_dir = Path(__file__).resolve().parent
    args.workdir.mkdir(parents=True, exist_ok=True)
    binary = args.workdir / "verify_ort_abi"
    subprocess.run(
        ["cc", "-I", str(args.header.parent), str(source_dir / "verify_ort_abi.c"), "-o", str(binary)],
        check=True,
    )
    output = subprocess.run([str(binary)], check=True, capture_output=True, text=True).stdout

    offsets: dict[str, int] = {}
    for line in output.splitlines():
        if line.startswith("sizeof "):
            offsets["sizeof"] = int(line.split()[1])
            continue
        name, value = line.split()
        offsets[name] = int(value)

    generated, member_count = zig_members(args.zig)
    errors: list[str] = []

    expected_size = member_count * 8
    if offsets.get("sizeof") != expected_size:
        errors.append(f"sizeof(OrtApi) ist {offsets.get('sizeof')}, erwartet {expected_size}")

    for index, name in sorted(MEMBER_NAMES.items()):
        if index not in TYPED_MEMBERS:
            continue
        if index not in generated:
            errors.append(f"Index {index} ({name}) fehlt in der generierten Datei")
            continue
        if generated[index] != name:
            errors.append(f"Index {index} traegt {generated[index]}, erwartet {name}")
        if name not in offsets:
            errors.append(f"{name} steht nicht im ABI-Programm")
            continue
        if offsets[name] != index * 8:
            errors.append(f"{name} liegt bei Offset {offsets[name]}, erwartet {index * 8}")

    if errors:
        for error in errors:
            print(f"FEHLER: {error}", file=sys.stderr)
        return 1

    checked = len([index for index in MEMBER_NAMES if index in TYPED_MEMBERS])
    print(
        f"ABI geprueft: sizeof(OrtApi)={offsets['sizeof']}, {member_count} Member, "
        f"{checked} typisierte Member passen"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
