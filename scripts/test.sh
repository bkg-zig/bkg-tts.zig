#!/usr/bin/env bash
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
cp zig-out/bin/bkg-magpietts-wasm.wasm web/public/wasm/bkg-magpietts-wasm.wasm
(cd web && npm_cmd run build)
node - <<'JS'
const fs = require('fs');
(async () => {
  const bytes = fs.readFileSync('zig-out/bin/bkg-magpietts-wasm.wasm');
  const {instance, module} = await WebAssembly.instantiate(bytes, {});
  const e = instance.exports;
  if (e.bkg_magpie_contract_version() !== 1) throw new Error('bad WASM contract version');
  if (e.bkg_magpie_sample_rate_allowed(22050) !== 1 || e.bkg_magpie_sample_rate_allowed(44100) !== 0) throw new Error('bad sample-rate validation');
  if (e.bkg_magpie_voice_index(4) !== 4 || e.bkg_magpie_voice_index(5) !== 255) throw new Error('bad voice validation');
  if (WebAssembly.Module.imports(module).length !== 0) throw new Error('WASM is not freestanding');
  console.log('WASM_OK exports=' + Object.keys(e).join(','));
})().catch(e => { console.error(e); process.exit(1); });
JS
