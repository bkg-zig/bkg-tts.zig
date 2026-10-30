# API-Kompatibilitätsvertrag: bkg-magpietts → Zig

Referenzen (maßgebliche bestehende Verträge):
- `/srv/bkg/services/bkg-magpietts/docs/API.md`
- `/srv/bkg/services/bkg-magpietts/docs/REALTIME.md`
- Router-Quellen unter `/srv/bkg/services/bkg-magpietts/app/api`
- App-Fabrik: `/srv/bkg/services/bkg-magpietts/app/main.py`

## HTTP-Endpunkte

| Methode | Pfad | Gruppe | Erwartetes Verhalten / Anmerkung |
|---|---|---|---|
| GET | `/health` | System | Liveness: 200, solange HTTP-Prozess lebt; kein Modell nötig |
| GET | `/ready` | System | 200 erst nach Modell-/Codec-Laden und bestandenem Warmup, sonst 503 |
| GET | `/api/system` | System | Version, Modell/Engine-Zustand, CPU-Runtime, Zähler/Metriken |
| GET | `/metrics` | Observability | Prometheus-Textformat |
| GET | `/v1/models` | OpenAI | `object=list`, `data=[…]` |
| GET | `/v1/models/{model_id}` | OpenAI | Details für Modell; unbekannte ID als 404 |
| POST | `/v1/audio/speech` | OpenAI | OpenAI-Payload; Audio als rohe Bytes; Header `X-Request-ID` |
| POST | `/v1/audio/cancel` | OpenAI | Wartende/aktive Jobs abbrechen; Barge-in |
| GET | `/v1/audio/voices` | OpenAI | Stimmenliste |
| GET | `/v1/audio/list_voices` | OpenAI/NVIDIA-Kompatibilität | Alias mit gleicher Stimmenliste |
| GET | `/api/voices` | Stimmen | Vollständige Stimmdaten (Legacy-Pfad) |
| GET | `/v1/voices` | Stimmen | Zusätzlich unterstützter Alias |
| GET | `/v1/languages` | Sprachen | Sprachen, die das Modell unterstützt |
| POST | `/api/tts/generate` | Native | Magpie-Steuerung; Text, Sprache, Sprecher, CFG, Format, Rate, Modus, Priorität |
| GET | `/api/tts/pronunciation` | Native | Wörterbuch als Liste |
| POST | `/api/tts/pronunciation` | Native | Wörterbucheintrag erstellen/aktualisieren |
| DELETE | `/api/tts/pronunciation/{word}` | Native | Eintrag löschen, Sprache als Query-Parameter |
| POST | `/api/tts/pronunciation/test` | Native | Ein Wort mit Wörterbuchregel synthetisieren |
| GET | `/api/profiles` | Admin | Profile, aktuelles Profil und Engine-Zustand |
| POST | `/api/profiles/switch` | Admin | Profilwechsel; bei nicht unterstütztem Profil klar ablehnen |
| POST | `/api/selftest` | Admin | reale Modell-/Audio-Checks durchführen |
| GET | `/api/logs?lines=N` | Admin | letzte Protokollzeilen; keine Secrets oder Kundentexte protokollieren |
| POST | `/api/reload` | Admin | unterstützte Config-/Wörterbuchänderungen neu laden |
| POST | `/api/benchmark` | Admin | tatsächliche Synthese messen; TTFA/RTF/Dauer und Fehler zurückgeben |
| GET | `/docs` | Doku | Swagger-UI beibehalten oder dokumentierte Alternative anbieten |
| GET | `/redoc` | Doku | ReDoc beibehalten oder dokumentierte Alternative anbieten |
| GET | `/openapi.json` | Doku | OpenAPI-Schema maschinenlesbar ausliefern |
| GET | `/` und Frontend-Pfade | UI | gebaute React-SPA mit History-Fallback ausliefern |

### `POST /v1/audio/speech`

Die bestehende Payload-Oberfläche muss dokumentiert und geprüft bleiben; gegenwärtig unterstützt der native Adapter WAV/PCM bei 22050 Hz und die im Modell hinterlegte CFG-Konfiguration:

- `model` (Default `magpie-tts-multilingual-357m`)
- `input` (Pflicht), `voice`, `language`
- `response_format`: pcm, wav, mp3, opus, flac, aac
- `speed`, `stream`, `stream_format`, `sample_rate`, `mode`
- `cfg_enabled`, `cfg_scale`, `text_normalization`

