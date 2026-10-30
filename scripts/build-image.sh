#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYGROUND="$(cd -- "$ROOT/../.." && pwd)"
FRAMEWORK="$PLAYGROUND/zig-body.bkg"
IMAGE_TAG="${BKG_MAGPIETTS_IMAGE:-bkg-magpietts-zig:latest}"
ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
CPP_SOURCE="${BKG_MAGPIE_CPP_SOURCE:-/bounty/docker/bkg-tts/bkg-tts.cpp}"
CONTEXT="$(mktemp -d -t bkg-magpietts-context.XXXXXX)"
trap 'rm -rf "$CONTEXT"' EXIT

if [[ ! -d "$FRAMEWORK/libs/bkg-web" || ! -d "$FRAMEWORK/libs/bkg-tts" ]]; then
  echo "BKG Zig framework not found at $FRAMEWORK" >&2
  exit 2
fi
if [[ ! -f "$CPP_SOURCE/CMakeLists.txt" || ! -f "$CPP_SOURCE/include/magpie_tts_capi.h" || ! -d "$CPP_SOURCE/third_party/ggml" ]]; then
  echo "A complete local magpie-tts.cpp source tree is required: $CPP_SOURCE" >&2
  exit 2
fi

mkdir -p "$CONTEXT/zig-app.bkg/bkg-magpietts.zig" "$CONTEXT/zig-body.bkg" "$CONTEXT/magpie-tts.cpp"
tar -C "$ROOT" \
  --exclude='./.git' --exclude='./.zig-cache' --exclude='./zig-out' \
  --exclude='./web/node_modules' --exclude='./web/dist' \
  --exclude='./web/public/wasm/*.wasm' --exclude='./*.wav' --exclude='./*.pcm' --exclude='./*.so' \
  -cf - . | tar -C "$CONTEXT/zig-app.bkg/bkg-magpietts.zig" -xf -
tar -C "$FRAMEWORK" \
  --exclude='./.git' --exclude='./.zig-cache' --exclude='./zig-out' \
  --exclude='./node_modules' --exclude='./dist' -cf - . \
  | tar -C "$CONTEXT/zig-body.bkg" -xf -
cp "$ROOT/Dockerfile" "$CONTEXT/Dockerfile"
cp "$CPP_SOURCE/CMakeLists.txt" "$CONTEXT/magpie-tts.cpp/"
cp -a "$CPP_SOURCE/include" "$CPP_SOURCE/src" "$CPP_SOURCE/third_party/ggml" "$CONTEXT/magpie-tts.cpp/"
rm -f "$CONTEXT/magpie-tts.cpp/third_party/ggml/.git"
cat > "$CONTEXT/.dockerignore" <<'EOF'
**/.git
**/.zig-cache
**/zig-out
**/node_modules
**/dist
**/*.wav
**/*.pcm
**/*.so
EOF

docker build \
  --build-arg "ZIG_VERSION=$ZIG_VERSION" \
  --tag "$IMAGE_TAG" \
  --file "$CONTEXT/Dockerfile" \
  "$CONTEXT"
echo "Built image: $IMAGE_TAG (local C++ source: $CPP_SOURCE)"
