# BKG-MagpieTTS Zig — Aufgaben und Handoff

Stand: 2026-10-27. Projektwurzel: `/bounty/playground/zig-app.bkg/bkg-magpietts.zig`. Ziel: Zig 0.16.x, Ubuntu 22.04 CPU-only. WASM/React-Referenz: https://github.com/Cugatay/zig-wasm-react-nodejs. Python-Referenz: `/srv/bkg/services/bkg-magpietts`.

Status: DONE nur nach passendem Test; IN PROGRESS begonnen; TODO offen. Aufwand in Personentagen, grob geschätzt.

## Leitplanken
- Python-Dienst nicht abschalten, bevor Kompatibilitäts- und Realtime-Tests bestanden sind.
- Kein Python/NeMo-Fallback im Zielcontainer. Native `libmagpie-tts.so` ist die lokale Engine.
- Keine erfundenen Streaming-Events. Das reale Event-Protokoll aus `app/api/realtime.py` bleibt Vertrag.
- Ubuntu 22.04 CPU-only, kein CUDA. Vite darf im Frontend-Build Node verwenden; keine Node-Runtime im finalen Server-Image.
- WASM ist für Frontend-Logik, nicht für HTTP/TCP oder native TTS-Inferenz.

## Aufgaben
| ID | Aufgabe | Status | Abhängigkeiten | Aufwand | Pfade |
|---|---|---|---|---:|---|
| T1.1 | Python-Dateien, Router, Config und Deployment inventarisieren | IN PROGRESS | keine | 0,5 d | `/srv/bkg/services/bkg-magpietts/app`, `configs/server.yaml`, `docs/API-COMPATIBILITY.md` |
| T1.2 | Request-/Response-Schemas, Fehlercodes, Header, Statuscodes, Audioformate erfassen | TODO | T1.1 | 1 d | `app/schemas`, `app/api/*.py`, `docs/API-COMPATIBILITY.md` |
| T1.3 | WebSocket-Events, Binärframes, Cancel/Close/Backpressure dokumentieren | TODO | T1.1 | 0,5 d | `app/api/realtime.py`, `docs/REALTIME-COMPATIBILITY.md` |
| T1.4 | React-Routen und UI-Parität als Matrix erfassen | TODO | T1.1 | 0,5 d | `web/src/App.tsx`, `web/src/pages/*`, `docs/UI-COMPATIBILITY.md` |
| T2.1 | `std.Io.net` Listener + `std.http.Server` Request-Loop | TODO | T1.2 | 1 d | `src/server.zig`, `src/main.zig` |
| T2.2 | Routing, Body-Limits, JSON, Fehlerantworten, CORS, Request-IDs | IN PROGRESS | T2.1, T1.2 | 1,5 d | `src/router.zig`, `src/api.zig`, `src/http_types.zig` |
| T2.3 | REST-Handler mit kompatiblen Payloads und Statuscodes | TODO | T2.2, T4.1 | 2 d | `src/api/*.zig`, `src/router.zig` |
| T2.4 | WebSocket-Upgrade, RFC-6455-Frames, Close/Ping/Pong und Streaming | TODO | T2.1, T1.3 | 2 d | `src/websocket.zig`, `src/realtime.zig` |
| T3.1 | Bestehende React-Seiten/Funktionen inventarisieren | TODO | T1.4 | 0,5 d | `web/src/*`, `docs/UI-COMPATIBILITY.md` |
| T3.2 | Zig-WASM-ABI, Memory-Vertrag und Zig-0.16-Build-Probe | TODO | keine | 1 d | `wasm/src/main.zig`, `build.zig` |
| T3.3 | WASM in Vite integrieren, Laden und Fehlerpfad testen | TODO | T3.2 | 0,5 d | `web/vite.config.ts`, `web/src/wasm.ts`, `web/public/main.wasm` |
| T3.4 | UI-API-Parität, Seiten- und Bedienbarkeitstest | TODO | T2.3, T3.1 | 2 d | `web/src/pages/*`, `web/src/api.ts` |
| T4.1 | C-ABI laden, ABI-Version prüfen, Modell/Audio/Fehler freigeben | IN PROGRESS | BKG `bkg-tts` | 0,5 d | `/bounty/playground/zig-body.bkg/libs/bkg-tts/src/magpie.zig`, `src/engine.zig` |
| T4.2 | `.so` reproduzierbar unter Ubuntu 22.04 bauen/installieren | TODO | C++-Quellrepo/CMake | 1 d | `/srv/bkg/services/bkg-tts/bkg-tts.cpp`, `docker/Dockerfile` |
| T4.3 | WAV/PCM/MP3, Resampling und Encoder-Parität herstellen | TODO | T1.2, T4.1 | 1 d | `src/audio.zig`, `src/encoder.zig`, BKG `libs/bkg-tts/src/wav.zig` |
| T5.1 | `build.zig` für Server, Tests, optional WASM und C-Library-Konfiguration | IN PROGRESS | T2.1, T3.2, T4.1 | 1 d | `build.zig`, `build.zig.zon` |
| T5.2 | Ubuntu-22.04-CPU-only-Dockerfile | TODO | T4.2, T5.1 | 0,5 d | `docker/Dockerfile`, `.dockerignore` |
| T5.3 | ENV-Konfiguration, Modell-/Library-Pfade und Shutdown | TODO | T5.1, T5.2 | 0,5 d | `src/config.zig`, `docker/entrypoint.sh` |
| T6.1 | Node-Glue inventarisieren; Build-Werkzeuge von Runtime trennen | TODO | T1.4, T3.3 | 0,5 d | `package.json`, `web/vite.config.ts`, Docker |
| T6.2 | Frontend statisch servieren; kein Node/Python im Runtime-Image | TODO | T5.2, T6.1 | 0,5 d | `docker/Dockerfile`, `src/static.zig` |
| T7.1 | Unit-Tests für Router/JSON/Config/PCM/WAV | TODO | T2.2, T4.3 | 1 d | `src/*_test.zig` |
| T7.2 | REST-Contract-Vergleich Python gegen Zig | TODO | T2.3, T1.2 | 1 d | `tests/api_contract.py`, `tests/fixtures/*` |
| T7.3 | WebSocket-Tests für Frames, Abbruch, Fehler, Backpressure | TODO | T2.4 | 1 d | `tests/realtime/*` |
| T7.4 | WASM-Exports/Memory und UI-Smoke-Test | TODO | T3.3 | 0,5 d | `tests/wasm/*`, `web/` |
| T7.5 | Echtes Modell: Synthese, nichtleeres Audio, WAV/PCM validieren | TODO | T4.2, T4.3 | 0,5 d | `tests/tts/*` |
| T8.1 | Image bauen, Runtime-Abhängigkeiten und Smoke-Test | TODO | T5.2, T7.1 | 0,5 d | `docker/Dockerfile`, `docker/compose.yaml` |
| T8.2 | Traefik, WebSocket-Upgrade, Streaming-Buffering und Timeouts | TODO | T2.4, T8.1 | 0,5 d | Compose und Traefik-Konfiguration |
| T8.3 | Atomarer Config-Reload und Modellwechsel mit Rollback | TODO | T2.3, T4.1 | 1 d | `src/config.zig`, `src/engine.zig`, `src/api/admin.zig` |
| T8.4 | Canary, Vergleich, Rollback; Python erst nach Abnahme abschalten | TODO | alle | 0,5 d | Deployment-Runbook |

