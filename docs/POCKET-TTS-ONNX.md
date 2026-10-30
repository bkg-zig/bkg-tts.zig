# Pocket-TTS-ONNX: verifizierter Laufzeitvertrag

Stand: 2026-10-29. Zweck: eine eigene Zig-Implementierung über die ONNX-Runtime-C-API soll denselben Vertrag fahren wie die Python- und TypeScript-Laufzeiten des Upstream-Projekts. Alle Zahlen, Namen und Shapes in diesem Dokument sind an echten Dateien aus dem Hub-Repo `thewh1teagle/pocket-tts-onnx` gemessen. Werte, die sich nicht messen ließen, stehen als offener Punkt am Ende.

## Prüfmethode

- ONNX Runtime 1.22.0 liegt lokal unter `~/.local/share/onnxruntime`. Das Prüfprogramm `/home/openchamber/.cache/probe/onnx_io.c` öffnet eine Session und liest Ein- und Ausgänge samt Shapes zur Laufzeit.
- Für Graph-Struktur, Metadaten und das SentencePiece-Proto dient der eigene Protobuf-Parser `/home/openchamber/dump/pocket-research/inspect_onnx.py`. Auf dem Host sind weder `onnx` noch `onnxruntime` als Python-Paket installiert.
- Die Laufzeitsemantik stammt aus dem Upstream-Quelltext unter `/home/openchamber/dump/upstream-clones/pocket-tts`. Zeilenangaben in diesem Dokument beziehen sich auf diesen Stand.

Der Hub-Repo-Bestand wurde über die Tree-API und der Release `models-v1.0` über die GitHub-API geprüft.

## Dateien im Hub-Repo

42 Einträge.

| Pfad | Bytes | Zweck |
|---|---:|---|
| `.gitattributes` | | Repo-Konfiguration |
| `README.md` | | Modellbeschreibung |
| `pocket-tts-english.onnx` | 228144283 | Single-File, Englisch, alle Metadaten enthalten |
| `pocket-tts-english-ipa.onnx` | 231924037 | Single-File, Englisch mit Hebräisch-Adapter |
| `renikud.onnx` | 20620594 | Sprechermodell, nicht Teil des Step-Graphs |
| `de/`, `en/`, `es/`, `fr/`, `he/`, `it/`, `pt/` | | Web-Asset-Sets, je `model.onnx`, `encoder.onnx`, `assets.json`, `manifest.json` |
| `en/renikud.onnx`, `he/renikud.onnx` | | Sprechermodell in den englischen und hebräischen Asset-Sets |

Eine deutsche Single-File gibt es weder im Hub-Repo noch im Release. `hub.py::model_filename` erzeugt für `german` den Namen `pocket-tts-german.onnx`, den das Repo nicht enthält. Deutsch läuft ausschließlich über das Asset-Set `de/`.

## Step-Graph: Ein- und Ausgänge

An `de/model.onnx` per ORT geprüft, 12 Eingänge und 7 Ausgänge. Die englischen Dateien liefern dieselben Namen und dieselben dynamischen Achsen.

| Eingang | Typ | Shape |
|---|---|---|
| `tokens` | int64 | [1, seq] |
| `latent` | float32 | [1, seq, 32] |
| `is_bos` | float32 | [1, seq, 1] |
| `cond` | float32 | [1, seq, 1024] |
| `gates` | float32 | [3] |
| `noise` | float32 | [1, 32] |
| `flow_kv` | float32 | [past, 6, 2, 1, 16, 64] |
| `flow_offset` | int64 | Skalar |
| `mimi_kv` | float32 | [266, 2, 2, 1, 8, 64] |
| `mimi_offset` | int64 | Skalar |
| `mimi_conv` | float32 | [14720] |
| `decode_steps` | float32 | Skalar |

| Ausgang | Typ | Shape |
|---|---|---|
| `audio` | float32 | [1, 1, 1920] |
| `next_latent` | float32 | [1, 1, 32] |
| `eos_logit` | float32 | [1, 1] |
| `flow_kv_new` | float32 | [seq, 6, 2, 1, 16, 64] |
| `mimi_kv_new` | float32 | [16, 2, 2, 1, 8, 64] |
| `mimi_offset_out` | int64 | Skalar |
| `mimi_conv_out` | float32 | [14720] |

