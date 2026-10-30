# Quelleninventar und Systemanalyse

Stand: 2026-10-27

## Repositories und unveränderte Schutzgrenzen

- Ziel-App: `/bounty/playground/zig-app.bkg/bkg-magpietts.zig`.
- Framework: `/bounty/playground/zig-body.bkg`. Die App verwendet bestehende Module `bkg-tts` und `bkg-web`.
- Legacy-Referenz: `/srv/bkg/services/bkg-magpietts`. Beim Audit lagen bereits lokale Änderungen und unversionierte Dateien vor; sie wurden nicht überschrieben oder zurückgesetzt.
- C++-Quellbaum: `/bounty/docker/bkg-tts/bkg-tts.cpp`, Commit `ba83d247e5d6a01b186654fc01167ee34e3ce2a9`. Die Quelle unter `/srv/bkg/archive/repos/dump/mudler/magpie-tts.cpp` hatte ein nicht initialisiertes ggml-Submodul, deshalb wurde sie nicht zum Kompilieren benutzt.
- Native Library im Test: `/tmp/bkg-magpietts-shared-build/libmagpie-tts.so`, CPU-only kompiliert.
- Zig-WASM-Referenz: `Cugatay/zig-wasm-react-nodejs`. Das Repo ist ein kleines freestanding-Beispiel, kein fertiger HTTP-/WebSocket-Server; es nennt Zig 0.13 und frühen 0.14-dev, während der Host Zig 0.16.0 hat.

## Legacy-App-Dateien

### API-Module
- `app/main.py`: App-Fabrik, Lifespan, Logging, CORS, Health-Lifecycle, Router und SPA-Mount.
- `app/api/openai.py`: `POST /v1/audio/speech`, `POST /v1/audio/cancel`, `GET /v1/audio/voices`, `GET /v1/audio/list_voices`.
- `app/api/native.py`: `POST /api/tts/generate`, Aussprache-Wörterbuch GET/POST/DELETE und `POST /api/tts/pronunciation/test`.
- `app/api/models.py`: Modellliste und Modell-Detail.
- `app/api/voices.py`: `GET /api/voices`, `GET /api/languages`.
- `app/api/system.py`: `GET /health`, `GET /ready`, `GET /api/system`, `GET /metrics`.
- `app/api/admin.py`: Profile, Profilwechsel, Self-Test, Logs, Config-Reload und Benchmark.
- `app/api/realtime.py`: WS-Session, Ereignis-Pipeline, Phrase-Buffer, Cancel und Audio-Events.
- `app/api/common.py`: Stimme-/Sprachauflösung und gemeinsamer Synthesepfad.

### Engine, Audio, Runtime und Text
- `app/engines/base.py`: Engineschnittstelle.
- `app/engines/magpie_cpp.py`: Python-`ctypes`-Aufruf der flachen C-API.
- `app/engines/magpie_nemo.py`: Python-/NeMo-Engine, im Ziel zu entfernen.
- `app/engines/nim_remote.py`: Remote-NIM-Engine, kein Ziel-Fallback.
- `app/audio/chunker.py`, `encoder.py`, `formats.py`, `pcm.py`, `resampler.py`: Audioformatierung, PCM, Chunking, Resampling.
- `app/runtime/model_manager.py`, `scheduler.py`, `health.py`, `warmup.py`, `profile_manager.py`, `gpu_monitor.py`: Modellzustand, Queue/Cancel, Health, Warmup, Profile, GPU-Monitor.
- `app/text/language.py`, `normalizer.py`, `phrase_buffer.py`, `ipa_dictionary.py`: Sprache, Textnormalisierung, Echtzeit-Phrasen, Wörterbuch.
- `app/schemas/speech.py`, `realtime.py`, `models.py`, `errors.py`, `benchmark.py`: HTTP-/WS- und Fehler-Modelle.
- `app/state.py`: Prozesszustand.
- `app/utils/common.py`, `middleware.py`, `logging_setup.py`: IDs/Statistiken, Request-Kontext und Logging.

