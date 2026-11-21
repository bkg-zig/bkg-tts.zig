import { useEffect, useState } from 'react'
import { listLanguages, listModels, listVoices } from '../api'
import { Card, Badge } from '../components/ui'

interface Endpoint {
  method: string
  path: string
  note: string
}

// Every route the server classifies. The list mirrors src/router.zig.
const ENDPOINTS: Endpoint[] = [
  { method: 'GET', path: '/health', note: 'liveness of the process' },
  { method: 'GET', path: '/ready', note: 'a model is loaded' },
  { method: 'GET', path: '/api/system', note: 'state of the engine' },
  { method: 'GET', path: '/metrics', note: 'Prometheus text format' },
  { method: 'GET', path: '/v1/models', note: 'registered models' },
  { method: 'GET', path: '/v1/models/{id}', note: 'one model' },
  { method: 'POST', path: '/v1/audio/speech', note: 'OpenAI compatible synthesis' },
  { method: 'POST', path: '/v1/audio/cancel', note: 'not implemented by the engine' },
  { method: 'GET', path: '/v1/audio/voices', note: 'voices of the active model' },
  { method: 'GET', path: '/api/voices', note: 'voices of the active model' },
  { method: 'GET', path: '/api/languages', note: 'languages of the active model' },
  { method: 'POST', path: '/api/tts/generate', note: 'native synthesis' },
  { method: 'GET', path: '/api/tts/pronunciation', note: 'pronunciation dictionary' },
  { method: 'POST', path: '/api/tts/pronunciation', note: 'writes one entry' },
  { method: 'DELETE', path: '/api/tts/pronunciation/{word}', note: 'removes one entry' },
  { method: 'POST', path: '/api/tts/pronunciation/test', note: 'speaks one word' },
  { method: 'GET', path: '/api/profiles', note: 'the engine has one profile' },
  { method: 'POST', path: '/api/profiles/switch', note: 'answers 409, there is only one profile' },
  { method: 'POST', path: '/api/selftest', note: 'one real synthesis with measurements' },
  { method: 'GET', path: '/api/logs', note: 'request log of the process' },
  { method: 'POST', path: '/api/reload', note: 'reloads the registry and the dictionary' },
  { method: 'POST', path: '/api/benchmark', note: 'timings of real syntheses' },
  { method: 'GET', path: '/openapi.json', note: 'API schema' },
]

interface LiveData {
  model: string
  voice: string
  language: string
}

const EMPTY_LIVE: LiveData = { model: '', voice: '', language: '' }

function bodyFor(path: string, live: LiveData): unknown {
  if (path.startsWith('/v1/audio/speech')) {
    return {
      model: live.model || undefined,
      input: 'Hello world.',
      voice: live.voice || undefined,
      language: live.language || undefined,
      response_format: 'wav',
      speed: 1,
    }
  }
  if (path.startsWith('/api/tts/generate')) {
    return {
      text: 'Hello world.',
      speaker: live.voice || undefined,
      audio: { format: 'wav' },
      speed: 1,
    }
  }
  if (path.startsWith('/api/benchmark')) {
    return { profile: 'cpu-default', concurrent_users: 1, streaming: false, iterations: 1 }
  }
  if (path === '/api/tts/pronunciation') {
    return { word: 'example', language: live.language || 'en', ipa: 'e g z æ m p əl', enabled: true }
  }
  if (path.startsWith('/api/tts/pronunciation/test')) {
    return { word: 'example', language: live.language || 'en' }
  }
  return {}
}

const CURL_TEMPLATE = (method: string, path: string, body: string) =>
  `curl -X ${method} ${location.origin}${path} \\\n  -H "Content-Type: application/json" \\\n  -d '${body.replace(/\n/g, ' ')}'`

const PY_TEMPLATE = (method: string, path: string, body: string) =>
  `import httpx, json

r = httpx.request(
    method="${method}",
    url="${location.origin}${path}",
    json=json.loads('''${body.replace(/'/g, "\\'")}'''),
)
print(r.status_code, r.content[:200])`

const JS_TEMPLATE = (method: string, path: string, body: string) =>
  `const res = await fetch("${location.origin}${path}", {
  method: "${method}",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(${body}),
});
console.log(res.status, await res.arrayBuffer());`

