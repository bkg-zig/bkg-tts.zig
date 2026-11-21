import { loadTtsWasm } from './wasm'
import { pcm16ToWav, pcmSampleRate } from './audio'

// Client for the BKG TTS HTTP API. Every list of models, voices and
// languages comes from the server, because the loaded model decides them.

const BASE = ''

export interface ModelInfo {
  id: string
  name: string
  version: string
  language: string
  sample_rate: number
  loaded: boolean
  state: string
}

export interface VoiceInfo {
  id: string
  name: string
  aliases: string[]
  default: boolean
}

export interface LanguageInfo {
  id: string
  name: string
}

export interface SystemInfo {
  status: string
  server: { version: string; name: string }
  remote: boolean
  model: {
    model_id: string
    state: string
    profile: string
    precision: string
    device: string
    revision: string
    loaded: boolean
  }
  gpu: { device: string; used_mb: number | null; total_mb: number | null; utilization: number | null }
  runtime: { active_sessions: number; queue_depth: number; completed: number; cancelled: number }
  stats: { requests: number; errors: number; cancelled: number }
}

export interface SelfTestResult {
  status: string
  passed: number
  total: number
  failed: number
  results: { name: string; passed: boolean; message: string; duration_ms: number }[]
  engine: string
  device: string
  sample_rate: number
  samples: number
  duration_s: number
  nonzero_samples: number
  peak: number
  rms: number
  generation_ms: number
}

export interface BenchmarkResult {
  status: string
  profile: string
  language: string
  concurrent_users: number
  iterations: number
  streaming: boolean
  generation_p50_ms: number
  generation_p95_ms: number
  generation_p99_ms: number
  generation_ms_total: number
  generation_ms_average: number
  audio_duration_s: number
  rtf: number
  requests_per_sec: number
  failures: number
  error_codes: string[]
}

export interface ReloadSummary {
  status: string
  scope: string
  added: string[]
  changed: string[]
  removed: string[]
  active_model: string | null
}

export async function api<T = any>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: { 'Content-Type': 'application/json', ...init?.headers },
  })
  if (!res.ok) {
    let body: any = null
    try { body = await res.json() } catch { /* no body */ }
    const msg = body?.error?.message || `${res.status} ${res.statusText}`
    throw new ApiError(msg, res.status, body?.error)
  }
  if (res.status === 204) return undefined as T
  const ct = res.headers.get('content-type') || ''
  if (ct.includes('application/json')) return res.json()
  return (await res.arrayBuffer()) as unknown as T
}

export class ApiError extends Error {
  status: number
  code?: string
  constructor(message: string, status: number, body?: any) {
    super(message)
    this.status = status
    this.code = body?.code
  }
}

export async function listModels(): Promise<ModelInfo[]> {
  const res = await api<{ data: ModelInfo[] }>('/v1/models')
  return res.data
}

export async function listVoices(): Promise<VoiceInfo[]> {
  const res = await api<{ data: VoiceInfo[] }>('/api/voices')
  return res.data
}

export async function listLanguages(): Promise<LanguageInfo[]> {
  const res = await api<{ data: LanguageInfo[] }>('/api/languages')
  return res.data
}

/** The model the engine has loaded, if the registry lists one. */
export async function activeModel(): Promise<ModelInfo | undefined> {
  const models = await listModels()
  return models.find((model) => model.loaded)
}

export interface SynthesisRequest {
  text: string
  language?: string
  voice?: string
  format?: 'wav' | 'pcm'
  speed?: number
  /** Naming another model switches the engine to it before the synthesis. */
  model?: string
  sampleRate?: number
}

export interface SynthesisResult {
  /** The bytes as the server sent them. */
  blob: Blob
  /** A playable object URL. PCM is wrapped in a WAV container. */
  url: string
  /** The object URL of the untouched server bytes. */
  rawUrl: string
  headers: Headers
  sampleRate: number
}

