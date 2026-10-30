# Piper-Phonemisierung: verifizierter Vertrag

Stand: 2026-10-30. Zweck: eine eigene Zig-Implementierung soll die Phonemisierung so fahren wie piper1-gpl. Alle Werte in diesem Dokument stammen aus dem Quelltext von `OHF-Voice/piper1-gpl` auf Commit `74ac24e7e8e2e57a5e1fada5505c74e3d9c1843a` vom 2026-10-23 und aus den Quellen von `espeak-ng/espeak-ng`. Zeilenangaben beziehen sich auf diesen Stand.

piper1-gpl pflegt zwei Phonemisierungspfade. Der Python-Pfad liegt in `src/piper/`, der C++-Pfad in `libpiper/`. Beide sprechen dieselbe espeak-ng an, erzeugen aber unterschiedliche ID-Folgen. Für den Zig-Port ist genau eine Semantik zu wählen.

## Prüfmethode

- Der Commit-SHA wurde per GitHub-API bestätigt, alle Quellpfade per `raw.githubusercontent.com` geladen und mit HTTP 200 geprüft.
- Die gelesenen Dateien liegen als lokale Kopie unter `/tmp/opencode/piper-research/`. Die Werte in diesem Dokument wurden aus dieser Kopie abgeleitet und per Zeilenabgleich gegen die Quelldateien geprüft.
- Die espeak-ng-Tags 1.51 und 1.52.0 wurden live gegengeprüft, dort fehlt die Terminator-API. Commit 724808c und `master` enthalten sie.
- Es wurde kein Piper-Code übernommen. Zitiert sind nur API-Aufrufe, Konstanten und Konfigurationswerte, die das Verhalten festlegen.

## Quellstand

| Pfad | Rolle |
|---|---|
| `src/piper/espeakbridge.c` | C-Bridge zur espeak-ng-C-API, liefert Phoneme mit Terminator |
| `src/piper/phonemize_espeak.py` | Python-Nachbearbeitung, Satzgruppen, Diphthong-Merge |
| `src/piper/phoneme_ids.py` | `DEFAULT_PHONEME_ID_MAP` und `phonemes_to_ids` |
| `src/piper/const.py` | Symbole für PAD, BOS und EOS |
| `src/piper/voice.py` | Tensorbau und ein ONNX-Lauf je Satz |
| `src/piper/config.py` | Defaults und Config-Felder |
| `libpiper/src/piper.cpp` | C++-Pfad, Phonemisierung und ID-Aufbau |
| `libpiper/include/piper_impl.hpp` | ID-Konstanten, CLAUSE-Makros, `get_codepoint` |

## espeak-ng aufrufen

Initialisierung (`src/piper/espeakbridge.c:29`, `libpiper/src/piper.cpp:151`):

```c
espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, data_dir, 0)
```

Ein Ergebnis kleiner als 0 ist ein Fehler. `data_dir` zeigt auf das Verzeichnis `espeak-ng-data`. piper1-gpl baut espeak-ng per CMake ExternalProject und kopiert das Datenverzeichnis nach `src/piper/espeak-ng-data` (`CMakeLists.txt:89-96`).

Stimme (`src/piper/espeakbridge.c:43`, `libpiper/src/piper.cpp:476`):

```c
espeak_SetVoiceByName(voice) != EE_OK
```

`EE_OK` ist 0. Die aktive Stimme ist prozessweiter Zustand. Piper hält dafür ein prozessweites `ESPEAK_LOCK`, weil zwei gleichzeitige Sprachen sonst um die Stimme racen (`src/piper/phonemize_espeak.py:13-19`).

Phonemisierung (`src/piper/espeakbridge.c:61-66`, `libpiper/src/piper.cpp:637-640`):

```c
const char *phonemes = espeak_TextToPhonemesWithTerminator(
    (const void **)&text, espeakCHARS_AUTO, espeakPHONEMES_IPA, &terminator);
```

| Flag | Wert |
|---|---:|
| `espeakCHARS_AUTO` | 0 |
| `espeakPHONEMES_IPA` | 0x02 |
| `espeakPHONEMES_SHOW` | 0x01 |

Die Werte stehen in `espeak-ng/src/include/espeak-ng/speak_lib.h:280` und `494-498`, die Deklaration in Zeile 547.

Drei Eigenschaften des Aufrufs sind für den Port relevant:

