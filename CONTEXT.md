# CONTEXT — speech logger

Domain glossary. The vocabulary every issue, ADR, test name, and code identifier should use.
Source of truth for scope is the GitHub issues; the rationale behind the load-bearing
decisions lives in [`docs/adr/`](docs/adr/).

## The product in one line

A macOS menubar app with **two modes on one hotkey**. Tap it twice and let go: you are recording a
**braindump** — the app transcribes locally, organizes the text with an LLM under a strict fidelity
contract, and drops the result in a log you collect from later. Tap it twice and **hold**: you are
**dictating** — the raw transcript is pasted where your cursor already is, no LLM, no waiting.

## The two modes

The load-bearing distinction. **Two speech acts, not two moods**, with opposite requirements — which
is the whole reason there is a second mode:

- **Braindump** — thought being formed. Long, asynchronous, needs the fidelity contract, delivered to
  a log and collected by clipboard on click. Toggle gesture. This is the MVP and everything below is
  about it unless marked otherwise.
- **Dictation** — a short throwaway instruction (a prompt for an agent, a search query, a Slack
  reply). You read the result in two seconds and fix it yourself, so the contract is over-engineering
  and the clipboard round trip is the entire friction. Push-to-talk, raw STT, pasted at the cursor.
  Specified in ADR-0007 and issue #40. The gesture, the raw transcript and the clipboard write
  are built (#42); **the paste at the cursor, the sound and the panel's dictation list are not**.

`dictation` deliberately collides with Apple's Dictation: the app is taking that job, and the
"typing at the cursor" non-goal was revoked to do it (ADR-0007). In prose, qualify — "macOS
dictation" vs "dictation mode". The word
is **not** a generic noun for "what the user said"; that is `the speech` or `the transcript`.

**What does not apply to dictation**, because there is no LLM in its path: the two passes, the
fidelity contract, the noise mark, the acceptance set, `organizing`/`organized`, `final.txt`,
`pass1.txt`, reprocess, and the ready notification. Everything else — the item, the store, the serial
lane, the states, retry, the menubar ladder, the guards — is shared.

## Core terms

- **Log item** (or **item**) — the unit of work: one recording and everything derived from it.
  It is a state machine (see below). The log is a flat list of items, always read whole. Both modes
  produce items; `meta.json` carries **`mode`** ∈ `braindump | dictation` (absent = `braindump`).

- **Item states** — the canonical set.
  - `recording` — mic is live, no content yet (a running clock).
  - `queued` — recording finished, waiting for the serial transcription lane.
  - `transcribing` — `mlx_whisper` is running.
  - `transcribed` — **terminal, happy path, `mode: dictation` only.** The transcript is the output;
    there is no organization stage to enter. A braindump never rests here.
  - `organizing` — the two LLM passes are running.
  - `organized` — **terminal, happy path, `mode: braindump` only.** The final pass-2 text exists and
    is copyable.
  - `failed` — **terminal, broke.** Carries `error: { stage, reason, detail, at }`.
  - `cancelled` — **terminal, you stopped it.** No error; carries `stoppedAt: { stage, at }`.
  - **`stage`** ∈ `recording | transcription | pass1 | pass2`.
  - **`reason`** ∈ `empty_output | cli_error | missing_binary | interrupted | timeout`
    (`timeout` is reserved; nothing ships that produces it in the MVP). There is no `no_speech`:
    a recording with no speech in it is **discarded**, not failed (#46). `empty_output` keeps its
    name rather than absorbing that meaning, because corrupt audio produces the identical
    signal — an empty transcript — and "no speech" would assert a cause never observed.

- **The two passes** — how organization works, and the reason this tool exists (ADR-0001).
  **Braindump only**; dictation has no LLM in its path.
  - **Pass 1 (annotate)** — an LLM marks `<del>` false starts, `<dup>` repetitions, `<old>`
    superseded self-corrections, `<noise>` ASR garbage. It rewrites nothing; every input word
    reappears in order, marked or not.
  - **Pass 2 (rewrite)** — an LLM applies the marks mechanically (delete `<del>`/`<dup>`/`<old>`,
    keep `<noise>` verbatim and swap the tags for the noise mark), then punctuates, paragraphs,
    fixes grammar, and formats technical identifiers. It touches nothing that was not marked.

- **Fidelity contract** — the product's promise, made testable. **Braindump only** — a dictation is
  raw Whisper output, and the contract governs what an LLM may do to speech. The single rule: *adjust the
  speech for readability and for the speaker's tone (clear, direct, brief), never change what was
  said.* Full text: [`.scratch/dictation-tool/assets/fidelity-contract.md`](.scratch/dictation-tool/assets/fidelity-contract.md).
  The test for any output is one question: *could a human have said this and meant it?*

- **ASR noise** and the **noise mark** — a transcribed span that is not plausible Portuguese is
  transcription error, not speech. It is kept verbatim and **marked** (`[? ... ?]`) so the user
  can find it; it is **never** repaired. Named after Whisper turning `se é proporcional` into
  `se profissional` — a span no model could recover from context. The mark is applied by pass 2, so
  **dictation has none**: it pastes what Whisper heard, wrong words included, and the user fixes it
  on sight.

- **Acceptance set** — the regression yardstick for **braindump organization**: four cases (three real recordings), each with a
  hand-approved expected output, judged against the fidelity contract by idea-count, new-word
  diff, modal check, and slip check. [`.scratch/dictation-tool/assets/acceptance-set.md`](.scratch/dictation-tool/assets/acceptance-set.md).
  It is a **development** artifact (human-run), not a runtime check. Judging it needs the real
  pipeline, so it is a sampled **measurement** run on demand via `DriftCheck`, reporting a failure
  *rate* over N samples rather than a pass/fail — never a unit test (ADR-0009).

## Pipeline and process terms

- **The three binaries** — the app shells out to all three by **absolute path** (ADR-0002):
  - `mlx_whisper` — local transcription (`whisper-large-v3-turbo`, `--language pt`). Exits 0 even
    on failure; success = output file exists and is non-empty.
  - `ffmpeg` — audio encode (native wav → mp3). Also invoked internally by `mlx_whisper` to decode.
  - `claude` — the Claude Code CLI, run once per pass. Gated on `is_error`, not exit code alone.

- **Preflight** — the launch-time gate that checks the three binaries are present, `claude` is
  logged in, the Whisper model is downloaded, the Input Monitoring grant is live, the
  **microphone is usable**, and — for dictation only — that Accessibility is granted. It never
  blocks the hotkey; a missing prerequisite surfaces as a degraded state, not a modal (ADR-0004,
  and the first-run decisions in the map).

- **Microphone state** — the device as it reports itself: `usable`, `permissionDenied`, `noDevice`
  or `silenced` (muted or at zero gain). A **device fact, not an acoustic one** — queried from
  AVFoundation and CoreAudio, never inferred from a recording that came back silent (#45). Read in
  preflight *and* again at the start of every recording, since mute state changes in between. An
  unusable device **refuses the recording**: it is the one thing that turns the hotkey down, on the
  grounds that capturing while knowing nothing will arrive is manufacturing the loss on purpose.
  Every unknown (a device with no mute or volume property) reads as `usable` — a false "unusable"
  costs a thought, a false "usable" costs a recording. **Accepted residual:** a device that is
  present, unmuted and gained but receiving nothing is undetectable this way.

- **Item directory** — storage is plain files, one directory per item (ADR-0003), no database.
  Holds `audio.mp3`, the three text stages, `pass1.txt` (the annotated pivot), and `meta.json`
  (the explicit `state`, `mode`, timestamps, duration, `error`, `schemaVersion`). Every write is
  temp+rename; delete goes to the macOS Trash. A dictation item holds only `audio.mp3`,
  `transcript.txt` and `meta.json`.

- **Retention** — braindump items are kept until deleted by hand: no cap, no expiry. **Dictation
  items expire by age, 7 days**, swept to the Trash. The window exists to recover a paste that just
  went wrong, not one from three weeks ago.

- **Retry** and **reprocess** — the two ways to run an item again, and they are not synonyms.
  - **Retry** *resumes*: it re-enters at the stage the item died at and reuses what survived
    (`audio.mp3`, `transcript.txt`, the `pass1.txt` pivot). Offered only on `failed`/`cancelled`,
    and only off the recording stage. Cheap; changes as little as possible. On a **dictation** item
    it can only ever mean *re-transcribe*.
  - **Reprocess** *starts over*: it discards everything derived from the audio and re-enters at
    `queued`, so transcription and both passes run again. Offered on any item past the recording
    stage, `organized` included. It is the answer to an item that finished *clean but wrong* (#24):
    with no runtime fidelity check, a pass can return fluent text that is not the speech, and
    there is no failed stage for retry to resume from. It is the one control that confirms first.
    **Does not exist on a dictation item** — there is no LLM run to start over.
  - **Derived artifacts** — what reprocess discards: `transcript.txt`, `pass1.txt`, `final.txt`.
    The audio is the input and survives. Dropping the pivot is load-bearing, not tidiness: the
    resume pass is read off its presence, so a stale one would send a later retry to pass 2.

## Interaction terms

- **The hotkey** — Right-Option double-tap (keyCode 61), 300 ms window, hard-coded, no rebind in
  the MVP. Captured via a `.flagsChanged` global monitor over Input Monitoring only (ADR-0004).

- **The hotkey grammar** — one key, two modes, decided by how long tap 2 is held. Recording starts on
  tap 2 in **both** modes; what waits for the threshold is the *label*, not the audio.
  - **`T`** — the mode threshold, **250 ms**. Released before `T` → braindump toggle. Still down at
    `T` → dictation.
  - **Push-to-talk (PTT)** — dictation's gesture: records while held, stops on release.
  - **Recording wins the key.** While a recording is in flight, *any* gesture only stops it; the
    grammar applies from idle only.
  - **Minimum duration is per mode**: 1.0 s braindump, **350 ms dictation** (`manda`, `commita` are
    legitimate dictations). The speech test is the second net for both.

- **The speech test** — the guard's energy verdict, and the reason a silent recording leaves
  nothing behind (#46). The capture accumulates the **RMS of fixed ~20 ms windows**, spanning the
  audio tap's buffers (whose size is a hint, not a guarantee), and hands the guard the **raw window
  sequence**. The verdict is *the fraction of windows above a floor*: a running peak would let one
  key click carry an empty recording into transcription, and a global average would dilute as a
  recording grew, sending a long braindump full of thinking pauses toward the silence verdict
  precisely as it got longer. A fraction is duration-invariant. Both thresholds — what counts as a
  loud window, and what fraction is enough — live at the **one seam** in `RecordingGuard`, which is
  what makes offline calibration against recorded fixtures possible, and both err toward accepting:
  a false "has speech" costs one hallucinated item you delete, a false "silent" deletes real speech
  invisibly. **Accepted residual:** the test passes and Whisper hallucinates rather than returning
  empty, so the post-transcription `empty_output` net does not fire and the item carries invented
  text. That is the tolerated direction of error, chosen over silent deletion.

- **Passthrough** — the app **cannot swallow** the gesture; the key also reaches the frontmost app.
  Benign — verified for a tap (ADR-0004) and for a multi-second hold on 3 targets (#35): no character,
  no armed dead key, no stuck modifier. Canvas apps and an ABNT layout are **untested**. A
  `listenOnly` tap is a hard limit of the permission model, not a choice — and per ADR-0007 a
  `defaultTap` stays forbidden by policy even now that Accessibility is granted.

- **Input Monitoring** — the TCC permission gating the **hotkey**, in both modes. The grant survives
  rebuilds **only** with a stable code-signing identity (ADR-0005).

- **Accessibility** — the second TCC permission, needed for **dictation's paste and nothing else**
  (ADR-0007). Checked with `AXIsProcessTrusted()` at launch and again immediately before pasting.
  Missing, it **degrades**: recording, transcript, item and clipboard all still happen and only the
  auto-paste is lost, surfaced as a per-capability banner. Braindump never needs it.

- **Auto-paste** — dictation's delivery: a synthetic `Cmd+V` via `CGEventPost` into whatever has
  focus. The app never reads the focused field (`AXFocusedUIElement` is `noValue` system-wide), so the
  paste is blind and its success is undetectable — your eye is the confirmation. The transcript is
  written to the clipboard **every time, pasted or not, and never restored**: that is the recovery net.

- **The auto-paste guard** — the boolean that decides whether the blind paste fires. Arms on key
  release, **disarms on the first app activation** (any app, this one included), pastes only if still
  armed. Deliberately not a deadline. Accepted hole: same app, different field.

- **The menubar icon** — reflects app state on a strict priority ladder, one state wins the glyph:
  `recording` > `failed` > `processing` (= `queued`/`transcribing`/`organizing`) > `idle`. The
  icon does **not** signal "ready". It is **mode-agnostic**: dictation climbs the same ladder with no
  exception, and dictation has no other visual surface — the hold is the feedback, the arriving text
  is the confirmation.

- **The panel** — the menubar dropdown: *Acontecendo agora* (live pipeline, both modes),
  *Prontos* (organized braindumps, clamped preview, click-to-copy), *Precisam de você* (`failed` /
  `cancelled` braindumps, with retry), and a separate **dictation list** (click-to-copy, retry,
  expiring at 7 days) kept out of the braindump log.

- **The ready notification** — a macOS notification, one per `organized` item, with a `Copiar`
  button that copies the final text straight from the banner. This is how you learn an item is
  done; it never opens the app. **Braindump only** — a dictation is never announced.

- **The dictation sound** — one distinct sound, two meanings: the dictation failed, or the text is
  ready but **did not land** at the cursor (queued behind a braindump, guard disarmed, paste
  swallowed). It plays **after** the paste decision, never before. There is no success sound — the
  asymmetry is about **presence**, not mode: a notification for someone who walked away (braindump),
  a sound for someone sitting there staring at the cursor (dictation).
</content>
</invoke>
