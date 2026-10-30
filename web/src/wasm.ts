export interface MagpieWasm {
  bkg_magpie_contract_version(): number
  bkg_magpie_max_text_chars(): number
  bkg_magpie_sample_rate_allowed(rate: number): number
  bkg_magpie_voice_index(voice: number): number
}

let wasmPromise: Promise<MagpieWasm> | undefined

export function loadMagpieWasm(): Promise<MagpieWasm> {
  if (!wasmPromise) {
    wasmPromise = (async () => {
      const response = await fetch('/wasm/bkg-magpietts-wasm.wasm', { cache: 'no-cache' })
      if (!response.ok) throw new Error(`WASM-Modul konnte nicht geladen werden (${response.status}).`)
      const bytes = await response.arrayBuffer()
      const result = await WebAssembly.instantiate(bytes, {})
      const exports = result.instance.exports as unknown as MagpieWasm
      for (const key of ['bkg_magpie_contract_version', 'bkg_magpie_max_text_chars', 'bkg_magpie_sample_rate_allowed', 'bkg_magpie_voice_index'] as const) {
        if (typeof exports[key] !== 'function') throw new Error(`WASM-Vertrag unvollständig: ${key}`)
      }
      if (exports.bkg_magpie_contract_version() !== 1) throw new Error('Nicht unterstützte WASM-Vertragsversion.')
      return exports
    })().catch((error) => {
      wasmPromise = undefined
      throw error
    })
  }
  return wasmPromise
}
