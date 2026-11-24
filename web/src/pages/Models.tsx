import { useEffect, useState } from 'react'
import { activateModel, listModels, reloadRegistry, type ModelInfo } from '../api'
import { Card, Badge, Spinner } from '../components/ui'

export function Models() {
  const [models, setModels] = useState<ModelInfo[]>([])
  const [busy, setBusy] = useState<string | null>(null)
  const [log, setLog] = useState<string[]>([])
  const [error, setError] = useState<string | null>(null)

  const load = async () => {
    setModels(await listModels())
  }

  useEffect(() => {
    load().catch(() => {})
  }, [])

  const activate = async (model: ModelInfo) => {
    setBusy(model.id)
    setError(null)
    try {
      await activateModel(model)
      setLog((entries) => [...entries.slice(-40), `→ ${model.id}: active`])
      await load()
    } catch (e: any) {
      setError(`${model.id}: ${e.message}`)
    } finally {
      setBusy(null)
    }
  }

  const reload = async () => {
    setBusy('reload')
    setError(null)
    try {
      const summary = await reloadRegistry()
      setLog((entries) => [
        ...entries.slice(-40),
        `reload: +${summary.added.length} ~${summary.changed.length} -${summary.removed.length}, active ${summary.active_model ?? 'none'}`,
      ])
      await load()
    } catch (e: any) {
      setError(e.message)
    } finally {
      setBusy(null)
    }
  }

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">Models</h1>
      <p className="text-sm text-zinc-400">
        The registry lists every model directory that holds a descriptor. The active model runs on the CPU.
        A synthesis request with the field model switches the engine to that model.
      </p>
      <Card title="Registry">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase text-zinc-500">
              <th className="pb-2">Model</th>
              <th className="pb-2">Version</th>
              <th className="pb-2">Language</th>
              <th className="pb-2">Sample rate</th>
              <th className="pb-2">State</th>
              <th className="pb-2"></th>
            </tr>
          </thead>
          <tbody>
            {models.length === 0 && (
              <tr><td className="py-2 text-zinc-600" colSpan={6}>No model registered.</td></tr>
            )}
            {models.map((model) => (
              <tr key={model.id} className="border-t border-zinc-800">
                <td className="py-2 font-medium">{model.name}</td>
                <td className="py-2 mono text-zinc-400">{model.version}</td>
                <td className="py-2 mono">{model.language}</td>
                <td className="py-2 mono">{model.sample_rate} Hz</td>
                <td className="py-2">
                  {model.loaded ? <Badge color="green">active</Badge> : <Badge>{model.state}</Badge>}
                </td>
                <td className="py-2 text-right">
                  {model.loaded ? (
                    <span className="text-xs text-zinc-500">Loaded</span>
                  ) : (
                    <button className="btn text-xs" onClick={() => activate(model)} disabled={busy !== null}>
                      Activate
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="mt-3 flex items-center gap-2">
          <button className="btn" onClick={reload} disabled={busy !== null}>Reload registry</button>
          {busy === 'reload' && <Spinner label="reading the model directories" />}
          {busy !== null && busy !== 'reload' && <Spinner label={`switching to ${busy}`} />}
        </div>
      </Card>
      {error && <div className="text-sm text-red-400">{error}</div>}
      <Card title="Actions">
        <div className="mono text-xs space-y-1 h-40 overflow-y-auto">
          {log.length === 0 && <div className="text-zinc-600">No actions yet.</div>}
          {log.map((entry, index) => <div key={index}>{entry}</div>)}
        </div>
      </Card>
    </div>
  )
}
