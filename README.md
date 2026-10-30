# BKG MagpieTTS — Zig

Native CPU-only Magpie-TTS-Anwendung mit Zig 0.16, `std.http.Server` und WebSocket. Die Engine läuft ohne Python/NeMo-Fallback über den bestehenden BKG-Zig-Adapter für die C-ABI von `magpie-tts.cpp`. React wird statisch ausgeliefert und lädt ein freestanding WASM-Modul.

## Wichtige Dateien

- `TASKS.md`: Aufgaben mit Status, Abhängigkeiten, Aufwand und Pfaden.
- `docs/SOURCE-INVENTORY.md`: Analyse von Legacy-Quellbaum, REST- und WS-Oberfläche sowie Frontend.
- `docs/API-COMPAT.md`: detaillierter API-Kompatibilitätsvertrag.
- `docs/POCKET-TTS-ONNX.md`: verifizierter Laufzeitvertrag des Pocket-TTS-ONNX-Formats, falls die Engine auf Pocket-TTS umgestellt wird.
- `docs/DEPLOYMENT.md`: Image-, Compose- und Traefik-Hinweise.
- `src/main.zig`: nativer HTTP-Einstieg, WebSocket-Upgrade und statische Dateiauslieferung.
- `src/router.zig`, `src/api.zig`, `src/realtime.zig`: Routing, REST und WS-Protokoll.
- `src/engine.zig`: Modell-Lifecycle und serialisierte C-ABI-Inferenz.
- `src/config.zig`: ENV-Konfiguration.
- `src/wasm.zig`, `web/src/wasm.ts`: WASM-Validierung und React-Anbindung.
- `build.zig`: native App, Tests und separates WASM-Target.

## Entwickeln

- `zig build`: nativen Server bauen.
- `zig build test`: Zig-Unit-Tests.
- `zig build wasm`: freestanding WASM erzeugen.
- `scripts/build-frontend.sh`: WASM und React-UI reproduzierbar bauen (npm-Lockfile).
- `scripts/build-image.sh`: temporären Docker-Kontext aus App und lokalem Framework bauen.

Setze `BKG_MAGPIE_MODEL=/pfad/zum/modell.gguf`; optional `BKG_MAGPIE_LIB_PATH=/pfad/libmagpie-tts.so`. Ohne Modell bleibt Liveness verfügbar, Readiness liefert 503.

## Bisherige Verifikation

Erfolgreich ausgeführt: `zig build`, `zig build test`, `zig build wasm`, TypeScript-`tsc -b` und Vite-Produktionsbuild. Ein echter HTTP-Synthesetest über den Zig-Server lieferte 22,05-kHz-Mono-WAV, 16-Bit-PCM, 6,037 Sekunden und messbar nicht-stille Samples. Das C++-Shared-Library-Ziel wurde mit CPU-only-Flags gebaut.

Die vollständige Legacy-Parität ist noch nicht fertig. Siehe `TASKS.md` und `docs/API-COMPAT.md`; die Produktionsroute wurde nicht umgeschaltet.
# bkg-tts.zig
# bkg-tts
