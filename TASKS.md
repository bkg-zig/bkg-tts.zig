# BKG-MagpieTTS Zig — Aufgaben- und Handoff-Dokument

Stand: 2026-10-27  
Projektwurzel: `/bounty/playground/zig-app.bkg/bkg-magpietts.zig`  
Bisheriger Python-Dienst (nur Referenz, nicht überschreiben): `/srv/bkg/services/bkg-magpietts`  
Ziel-Deployment-Pfad: `/srv/bkg/services/bkg-magpietts.zig`  
Framework: `/bounty/playground/zig-body.bkg`, Zig `0.16.0`

## Ziel und harte Grenzen

Die produktive Python-/NeMo-Serverimplementierung wird durch einen nativen Zig-Server ersetzt. Die Inferenz bleibt CPU-only und erfolgt ausschließlich über `magpie-tts.cpp` und dessen C-ABI. Es gibt keinen Python-/NeMo-Fallback. Die React-Oberfläche bleibt React; WASM ist für echte, messbare Frontend-Logik zuständig und nicht als Behauptung für „alles nativ“ misszuverstehen. Node/Bun darf für Frontend-Build und Paketauflösung erforderlich sein, aber nicht als Laufzeit-Backend oder Glue-Schicht.

Die API-Kompatibilität wird anhand des bestehenden Quellcodes und `docs/API.md` sowie `docs/REALTIME.md` abgesichert. Unfertige Endpunkte müssen ehrlich mit einem klaren Fehler antworten, niemals eine erfolgreiche Antwort vortäuschen. Vorhandene lokale Änderungen im alten Python-Repo sind fremder Arbeitsstand und werden nicht zurückgesetzt oder überschrieben.

## Status-Legende

- `TODO`: noch nicht begonnen.
- `IN PROGRESS`: aktive Umsetzung oder Audit noch nicht vollständig verifiziert.
- `DONE`: Datei/Umsetzung vorhanden und die angegebenen Prüfschritte wurden tatsächlich ausgeführt.
- `BLOCKED`: wartet auf eine konkret benannte Abhängigkeit.

## Arbeitsliste

| ID | Bereich / Ergebnis | Status | Abhängigkeiten | Aufwand | Zentrale Dateipfade |
|---|---|---|---|---:|---|
| T01 | Bestehende Anwendung, Verträge, Laufzeit- und Build-Abhängigkeiten inventarisieren | DONE | — | 4–6 h | `/srv/bkg/services/bkg-magpietts/app`, `docs/API.md`, `docs/REALTIME.md`, `docs/API-COMPAT.md` |
| T02 | Native HTTP/REST-API mit identischen Pfaden, Methoden, Statuscodes, Audioformaten und Fehlerobjekten | IN PROGRESS | T01, T05 | 2–4 Tage | `src/main.zig`, `src/router.zig`, `src/api.zig`, `src/engine.zig` |
| T03 | Realtime-WebSocket-Protokoll einschließlich Session-Lifecycle, Append/Commit, Chunk-Events, Cancel, Ping/Pong | IN PROGRESS | T01, T02 | 2–3 Tage | `src/main.zig`, `src/router.zig`, `src/realtime.zig`, Framework `libs/bkg-web/src/websocket.zig` |
| T04 | React-UI: alle bisherigen Seiten/Funktionen übernehmen, Verhalten verbessern, barrierearm und responsiv halten | IN PROGRESS | T01, T02 | 3–5 Tage | `web/src`, Referenz `/srv/bkg/services/bkg-magpietts/web/src` |
| T05 | Build-Grundgerüst für nativen Server und separates WASM-Target; BKG-Module korrekt einbinden | DONE | — | 4–8 h | `build.zig`, `build.zig.zon`, `src/wasm.zig` |
| T06 | Native Magpie-Inferenz über C-ABI, Modell-Lifecycle, ABI-Check, Pufferfreigabe und Fehlerabbildung | IN PROGRESS | T05 | 1–2 Tage | `src/engine.zig`, Framework `/bounty/playground/zig-body.bkg/libs/bkg-tts/src/magpie.zig`, native Build-Ausgabe `libmagpie-tts.so` |
| T07 | Python/NeMo- und Node-Backend-Glue aus dem neuen Runtime-Image entfernen | TODO | T02, T03, T04, T06 | 1–2 Tage | `Dockerfile`, `docker/entrypoint.sh`, `build.zig`, `web/package.json` |
| T08 | Reproduzierbare Tests: Route-Matrix, HTTP-Integration, WebSocket-Vertrag, WASM-Validierung und Audio-Qualität | IN PROGRESS | T02–T06 | 2–3 Tage | `tests`, `src/*_test.zig`, `scripts/test.sh` |
| T09 | CPU-only Docker-Image auf Ubuntu 22.04, Health-/Ready-Probes, Persistenz und sichere Konfiguration | TODO | T02, T03, T05–T08 | 1–2 Tage | `Dockerfile`, `docker/compose.yaml`, `configs/server.yaml` |
| T10 | Traefik, Streaming/Buffering, Config-Reload, Rollout/Smoke-Test und Rückfallplan | TODO | T08, T09 | 4–8 h | `deploy/traefik`, `docs/DEPLOYMENT.md`, `scripts/smoke-test.sh` |
| T11 | Python-Abschaltung erst nach Paritätsnachweis; Vergleichsmatrix und Betriebsübergabe | TODO | T08–T10 | 4–8 h | `docs/MIGRATION.md`, `docs/API-COMPAT.md`, Deployment-Konfiguration |