Nur `pocket-tts-english-ipa.onnx` hat zusätzlich den Eingang `lora` float32 als Skalar. Er aktiviert den Hebräisch-Adapter und ist in `tts.py:498` und `tts.ts:628` mit 0 oder 1 zu belegen.

Namen und Reihenfolge stehen in `src/pocket_tts_onnx/export/step_model.py:422-446`.

## Gates und Ablauf

Drei Gates, siehe `packages/pocket-tts-onnx/src/tts.ts:25-27` und `src/pocket_tts_onnx/tts.py:32`.

| Gate | Wert | Bedeutung |
|---|---|---|
| Text | [1, 0, 0] | Der Text-Prompt wird eingebettet |
| Latent | [0, 1, 0] | Das zuletzt erzeugte Latent wird eingebettet |
| Cond | [0, 0, 1] | Das Stimm-Conditioning wird eingebettet |

Die Mischung im Graph (`step_model.py:255-258`): `flow_input = gates[0] * text + gates[1] * input_linear(latent) + gates[2] * cond`. Ist `is_bos > 0`, ersetzt der Graph das Latent durch `bos_emb`.

Ablauf pro Stimme und Chunk (`tts.py:320-385`):

1. Voice-Prefill, einmal pro Stimme und Adapter-Gate. Ein Lauf mit `gates` Cond, `cond` [1, T, 1024], `seq` T und Nullrauschen. Das Ergebnis `flow_kv_new` wird als Präfix gehalten (`tts.py:423-463`).
2. Text-Prompt. Ein Lauf mit `gates` Text, `tokens` [1, N], `seq` N und Nullrauschen, `flow_kv` mit dem Voice-Präfix (`tts.py:342-354`).
3. Latent-Schritte. Je Frame ein Lauf mit `gates` Latent, `seq` 1, `latent` [1, 1, 32], `is_bos` beim ersten Schritt 1 und danach 0, und neuem Rauschen je Frame (`tts.py:356-385`).

## Cache

- `flow_kv` wächst mit jedem Schritt. Übergeben wird der volle Puffer, `flow_offset` zählt die Einträge (`tts.py:491-492`). Nach jedem Chunk wird der Puffer auf die Voice-Länge zurückgesetzt (`tts.py:333`).
- `mimi_kv` ist immer die letzten 266 Einträge, vorne nullgepolstert, solange der Puffer kürzer ist (`tts.py:93-103` und `tts.py:493`).
- `mimi_offset` und `mimi_conv` mit 14720 Werten sind Zustand über die Frames eines Chunks.

## Metadaten der Single-File-Modelle

Der Export schreibt genau vier Schlüssel (`src/pocket_tts_onnx/export/export.py:253-312`).

| Schlüssel | Inhalt |
|---|---|
| `pocket_tts_config` | JSON mit allen Laufzeitwerten |
| `pocket_tts_tokenizer` | base64 der SentencePiece-`.model`-Datei |
| `pocket_tts_encoder` | base64 des ONNX-Encoders |
| `pocket_tts_voice/<name>` | base64 der float16-Rohbytes der Stimme |

Für Zig liefert das ONNX-Runtime-Header die passenden Aufrufe: `SessionGetModelMetadata` (`onnxruntime_c_api.h:2125`), `ModelMetadataLookupCustomMetadataMap` (`:2185`) und `ModelMetadataGetCustomMetadataMapKeys` (`:2262`).

## pocket_tts_config

| Feld | Englisch | Deutsch |
|---|---:|---:|
| `sample_rate` | 24000 | 24000 |
| `frame_rate` | 12.5 | 12.5 |
| `frame_size` | 1920 | 1920 |
| `latent_dim` | 32 | 32 |
| `model_dim` | 1024 | 1024 |
| `flow_layers` | 6 | 6 |
| `flow_heads` | 16 | 16 |
| `flow_head_dim` | 64 | 64 |
| `mimi_layers` | 2 | 2 |
| `mimi_heads` | 8 | 8 |
| `mimi_head_dim` | 64 | 64 |
| `mimi_kv_len` | 266 | 266 |
| `mimi_steps_per_latent` | 16 | 16 |
| `conv_state_size` | 14720 | 14720 |
| `sampler_decode_steps` | 1 | 1 |
| `max_decode_steps` | 4 | 4 |
| `temperature` | 0.3 | 0.7 |
| `noise_clamp` | null | null |
| `eos_threshold` | -4.0 | -4.0 |
| `max_tokens_per_chunk` | 50 | 50 |
| `pad_with_spaces_for_short_inputs` | false | false |
| `remove_semicolons` | false | true |
| `frames_after_eos` | null | null |
| `tokens_per_second_estimate` | 3.0 | 3.0 |
| `gen_seconds_padding` | 2.0 | 2.0 |
| `language` | english | german |
| `quantized` | true | true |

