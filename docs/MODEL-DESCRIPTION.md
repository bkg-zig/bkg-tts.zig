# Modellbeschreibung (`config.json`)

Die Engine kennt keine Modellfamilie. Jedes Modell beschreibt sich selbst in
einer JSON-Datei. Diese Datei ist die einzige Quelle für Verarbeitungsweg,
Dateien, Textpfade, Stimmen und die Namen der ONNX-Ein- und Ausgänge.

Der Parser steht in `src/tts/descriptor.zig`. Dieses Dokument beschreibt den
Vertrag, den dieser Parser tatsächlich liest.

## Wo die Datei liegt

Ein Modell ist ein Verzeichnis. Es heiße `model-dir` und enthält die Datei
`config.json` sowie die Gewichte, das Vokabular und die Stimmtabelle.

Die Registry liest ein Verzeichnis mit Modellordnern (`BKG_TTS_MODELS_DIR`).
Sie nimmt zwei Formen von Deskriptoren an:

- Jede Datei `*.json` direkt im Verzeichnis ist ein Deskriptor.
- Jedes Unterverzeichnis, in dem `config.json` liegt, ist ein Modellordner.

Der Deskriptor im Modellordner hat den Vorrang, weil dort die relativen Pfade
zu den Gewichten stimmen. Ohne `registry.json` gilt die erste Datei in
alphabetischer Reihenfolge als Vorgabemodell.

## Pflichtfelder

| Feld | Typ | Bedeutung |
|---|---|---|
| `name` | Text | Anzeigename des Modells |
| `model_file` | Text | Pfad der ONNX-Datei |

Fehlt eines dieser Felder, liest die Engine den Deskriptor nicht. Die Registry
meldet den Fehler und überspringt die Datei. Andere Modelle bleiben benutzbar.

## Relative Pfade

Alle Pfade im Deskriptor werden gegen das Verzeichnis der Deskriptordatei
aufgelöst. Ein absoluter Pfad bleibt unverändert. So kann ein Modellordner an
eine andere Stelle kopiert werden, ohne die Datei anzufassen.

## Allgemeine Felder

| Feld | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `name` | Text | Pflicht | Anzeigename |
| `version` | Text | `""` | Version des Modells |
| `model` | Text | `name` | Eindeutige Kennung des Modells |
| `type` | Text | `ONNX2` | Verarbeitungsweg, siehe unten |
| `model_file` | Text | Pflicht | ONNX-Datei |
| `sample_rate` | Zahl | aus dem Modell | Abtastrate der Ausgabe in Hertz |

Fehlt `sample_rate`, liest die Engine den Metadatenwert `sample_rate` des
ONNX-Graphen. Fehlt auch der, gilt 24000 Hz.

Die Kennung `model` muss innerhalb einer Registry eindeutig sein. Zwei
Deskriptoren mit derselben Kennung: der erste gewinnt, der zweite wird
gemeldet und übersprungen.

## Verarbeitungsweg (`type`)

| Wert | Verarbeitungsweg |
|---|---|
| `ONNX2`, `onnx2`, `onnx_ar`, `style_tokens` | Stimmembedding und Tokenfolge in einem Lauf |
| `phoneme_ids` | Phonem-IDs je Satz, ein Graphenlauf je Satz |
| `pocket_step` | Schrittweiser Decoder. Noch nicht implementiert, das Laden liefert `UnsupportedBackend` |

Die beiden implementierten Wege unterscheiden sich in drei Punkten: der
Tokenizer, die Anzahl der Graphenläufe und die Bedeutung des Tempos.

- `style_tokens` bekommt einen Tensor mit der Tokenfolge, optional die
  Stimmzeile, optional das Tempo. Der Text wird in Abschnitte geteilt, jeder
  Abschnitt ergibt eine Tokenfolge und einen Lauf.
- `phoneme_ids` bekommt je Satz eine Folge von Phonem-IDs, die Länge der
  Folge und die Werte der Inference. Das Tempo steckt in der Dehnung des
  Textes: Die Dehnung ist `length_scale / speed`.

## Stimmen (`voices`)

Ohne `voices` hat das Modell eine einzige Stimme. Sie trägt den Namen des
Modells und benutzt 256 Spalten.

Als Text nennt das Feld eine NPZ-Datei. Das Archiv enthält je Stimme eine
`.npy`-Datei mit einer zweidimensionalen Matrix aus Float32-Werten in
Little-Endian-Reihenfolge. Der Name der Datei ohne Endung ist der Name der
Stimme. Die erste Zeile ist die Zeile für den kürzesten Text, die letzte die
für den längsten.