/** A short greeting, the same text the server uses for its own tests. */
export function greetingFor(language: string): string {
  const primary = language.toLowerCase().split(/[-_]/)[0]
  const greetings: Record<string, string> = {
    de: 'Guten Tag.',
    fr: 'Bonjour.',
    es: 'Buenos dias.',
    it: 'Buongiorno.',
    pt: 'Bom dia.',
  }
  return greetings[primary] ?? 'Hello world.'
}

export async function synthesize(params: SynthesisRequest): Promise<SynthesisResult> {
  const wasm = await loadTtsWasm()
  const text = params.text ?? ''
  if (text.length === 0) throw new ApiError('The text must not be empty.', 422)
  if (text.length > wasm.bkg_tts_max_text_chars()) {
    throw new ApiError(`The text exceeds the limit of ${wasm.bkg_tts_max_text_chars()} characters.`, 422)
  }
  const speed = params.speed ?? 1
  if (!wasm.bkg_tts_speed_allowed(speed)) {
    throw new ApiError(`The speed must lie between ${wasm.bkg_tts_min_speed()} and ${wasm.bkg_tts_max_speed()}.`, 422)
  }
  const format = params.format ?? 'wav'
  if (format !== 'wav' && format !== 'pcm') throw new ApiError('Only wav and pcm are available.', 422)

  const body: Record<string, unknown> = {
    input: text,
    response_format: format,
    speed,
  }
  if (params.language) body.language = params.language
  if (params.voice) body.voice = params.voice
  if (params.model) body.model = params.model
  // The sample rate belongs to the model. The server rejects a rate that
  // differs from the loaded model, so the client sends none.

  const res = await fetch(`${BASE}/v1/audio/speech`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    let body: any = null
    try { body = await res.json() } catch { /* no body */ }
    throw new ApiError(body?.error?.message || res.statusText, res.status, body?.error)
  }

  const contentType = res.headers.get('content-type') || ''
  const bytes = new Uint8Array(await res.arrayBuffer())
  const rawBlob = new Blob([bytes], { type: contentType || 'application/octet-stream' })
  const rawUrl = URL.createObjectURL(rawBlob)

  if (format === 'pcm') {
    const rate = pcmSampleRate(contentType) ?? params.sampleRate
    if (!rate) {
      URL.revokeObjectURL(rawUrl)
      throw new ApiError('The server did not report a sample rate for the PCM response.', 500)
    }
    const wav = new Blob([pcm16ToWav(bytes, rate)], { type: 'audio/wav' })
    return { blob: wav, url: URL.createObjectURL(wav), rawUrl, headers: res.headers, sampleRate: rate }
  }

  return { blob: rawBlob, url: rawUrl, rawUrl, headers: res.headers, sampleRate: params.sampleRate ?? 0 }
}

/** Switches the engine to another model through the `model` field. */
export async function activateModel(model: ModelInfo): Promise<void> {
  const result = await synthesize({
    text: greetingFor(model.language),
    language: model.language,
    model: model.id,
    format: 'wav',
  })
  URL.revokeObjectURL(result.url)
}

export async function runSelftest(): Promise<SelfTestResult> {
  return api<SelfTestResult>('/api/selftest', { method: 'POST' })
}

export async function runBenchmark(request: {
  text?: string
  language?: string
  voice?: string
  iterations?: number
}): Promise<BenchmarkResult> {
  return api<BenchmarkResult>('/api/benchmark', {
    method: 'POST',
    body: JSON.stringify({
      profile: 'cpu-default',
      concurrent_users: 1,
      streaming: false,
      iterations: 1,
      ...request,
    }),
  })
}

export async function reloadRegistry(): Promise<ReloadSummary> {
  return api<ReloadSummary>('/api/reload', { method: 'POST' })
}

export const wsUrl = (path: string) => {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws'
  return `${proto}://${location.host}${BASE}${path}`
}
