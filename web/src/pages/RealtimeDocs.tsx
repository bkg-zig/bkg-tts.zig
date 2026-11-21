import { Card } from '../components/ui'

const LIFECYCLE = `CONNECT  ws://SERVER/v1/realtime?intent=synthesize
  |
  |  { "type": "session.created", "session_id": "sess_1", "voice": "<voice>", "language": "<language>", "format": "pcm", "sample_rate": <rate> }   <- server
  |
  |  { "type": "session.update", "session": { "voice": "<voice>", "language": "<language>", "format": "pcm", "sample_rate": <rate>, "speed": 1.0 } }
  |  { "type": "session.updated" }                <- server
  |
  |  { "type": "input_text.append", "text": "Hello " }   (text fragments)
  |  { "type": "input_text.append", "text": "world." }
  |  { "type": "input_text.commit" }
  |
  |  { "type": "response.created" }               <- server
  |  { "type": "audio.chunk", "data": "<base64>", "format": "pcm", "sample_rate": <rate>, "chunk_index": 0 }   xN
  |  { "type": "response.completed", "duration_s": 1.234, "ttfa_ms": 210.5 }   <- server
  |
  |  { "type": "response.cancel" }                (client, clears the text buffer)
  |  { "type": "response.cancelled", "cancelled_jobs": 1 }   <- server
`

const CLIENT_EVENTS = [
  {
    name: 'session.update',
    payload: `{
  "type": "session.update",
  "session": {
    "voice": "<voice>",
    "language": "<language>",
    "format": "pcm",
    "sample_rate": 24000,
    "speed": 1.0
  }
}`,
  },
  { name: 'input_text.append', payload: `{ "type": "input_text.append", "text": "Hello " }` },
  { name: 'input_text.commit', payload: `{ "type": "input_text.commit" }` },
  { name: 'response.cancel', payload: `{ "type": "response.cancel" }` },
  { name: 'ping', payload: `{ "type": "ping" }` },
]

const SERVER_EVENTS = [
  {
    name: 'session.created',
    payload: `{
  "type": "session.created",
  "session_id": "sess_1",
  "request_id": "req_1",
  "voice": "<voice>",
  "language": "<language>",
  "format": "pcm",
  "sample_rate": 24000
}`,
  },
  {
    name: 'session.updated',
    payload: `{
  "type": "session.updated",
  "session_id": "sess_1",
  "session": {
    "voice": "<voice>",
    "language": "<language>",
    "format": "pcm",
    "sample_rate": 24000,
    "speed": 1.00,
    "text_normalization": false,
    "cfg_enabled": false
  }
}`,
  },
  { name: 'response.created', payload: `{ "type": "response.created", "session_id": "sess_1" }` },
  {
    name: 'audio.chunk',
    payload: `{
  "type": "audio.chunk",
  "session_id": "sess_1",
  "data": "<base64 of PCM16>",
  "format": "pcm",
  "sample_rate": 24000,
  "chunk_index": 0
}`,
  },
  {
    name: 'response.completed',
    payload: `{ "type": "response.completed", "session_id": "sess_1", "duration_s": 1.234, "ttfa_ms": 210.5 }`,
  },
  {
    name: 'response.cancelled',
    payload: `{ "type": "response.cancelled", "session_id": "sess_1", "cancelled_jobs": 1 }`,
  },
  {
    name: 'error',
    payload: `{
  "type": "error",
  "error": {
    "code": "INVALID_VOICE",
    "message": "Das Modell kennt die angeforderte Stimme nicht.",
    "retryable": false,
    "session_id": "sess_1"
  }
}`,
  },
  { name: 'pong', payload: `{ "type": "pong", "session_id": "sess_1" }` },
]

const ERROR_CODES = [
  'INVALID_VOICE',
  'UNSUPPORTED_LANGUAGE',
  'UNSUPPORTED_FORMAT',
  'INVALID_SAMPLE_RATE',
  'UNSUPPORTED_SETTING',
  'INVALID_REQUEST',
  'INPUT_TOO_LONG',
  'MODEL_NOT_READY',
  'SYNTHESIS_FAILED',
  'PRONUNCIATION_APPLY_FAILED',
  'WEBSOCKET_PROTOCOL_ERROR',
]

export function RealtimeDocs() {
  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">Realtime WebSocket protocol</h1>
      <Card title="Connection lifecycle">
        <pre className="mono text-xs text-zinc-300 overflow-x-auto">{LIFECYCLE}</pre>
      </Card>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <Card title="Client events">
          <div className="space-y-3">
            {CLIENT_EVENTS.map((event) => (
              <div key={event.name}>
                <div className="text-sm font-semibold text-sky-400">→ {event.name}</div>
                <pre className="mono text-[11px] text-zinc-400 bg-zinc-950 rounded p-2 overflow-x-auto">{event.payload}</pre>
              </div>
            ))}
          </div>
        </Card>
        <Card title="Server events">
          <div className="space-y-3">
            {SERVER_EVENTS.map((event) => (
              <div key={event.name}>
                <div className="text-sm font-semibold text-emerald-400">← {event.name}</div>
                <pre className="mono text-[11px] text-zinc-400 bg-zinc-950 rounded p-2 overflow-x-auto">{event.payload}</pre>
              </div>
            ))}
          </div>
        </Card>
      </div>
      <Card title="Rules of the session">
        <ul className="list-disc pl-5 space-y-1 text-sm text-zinc-400">
          <li>The voice, the language and the sample rate come from the active model.</li>
          <li>The speed must lie between 0.5 and 2.0. Other values are refused with UNSUPPORTED_SETTING.</li>
          <li>The format must be pcm. Other formats are refused with UNSUPPORTED_FORMAT.</li>
          <li>A sample rate that differs from the model rate is refused with INVALID_SAMPLE_RATE.</li>
          <li>The fields cfg_enabled, cfg_scale and text_normalization are not available.</li>
          <li>A synthesis starts when an appended fragment contains . ? ! ; : , or a newline, otherwise on input_text.commit.</li>
          <li>The text buffer holds at most 5000 bytes. A larger buffer is dropped with INPUT_TOO_LONG.</li>
          <li>Every audio chunk holds 200 ms of mono PCM16.</li>
        </ul>
      </Card>
      <Card title="Error codes">
        <div className="flex flex-wrap gap-2">
          {ERROR_CODES.map((code) => (
            <span key={code} className="mono text-xs bg-zinc-950 rounded px-2 py-1 text-zinc-400">{code}</span>
          ))}
        </div>
      </Card>
    </div>
  )
}