Die englischen Werte stammen aus `pocket_tts_config` von `pocket-tts-english.onnx`, die deutschen aus dem `config`-Objekt von `de/assets.json`.

Stimmen und ihre Conditioning-Shapes:

| Datei | Stimme | Shape |
|---|---|---|
| `pocket-tts-english.onnx` | alba, cosette, marius, javert | [126, 1024] |
| `pocket-tts-english.onnx` | anna | [159, 1024] |
| `pocket-tts-english.onnx` | michael | [148, 1024] |
| `pocket-tts-english-ipa.onnx` | omer | [47, 1024] |
| `pocket-tts-english-ipa.onnx` | liat | [96, 1024] |
| `de/assets.json` | juergen | [127, 1024] |
| `de/assets.json` | alba | [126, 1024] |

`pocket-tts-english-ipa.onnx` trägt zusätzlich `voice_languages` und `lora` mit `atomic_chars`, `vocab_base` 4001, `step` 5000 und den Defaults `frames_after_eos` 2, `temperature` 0.3, `max_tokens_per_chunk` 200.

## Tokenizer

Das Proto liegt in `pocket_tts_tokenizer` als base64 der SentencePiece-`.model`-Datei. Englisch 59339 Bytes, Deutsch 59837 Bytes.

| Eigenschaft | Wert |
|---|---|
| `vocab_size` | 4000 |
| Pieces | 4000, davon 3740 NORMAL, 1 UNKNOWN, 3 CONTROL, 256 BYTE |
| `unk_id` | 0 |
| `bos_id` | 1 |
| `eos_id` | 2 |
| `pad_id` | 3 |
| `byte_fallback` | true |
| `add_dummy_prefix` | true |
| `remove_extra_whitespaces` | false |
| USER_DEFINED | keine |

Die TypeScript-Laufzeit liest aus dem Proto nur Pieces, Scores, Typen und `add_dummy_prefix`. Die Segmentierung ist Viterbi über die Pieces mit Byte-Fallback (`packages/pocket-tts-onnx/src/sentencepiece.ts:144-199`). Die CONTROL-Pieces `<s>`, `</s>` und `<pad>` sind vorhanden, werden im Textpfad aber nicht eingefügt. Das BOS im Textpfad ist das Float-Flag `is_bos`.

## Stimmkodierung

`pocket_tts_voice/<name>` enthält die float16-Rohbytes der Conditioning-Matrix in der Reihenfolge des Base64-Dekoders, ohne Header. Die Shape steht in `config.voices`, sie reicht von [47, 1024] bei omer bis [159, 1024] bei anna. Die Umwandlung nach float32 steht in `tts.ts:253`, der Abruf in `tts.ts:309-313`.

Eigene Stimmen entstehen durch den Encoder: Audio [1, 1, samples] hinein, `cond` [1, frames, 1024] heraus (`tts.ts:333`).

## Sampling und Decoding

