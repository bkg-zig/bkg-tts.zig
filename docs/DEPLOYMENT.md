# Deployment — BKG MagpieTTS Zig

## Image und Runtime

Finales Image: Ubuntu 22.04, nativer Zig-Server, `libmagpie-tts.so`, gebaute React-Dateien und WASM. Kein Python/NeMo und kein Node-Prozess zur Laufzeit. Node/npm und der C++-Compiler werden nur in der Build-Stufe benutzt.

Das GGUF bleibt extern gemountet. Standard auf diesem Host: `/srv/bkg/services/bkg-magpietts/models/magpie-tts-multilingual-357m-q8_0.gguf`. Der Build oder Compose-Start stoppt bzw. überschreibt den alten Dienst nicht.

## Image bauen

Vom Zielprojekt `/bounty/playground/zig-app.bkg/bkg-magpietts.zig` den Befehl `scripts/build-image.sh` ausführen. Er paketiert temporär diese App und das lokale Framework `/bounty/playground/zig-body.bkg`, baut native Zig-App, WASM, React und die CPU-only Shared Library. Er verändert Framework und Legacy-Quellbaum nicht. Benötigt Docker, Netzwerkzugriff für Build-Abhängigkeiten und ausreichend Speicherplatz.

## Parallelbetrieb / Smoke-Test

`docker compose -f docker/compose.yaml -f docker/compose.local.yaml up -d`

Der Aussprachewortschatz liegt in einem persistierenden Docker-Volume `magpietts-data`. Der lokale Override veröffentlicht nur `127.0.0.1:18093`, sodass der alte Dienst auf Port 8092 unangetastet bleibt.

- `curl -i http://127.0.0.1:18093/health`
- `curl -i http://127.0.0.1:18093/ready`
- `curl -sS http://127.0.0.1:18093/api/system`
- `curl -sS http://127.0.0.1:18093/openapi.json`
- `curl -fsS http://127.0.0.1:18093/wasm/bkg-magpietts-wasm.wasm -o /tmp/magpie.wasm`

Health prüft Liveness; Readiness gibt vor abgeschlossenem Modellladen 503 zurück.

## Traefik

Die Host-Inspektion fand das externe Netzwerk `bkg_net` und den Traefik-Container `bkg-core-traefik-1` darin. Der bestehende Legacy-Container liegt derzeit in `docker_default`, hat keine Docker-Traefik-Labels und veröffentlicht Port 8092 auf dem Host. Das neue Compose hängt sich an `bkg_net` und veröffentlicht standardmäßig keinen Host-Port.

Zum Aktivieren der neuen Host-Route: `MAGPIE_TRAEFIK_HOST=dein.tatsächlicher.hostname docker compose -f docker/compose.yaml -f docker/compose.traefik.yaml up -d`. Der Hostname ist absichtlich erforderlich statt geraten. Das Override setzt Host-Regel, EntryPoint (Default `websecure`), TLS und Backend-Port 8092. Traefik muss Docker-Provider, EntryPoint und Zertifikatsvergabe passend konfiguriert haben.

WebSocket-Upgrades funktionieren über die HTTP-Route; kein Buffering-Middleware für Realtime einsetzen. Die CORS-OPTIONS-Preflight-Antwort wird vom Zig-Server bedient.

## ENV

- `MAGPIE_HOST` Default `0.0.0.0`
- `MAGPIE_PORT` Default `8092`
- `MAGPIE_DEVICE=cpu`
- `BKG_MAGPIE_MODEL=/srv/magpie/models/magpie-tts-multilingual-357m-q8_0.gguf`
- `BKG_MAGPIE_LIB_PATH=/usr/local/lib/libmagpie-tts.so`
- `MAGPIE_WEB_DIST=/srv/magpie/web/dist`
- `MAGPIE_MODEL_DIR` Hostpfad des GGUF-Verzeichnisses

Keine NVIDIA-/HF-Secrets: lokales GGUF, keine Remote-NIM-/Python-Fallbacks.

## Umschalten

Das neue Compose nutzt `container_name: bkg-magpietts-zig` und stoppt den Legacy-Dienst nicht. Produktionsumschaltung erst nach API-/WS-Parität, Browser-, Last- und Audio-Test und geprüftem Traefik-Routing.