Nicht vom C-ABI abgedeckte Formate/Parameter dürfen nicht stillschweigend als erfolgreich unterstützt ausgegeben werden. Encoder sind nativ zu implementieren oder als explizite Laufzeitabhängigkeit zu dokumentieren.

### `POST /api/tts/generate`

- `text`, `language`, `speaker`, `profile`, `text_normalization`
- `cfg.enabled`, `cfg.scale`
- `audio.format`, `audio.sample_rate`
- `stream`, `priority`, `mode`

Die CPU-only Magpie-Engine hat keine CUDA-/VRAM-Profile. Profiloperationen müssen eine ehrliche CPU-Ansicht abbilden und nicht erfundene GPU-Metriken zurückgeben.

## Einheitliches Fehlerformat

Die Referenz verwendet bei strukturierten API-Fehlern typischerweise:

```json
{
  "error": {
    "code": "INVALID_REQUEST",
    "message": "Request validation failed.",
    "type": "validation_error",
    "request_id": "req_...",
    "retryable": false,
    "details": {}
  }
}
```

Wichtige Statusklassen: 400/404/409/422/429/500/503/504. Binäre Audioantworten erhalten den korrekten MIME-Type und `X-Request-ID`. Niemals Stacktraces, C-ABI-Pointer oder geheime Pfade an Clients geben.

## Realtime WebSocket: `/v1/realtime?intent=synthesize`

### Client → Server

- `session.update`: voice, language, format, sample_rate, speed, text_normalization, cfg_enabled, cfg_scale, priority, mode und optionale Phrase-Parameter.
- `input_text.append`: Textfragment wort-/satzübergreifend an den Puffer anhängen.
- `input_text.commit`: ausstehende Phrase(n) synthetisieren und Audio-Chunks senden.
- `response.cancel`: aktive/wartende Synthese abbrechen und Puffer zurücksetzen.
- `ping`: mit `pong` antworten.

### Server → Client

- `session.created`, `session.updated`
- `response.created`
- `audio.chunk`: `data` ist Base64-kodiertes Audio, dazu `format`, `sample_rate`, `chunk_index`
- `response.completed`: Dauer und TTFA
- `response.cancelled`
- `error`: Code, lesbare Nachricht, retryable/request/session IDs
- `pong`

Der Python-Dienst registriert zusätzlich die bestehenden Routen `/docs`, `/redoc` und `/openapi.json`; die neue App liefert eine lokale Dokumentationsseite und ein eingebettetes OpenAPI-Schema.

Die bestehende Implementierung puffert Tokens und flusht an Satzzeichen sowie konfigurierbaren Wort-/Zeitgrenzen (min/preferred/max words, soft/hard timeout). Der Zielserver muss echtes Audio aus der Magpie-Engine liefern; ein Echo- oder Dummy-Stream erfüllt den Vertrag nicht.

## Bestehende React-Oberfläche

Der alte Quellbaum ist `/srv/bkg/services/bkg-magpietts/web/src`. Die Seiten sind:
- Dashboard
- Playground + AudioPlayer
- Voices
- Models
- Performance
- API Tester
- Logs
- Pronunciation
- Self-Test
- Realtime Lab und Realtime-Dokumentation
- Systemstatus

Die neue Oberfläche muss dieselben Arbeitsabläufe wieder anbieten. WASM darf Validierung/Clientlogik übernehmen; HTTP, Audio-Playback, Browser-API-Aufrufe und React-Rendering brauchen weiterhin die Browser-Laufzeit. Ein reduziertes Mock-Dashboard ist kein Port.

## Hinweise zur Implementierung

- Der BKG-HTTP-Server nutzt Zig 0.16 `std.http.Server`; der Framework-Helper verarbeitet aktuell eine HTTP-Anfrage pro Verbindung. Für den dauerhaften WS-Lifecycle ist ein eigener Verbindungsweg über `Request.respondWebSocket` nötig.
- `bkg-tts.magpie` bindet die stabile C-ABI über `std.DynLib`. Es existiert derzeit kein bestätigter `libmagpie-tts.so`-Pfad in der Projektbaum-Suche. Vor E2E-Audio muss die echte Build-Ausgabe gefunden/erstellt und ABI-Version geprüft werden.
- Die WASM-Referenz ist ein kleines freestanding-Beispiel für Zig 0.13/0.14-dev, kein direkt übernehmbares Zig-0.16-Template.
