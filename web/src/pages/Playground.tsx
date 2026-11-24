import { useEffect, useState } from 'react'
import { greetingFor, listLanguages, listModels, listVoices, synthesize, type LanguageInfo, type ModelInfo, type VoiceInfo } from '../api'
import { loadTtsWasm } from '../wasm'
import { AudioPlayer } from '../components/AudioPlayer'
import { Card, Field, Badge, Spinner } from '../components/ui'

const FORMATS = ['wav', 'pcm'] as const

export function Playground() {
  const [models, setModels] = useState<ModelInfo[]>([])
  const [voices, setVoices] = useState<VoiceInfo[]>([])
  const [languages, setLanguages] = useState<LanguageInfo[]>([])
  const [modelId, setModelId] = useState('')
  const [voice, setVoice] = useState('')
  const [language, setLanguage] = useState('')
  const [text, setText] = useState('Hello world.')
  const [speed, setSpeed] = useState(1)
  const [format, setFormat] = useState<'wav' | 'pcm'>('wav')
  const [limits, setLimits] = useState({ min: 0.25, max: 4, chars: 5000 })
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<{ url: string; rawUrl: string; name: string } | null>(null)
  const [metrics, setMetrics] = useState<{ total_ms: number; bytes: number } | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = async () => {
    const [modelList, voiceList, languageList] = await Promise.all([
      listModels(),
      listVoices(),
      listLanguages(),
    ])
    setModels(modelList)
    setVoices(voiceList)
    setLanguages(languageList)
    const active = modelList.find((model) => model.loaded)
    if (active) {
      setModelId((current) => current || active.id)
      setLanguage((current) => current || active.language)
      setText((current) => (current === 'Hello world.' ? greetingFor(active.language) : current))
    }
    const firstVoice = voiceList.find((entry) => entry.default) ?? voiceList[0]
    setVoice((current) => current || firstVoice?.id || '')
  }

  useEffect(() => {
    load().catch(() => {})
    loadTtsWasm()
      .then((wasm) => setLimits({
        min: wasm.bkg_tts_min_speed(),
        max: wasm.bkg_tts_max_speed(),
        chars: wasm.bkg_tts_max_text_chars(),
      }))
      .catch(() => {})
  }, [])

  const selectedModel = models.find((model) => model.id === modelId)
  const sampleRate = selectedModel?.sample_rate ?? 0

  const run = async () => {
    setBusy(true)
    setError(null)
    setMetrics(null)
    if (result) {
      URL.revokeObjectURL(result.url)
      URL.revokeObjectURL(result.rawUrl)
    }
    setResult(null)
    try {
      const started = performance.now()
      const response = await synthesize({
        text,
        language: language || undefined,
        voice: voice || undefined,
        format,
        speed,
        model: modelId || undefined,
        sampleRate: sampleRate || undefined,
      })
      const elapsed = performance.now() - started
      setResult({
        url: response.url,
        rawUrl: response.rawUrl,
        name: `speech-${voice || 'default'}.${format}`,
      })
      setMetrics({ total_ms: Math.round(elapsed), bytes: response.blob.size })
      await load()
    } catch (e: any) {
      setError(e.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">TTS Playground</h1>
      <p className="text-sm text-zinc-400">
        The engine reads voices, languages and the sample rate from the model that is loaded.
        Naming another model in the request switches the engine to it.
      </p>
      <Card title="Input">
        <textarea
          className="input h-28"
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Text to synthesize"
        />
        <div className="mt-1 text-xs text-zinc-600">{text.length} / {limits.chars} characters</div>
        <div className="mt-4 grid grid-cols-2 md:grid-cols-4 gap-4">
          <Field label="Model">
            <select className="input" value={modelId} onChange={(e) => setModelId(e.target.value)}>
              {models.length === 0 && <option value="">no model registered</option>}
              {models.map((model) => (
                <option key={model.id} value={model.id}>
                  {model.id}{model.loaded ? ' (active)' : ''}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Voice">
            <select className="input" value={voice} onChange={(e) => setVoice(e.target.value)}>
              {voices.length === 0 && <option value="">no voices</option>}
              {voices.map((entry) => (
                <option key={entry.id} value={entry.id}>
                  {entry.name}{entry.aliases.length > 0 ? ` (${entry.aliases.join(', ')})` : ''}
                </option>
              ))}
            </select>
          </Field>
          <Field label="Language">
            <select className="input" value={language} onChange={(e) => setLanguage(e.target.value)}>
              {languages.length === 0 && <option value="">language of the model</option>}
              {languages.map((entry) => (
                <option key={entry.id} value={entry.id}>{entry.id}</option>
              ))}
            </select>
          </Field>
          <Field label="Format">
            <select className="input" value={format} onChange={(e) => setFormat(e.target.value as 'wav' | 'pcm')}>
              {FORMATS.map((entry) => <option key={entry} value={entry}>{entry}</option>)}
            </select>
          </Field>
          <Field label={`Speed: ${speed.toFixed(2)}x`}>
            <input
              type="range"
              min={limits.min}
              max={limits.max}
              step={0.05}
              value={speed}
              onChange={(e) => setSpeed(Number(e.target.value))}
              className="w-full"
            />
          </Field>
          <Field label="Sample rate" hint="Fixed by the model">
            <div className="input mono flex items-center">{sampleRate ? `${sampleRate} Hz` : '—'}</div>
          </Field>
        </div>
        <div className="mt-4 flex gap-2">
          <button className="btn-primary" onClick={run} disabled={busy || !text.trim()}>
            {busy ? 'Generating…' : 'Generate'}
          </button>
          {busy && <Spinner label="synthesizing" />}
        </div>
      </Card>
      {error && (
        <Card title="Error">
          <div className="text-red-400 text-sm">{error}</div>
        </Card>
      )}
      {metrics && (
        <div className="flex flex-wrap gap-3">
          <Badge color="green">total {metrics.total_ms} ms</Badge>
          <Badge color="blue">{metrics.bytes} bytes</Badge>
          {format === 'pcm' && <Badge>playback uses a WAV wrapper, the download holds the raw PCM</Badge>}
        </div>
      )}
      {result && (
        <Card title="Result">
          <AudioPlayer src={result.url} downloadSrc={result.rawUrl} name={result.name} />
        </Card>
      )}
    </div>
  )
}