## T01 — bisherige Analyse

### Vorhandene Pfade und Zustand

- Bestehende App: `/bounty/playground/zig-app.bkg/bkg-magpietts.zig`.
- Bereits vorhanden: `build.zig`, `build.zig.zon`, `src/main.zig`, `src/config.zig`, `src/engine.zig`.
- `src/main.zig` importiert bereits `router.zig` und `api.zig`; diese zwei Quelldateien fehlen zum Audit-Zeitpunkt. Das ist ein konkreter Grund, warum der Stand noch nicht als lauffähiger Server gelten darf.
- `build.zig.zon` bindet `../../zig-body.bkg` als Abhängigkeit ein. Das entspricht dem vorhandenen BKG-Schichtenlayout.
- Framework-Inferenz-Adapter: `/bounty/playground/zig-body.bkg/libs/bkg-tts/src/magpie.zig`; er lädt die Bibliothek über `std.DynLib`, löst die C-ABI-Symbole zur Laufzeit auf und besitzt/freigibt die Audio-Puffer.
- Web-Framework: `/bounty/playground/zig-body.bkg/libs/bkg-web`; HTTP-Server nutzt `std.http.Server`. Der bestehende `server.serveStream` behandelt aktuell einen HTTP-Request pro Verbindung und enthält noch keinen vollständigen WebSocket-Realtime-Workflow. Die vorhandenen WebSocket-Primitiven sind separat zu integrieren.
- Der Referenz-Stack `Cugatay/zig-wasm-react-nodejs` zeigt ein freestanding WASM-Modul plus React-Frontend. Er ist ein kleines Beispiel, kein fertiger HTTP-/WebSocket-Server und kein passender kompletter UI-Baukasten.
- Auf dem untersuchten Host wurde Zig `0.16.0` gefunden. Die Referenz nennt Zig `0.13` und einen frühen `0.14-dev`-Stand; deren Builddatei nicht blind kopieren.
- Die alte Dienstkopie hat derzeit lokale, nicht eingecheckte Änderungen. Diese werden als Referenz gelesen, nicht bereinigt.
- Bei der Dateisuche unter `/bounty` sowie `/srv/bkg/services` wurde keine gebaute `libmagpie-tts.so` gefunden. Das beweist nicht, dass sie nirgendwo auf dem Host vorhanden ist; vor Laufzeittests muss der konkrete Build-Ausgabepfad verifiziert werden.

### Bekannte Vertragsgruppen

- OpenAI-kompatible REST-API: `POST /v1/audio/speech`, `GET /v1/models`, `GET /v1/models/{model_id}`, `POST /v1/audio/cancel`, `GET /v1/audio/voices`, `GET /v1/audio/list_voices`.
- Native REST-API: `POST /api/tts/generate`, Pronunciation-CRUD und Pronunciation-Test.
- Modelle, Stimmen, Sprachen, System/Health/Metrics, Profile, Logs, Config-Reload, Selftest und Benchmark.
- Realtime-WebSocket: `/v1/realtime?intent=synthesize`.
- Dokumentation und UI: `/docs`, `/redoc`, `/openapi.json`, Root/SPA sowie Dashboard, Playground, Voices, Models, Performance, API Tester, Logs, Pronunciation, Self-Test, Realtime Lab/Docs und System.

Vollständige Pfad-/Methodenliste und Protokollvertrag: `docs/API-COMPAT.md`.

## T05 — Build- und Target-Plan

