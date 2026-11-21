// Helpers for the raw PCM that the server returns next to WAV.

/** Wraps mono PCM16 data in a WAV container so the browser can play it. */
export function pcm16ToWav(pcm: Uint8Array, sampleRate: number): ArrayBuffer {
  const buffer = new ArrayBuffer(44 + pcm.length)
  const view = new DataView(buffer)
  const writeAscii = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i += 1) view.setUint8(offset + i, text.charCodeAt(i))
  }
  writeAscii(0, 'RIFF')
  view.setUint32(4, 36 + pcm.length, true)
  writeAscii(8, 'WAVE')
  writeAscii(12, 'fmt ')
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true)
  view.setUint16(22, 1, true)
  view.setUint32(24, sampleRate, true)
  view.setUint32(28, sampleRate * 2, true)
  view.setUint16(32, 2, true)
  view.setUint16(34, 16, true)
  writeAscii(36, 'data')
  view.setUint32(40, pcm.length, true)
  new Uint8Array(buffer, 44).set(pcm)
  return buffer
}

/** Reads the sample rate from a `audio/pcm;rate=24000;channels=1` header. */
export function pcmSampleRate(contentType: string | null): number | undefined {
  const match = /rate=(\d+)/.exec(contentType || '')
  if (!match) return undefined
  const rate = Number(match[1])
  return Number.isFinite(rate) && rate > 0 ? rate : undefined
}