## Abnahme-Gates
1. `zig build` und `zig build test` mit festgelegter Zig-Version erfolgreich.
2. API-Matrix: Pfade, Methoden, Payloads, Fehler, Statuscodes und Audio-Content-Types verglichen.
3. Echtes WebSocket-Upgrade und echte Frames; vorhandene Clientsequenzen bestehen.
4. Echtes `.so` und Modell laden; Audio erzeugen und Header/Format validieren.
5. React-Build/WASM-Laden erfolgreich, alle bisherigen UI-Seiten erhalten.
6. Runtime-Image Ubuntu 22.04 ohne Python/NeMo/CUDA/Node.
7. Traefik-Streaming und Reload/Rollback nachweislich getestet.

## Verifizierter Ausgangspunkt
- Host-Zig ist `0.16.0`.
- Git-Branch `tts/read-batch`; übergeordneter Arbeitsbaum enthält weitere Änderungen. Keine davon zurücksetzen.
- Der erste Build scheiterte am ungültigen Fingerprint in `build.zig.zon`, danach an fehlenden `src/api.zig` und `src/router.zig`.
- Fingerprint aktualisiert und die beiden fehlenden Zig-Module angelegt. Build erneut ausführen und Fehler beheben.
- C-ABI-Header vorhanden; `libmagpie-tts.so` in den geprüften Pfaden nicht gefunden.
- Nächster Schritt: `zig build`, Compilerfehler beheben, anschließend HTTP-Listener implementieren.