Als Objekt nennt das Feld die Datei und ihre Form:

| Feld | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `file` | Text | Pflicht | Datei mit den Stimmembeddings |
| `format` | Text | `npz` | `npz` oder `flat` |
| `names` | Liste von Text | `[]` | Namen der Stimmen in Dateireihenfolge |
| `rows` | Zahl | `0` | Zeilen je Stimme |
| `columns` | Zahl | `256` | Werte je Zeile |

Bei `flat` sind `names` und `rows` Pflicht. Die Datei hat keinen Kopf. Die
Werte stehen als Float32 in Little-Endian hintereinander, erst alle Zeilen der
ersten Stimme, dann die der zweiten. Ihre Größe muss exakt zu
`names × rows × columns × 4` passen.

Bei `npz` kommen Namen, Zeilen und Spalten aus dem Archiv. `names`, `rows` und
`columns` werden dann ignoriert.

## Text (`text`)

| Feld | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `language` | Text | `en-us` | Sprache des Textes, zugleich die Stimme von espeak-ng |
| `preprocess` | Text | `numbers` | `none` oder `numbers` |
| `mode` | Text | `whole` | `whole` oder `clause` |
| `normalize_nfd` | Wahrheitswert | `false` | Text vor der Zuordnung in Normalisierungsform D zerlegen |
| `max_tokens` | Zahl | `0` | Höchstzahl der Tokens im Textkörper. Null schaltet die Grenze ab |
| `append_terminator` | Wahrheitswert | `false` | Satzzeichen des espeak-Terminators an den Phonemtext hängen |
| `clause_separator` | Text | `" "` | Trenner zwischen den Phonemen der einzelnen Sätze |
| `chunk_chars` | Zahl | `400` | Höchstlänge eines Abschnitts in Byte. Null schaltet die Aufteilung ab |
| `chunk_split` | Text | `".!?"` | Zeichen, an denen ein Abschnitt endet. Die Zeichen entfallen |
| `chunk_punctuation` | Text | `","` | Zeichen, das an einen Abschnitt ohne Satzzeichen angehängt wird |
| `replacements` | Liste | `[]` | Ersetzungen im Phonemtext, je `{ "from": …, "to": … }` |

`preprocess` mit `numbers` ersetzt Zahlen und Währungen durch Wörter.
`mode` mit `clause` verarbeitet jeden Satz aus den espeak-Terminatoren
einzeln, `whole` verarbeitet den ganzen Abschnitt als einen Text.

`chunk_chars` gilt in Byte. Ein Abschnitt, der länger ist, wird an Wortgrenzen
geteilt. `chunk_split` ohne Zeichen trennt nicht, `chunk_punctuation` ohne
Zeichen hängt nichts an.

## Tokenizer (`tokenizer`)

| Feld | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `mode` | Text | `builtin` | `builtin`, `vocab` oder `phoneme_ids` |
| `symbols` | Text | `[]` | Vokabulardatei, Pflicht bei `vocab` |
| `phoneme_id_map` | Text | `[]` | JSON-Datei mit der Phonem-ID-Map, Pflicht bei `phoneme_ids` |
| `phoneme_id_map_field` | Text | `phoneme_id_map` | Feld der JSON-Datei, das die Map enthält |
| `start_id` | Zahl oder `null` | `0` | ID vor dem Textkörper |
| `end_id` | Zahl oder `null` | `10` | ID nach dem Textkörper |
| `pad_id` | Zahl oder `null` | `0` | ID am Ende der Folge |
| `start_key` | Text | `[]` | Schlüssel des Starttokens in der Phonem-ID-Map |
| `pad_key` | Text | `[]` | Schlüssel des Füllzeichens in der Phonem-ID-Map |
| `end_key` | Text | `[]` | Schlüssel des Endtokens in der Phonem-ID-Map |
| `word_split` | Wahrheitswert | siehe unten | Wortzeichen zu Wörtern gruppieren |
| `symbol_scheme` | Text | `first_wins` | `first_wins` oder `last_wins`, nur bei `builtin` |

`word_split` folgt dem Modus, wenn der Deskriptor es nicht nennt: Die
eingebaute Tabelle gruppiert Wortzeichen, ein Vokabular ordnet jedes Zeichen
einzeln zu.

