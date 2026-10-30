import { useState } from 'react'
import { runBenchmark } from '../api'
import { Card, Field, Badge, Spinner } from '../components/ui'

export function Performance() {
  const [profile, setProfile] = useState('cpu-default')
  const [users, setUsers] = useState(1)
  const [language, setLanguage] = useState('en')
  const [iterations, setIterations] = useState(3)
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<any>(null)
  const [error, setError] = useState<string | null>(null)

  const run = async () => {
    setBusy(true); setError(null); setResult(null)
    try {
      setResult(await runBenchmark({
        profile, concurrent_users: users, language, iterations, streaming: false,
      }))
    } catch (e: any) {
      setError(e.message)
    }
    setBusy(false)
  }

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">Benchmark Lab</h1>
      <p className="text-sm text-zinc-400">Misst echte serielle Synthese-Laufzeiten. Die aktuelle C-ABI liefert erst nach abgeschlossener Phrase Audio; TTFA und GPU-/VRAM-Werte werden deshalb nicht vorgetäuscht.</p>
      <Card title="Configuration">
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <Field label="Profile">
            <select className="input" value={profile} onChange={(e) => setProfile(e.target.value)}>
              <option value="cpu-default">cpu-default</option>
            </select>
          </Field>
          <Field label="Concurrent users">
            <select className="input" value={users} onChange={(e) => setUsers(Number(e.target.value))}>
              <option value={1}>1 (serial C-ABI)</option>
            </select>
          </Field>
          <Field label="Language">
            <select className="input" value={language} onChange={(e) => setLanguage(e.target.value)}>
              <option value="en">English</option>
              <option value="hi">Hindi</option>
            </select>
          </Field>
          <Field label="Iterations">
            <input type="number" min={1} max={10} className="input" value={iterations}
                   onChange={(e) => setIterations(Number(e.target.value))} />
          </Field>
        </div>
        <div className="mt-3">
          <button className="btn-primary" onClick={run} disabled={busy}>
            {busy ? 'Benchmarking…' : 'Run benchmark'}
          </button>
          {busy && <Spinner label={`${users} worker(s) × ${iterations} iters`} />}
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
            <Metric label="Peak VRAM" value={result.peak_vram_mb == null ? 'N/A (CPU)' : `${result.peak_vram_mb.toFixed(0)} MB`} />
            <Metric label="Avg VRAM" value={result.avg_vram_mb == null ? 'N/A (CPU)' : `${result.avg_vram_mb.toFixed(0)} MB`} />
            <Metric label="GPU util" value={result.gpu_util_pct == null ? 'N/A (CPU)' : `${result.gpu_util_pct.toFixed(1)}%`} sub={result.gpu_temp_c == null ? 'CPU-only engine' : `temp ${result.gpu_temp_c.toFixed(0)}°C`} />
            <Metric label="Throughput" value={`${result.requests_per_sec.toFixed(2)} req/s`} />
            <Metric label="Total audio" value={`${result.audio_duration_s.toFixed(1)} s`} />
            <Metric label="Failures" value={result.failures}
                    sub={result.error_codes.join(', ')} />
          </div>
          <div className="mt-3 flex gap-2">
            <Badge color="green">done</Badge>
            <Badge color="zinc">{result.profile}</Badge>
            <Badge color="blue">{result.language}</Badge>
          </div>
        </Card>
      )}
    </div>
  )
}

function Metric({ label, value, sub }: { label: string; value: any; sub?: string }) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/60 p-3">
      <div className="text-xs uppercase tracking-wide text-zinc-500">{label}</div>
      <div className="mt-1 text-lg font-semibold mono">{value}</div>
      {sub && <div className="text-xs text-zinc-500 mt-0.5">{sub}</div>}
    </div>
  )
}
