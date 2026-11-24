#!/usr/bin/env bash
# Baut Server, Tests, WASM-Modul und Weboberflaeche und prueft den
# WASM-Vertrag im Browser-Format.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
zig build
zig build test
zig build wasm
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
cp zig-out/bin/bkg-tts-wasm.wasm web/public/wasm/bkg-tts-wasm.wasm
(cd web && npm_cmd run build)
node - <<'JS'
const fs = require('fs');
(async () => {
  const bytes = fs.readFileSync('zig-out/bin/bkg-tts-wasm.wasm');
  const {instance, module} = await WebAssembly.instantiate(bytes, {});
  const e = instance.exports;
  if (e.bkg_tts_contract_version() !== 1) throw new Error('bad WASM contract version');
  if (e.bkg_tts_max_text_chars() !== 5000) throw new Error('bad text limit');
  if (e.bkg_tts_speed_allowed(0.25) !== 1 || e.bkg_tts_speed_allowed(4.01) !== 0) throw new Error('bad tempo validation');
  if (e.bkg_tts_realtime_speed_allowed(0.5) !== 1 || e.bkg_tts_realtime_speed_allowed(2.01) !== 0) throw new Error('bad realtime tempo validation');
  if (WebAssembly.Module.imports(module).length !== 0) throw new Error('WASM is not freestanding');
  console.log('WASM_OK exports=' + Object.keys(e).join(','));
})().catch(e => { console.error(e); process.exit(1); });
JS
