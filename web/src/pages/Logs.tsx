import { useEffect, useState } from 'react'
import { api } from '../api'
import { Card } from '../components/ui'

interface LogLine {
  request_id: number
  method: string
  route: string
  status: number
  elapsed_ms: number
}

export function Logs() {
  const [lines, setLines] = useState<string[]>([])
  const [auto, setAuto] = useState(true)

  const load = () => api<{ lines: LogLine[] }>('/api/logs?lines=128')
    .then((r) => setLines(r.lines.map((entry) =>
      `req_${entry.request_id} ${entry.method} ${entry.route} ${entry.status} ${entry.elapsed_ms}ms`)))
    .catch(() => {})

  useEffect(() => {
    load()
    let id: ReturnType<typeof setInterval> | null = null
    if (auto) {
      id = setInterval(load, 3000)
    }
    return () => { if (id) clearInterval(id) }
  }, [auto])

  return (
    <div className="space-y-4 max-w-6xl">
      <div className="flex items-center gap-3">
        <h1 className="text-2xl font-bold">Logs</h1>
        <label className="flex items-center gap-1.5 text-sm text-zinc-400">
          <input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} className="h-4 w-4 accent-indigo-500" />
          auto refresh
        </label>
        <button className="btn" onClick={load}>Refresh</button>
      </div>
      <Card>
        <pre className="mono text-[11px] text-zinc-300 overflow-x-auto h-[70vh] overflow-y-auto whitespace-pre-wrap">
          {lines.length === 0 ? 'No requests recorded yet.' : lines.join('\n')}
        </pre>
      </Card>
    </div>
  )
}
