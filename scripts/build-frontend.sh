#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
zig build wasm
mkdir -p web/public/wasm
cp zig-out/bin/bkg-magpietts-wasm.wasm web/public/wasm/bkg-magpietts-wasm.wasm
npm_cli=""
node_dir="$(dirname "$(readlink -f "$(command -v node)")")"
for candidate in   "$node_dir/../lib/node_modules/npm/bin/npm-cli.js"   "$node_dir/../share/nodejs/npm/bin/npm-cli.js"   "/usr/share/nodejs/npm/bin/npm-cli.js"; do
  if [[ -f "$candidate" ]]; then npm_cli="$candidate"; break; fi
done
npm_cmd() {
  if [[ -n "$npm_cli" ]]; then node "$npm_cli" "$@"; else command npm "$@"; fi
}
if [[ ! -x web/node_modules/.bin/vite ]]; then
  (cd web && npm_cmd ci --no-audit --no-fund)
fi
(cd web && npm_cmd run build)
