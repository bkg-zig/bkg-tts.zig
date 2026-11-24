// The WASM module carries the limits that the server contract fixes.
// Voices, languages, models and sample rates come from the HTTP API,
// because they depend on the loaded model.

export interface TtsWasm {
  bkg_tts_contract_version(): number
  bkg_tts_max_text_chars(): number
  bkg_tts_min_speed(): number
  bkg_tts_max_speed(): number
  bkg_tts_realtime_min_speed(): number
  bkg_tts_realtime_max_speed(): number
  bkg_tts_speed_allowed(speed: number): number
  bkg_tts_realtime_speed_allowed(speed: number): number
}

const REQUIRED_EXPORTS = [
  'bkg_tts_contract_version',
  'bkg_tts_max_text_chars',
  'bkg_tts_min_speed',
  'bkg_tts_max_speed',
  'bkg_tts_realtime_min_speed',
  'bkg_tts_realtime_max_speed',
  'bkg_tts_speed_allowed',
  'bkg_tts_realtime_speed_allowed',
] as const

let wasmPromise: Promise<TtsWasm> | undefined

export function loadTtsWasm(): Promise<TtsWasm> {
  if (!wasmPromise) {
    wasmPromise = (async () => {
      const response = await fetch('/wasm/bkg-tts-wasm.wasm', { cache: 'no-cache' })
      if (!response.ok) throw new Error(`The WASM module could not be loaded (${response.status}).`)
      const bytes = await response.arrayBuffer()
      const result = await WebAssembly.instantiate(bytes, {})
      const exports = result.instance.exports as unknown as TtsWasm
      for (const key of REQUIRED_EXPORTS) {
        if (typeof exports[key] !== 'function') throw new Error(`Incomplete WASM contract: ${key}`)
      }
      const version = exports.bkg_tts_contract_version()
      if (version !== 1) throw new Error(`Unsupported WASM contract version ${version}.`)
      return exports
    })().catch((error) => {
      wasmPromise = undefined
      throw error
    })
  }
  return wasmPromise
}
