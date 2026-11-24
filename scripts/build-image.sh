#!/usr/bin/env bash
# Baut das Image lokal. Es wird kein Image aus einer Registry gezogen.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMPOSE_FILE="${COMPOSE_FILE:-$ROOT/docker/compose.yaml}"
IMAGE_TAG="${BKG_TTS_IMAGE:-bkg-tts-zig:local}"

docker compose -f "$COMPOSE_FILE" build
echo "Image gebaut: $IMAGE_TAG"