Die Rahmenzeichen stehen in der Reihenfolge Start, Ende, Füllzeichen. `null`
lässt ein Zeichen weg. Bei `phoneme_ids` kommen die IDs aus der Map, und die
Schlüssel `start_key`, `pad_key` und `end_key` müssen sie benennen. Fehlen sie,
liefert das Laden `MissingFramePhoneme`.

Die eingebaute Tabelle kennt die Symbole der Kitten-Modelle. Bei `vocab` hat
die Datei eine Zeile je Symbol, die Nummer der Zeile ist die ID. Die
Phonem-ID-Map ist eine JSON-Datei mit einem Objekt aus Text zu Zahl.

## Stimmzeile (`style`)

| Feld | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `index.basis` | Text | `tokens` | `tokens` zählt die Folge mit Rahmen, `symbols` nur die Symbole |
| `index.offset` | Zahl | `0` | Wert, der von der Länge abgezogen wird |
| `index.min` | Zahl | `0` | Untere Grenze der Zeilennummer |
| `index.max` | Zahl | letzte Zeile | Obere Grenze der Zeilennummer |

Die Zeilennummer entsteht so:

```
local = clamp(length - offset, min, max oder rows - 1)
```

`length` ist die Zahl der Tokens mit Rahmen oder die Zahl der Symbole ohne
Rahmen, je nach `basis`.

## Ein- und Ausgänge (`inputs`, `output`)

| Feld | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `inputs.tokens` | Text | `input_ids` | Name des Eingangs mit der Tokenfolge |
| `inputs.style` | Text | `style` | Name des Eingangs mit dem Stimmembedding |
| `inputs.speed` | Text | `speed` | Name des Eingangs mit dem Tempo |
| `inputs.lengths` | Text | `[]` | Name des Eingangs mit der Länge der Folge |
| `inputs.scales` | Text | `[]` | Name des Eingangs mit den Werten der Inference |
| `output.name` | Text | `audio` | Name des Ausgangs mit den Samples |
| `output.trim_tail_samples` | Zahl | `5000` | Samples, die am Ende abgeschnitten werden |
| `output.normalize` | Text | `none` | `none` oder `peak` |

Ein Eingang, dessen Name der Graph nicht kennt, wird nicht belegt. Ein
Ausgang, dessen Name der Graph nicht kennt, liefert beim Laden einen Fehler.

`trim_tail_samples` wird nie größer angewendet als die Ausgabe lang ist.
`peak` bringt die Samples auf den größten Wert 1.0.

Die Werte der Inference (`noise_scale`, `length_scale`, `noise_w`) gehen in
den Eingang `scales`, wenn der Graph ihn kennt.

## Aliase und Tempopriors

`voice_aliases` bildet einen Namen auf einen internen Stimmnamen ab:

```json
"voice_aliases": { "Bella": "expr-voice-2-f" }
```

Eine Anfrage wird in dieser Reihenfolge aufgelöst: exakter Alias, Alias ohne
Beachtung der Groß- und Kleinschreibung, exakter Name der Stimmtabelle, Name
der Stimmtabelle ohne Beachtung der Groß- und Kleinschreibung. Eine leere
Anfrage nimmt die erste Stimme der Tabelle.

`speed_priors` nennt je internem Stimmnamen einen Faktor, der mit dem
Tempowert der Anfrage verrechnet wird. Der Prior gehört zum internen Namen,
nicht zum Alias.

## espeak-ng (`espeak`)

| Feld | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `library_path` | Text | `[]` | Pfad der Shared Library |
| `data_dir` | Text | `[]` | Verzeichnis mit den espeak-Daten |

Ohne Angaben gelten die Vorgaben der Engine, also die Umgebungsvariablen
`BKG_TTS_ESPEAK_LIBRARY` und `BKG_TTS_ESPEAK_DATA`.

## Werte der Inference (`inference`)

| Feld | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `noise_scale` | Zahl | `0.667` | Zufallsrauschen des Modells |
| `length_scale` | Zahl | `1.0` | Dehnung des Textes. Größere Werte sprechen langsamer |
| `noise_w` | Zahl | `0.8` | Zufallsrauschen der Dauer |

## Modellliste (`registry.json`)

Die Datei `registry.json` im Modellverzeichnis benennt die benutzten Modelle
und ihre Reihenfolge:

