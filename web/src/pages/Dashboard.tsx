import { useEffect, useState } from 'react'
import { activeModel, type ModelInfo, type SystemInfo } from '../api'
import { Card, Stat, Badge } from '../components/ui'

export function Dashboard({ sys, onNav }: { sys: SystemInfo | null; onNav: (p: string) => void }) {
  const [model, setModel] = useState<ModelInfo | undefined>(undefined)

  useEffect(() => {
    activeModel().then(setModel).catch(() => setModel(undefined))
  }, [sys?.model?.model_id])

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">Dashboard</h1>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <Stat label="Server" value={<Badge color={sys ? 'green' : 'red'}>{sys ? sys.status : 'OFFLINE'}</Badge>} sub={sys?.server?.name} />
        <Stat label="Model" value={sys?.model?.model_id || '—'} sub={`state ${sys?.model?.state || '—'}`} />
        <Stat label="Device" value={sys?.model?.device || '—'} sub={sys?.model?.precision} />
        <Stat label="Sample rate" value={model ? `${model.sample_rate} Hz` : '—'} sub={model?.language} />
        <Stat label="Active sessions" value={sys?.runtime?.active_sessions ?? 0} sub={`queue ${sys?.runtime?.queue_depth ?? 0}`} />
        <Stat label="Completed" value={sys?.runtime?.completed ?? 0} sub={`cancelled ${sys?.runtime?.cancelled ?? 0}`} />
        <Stat label="Requests" value={sys?.stats?.requests ?? 0} sub={`errors ${sys?.stats?.errors ?? 0}`} />
        <Stat label="Runtime" value={sys?.model?.revision || '—'} sub={sys?.model?.profile} />
      </div>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <button className="btn h-20 flex flex-col items-center justify-center gap-1" onClick={() => onNav('playground')}>
          <span className="text-lg">◉</span> TTS Playground
        </button>
        <button className="btn h-20 flex flex-col items-center justify-center gap-1" onClick={() => onNav('realtime')}>
          <span className="text-lg">⇄</span> Realtime Lab
        </button>
        <button className="btn h-20 flex flex-col items-center justify-center gap-1" onClick={() => onNav('selftest')}>
          <span className="text-lg">✓</span> Self Test
        </button>
        <button className="btn h-20 flex flex-col items-center justify-center gap-1" onClick={() => onNav('performance')}>
          <span className="text-lg">∿</span> Benchmark
        </button>
      </div>
      <Card title="Model state">
        <pre className="mono text-xs text-zinc-400 overflow-x-auto">{JSON.stringify(sys?.model ?? {}, null, 2)}</pre>
      </Card>
    </div>
  )
}
