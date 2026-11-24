import { useEffect, useRef, useState } from 'react'
import { activeModel, listLanguages, listVoices, wsUrl, type LanguageInfo, type VoiceInfo } from '../api'
import { pcm16ToWav } from '../audio'
import { loadTtsWasm } from '../wasm'
import { AudioPlayer } from '../components/AudioPlayer'
import { Card, Field, Badge, Spinner } from '../components/ui'

const DEMO_TEXT = 'Hello world. The engine reads the voices from the model. Every chunk carries the sample rate of that model.'

export function RealtimeLab() {
  const wsRef = useRef<WebSocket | null>(null)
  const clipRef = useRef<Uint8Array[]>([])
  const clipSeqRef = useRef(0)
  const [connected, setConnected] = useState(false)
  const [text, setText] = useState(DEMO_TEXT)
  const [tokenRate, setTokenRate] = useState(12)
  const [language, setLanguage] = useState('')
  const [voice, setVoice] = useState('')
  const [sampleRate, setSampleRate] = useState(0)
  const [speed, setSpeed] = useState(1)
  const [limits, setLimits] = useState({ min: 0.5, max: 2 })
  const [voices, setVoices] = useState<VoiceInfo[]>([])
  const [languages, setLanguages] = useState<LanguageInfo[]>([])
  const [log, setLog] = useState<{ dir: string; msg: string }[]>([])
  const [clips, setClips] = useState<{ id: number; url: string; duration: number; ttfa: number }[]>([])
  const [streaming, setStreaming] = useState(false)
  const [chunkCount, setChunkCount] = useState(0)

  const pushLog = (dir: string, msg: string) => {
    setLog((previous) => [...previous.slice(-150), { dir, msg }])
  }

  useEffect(() => {
    Promise.all([listVoices(), listLanguages(), activeModel()])
      .then(([voiceList, languageList, model]) => {
        setVoices(voiceList)
        setLanguages(languageList)
        setVoice((current) => current || voiceList.find((entry) => entry.default)?.id || voiceList[0]?.id || '')
        setLanguage((current) => current || model?.language || languageList[0]?.id || '')
        setSampleRate(model?.sample_rate ?? 0)
      })
      .catch(() => {})
    loadTtsWasm()
      .then((wasm) => setLimits({
        min: wasm.bkg_tts_realtime_min_speed(),
        max: wasm.bkg_tts_realtime_max_speed(),
      }))
      .catch(() => {})
  }, [])

  useEffect(() => () => { wsRef.current?.close() }, [])

  const finalizeClip = (duration: number, ttfa: number) => {
    const parts = clipRef.current
    clipRef.current = []
    const total = parts.reduce((sum, part) => sum + part.length, 0)
    if (total === 0 || sampleRate === 0) return
    const pcm = new Uint8Array(total)
    let offset = 0
    for (const part of parts) {
      pcm.set(part, offset)
      offset += part.length
    }
    const wav = new Blob([pcm16ToWav(pcm, sampleRate)], { type: 'audio/wav' })
    setClips((previous) => [...previous, { id: ++clipSeqRef.current, url: URL.createObjectURL(wav), duration, ttfa }])
  }

  const connect = () => {
    wsRef.current?.close()
    const ws = new WebSocket(wsUrl('/v1/realtime?intent=synthesize'))
    wsRef.current = ws
    ws.onopen = () => {
      setConnected(true)
      ws.send(JSON.stringify({
        type: 'session.update',
        session: {
          voice,
          language,
          format: 'pcm',
          sample_rate: sampleRate,
          speed,
        },
      }))
    }
    ws.onmessage = (event) => {
      const message = JSON.parse(event.data)
      if (message.type === 'session.created' || message.type === 'session.updated') {
        pushLog('←', `${message.type} (voice ${message.session?.voice ?? message.voice}, ${message.session?.sample_rate ?? message.sample_rate} Hz)`)
      } else if (message.type === 'response.created') {
        clipRef.current = []
        pushLog('←', 'response.created')
      } else if (message.type === 'audio.chunk') {
        clipRef.current.push(Uint8Array.from(atob(message.data), (char) => char.charCodeAt(0)))
        setChunkCount((count) => count + 1)
        pushLog('←', `audio.chunk #${message.chunk_index}`)
      } else if (message.type === 'response.completed') {
        pushLog('←', `response.completed (${message.duration_s}s, ${message.ttfa_ms} ms)`)
        finalizeClip(message.duration_s ?? 0, message.ttfa_ms ?? 0)
      } else if (message.type === 'response.cancelled') {
        pushLog('←', 'response.cancelled')
        clipRef.current = []
      } else if (message.type === 'error') {
        pushLog('←', `error: ${message.error?.code} ${message.error?.message}`)
      } else {
        pushLog('←', message.type)
      }
    }
    ws.onclose = () => { setConnected(false); pushLog('•', 'disconnected') }
    ws.onerror = () => pushLog('•', 'websocket error')
  }

  const startStream = async () => {
    connect()
    setStreaming(true)
    setLog([])
    setClips([])
    setChunkCount(0)
    clipRef.current = []
    const ws = wsRef.current
    if (!ws) return
    if (ws.readyState !== WebSocket.OPEN) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, 5000)
        ws.addEventListener('open', () => { clearTimeout(timer); resolve() }, { once: true })
      })
      if (wsRef.current?.readyState !== WebSocket.OPEN) {
        pushLog('•', 'the websocket did not open')
        setStreaming(false)
        return
      }
    }
    let index = 0
    while (index < text.length) {
      if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) break
      const chunk = text.slice(index, index + tokenRate)
      pushLog('→', `input_text.append "${chunk}"`)
      wsRef.current.send(JSON.stringify({ type: 'input_text.append', text: chunk }))
      index += tokenRate
      await new Promise((resolve) => setTimeout(resolve, 40))
    }
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      pushLog('→', 'input_text.commit')
      wsRef.current.send(JSON.stringify({ type: 'input_text.commit' }))
    }
    setStreaming(false)
  }

  const cancel = () => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      pushLog('→', 'response.cancel')
      wsRef.current.send(JSON.stringify({ type: 'response.cancel' }))
    }
  }

  const disconnect = () => {
    wsRef.current?.close()
    setConnected(false)
  }

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">Realtime lab</h1>
      <Card title="Session">
        <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
          <Field label="Voice">
            <select className="input" value={voice} onChange={(e) => setVoice(e.target.value)}>
              {voices.length === 0 && <option value="">no voices</option>}
              {voices.map((entry) => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
            </select>
          </Field>
          <Field label="Language">
            <select className="input" value={language} onChange={(e) => setLanguage(e.target.value)}>
              {languages.length === 0 && <option value="">language of the model</option>}
              {languages.map((entry) => <option key={entry.id} value={entry.id}>{entry.id}</option>)}
            </select>
          </Field>
          <Field label="Sample rate" hint="Fixed by the model">
            <div className="input mono flex items-center">{sampleRate ? `${sampleRate} Hz` : '—'}</div>
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
          <Field label="Characters per step">
            <input type="number" min={1} max={50} className="input" value={tokenRate}
                   onChange={(e) => setTokenRate(Number(e.target.value))} />
          </Field>
        </div>
      </Card>

      <Card title="Stream text">
        <textarea className="input h-24" value={text} onChange={(e) => setText(e.target.value)} />
        <div className="mt-3 flex gap-2 flex-wrap items-center">
          <button className="btn-primary" onClick={startStream} disabled={streaming}>Start</button>
          <button className="btn-danger" onClick={cancel} disabled={!connected}>Cancel</button>
          <button className="btn" onClick={disconnect} disabled={!connected}>Disconnect</button>
          {connected && <Badge color="green">connected</Badge>}
          {streaming && <Spinner label="sending" />}
        </div>
        <p className="mt-3 text-xs text-zinc-500">
          The server starts a synthesis as soon as an appended fragment contains . ? ! ; : , or a newline.
          The commit event starts it in any case.
        </p>
      </Card>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <Card title="Event timeline">
          <div className="h-72 overflow-y-auto mono text-xs space-y-0.5">
            {log.length === 0 && <div className="text-zinc-600">No events yet.</div>}
            {log.map((entry, index) => (
              <div key={index} className={entry.dir === '→' ? 'text-sky-400' : entry.dir === '←' ? 'text-emerald-400' : 'text-zinc-500'}>
                {entry.dir} {entry.msg}
              </div>
            ))}
          </div>
        </Card>
        <Card title="Received audio">
          {clips.length === 0 ? (
            <div className="text-zinc-600 text-sm">The chunks arrive here.</div>
          ) : (
            <div className="space-y-2">
              {clips.map((clip, index) => (
                <div key={clip.id} className="flex items-center gap-2">
                  <span className="mono text-xs text-zinc-500 w-20 shrink-0">phrase {index + 1}</span>
                  <div className="flex-1 min-w-0">
                    <AudioPlayer src={clip.url} name={`phrase-${index + 1}.wav`} />
                  </div>
                  <span className="mono text-xs text-zinc-500 shrink-0">{clip.duration.toFixed(2)}s</span>
                </div>
              ))}
            </div>
          )}
          <div className="mt-2 text-xs text-zinc-500">
            {chunkCount} chunks at {sampleRate || '—'} Hz, assembled client side into playable WAV clips.
          </div>
        </Card>
      </div>
    </div>
  )
}