- Die Schleife läuft, solange der Textzeiger nicht NULL ist. espeak-ng setzt `*textptr` auf den Resttext (`espeak-ng/src/libespeak-ng/speech.c:870`), und der Textdecoder liefert bei EOF NULL (`espeak-ng/src/libespeak-ng/encoding.c:786-791`).
- Der zurückgegebene Zeiger zeigt auf einen statischen Puffer in espeak-ng (`espeak-ng/src/libespeak-ng/dictionary.c:438`, `560-687`). Er wird nicht freigegeben und ist nach dem nächsten Aufruf überschrieben.
- Der Terminator ist ein Rückgabewert, kein Textzeichen. `espeak_TextToPhonemes` ruft intern dieselbe Funktion mit NULL-Terminator auf (`espeak-ng/src/libespeak-ng/speech.c:875-878`).

## Terminatoren und Satzgrenzen

Piper maskiert den Terminator auf 20 Bit (`src/piper/espeakbridge.c:68`, `libpiper/src/piper.cpp:645`):

```c
terminator &= 0x000FFFFF;
```

Danach vergleicht Piper mit sechs eigenen Konstanten (`src/piper/espeakbridge.c:10-21`, `libpiper/include/piper_impl.hpp:46-55`). espeak-ng definiert dieselben Werte in `translate.h:220-243`.

| Konstante | Wert | angehängtes Zeichen |
|---|---|---|
| `CLAUSE_PERIOD` | 40 \| FULL_STOP \| SENTENCE | `.` |
| `CLAUSE_QUESTION` | 40 \| QUESTION \| SENTENCE | `?` |
| `CLAUSE_EXCLAMATION` | 45 \| EXCLAMATION \| SENTENCE | `!` |
| `CLAUSE_COMMA` | 20 \| COMMA \| CLAUSE | `,` |
| `CLAUSE_COLON` | 30 \| FULL_STOP \| CLAUSE | `:` |
| `CLAUSE_SEMICOLON` | 30 \| COMMA \| CLAUSE | `;` |

`FULL_STOP` ist 0x00000000, `COMMA` 0x00001000, `QUESTION` 0x00002000, `EXCLAMATION` 0x00003000. Die Typbits stehen bei `CLAUSE_TYPE_CLAUSE` 0x00040000 und `CLAUSE_TYPE_SENTENCE` 0x00080000.

Satzende erkennt Piper über ein Bit-Test, nicht über den Zeichenvergleich (`src/piper/espeakbridge.c:86-87`, `libpiper/src/piper.cpp:663`):

```c
(terminator & CLAUSE_TYPE_SENTENCE) == CLAUSE_TYPE_SENTENCE
```

Am Textende liefert espeak-ng `CLAUSE_EOF` mit dem Wert 40 \| FULL_STOP \| SENTENCE \| EOF, also 0x00090028 (`espeak-ng/src/libespeak-ng/translate.h:234`, `readclause.c:968`). Der Wert passt zu keiner der sechs Piper-Konstanten, es wird also kein Zeichen angehängt. Das SENTENCE-Bit ist gesetzt, der letzte Satz endet dort sauber.

## Nachbearbeitung des Phonem-Strings

Python-Pfad (`src/piper/phonemize_espeak.py`):

1. Sprachwechsel-Klammern fliegen per Regex raus, Zeile 49: `re.sub(r"\([^)]+\)", "", phonemes_str)`.
2. Der Terminator wird angehängt. Bei Komma, Doppelpunkt und Semikolon folgt ein Leerzeichen, Zeilen 52-56.
3. Die Zerlegung erfolgt codepointweise über NFD, Zeile 59: `list(unicodedata.normalize("NFD", phonemes_str))`. Dadurch wird ein Akzentzeichen zum eigenen Phonem.
4. Bei Satzende wird die Liste abgeschlossen, Zeilen 61-66. Text ohne abschließenden Terminator ergibt eine letzte Gruppe, Zeilen 70-77.
5. Ist `vowel_clusters` gesetzt, fasst `_merge_known_vowel_clusters` bekannte Diphthonge zusammen, Zeilen 82-108. Gesucht wird ab der längsten Clusterlänge.

C++-Pfad (`libpiper/src/piper.cpp`):

1. Sprachwechsel-Klammern überspringt eine Zustandsmaschine mit dem Flag `in_lang_flag`, Zeilen 703-713.
2. Terminatoren werden direkt mit Leerzeichen angehängt: `", "`, `": "`, `"; "`, Zeilen 652-659.
3. NFD läuft über `una::norm::to_nfd_utf8`, die Iteration über `una::ranges::utf8_view`, Zeilen 698-699.
4. Ein `vowel_clusters` gibt es im C++-Pfad nicht. Diphthonge bleiben dort getrennte Codepoints.

