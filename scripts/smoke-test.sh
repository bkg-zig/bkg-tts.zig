#!/usr/bin/env bash
set -euo pipefail
BASE_URL="${BASE_URL:-http://127.0.0.1:18093}"
CURL="curl --silent --show-error"
expect_code() {
  local expected="$1"; shift
  local actual
  actual="$($CURL -o /tmp/bkg-magpietts-smoke.body -w '%{http_code}' "$@")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected HTTP $expected, got $actual for $*" >&2
    cat /tmp/bkg-magpietts-smoke.body >&2 || true
    exit 1
  fi
  printf 'HTTP %s  %s\n' "$actual" "$*"
}
expect_code 200 "$BASE_URL/health"
expect_code 200 "$BASE_URL/ready"
expect_code 200 "$BASE_URL/api/system"
expect_code 200 "$BASE_URL/v1/models"
expect_code 200 "$BASE_URL/api/voices"
expect_code 200 "$BASE_URL/api/languages"
expect_code 200 "$BASE_URL/docs"
expect_code 200 "$BASE_URL/redoc"
expect_code 200 "$BASE_URL/openapi.json"
expect_code 200 "$BASE_URL/"
expect_code 200 "$BASE_URL/wasm/bkg-magpietts-wasm.wasm"
expect_code 405 "$BASE_URL/v1/audio/speech"
$CURL "$BASE_URL/openapi.json" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const x=JSON.parse(s);if(x.openapi!=="3.1.0"||!x.paths["/v1/realtime"])process.exit(1);console.log("OPENAPI_OK",Object.keys(x.paths).length,"paths")})'
echo "HTTP smoke tests passed."
