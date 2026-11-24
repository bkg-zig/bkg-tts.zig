import { useEffect, useState } from 'react'
import { listLanguages, listVoices, runBenchmark, type LanguageInfo, type VoiceInfo } from '../api'
import { Card, Field, Badge, Spinner } from '../components/ui'

export function Performance() {
  const [voices, setVoices] = useState<VoiceInfo[]>([])
  const [languages, setLanguages] = useState<LanguageInfo[]>([])
  const [language, setLanguage] = useState('')
  const [voice, setVoice] = useState('')
  const [text, setText] = useState('')
  const [iterations, setIterations] = useState(3)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<Awaited<ReturnType<typeof runBenchmark>> | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    Promise.all([listVoices(), listLanguages()])
      .then(([voiceList, languageList]) => {
        setVoices(voiceList)
        setLanguages(languageList)
        setLanguage((current) => current || languageList[0]?.id || '')
        setVoice((current) => current || voiceList.find((entry) => entry.default)?.id || voiceList[0]?.id || '')
      })
      .catch(() => {})
  }, [])

  const run = async () => {
    setBusy(true)
    setError(null)
    setResult(null)
    try {
      setResult(await runBenchmark({
        text: text || undefined,
        language: language || undefined,
        voice: voice || undefined,
        iterations,
      }))
    } catch (e: any) {
      setError(e.message)
    }
    setBusy(false)
  }

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">Benchmark</h1>
      <p className="text-sm text-zinc-400">
        The engine measures real syntheses. It runs them one after the other, because the single model
        context cannot serve several requests at the same time.
      </p>
      <Card title="Configuration">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <Field label="Language">
            <select className="input" value={language} onChange={(e) => setLanguage(e.target.value)}>
              {languages.length === 0 && <option value="">language of the model</option>}
              {languages.map((entry) => <option key={entry.id} value={entry.id}>{entry.id}</option>)}
            </select>
          </Field>
          <Field label="Voice">
            <select className="input" value={voice} onChange={(e) => setVoice(e.target.value)}>
              {voices.length === 0 && <option value="">default voice</option>}
              {voices.map((entry) => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
            </select>
          </Field>
          <Field label="Iterations" hint="1 to 10">
            <input type="number" min={1} max={10} className="input" value={iterations}
                   onChange={(e) => setIterations(Number(e.target.value))} />
          </Field>
          <Field label="Text" hint="empty means the text of the model">
            <input className="input" value={text} onChange={(e) => setText(e.target.value)} />
          </Field>
        </div>
        <div className="mt-3 flex items-center gap-2">
          <button className="btn-primary" onClick={run} disabled={busy}>
            {busy ? 'Benchmarking…' : 'Run benchmark'}
          </button>
          {busy && <Spinner label={`${iterations} iterations`} />}
        </div>
      </Card>
      {error && <div className="text-sm text-red-400">{error}</div>}
      {result && (
        <Card title="Results">
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            <Metric label="Generation P50" value={`${result.generation_p50_ms.toFixed(1)} ms`} />
            <Metric label="Generation P95" value={`${result.generation_p95_ms.toFixed(1)} ms`} />
            <Metric label="Generation P99" value={`${result.generation_p99_ms.toFixed(1)} ms`} />
            <Metric label="RTF" value={result.rtf.toFixed(4)} />
            <Metric label="Total time" value={`${result.generation_ms_total.toFixed(0)} ms`} />
            <Metric label="Average time" value={`${result.generation_ms_average.toFixed(0)} ms`} />
            <Metric label="Throughput" value={`${result.requests_per_sec.toFixed(2)} req/s`} />
            <Metric label="Audio length" value={`${result.audio_duration_s.toFixed(2)} s`} />
            <Metric label="Failures" value={result.failures} />
            <Metric label="Errors" value={result.error_codes.length > 0 ? result.error_codes.join(', ') : 'none'} />
          </div>
          <div className="mt-3 flex gap-2 flex-wrap">
            <Badge color="green">{result.status}</Badge>
            <Badge>{result.profile}</Badge>
            <Badge color="blue">{result.language}</Badge>
            <Badge>{result.iterations} iterations</Badge>
            <Badge>concurrent users {result.concurrent_users}</Badge>
          </div>
        </Card>
      )}
    </div>
  )
}

function Metric({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-3">
      <div className="text-xs uppercase tracking-wide text-zinc-500">{label}</div>
      <div className="mt-1 text-lg font-semibold mono">{value}</div>
    </div>
  )
}