## phoneme_id_map

Format: JSON-Objekt, Schlüssel ist das Phonemsymbol, Wert ist eine Liste von IDs.

```json
"phoneme_id_map": { "_": [0], "^": [1], "$": [2], ";": [12], "aɪ": [161] }
```

Ausgewertet an `tests/test_voice.onnx.json`:

| Schlüssel | IDs |
|---|---|
| `;` | [12] |
| `,` | [8] |
| `.` | [10] |
| `aɪ` | [161] |
| `aʊ` | [162] |
| `ɔɪ` | [163] |
| `eɪ` | [164] |
| `oʊ` | [165] |

Die Datei hat 159 Schlüssel. `DEFAULT_PHONEME_ID_MAP` in `src/piper/phoneme_ids.py:11` hat 165 Schlüssel mit den IDs 0 bis 165, ID 150 bleibt unbelegt.

Der Python-Pfad schlägt mit dem exakten String nach (`src/piper/phoneme_ids.py:194-199`). Ein Diphthong-Key wird nur erreicht, wenn `vowel_clusters` ihn vorher zusammengeführt hat.

Der C++-Pfad indexiert über `get_codepoint` (`libpiper/include/piper_impl.hpp:146-157`), also den ersten Codepoint des Keys, und hängt die IDs per `push_back` an (`libpiper/src/piper.cpp:206-213`). Alle Keys mit gleichem Anfangs-Codepoint landen damit in einer gemeinsamen Liste. `"a"` trägt dadurch seine eigene ID und zusätzlich die IDs 161 und 162 von `"aɪ"` und `"aʊ"`. Der Pinyin-Zweig nutzt dagegen weiterhin exakte String-Keys (`libpiper/src/piper.cpp:177-198`).

## ID-Folge je Satz

Sonderzeichen sind in beiden Pfaden gleich belegt. `src/piper/const.py:3-5` nennt PAD `_` mit ID 0, BOS `^` mit ID 1 und EOS `$` mit ID 2. `libpiper/include/piper_impl.hpp:25-27` definiert `ID_PAD` 0, `ID_BOS` 1 und `ID_EOS` 2.

Python-Folge (`src/piper/phoneme_ids.py:191-202`):

```
BOS-IDs, PAD-IDs, je Phonem alle Map-IDs gefolgt von PAD-IDs, EOS-IDs
```

C++-Folge (`libpiper/src/piper.cpp:691-734`):

```
BOS 1, PAD 0, Separator,
je Map-ID: ID, PAD 0, Separator,
EOS 2, Separator
```

Der Separator (`PHONEME_SEPARATOR` 0, `libpiper/include/piper_impl.hpp:32`) gibt es nur im C++-Pfad. Punkt, Komma und Semikolon sind reine Punctuation-Phoneme mit IDs aus der Map. Ein Satzende entsteht ausschließlich über das SENTENCE-Bit von espeak.

Fehlt ein Phonem in der Map, verhält sich der Python-Pfad anders als der C++-Pfad:

- Python warnt und überspringt das Phonem samt PAD (`src/piper/phoneme_ids.py:195-197`): `_LOGGER.warning("Missing phoneme from id map: %s", phoneme)`.
- Der C++-Pfad verwirft unbekannte Phoneme stillschweigend (`libpiper/src/piper.cpp:714-725`).

Das historische C++ aus `rhasspy/piper` sammelte und meldete die fehlenden Phoneme: "Missing {} phoneme(s) from phoneme/id map!" und "Missing \"{}\" (\u{:04X}): {} time(s)".

## ONNX-Eingaben

Aufbau in `src/piper/voice.py:533-556`.

| Eingang | Typ | Form | Wert |
|---|---|---|---|
| `input` | int64 | [1, N] | Phonem-IDs |
| `input_lengths` | int64 | [1] | N |
| `scales` | float32 | [3] | `noise_scale`, `length_scale`, `noise_w_scale` |
| `sid` | int64 | [1] | nur bei `num_speakers > 1` |

Defaults aus `src/piper/config.py:7-11`:

| Feld | Wert |
|---|---:|
| `noise_scale` | 0.667 |
| `length_scale` | 1.0 |
| `noise_w_scale` | 0.8 |
| `hop_length` | 256 |

