# MagpieTTS API-Kompatibilitätsinventar

Stand: 2026-10-27. Quelle: `/srv/bkg/services/bkg-magpietts/app/main.py` und die eingebundenen Router. Diese Tabelle ist eine Prüfliste, kein Nachweis implementierter Handler.

| Methode | Pfad | Funktion | Status |
|---|---|---|---|
| GET | `/health` | Liveness | TODO |
| GET | `/ready` | Modellbereitschaft | TODO |
| GET | `/api/system` | Systemstatus | TODO |
| GET | `/metrics` | Prometheus-Metriken | TODO |
| GET | `/v1/models` | Modellliste | TODO |
| GET | `/v1/models/{model_id}` | Modellinfo | TODO |
| POST | `/v1/audio/speech` | OpenAI-kompatible Synthese | TODO |
| POST | `/v1/audio/cancel` | Synthese abbrechen | TODO |
| GET | `/v1/audio/list_voices` | NVIDIA-Voice-Liste | TODO |
| GET | `/v1/audio/voices` | Voice-Liste | TODO |
| POST | `/api/tts/generate` | Native Synthese | TODO |
| GET/POST | `/api/tts/pronunciation` | Aussprache lesen/setzen | TODO |
| DELETE | `/api/tts/pronunciation/{word}` | Aussprache löschen | TODO |
| POST | `/api/tts/pronunciation/test` | Aussprache testen | TODO |
| GET | `/api/voices` | Voice-Metadaten | TODO |
| GET | `/api/languages` | Sprachliste | TODO |
| GET/POST | `/api/profiles`, `/api/profiles/switch` | Profile | TODO; CPU-Profilsemantik festlegen |
| POST | `/api/selftest` | Selbsttest | TODO |
| GET | `/api/logs` | Logs | TODO |
| POST | `/api/reload` | Config-Reload | TODO |
| POST | `/api/benchmark` | Benchmark | TODO |
| GET | `/docs`, `/redoc`, `/openapi.json` | API-Dokumentation | TODO |
| GET | `/` und GUI-Routen | React-UI | TODO |
| WS | `/v1/realtime` | Realtime-Protokoll | TODO; Event-Schema und RFC 6455 erforderlich |

## Befunde

- Python-Router: `app/api/openai.py`, `native.py`, `models.py`, `voices.py`, `system.py`, `admin.py`, `realtime.py`.
- React 19/Vite-UI in `/srv/bkg/services/bkg-magpietts/web`; Seiten: Dashboard, Voices, Models, System, SelfTest, Logs, API Tester, Realtime Lab/Docs, Aussprache, Playground und Performance.
- C-ABI-Header: `/srv/bkg/services/bkg-tts/bkg-tts.cpp/include/magpie_tts_capi.h`. Audioausgabe: Mono-f32-PCM, 22050 Hz. Die BKG-Bibliothek nutzt `std.DynLib`; eine gebaute `libmagpie-tts.so` wurde in den geprüften Pfaden nicht gefunden.
- `zig-wasm-react-nodejs` dokumentiert WASM-Exports für Frontend-Logik und React-Integration, wurde laut README aber mit Zig 0.13/0.14 getestet. Host: Zig 0.16.0. WASM ersetzt weder HTTP/TCP noch native Inferenz.