```json
{
  "default": "kitten-tts-nano-0.8",
  "models": ["kitten-tts-nano-0.8", "kokoro-en-v0_19"]
}
```

`models` legt die Reihenfolge fest. Modelle, die nicht in der Liste stehen,
bleiben erhalten und kommen hinten. `default` benennt das Modell beim Start.
Fehlt das Feld, gilt das erste Modell der Liste.

Nennt die Liste eine Kennung, die es nicht gibt, bricht das Laden mit
`UnknownModel` ab. Das ist ein Fehler und keine Warnung, weil eine falsche
Modellliste den Betriebsdienst sonst mit einem Modell starten würde, das der
Betreiber nicht ausgewählt hat.

## Beispiel: Kitten-artiges Modell

```json
{
  "name": "Kitten TTS Nano",
  "version": "0.8",
  "type": "ONNX2",
  "model": "kitten-tts-nano-0.8",
  "voices": "voices.npz",
  "model_file": "kitten_tts_nano_v0_8.onnx",
  "sample_rate": 24000,
  "text": {
    "language": "en-us",
    "preprocess": "numbers",
    "mode": "whole",
    "chunk_chars": 400,
    "chunk_split": ".!?",
    "chunk_punctuation": ","
  },
  "tokenizer": {
    "mode": "builtin",
    "start_id": 0,
    "end_id": 10,
    "pad_id": 0
  },
  "style": {
    "index": { "basis": "tokens", "offset": 0, "min": 0 }
  },
  "inputs": {
    "tokens": "input_ids",
    "style": "style",
    "speed": "speed"
  },
  "output": {
    "name": "waveform",
    "trim_tail_samples": 5000
  },
  "speed_priors": { "expr-voice-2-f": 0.8 },
  "voice_aliases": { "Bella": "expr-voice-2-f" }
}
```

## Beispiel: Modell mit flacher Stimmdatei

```json
{
  "name": "Kokoro English",
  "type": "onnx_ar",
  "model": "kokoro-en-v0_19",
  "model_file": "model.onnx",
  "sample_rate": 24000,
  "voices": {
    "file": "voices.bin",
    "format": "flat",
    "names": ["af", "af_bella", "am_adam"],
    "rows": 511,
    "columns": 256
  },
  "text": { "language": "en-us", "preprocess": "none", "chunk_chars": 0 },
  "tokenizer": {
    "mode": "vocab",
    "symbols": "tokens.txt",
    "start_id": 0,
    "end_id": null,
    "pad_id": 0
  },
  "style": { "index": { "basis": "symbols", "offset": 2, "min": 0, "max": 509 } },
  "inputs": { "tokens": "tokens", "style": "style", "speed": "speed" },
  "output": { "name": "audio", "trim_tail_samples": 0 }
}
```

## Beispiel: Modell mit Phonem-IDs

```json
{
  "name": "Piper Deutsch (Thorsten)",
  "version": "medium",
  "type": "phoneme_ids",
  "model": "piper-de_DE-thorsten-medium",
  "model_file": "de_DE-thorsten-medium.onnx",
  "sample_rate": 22050,
  "text": {
    "language": "de",
    "preprocess": "none",
    "mode": "clause",
    "normalize_nfd": true,
    "append_terminator": true,
    "clause_separator": "",
    "chunk_chars": 0,
    "chunk_split": "",
    "chunk_punctuation": ""
  },
  "tokenizer": {
    "mode": "phoneme_ids",
    "phoneme_id_map": "de_DE-thorsten-medium.onnx.json",
    "phoneme_id_map_field": "phoneme_id_map",
    "start_key": "^",
    "pad_key": "_",
    "end_key": "$"
  },
  "inputs": {
    "tokens": "input",
    "lengths": "input_lengths",
    "scales": "scales"
  },
  "output": { "name": "output", "trim_tail_samples": 0, "normalize": "peak" },
  "inference": { "noise_scale": 0.667, "length_scale": 1.0, "noise_w": 0.8 }
}
```

Das ist der Deskriptor des Modells `vits-piper-de_DE-thorsten-medium` aus dem
Testverzeichnis. Der Vertrag des Phonemwegs steht in
`docs/PIPER-PHONEMIZATION.md`.

## Prüfen

`bkg-tts info --model <ordner>` liest den Deskriptor und gibt die Felder aus.
`bkg-tts info --model <ordner> --load` lädt das Modell zusätzlich und prüft
damit ONNX-Graph, Stimmtabelle und Tokenizer.
