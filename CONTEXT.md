# CONTEXT — speech logger

Domain glossary. The vocabulary every issue, ADR, test name, and code identifier should use.
Source of truth for scope is [`SPEC.md`](SPEC.md); the rationale behind the load-bearing
decisions lives in [`docs/adr/`](docs/adr/).

## The product in one line

A macOS menubar app: press a hotkey, speak, press again. The app records, transcribes locally,
organizes the text with an LLM under a strict fidelity contract, and drops the result in a log.
Click a log entry, its final text is on your clipboard. The pipeline is asynchronous.

## Core terms

- **Log item** (or **item**) — the unit of work: one recording and everything derived from it.
  It is a state machine (see below). The log is a flat list of items, always read whole.

- **Item states** — the canonical set. Supersedes the four-state table in `PRD.md` §5.
  - `recording` — mic is live, no content yet (a running clock).
  - `queued` — recording finished, waiting for the serial transcription lane.
  - `transcribing` — `mlx_whisper` is running.
  - `organizing` — the two LLM passes are running.
  - `organized` — **terminal, happy path.** The final pass-2 text exists and is copyable.
  - `failed` — **terminal, broke.** Carries `error: { stage, reason, detail, at }`.
  - `cancelled` — **terminal, you stopped it.** No error; carries `stoppedAt: { stage, at }`.
  - **`stage`** ∈ `recording | transcription | pass1 | pass2`.
  - **`reason`** ∈ `no_speech | empty_output | cli_error | missing_binary | interrupted | timeout`
    (`timeout` is reserved; nothing ships that produces it in the MVP).

- **The two passes** — how organization works, and the reason this tool exists (ADR-0001).
  - **Pass 1 (annotate)** — an LLM marks `<del>` false starts, `<dup>` repetitions, `<old>`
    superseded self-corrections, `<noise>` ASR garbage. It rewrites nothing; every input word
    reappears in order, marked or not.
  - **Pass 2 (rewrite)** — an LLM applies the marks mechanically (delete `<del>`/`<dup>`/`<old>`,
    keep `<noise>` verbatim and swap the tags for the noise mark), then punctuates, paragraphs,
    fixes grammar, and formats technical identifiers. It touches nothing that was not marked.

- **Fidelity contract** — the product's promise, made testable. The single rule: *adjust the
  speech for readability and for the speaker's tone (clear, direct, brief), never change what was
  said.* Full text: [`.scratch/dictation-tool/assets/fidelity-contract.md`](.scratch/dictation-tool/assets/fidelity-contract.md).
  The test for any output is one question: *could a human have said this and meant it?*

- **ASR noise** and the **noise mark** — a transcribed span that is not plausible Portuguese is
  transcription error, not speech. It is kept verbatim and **marked** (`[? ... ?]`) so the user
  can find it; it is **never** repaired. Named after Whisper turning `se é proporcional` into
  `se profissional` — a span no model could recover from context.

- **Acceptance set** — the regression yardstick: four cases (three real recordings), each with a
  hand-approved expected output, judged against the fidelity contract by idea-count, new-word
  diff, modal check, and slip check. [`.scratch/dictation-tool/assets/acceptance-set.md`](.scratch/dictation-tool/assets/acceptance-set.md).
  It is a **development** artifact (offline, human-run), not a runtime check.

## Pipeline and process terms

- **The three binaries** — the app shells out to all three by **absolute path** (ADR-0002):
  - `mlx_whisper` — local transcription (`whisper-large-v3-turbo`, `--language pt`). Exits 0 even
    on failure; success = output file exists and is non-empty.
  - `ffmpeg` — audio encode (native wav → mp3). Also invoked internally by `mlx_whisper` to decode.
  - `claude` — the Claude Code CLI, run once per pass. Gated on `is_error`, not exit code alone.

- **Preflight** — the launch-time gate that checks the three binaries are present, `claude` is
  logged in, the Whisper model is downloaded, and the Input Monitoring grant is live. It never
  blocks the hotkey; a missing prerequisite surfaces as a degraded state, not a modal (ADR-0004,
  and the first-run decisions in the map).

- **Item directory** — storage is plain files, one directory per item (ADR-0003), no database.
  Holds `audio.mp3`, the three text stages, `pass1.txt` (the annotated pivot), and `meta.json`
  (the explicit `state`, timestamps, duration, `error`, `schemaVersion`). Every write is
  temp+rename; delete goes to the macOS Trash.

## Interaction terms

- **The hotkey** — Right-Option double-tap (keyCode 61), 300 ms window, hard-coded, no rebind in
  the MVP. Captured via a `.flagsChanged` global monitor over Input Monitoring only (ADR-0004).

- **Passthrough** — the app **cannot swallow** the double-tap; both key presses also reach the
  frontmost app. Benign (Option alone inserts nothing). A `listenOnly` tap is a hard limit of the
  permission model, not a choice.

- **Input Monitoring** — the single macOS TCC permission the app needs. Not Accessibility. The
  grant survives rebuilds **only** with a stable code-signing identity (ADR-0005).

- **The menubar icon** — reflects app state on a strict priority ladder, one state wins the glyph:
  `recording` > `failed` > `processing` (= `queued`/`transcribing`/`organizing`) > `idle`. The
  icon does **not** signal "ready".

- **The panel** — the menubar dropdown, three sections: *Acontecendo agora* (live pipeline),
  *Prontos* (organized items, clamped preview, click-to-copy), *Precisam de você* (`failed` /
  `cancelled`, with retry).

- **The ready notification** — a macOS notification, one per `organized` item, with a `Copiar`
  button that copies the final text straight from the banner. This is how you learn an item is
  done; it never opens the app.
</content>
</invoke>