- Kein top-p und kein Token-Sampling. Eine Suche in den Python- und TypeScript-Dateien des Upstream-Clones nach `top_p`, `topk` oder `top-k` findet nichts.
- Das Rauschen je Frame ist N(0,1) mal `sqrt(temperature)`. Python nutzt `np.random.default_rng(seed)` (`tts.py:306` und `tts.py:389-399`), TypeScript mulberry32 mit Box-Muller (`tts.ts:228` und `tts.ts:241`), Aufruf in `tts.ts:452`. `noise_clamp` ist null, also greift kein Clamp.
- Der Flow-Sampler ist im Graph bis `max_decode_steps` 4 unrolled. Die Zahl der aktiven Schritte steht im Eingang `decode_steps` als float32-Skalar, erlaubt sind 1 bis 4 (`tts.py:298-304`, `step_model.py:260-274`).
- EOS: `eos_logit > eos_threshold` mit -4.0 markiert das Frame. Der Lauf bricht ab, sobald `frame >= eos_frame + frames_after_eos`, und zwar vor dem Ausliefern des Audios, das Frame entfällt also (`tts.py:381-385`, gleich in `tts.ts:467-469`).
- `frames_after_eos` null bedeutet Schätzung plus 2. Die Schätzung ist 3 bei höchstens 4 Wörtern und sonst 1 (`text.py:40`, `tts.py:327-329`, `tts.ts:427`).
- Ein Frame sind 1920 Samples bei 24 kHz, also 80 ms. 12.5 Frames pro Sekunde.

## Chunking und Textaufbereitung

`max_tokens_per_chunk` ist 50 für Englisch und Deutsch, der Adapter nutzt 200. `split_into_best_sentences` (`src/pocket_tts_onnx/text.py`) und `text.ts:158-175` teilen an Satzgrenzen und fassen Chunks zusammen, bis das Tokenbudget passt.

`prepare_text_prompt` (`text.py:30-48`) macht daraus den Prompt:

- trimmen, Zeilenumbrüche und carriage returns zu Spaces, dann einmal `  ` durch ` ` ersetzen.
- Semikolons optional durch Kommas ersetzen, im deutschen Modell aktiv.
- Der erste Buchstabe wird groß, am Ende wird ein Punkt ergänzt, wenn das letzte Zeichen alphanumerisch ist.
- Optional acht Leerzeichen voran, wenn der Text weniger als fünf Wörter hat. Im englischen und deutschen Modell ist `pad_with_spaces_for_short_inputs` false.

Die maximale Framezahl je Chunk folgt aus `ceil((token_count / tokens_per_second_estimate + gen_seconds_padding) * frame_rate)`, also `ceil((N / 3.0 + 2.0) * 12.5)` (`tts.py:401-404`).

## Encoder

`de/encoder.onnx` hat 39183564 Bytes, sha256 `80e0efae03c43e2ca1252874095fa1df4a2f36c5140246c9349810de70abdd50`.

| Eigenschaft | Wert |
|---|---|
| Eingang | `audio` float32 [1, 1, -1] |
| Ausgang | `cond` float32 [1, -1, 1024] |
| `ir_version` | 8 |
| Producer | pytorch |
| Opset | ai.onnx 17 |
| Nodes | 553 |
| Initializers | 45 |
| Quantisierung | keine |

Der Encoder bleibt float32. Der Step-Graph dagegen ist quantisiert und enthält 24 `DynamicQuantizeLinear` und 24 `MatMulInteger`.

Der in `pocket-tts-english.onnx` eingebettete Encoder (`pocket_tts_encoder`, base64) hat dieselbe Architektur, aber andere Gewichte.

| Eigenschaft | `de/encoder.onnx` | eingebetteter Encoder |
|---|---|---|
| Bytes | 39183564 | 39183564 |
| sha256 | `80e0efae03c43e2ca1252874095fa1df4a2f36c5140246c9349810de70abdd50` | `89451a17187f589bb00d6b127e4bb82d99849d31472abd62c5546acd78df0246` |
| Eingang | `audio` float32 [1, 1, -1] | `audio` float32 [1, 1, -1] |
| Ausgang | `cond` float32 [1, -1, 1024] | `cond` float32 [1, -1, 1024] |
| Nodes | 553 | 553, identische Liste |
| Initializers | 45 | 45, identische Namen |

Alle 45 Initializer haben andere Werte, das betrifft auch `tts.flow_lm.bos_before_voice`. `pocket-tts-english-ipa.onnx` bettet dieselben Bytes ein, sha256 `89451a17187f589bb00d6b127e4bb82d99849d31472abd62c5546acd78df0246`. Beide Encoder wurden per ORT-C-API geöffnet, der I/O-Vertrag oben ist gemessen und nicht aus der Dateistruktur abgeleitet. Das Vergleichsprogramm liegt unter `/home/openchamber/dump/pocket-research/pocket_encoder_compare.py`.

