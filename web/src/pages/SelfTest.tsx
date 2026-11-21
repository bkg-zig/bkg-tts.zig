import { useState } from 'react'
import { runSelftest, type SelfTestResult } from '../api'
import { Card, Badge, Spinner } from '../components/ui'

const TEST_NAMES: Record<string, string> = {
  test_native_generation: 'Native generation',
}

export function SelfTest() {
  const [result, setResult] = useState<SelfTestResult | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const run = async () => {
    setBusy(true)
    setError(null)
    setResult(null)
    try {
      setResult(await runSelftest())
    } catch (e: any) {
      setError(e.message)
    }
    setBusy(false)
  }

  return (
    <div className="space-y-6 max-w-4xl">
      <h1 className="text-2xl font-bold">Self test</h1>
      <p className="text-sm text-zinc-400">
        The server runs one real synthesis with the text of the active model and measures the result.
      </p>
      <button className="btn-primary" onClick={run} disabled={busy}>
        {busy ? 'Running…' : 'Run self test'}
      </button>
      {busy && <Spinner label="synthesizing" />}
      {error && <div className="text-sm text-red-400">{error}</div>}
      {result && (
        <>
          <Card title="Results">
            <div className="mb-4 text-lg font-semibold">
              {result.passed} / {result.total} passed
              {result.failed > 0 && <span className="text-red-400 ml-2">{result.failed} failed</span>}
            </div>
            <table className="w-full text-sm">
              <tbody>
                {result.results.map((entry) => (
                  <tr key={entry.name} className="border-t border-zinc-800">
                    <td className="py-1.5">{TEST_NAMES[entry.name] ?? entry.name}</td>
                    <td className="py-1.5">
                      {entry.passed ? <Badge color="green">passed</Badge> : <Badge color="red">failed</Badge>}
                    </td>
                    <td className="py-1.5 text-xs text-zinc-500 max-w-md truncate" title={entry.message}>{entry.message}</td>
                    <td className="py-1.5 text-xs text-zinc-600 mono">{entry.duration_ms.toFixed(0)} ms</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </Card>
          <Card title="Measurement">
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              <Metric label="Engine" value={result.engine} />
              <Metric label="Device" value={result.device} />
              <Metric label="Sample rate" value={`${result.sample_rate} Hz`} />
              <Metric label="Samples" value={result.samples} />
              <Metric label="Duration" value={`${result.duration_s.toFixed(3)} s`} />
              <Metric label="Nonzero samples" value={result.nonzero_samples} />
              <Metric label="Peak" value={result.peak.toFixed(5)} />
              <Metric label="RMS" value={result.rms.toFixed(5)} />
              <Metric label="Generation" value={`${result.generation_ms.toFixed(0)} ms`} />
            </div>
          </Card>
        </>
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
