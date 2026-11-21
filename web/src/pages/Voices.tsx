import { useEffect, useState } from 'react'
import { listLanguages, listVoices, synthesize, type LanguageInfo, type VoiceInfo } from '../api'
import { AudioPlayer } from '../components/AudioPlayer'
import { Card, Badge, Spinner } from '../components/ui'

export function Voices() {
  const [voices, setVoices] = useState<VoiceInfo[]>([])
  const [languages, setLanguages] = useState<LanguageInfo[]>([])
  const [language, setLanguage] = useState('')
  const [text, setText] = useState('Hello world.')
  const [results, setResults] = useState<Record<string, { url: string; rawUrl: string } | null>>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const load = async () => {
    const [voiceList, languageList] = await Promise.all([listVoices(), listLanguages()])
    setVoices(voiceList)
    setLanguages(languageList)
    setLanguage((current) => current || languageList[0]?.id || '')
  }

  useEffect(() => {
    load().catch(() => {})
  }, [])

  const runAll = async () => {
    setBusy(true)
    setError(null)
    for (const voice of voices) {
      try {
        const response = await synthesize({ text, language: language || undefined, voice: voice.id, format: 'wav' })
        setResults((previous) => {
          const old = previous[voice.id]
          if (old) URL.revokeObjectURL(old.url)
          return { ...previous, [voice.id]: { url: response.url, rawUrl: response.rawUrl } }
        })
      } catch (e: any) {
        setError(`Voice ${voice.id}: ${e.message}`)
      }
    }
    setBusy(false)
  }

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">Voice matrix</h1>
      <p className="text-sm text-zinc-400">
        The voices come from the model that is loaded. The engine reads them from the model descriptor.
      </p>
      <Card title="Same text through every voice">
        <textarea className="input h-24" value={text} onChange={(e) => setText(e.target.value)} />
        <div className="mt-3 flex gap-3 items-center flex-wrap">
          <select className="input w-48" value={language} onChange={(e) => setLanguage(e.target.value)}>
            {languages.length === 0 && <option value="">language of the model</option>}
            {languages.map((entry) => <option key={entry.id} value={entry.id}>{entry.id}</option>)}
          </select>
          <button className="btn-primary" onClick={runAll} disabled={busy || voices.length === 0}>
            Generate {voices.length} voices
          </button>
          {busy && <Spinner label="generating" />}
        </div>
      </Card>
      {error && <div className="text-red-400 text-sm">{error}</div>}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {voices.map((voice) => (
          <Card
            key={voice.id}
            title={
              <span className="flex items-center gap-2">
                {voice.name}
                {voice.default && <Badge color="green">default</Badge>}
              </span>
            }
          >
            {voice.aliases.length > 0 && (
              <div className="mb-2 text-xs text-zinc-500">aliases: {voice.aliases.join(', ')}</div>
            )}
            {results[voice.id] ? (
              <AudioPlayer
                src={results[voice.id]!.url}
                downloadSrc={results[voice.id]!.rawUrl}
                name={`voice-${voice.id}.wav`}
              />
            ) : (
              <div className="text-sm text-zinc-600">Not generated yet.</div>
            )}
          </Card>
        ))}
      </div>
    </div>
  )
}
