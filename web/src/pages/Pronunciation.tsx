import { useEffect, useState } from 'react'
import { api, listLanguages, synthesize } from '../api'
import { AudioPlayer } from '../components/AudioPlayer'
import { Card, Badge } from '../components/ui'

interface Entry { word: string; language: string; ipa: string; enabled: boolean }

export function Pronunciation() {
  const [entries, setEntries] = useState<Entry[]>([])
  const [languages, setLanguages] = useState<string[]>([])
  const [word, setWord] = useState('')
  const [language, setLanguage] = useState('')
  const [ipa, setIpa] = useState('')
  const [enabled, setEnabled] = useState(true)
  const [testResult, setTestResult] = useState<{ url: string; rawUrl: string; name: string } | null>(null)
  const [testWord, setTestWord] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  const load = () => api<{ data: Entry[] }>('/api/tts/pronunciation').then((r) => setEntries(r.data)).catch(() => {})
  useEffect(() => { load() }, [])
  useEffect(() => {
    listLanguages()
      .then((list) => setLanguages(list.map((entry) => entry.id)))
      .catch(() => {})
  }, [])

  const save = async () => {
    if (!word.trim() || !ipa.trim()) return
    try {
      await api('/api/tts/pronunciation', {
        method: 'POST',
        body: JSON.stringify({ word, language, ipa, enabled }),
      })
      setWord('')
      setIpa('')
      setMessage(`Saved "${word}"`)
      load()
    } catch (e: any) {
      setMessage(e.message)
    }
  }

  const remove = async (entry: Entry) => {
    try {
      await api(`/api/tts/pronunciation/${encodeURIComponent(entry.word)}?language=${encodeURIComponent(entry.language)}`, { method: 'DELETE' })
      load()
    } catch (e: any) {
      setMessage(e.message)
    }
  }

  const test = async (entry: Entry) => {
    setBusy(true)
    setTestWord(entry.word)
    try {
      const response = await synthesize({ text: entry.word, language: entry.language, format: 'wav' })
      if (testResult) URL.revokeObjectURL(testResult.url)
      setTestResult({ url: response.url, rawUrl: response.rawUrl, name: `pron-${entry.word}.wav` })
    } catch (e: any) {
      setMessage(`test failed: ${e.message}`)
    }
    setBusy(false)
  }

  return (
    <div className="space-y-6 max-w-6xl">
      <h1 className="text-2xl font-bold">Pronunciation dictionary</h1>
      <p className="text-sm text-zinc-400">
        A rule replaces the word at a word boundary with the IPA in the bars. The engine applies the rules
        of the requested language, with English as the fallback.
      </p>
      <Card title="New entry">
        <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
          <input className="input" placeholder="Word" value={word} onChange={(e) => setWord(e.target.value)} />
          <input
            className="input"
            placeholder="Language"
            list="pronunciation-languages"
            value={language}
            onChange={(e) => setLanguage(e.target.value)}
          />
          <datalist id="pronunciation-languages">
            {languages.map((entry) => <option key={entry} value={entry} />)}
          </datalist>
          <input className="input md:col-span-2" placeholder="IPA, for example b aɪ oʊ l æ s t ɪ k" value={ipa} onChange={(e) => setIpa(e.target.value)} />
          <div className="flex items-center gap-2">
            <label className="flex items-center gap-1 text-xs text-zinc-400">
              <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} className="h-4 w-4 accent-indigo-500" />
              enabled
            </label>
            <button className="btn-primary" onClick={save} disabled={!word.trim() || !ipa.trim()}>Save</button>
          </div>
        </div>
      </Card>
      {message && <div className="text-sm text-zinc-400">{message}</div>}
      <Card title={`Entries (${entries.length})`}>
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase text-zinc-500">
              <th className="pb-2">Word</th><th className="pb-2">Language</th>
              <th className="pb-2">IPA</th><th className="pb-2">Enabled</th><th className="pb-2">Actions</th>
            </tr>
          </thead>
          <tbody className="mono">
            {entries.length === 0 && (
              <tr><td className="py-2 text-zinc-600" colSpan={5}>No entry yet.</td></tr>
            )}
            {entries.map((entry) => (
              <tr key={`${entry.word}-${entry.language}`} className="border-t border-zinc-800">
                <td className="py-2">{entry.word}</td>
                <td className="py-2">{entry.language}</td>
                <td className="py-2 text-zinc-400">| {entry.ipa} |</td>
                <td className="py-2">{entry.enabled ? <Badge color="green">on</Badge> : <Badge>off</Badge>}</td>
                <td className="py-2 flex gap-2">
                  <button className="btn text-xs" onClick={() => test(entry)} disabled={busy}>
                    {testWord === entry.word && busy ? '…' : 'test'}
                  </button>
                  <button className="btn text-xs" onClick={() => remove(entry)}>remove</button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {testResult && (
          <div className="mt-4">
            <AudioPlayer src={testResult.url} downloadSrc={testResult.rawUrl} name={testResult.name} />
          </div>
        )}
      </Card>
    </div>
  )
}