Dieselben drei Export-Defaults stehen in `src/piper/train/export_onnx.py:88`, die Eingabenamen in Zeile 98.

`length_scale` wird nicht invertiert. Die Trainingsformel lautet `w = torch.exp(logw) * x_mask * length_scale` (`src/piper/train/vits/models.py:795`). Ein Wert über 1 verlängert die Dauer.

Pro Satz läuft das Modell genau einmal. Die Schleife `for phonemes in sentence_phonemes` in `synthesize` (`src/piper/voice.py:363`) endet in einem `session.run` (`src/piper/voice.py:558`).

## Versionsanforderung an espeak-ng

Die Terminator-API `espeak_TextToPhonemesWithTerminator` gibt es erst ab Commit 724808c vom 2026-04-06. piper1-gpl baut genau diesen Stand (`CMakeLists.txt:26-27`):

```
GIT_REPOSITORY https://github.com/espeak-ng/espeak-ng.git
GIT_TAG 724808c  # 2026-Apr-06
```

Live gegengeprüft am 2026-10-30, Treffer der Funktion in `src/libespeak-ng/speech.c`:

| Stand | Treffer |
|---|---:|
| Tag 1.51 | 0 |
| Tag 1.52.0 | 0 |
| Commit 724808c | 2 |
| `master` | 2 |

## Empfehlung für den Zig-Port

- Die Python-Semantik übernehmen. Exakter String-Key-Lookup, Warnung bei fehlendem Phonem und ein PAD je Phonem sind einfacher zu prüfen als der C++-Codepoint-Index.
- espeak-ng ab Commit 724808c festlegen und das Verzeichnis `espeak-ng-data` mitliefern.
- Den Terminator mit `0x000FFFFF` maskieren und das Satzende über `CLAUSE_TYPE_SENTENCE` bestimmen, nicht über den Zeichenvergleich.
- Fehlende Phoneme melden statt still verwerfen.
- `length_scale` unverändert an `scales[1]` reichen.
- Espeak-Aufrufe serialisieren, die aktive Stimme ist prozessweit.

## Offene Punkte

- Ob `espeak_Initialize` mehrfach pro Prozess aufgerufen werden darf, steht nicht in der Quelle. Piper ruft es beim Erzeugen des Synthesizers auf.
- Ob die ONNX-Eingabenamen bei jedem fremden Piper-Modell gleich heißen, ist nicht belegt. Geprüft sind der Trainings-Export und der piper1-gpl-Inferenzpfad.
- Wie gut die espeak-ng-Stimmen für eine konkrete Zielsprache klingen, geht aus dem Quelltext nicht hervor.
- Warum die Modelle die NFD-Zerlegung erwarten, ist nicht dokumentiert. Belegt ist, dass Piper sie anwendet.

## Quellen

- `src/piper/espeakbridge.c`, Zeilen 10-21, 29, 43, 61-88
- `src/piper/phonemize_espeak.py`, Zeilen 13-19, 46-77, 82-108
- `src/piper/phoneme_ids.py`, Zeilen 11, 182-204
- `src/piper/const.py`, Zeilen 3-5
- `src/piper/voice.py`, Zeilen 202-327, 344-363, 533-561
- `src/piper/config.py`, Zeilen 7-11, 52-58, 72-92
- `src/piper/train/export_onnx.py`, Zeilen 57-66, 88-102
- `src/piper/train/vits/models.py`, Zeile 795
- `libpiper/src/piper.cpp`, Zeilen 150-216, 476, 631-738
- `libpiper/include/piper_impl.hpp`, Zeilen 25-32, 46-55, 146-157
- `CMakeLists.txt`, Zeilen 26-27, 89-96
- `tests/test_voice.onnx.json`
- `espeak-ng/src/libespeak-ng/speech.c`, Zeilen 855-878
- `espeak-ng/src/libespeak-ng/dictionary.c`, Zeilen 438, 560-687
- `espeak-ng/src/libespeak-ng/encoding.c`, Zeilen 786-791
- `espeak-ng/src/libespeak-ng/translate.h`, Zeilen 215-243
- `espeak-ng/src/libespeak-ng/readclause.c`, Zeilen 528, 968
- `espeak-ng/src/include/espeak-ng/speak_lib.h`, Zeilen 280, 494-498, 547
- `rhasspy/piper-phonemize/src/phonemize.cpp`, `rhasspy/piper/src/cpp/piper.cpp`