Für den Port heißt das: Jedes Sprach-Asset-Set bringt seinen eigenen Encoder mit, und die Stimm-Conditioning einer Sprache gehört zum Encoder derselben Sprache. Der Encoder aus der englischen Single-File ersetzt `de/encoder.onnx` nicht.

## Web-Variante

Die Web-Asset-Sets tragen keine ONNX-Metadaten. `split_for_web` (`src/pocket_tts_onnx/export/web.py:29-74`) löscht sie mit `del model.metadata_props[:]` und legt stattdessen an:

- `assets.json` mit den Feldern `config`, `tokenizer` und `voices`. Das Schema bestätigt `packages/pocket-tts-onnx/src/tts.ts:63-67`.
- `manifest.json` mit `version` 1, `baseUrl`, den Einträgen `model`, `encoder` und `assets` je mit `file`, `bytes` und den ersten 16 Hex-Zeichen des sha256, dazu `sampleRate`, `voices` alphabetisch, `voiceLanguages` und `phonemes`. Die Felder entstehen in `web.py:57-68`, `_entry` steht in `web.py:77-83`, das Schema in `packages/pocket-tts-onnx/src/pipeline.ts:21-31`.

`de/manifest.json` gemessen:

```json
{
  "version": 1,
  "baseUrl": "",
  "model": { "file": "model.onnx", "bytes": 173604779, "sha256": "6ea90a844c839eb9" },
  "encoder": { "file": "encoder.onnx", "bytes": 39183564, "sha256": "80e0efae03c43e2c" },
  "assets": { "file": "assets.json", "bytes": 771450, "sha256": "a0c0bedad0a7780f" },
  "sampleRate": 24000,
  "voices": ["alba", "juergen"],
  "voiceLanguages": { "juergen": "de", "alba": "de" },
  "phonemes": false
}
```

Für den Zig-Port folgt daraus: Die englische Single-File bringt Config, Tokenizer und Stimmen über die ONNX-Metadaten mit. Die deutsche Variante braucht zwingend `assets.json` und `manifest.json` zusätzlich zur ONNX-Datei.

## Offene Punkte

- Python und TypeScript erzeugen bei gleichem Seed unterschiedliche Rauschwerte, weil `numpy default_rng` und mulberry32 verschiedene Zufallsfolgen liefern. Beide skalieren mit `sqrt(temperature)`.
- Ob neben den vier dokumentierten Metadaten-Schlüssel weitere zulässig sind, ist nicht dokumentiert. Der Export schreibt genau diese vier.
- Die englischen Modelldateien wurden nach der ersten Messung gelöscht, das Dateisystem war zu 93 Prozent belegt. Sie liegen seit dem 30.10.2026 wieder unter `/home/openchamber/dump/pocket-research/`, werden dort aber von einer zweiten Sitzung genutzt und wurden deshalb nicht erneut gelöscht.

## Quellen

- `src/pocket_tts_onnx/tts.py`, Zeilen 32, 73-107, 277-404, 412-501
- `src/pocket_tts_onnx/text.py`, Zeilen 30-48
- `src/pocket_tts_onnx/hub.py`, `model_filename`
- `src/pocket_tts_onnx/export/step_model.py`, Zeilen 255-274, 422-446
- `src/pocket_tts_onnx/export/export.py`, Zeilen 253-312
- `src/pocket_tts_onnx/export/web.py`, Zeilen 20-23, 29-74, 77-83
- `packages/pocket-tts-onnx/src/tts.ts`, Zeilen 25-27, 63-67, 228-253, 309-313, 333, 349-469
- `packages/pocket-tts-onnx/src/text.ts`, Zeilen 158-175
- `packages/pocket-tts-onnx/src/sentencepiece.ts`, Zeilen 144-199
- `packages/pocket-tts-onnx/src/languages.ts`, Tabelle LANGUAGES
- `packages/pocket-tts-onnx/src/pipeline.ts`, Zeilen 21-31
- `exports/export-all.sh` und `exports/export-all.log`
- `docs/WEB.md`
- `~/.local/share/onnxruntime/include/onnxruntime_c_api.h`, Zeilen 2125, 2185, 2262