export function ApiTester() {
  const [method, setMethod] = useState('POST')
  const [path, setPath] = useState('/v1/audio/speech')
  const [body, setBody] = useState('')
  const [live, setLive] = useState<LiveData>(EMPTY_LIVE)
  const [status, setStatus] = useState<number | null>(null)
  const [response, setResponse] = useState('')
  const [duration, setDuration] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    Promise.all([listModels(), listVoices(), listLanguages()])
      .then(([models, voices, languages]) => {
        const active = models.find((model) => model.loaded) ?? models[0]
        const next: LiveData = {
          model: active?.id ?? '',
          voice: voices.find((voice) => voice.default)?.id ?? voices[0]?.id ?? '',
          language: active?.language ?? languages[0]?.id ?? '',
        }
        setLive(next)
        setBody(JSON.stringify(bodyFor(path, next), null, 2))
      })
      .catch(() => {})
  }, [path])

  const selectPath = (nextPath: string) => {
    setPath(nextPath)
    setBody(JSON.stringify(bodyFor(nextPath, live), null, 2))
  }

  const send = async () => {
    setBusy(true)
    setResponse('')
    try {
      const started = performance.now()
      const res = await fetch(path, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: method === 'GET' ? undefined : body,
      })
      setStatus(res.status)
      setDuration(performance.now() - started)
      const contentType = res.headers.get('content-type') || ''
      const buffer = await res.arrayBuffer()
      if (contentType.includes('json')) {
        setResponse(JSON.stringify(JSON.parse(new TextDecoder().decode(buffer)), null, 2))
      } else {
        setResponse(`[${contentType || 'unknown type'}] ${buffer.byteLength} bytes`)
      }
    } catch (e: any) {
      setStatus(-1)
      setResponse(String(e))
    }
    setBusy(false)
  }

  const statusColor = status === null ? 'zinc' : status < 400 ? 'green' : status === 409 || status === 429 ? 'amber' : 'red'
  const selected = ENDPOINTS.find((entry) => entry.path === path)

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">API tester</h1>
      <Card title="Request">
        <div className="flex gap-2 flex-wrap">
          <select className="input w-28" value={method} onChange={(e) => setMethod(e.target.value)}>
            {['GET', 'POST', 'DELETE'].map((entry) => <option key={entry}>{entry}</option>)}
          </select>
          <select className="input flex-1 min-w-72" value={path} onChange={(e) => selectPath(e.target.value)}>
            {ENDPOINTS.map((entry) => (
              <option key={`${entry.method} ${entry.path}`} value={entry.path}>
                {entry.method} {entry.path}
              </option>
            ))}
          </select>
          <button className="btn-primary" onClick={send} disabled={busy}>{busy ? '…' : 'Send'}</button>
        </div>
        {selected && <div className="mt-2 text-xs text-zinc-500">{selected.note}</div>}
        {method !== 'GET' && (
          <textarea className="input mt-3 h-44 mono text-xs" value={body} onChange={(e) => setBody(e.target.value)} />
        )}
        <div className="mt-2 flex items-center gap-3">
          {status !== null && <Badge color={statusColor}>{status} · {duration?.toFixed(0)} ms</Badge>}
        </div>
      </Card>
      {response && (
        <Card title="Response">
          <pre className="mono text-xs text-zinc-300 overflow-x-auto max-h-96 overflow-y-auto">{response}</pre>
        </Card>
      )}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <Card title="Equivalent curl">
          <pre className="mono text-[11px] text-zinc-400 overflow-x-auto whitespace-pre-wrap">{CURL_TEMPLATE(method, path, body)}</pre>
        </Card>
        <Card title="Equivalent Python">
          <pre className="mono text-[11px] text-zinc-400 overflow-x-auto whitespace-pre-wrap">{PY_TEMPLATE(method, path, body)}</pre>
        </Card>
        <Card title="Equivalent JavaScript">
          <pre className="mono text-[11px] text-zinc-400 overflow-x-auto whitespace-pre-wrap">{JS_TEMPLATE(method, path, body)}</pre>
        </Card>
      </div>
    </div>
  )
}