- Host-Binary: natives Linux-Ziel, CPU-only, Zig 0.16.0; kein CUDA-Link und keine Python-Abhängigkeit.
- WebAssembly-Binary: eigenes freestanding `wasm32`-Target; darf keine native `libmagpie-tts.so` einbinden. Es enthält reine Frontend-/Validierungslogik.
- React/Vite baut gegen den erzeugten WASM-Blob. JavaScript/React bleibt die unvermeidliche Browser-Laufzeitoberfläche; das Backend bleibt vollständig Zig.
- Der bestehende BKG-Adapter wird wiederverwendet, statt den C-ABI-Wrapper außerhalb des Frameworks zu duplizieren. Aktuell dynamisches Laden via `std.DynLib`; ein echter ABI-Version-Check sowie exakte Library-/Modellpfade sind vor produktiver TTS-Freigabe noch zu verifizieren.
- Zielkommandos: `zig build`, `zig build test`, `zig build wasm`. Die Kommandos gelten erst als bestanden, wenn sie in diesem Arbeitsverzeichnis ausgeführt wurden und Exit 0 liefern.

## Abnahmekriterien (Definition of Done)

1. Jede in `docs/API-COMPAT.md` aufgeführte Route besitzt eine Testspezifikation und ist entweder kompatibel implementiert oder wird ausdrücklich als nicht-kompatibel/noch nicht implementiert ausgewiesen. Keine stillen Erfolgs-Stub-Antworten.
2. Der WebSocket hält den dokumentierten Event-Lifecycle ein; Audio-Chunks sind echte, dekodierbare Audio-Nutzdaten und kein Platzhalter.
3. Die tatsächliche WAV-Ausgabe enthält nicht nur einen gültigen Header: PCM-Länge, Sample-Rate, Nicht-Stille und Dauer werden überprüft.
4. Native Release-Builds laufen in Ubuntu 22.04 CPU-only. Das Laufzeit-Image enthält kein Python/NeMo und startet keinen Node-Backendprozess.
5. WASM kompiliert zum Browser-Target und wird von der React-App tatsächlich geladen und verwendet.
6. Docker-/Traefik-Smoke-Tests bestehen einschließlich WebSocket-Upgrade und deaktiviertem Proxy-Buffering für Streaming.
7. Erst dann wird das alte Python-Deployment abgeschaltet. Bestehende Dateien und der bisherige Service bleiben bis zum erfolgreichen Paritätsvergleich unangetastet.

## Übergabe / nächste Schritte

1. T01 abschließen: alle API-Module, Schemas, Engine-/Audio-Verarbeitung, Config und React-Seiten in der Vergleichsmatrix referenzieren.
2. T05 fertigstellen: native + WASM-Buildtargets und Modulgraph kompilieren.
3. T02/T03 getrennt implementieren und zuerst Health/Ready, Modellstatus, echte WAV-Synthese und WebSocket-Lifecycle testen.
4. T04 anhand des vorhandenen React-Frontends portieren, nicht mit einem abgespeckten Ersatz-Dashboard.
5. Nach jedem Task: echte Builds/Tests ausführen, Resultat und konkrete Lücken dokumentieren. Keine Git-Pushes ohne ausdrücklichen Auftrag.


## Aktualisierte Ausführungsbelege (2026-10-27)

- **T01 DONE:** `docs/SOURCE-INVENTORY.md` und `docs/API-COMPAT.md` dokumentieren Quellbaum, REST-/WS-Oberfläche, React-Seiten und offene Paritätslücken.
- **T05 DONE:** `build.zig` enthält ein natives Serverziel, Tests und ein separates wasm32/freestanding-Target. `zig build`, `zig build test` und `zig build wasm` wurden erfolgreich ausgeführt.
- **T06 IN PROGRESS:** CPU-only Shared Library aus `/bounty/docker/bkg-tts/bkg-tts.cpp` wurde unter `/tmp/bkg-magpietts-shared-build/libmagpie-tts.so` gebaut. Echte HTTP-Synthese mit vorhandenem Q8-GGUF lieferte 22,05-kHz-Mono-WAV mit 133.120 Samples, 6,037 s und nicht-stillem PCM.
- **T04 IN PROGRESS:** React-Quellseiten wurden kopiert; `tsc -b` und Vite-Produktionsbuild waren erfolgreich. WASM wird vom UI geladen und für Request-Prüfungen genutzt. Nicht unterstützte Optionen sind deaktiviert oder werden abgelehnt.
- **T02/T03/T08 IN PROGRESS:** Native REST-/WS-Routen und Tests sind implementiert. Die WS-E2E-Probe wird separat verifiziert. Admin-/Aussprache-/Cancel-APIs, komprimierte Encoder, echtes tokenweises Streaming und volle Parität sind noch offen.
- Kein Produktions-Container wurde ersetzt, keine Legacy-Dateien zurückgesetzt und kein Git-Push ausgeführt.
