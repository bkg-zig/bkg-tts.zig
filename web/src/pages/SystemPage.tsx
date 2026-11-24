import type { SystemInfo } from '../api'
import { Card, Stat, Badge } from '../components/ui'

export function SystemPage({ sys }: { sys: SystemInfo | null }) {
  const gpu = sys?.gpu
  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">System</h1>
      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <Stat
          label="Status"
          value={<Badge color={sys?.status === 'ready' ? 'green' : 'amber'}>{sys?.status ?? 'offline'}</Badge>}
          sub={sys?.remote ? 'remote' : 'local'}
        />
        <Stat label="Server" value={sys?.server?.name ?? '—'} sub={`version ${sys?.server?.version ?? '—'}`} />
        <Stat label="Model" value={sys?.model?.model_id || '—'} sub={`state ${sys?.model?.state ?? '—'}`} />
        <Stat label="Device" value={sys?.model?.device ?? '—'} sub={sys?.model?.precision} />
        <Stat label="Profile" value={sys?.model?.profile ?? '—'} sub={sys?.model?.revision} />
        <Stat label="Active sessions" value={sys?.runtime?.active_sessions ?? 0} sub={`queue ${sys?.runtime?.queue_depth ?? 0}`} />
        <Stat label="Completed" value={sys?.runtime?.completed ?? 0} sub={`cancelled ${sys?.runtime?.cancelled ?? 0}`} />
        <Stat label="Requests" value={sys?.stats?.requests ?? 0} sub={`errors ${sys?.stats?.errors ?? 0}`} />
        <Stat label="GPU" value={gpu?.device ?? '—'} sub="the engine reports no GPU memory values" />
      </div>
      <Card title="Payload of /api/system">
        <pre className="mono text-xs text-zinc-400 overflow-x-auto">{JSON.stringify(sys, null, 2)}</pre>
      </Card>
    </div>
  )
}