### Config, Tests und Deployment
- `configs/server.yaml`: Host/Port, Modell, Sprache, Runtime, Queue, Phrasen, Audio, Logging und optionaler Remote-Modus.
- `configs/voices.yaml`, `profiles.yaml`, `pronunciation.yaml`: Stimmen, Profile und Wörterbuch.
- `app/tests/compatibility_test.py`, `quality_test.py`, `selftest.py`, `streaming_test.py`, `tests/test_core.py`: bestehende Verträge und Qualität.
- `docs/API.md`, `docs/REALTIME.md`: maßgebliche Legacy-Verträge.
- `pyproject.toml`, `requirements.txt`, `uv.lock`: Python-Abhängigkeiten für das alte Image.
- `docker/Dockerfile`, `docker/docker-compose.yml`, `docker/docker-entrypoint.sh`: altes Python-/NeMo-/Node-Image; nicht für das neue Image übernehmen.
- `scripts/test.sh`, `benchmark.sh`, `download-model.sh`, `install.sh`, `update.sh`: altes Tooling, nur als Referenz.

## React-Oberfläche

Alle folgenden bestehenden Module wurden von `/srv/bkg/services/bkg-magpietts/web/src` nach `web/src` im Zielprojekt kopiert; `node_modules`/Legacy-`dist` wurden nicht als Quellen übernommen:
- Shell/Kommunikation: `App.tsx`, `main.tsx`, `api.ts`, `index.css`.
- Komponenten: `components/AudioPlayer.tsx`, `components/ui.tsx`.
- Seiten: `pages/Dashboard.tsx`, `Playground.tsx`, `RealtimeLab.tsx`, `RealtimeDocs.tsx`, `Voices.tsx`, `Models.tsx`, `Performance.tsx`, `ApiTester.tsx`, `Logs.tsx`, `Pronunciation.tsx`, `SelfTest.tsx`, `SystemPage.tsx`.
- Assets: `assets/*`, öffentliche Favicons/Icons unter `web/public`.
- Build: `web/package.json`, `package-lock.json`, `vite.config.ts`, `tsconfig*.json`, `eslint.config.js`. Node/npm wird nur zum Build verwendet.
- Neue WASM-Anbindung: `web/src/wasm.ts` lädt `/wasm/bkg-magpietts-wasm.wasm`, prüft Vertragsversion und Exporte. `api.ts` verwendet dessen Prüfungen vor TTS-Anfragen; `App.tsx` zeigt den WASM-Zustand.

## Endpoint-/WebSocket-Oberfläche

REST-Pfade stehen vollständig in `API-COMPAT.md` und `web/public/openapi.json`. Zentrale Legacy-Pfade sind:
- OpenAI-REST: `POST /v1/audio/speech`, `POST /v1/audio/cancel`, `GET /v1/models`, `GET /v1/models/{model_id}`, Stimmen-Aliase.
- Native: `POST /api/tts/generate`, `GET/POST /api/tts/pronunciation`, `DELETE /api/tts/pronunciation/{word}`, `POST /api/tts/pronunciation/test`.
- Voices/Language: `GET /api/voices`, `GET /api/languages`.
- System: `GET /health`, `GET /ready`, `GET /api/system`, `GET /metrics`.
- Admin: `GET /api/profiles`, `POST /api/profiles/switch`, `POST /api/selftest`, `GET /api/logs`, `POST /api/reload`, `POST /api/benchmark`.
- WebSocket: `/v1/realtime?intent=synthesize`.
- Doku/SPA: `/docs`, `/redoc`, `/openapi.json`, Root und History-Fallback-URLs.

WS-Ereignisse: Client `session.update`, `input_text.append`, `input_text.commit`, `response.cancel`, `ping`; Server `session.created`, `session.updated`, `response.created`, `audio.chunk`, `response.completed`, `response.cancelled`, `error`, `pong`.

## Noch offene Engine-/Paritätsgrenzen

Die C-ABI-v1 akzeptiert Text/Sprache/Sprecher; sie exponiert keine Sample-Rate-, Speed-, TN- oder CFG-Overrides. Der Server behauptet diese Optionen nicht als funktionsfähig: Nicht unterstützte Werte werden abgelehnt. WAV/PCM bei 22050 Hz wird real synthetisiert. MP3/Opus/FLAC/AAC, Resampling, Aussprachewörterbuch, aktives Cancel, Benchmark/Selftest/Reload und tokenweises Audio während der Inferenzen sind offen. WebSocket liefert echte PCM-Chunks pro Phrase, aber erst nachdem der C-ABI-Aufruf die gesamte Phrase synthetisiert hat.
