# SPEC — speech logger (MVP)

The closed scope of the MVP, implementable as written. Every decision that blocked opening an editor
is resolved here; the load-bearing ones are recorded as ADRs under [`docs/adr/`](docs/adr/), and the
domain vocabulary is in [`CONTEXT.md`](CONTEXT.md). Source of the problem framing is [`PRD.md`](PRD.md);
the decision record behind it is the closed wayfinder map in `.scratch/dictation-tool/`.

The MVP is the **whole PRD** (§2–§6): hotkey, recording, local transcription, two-pass LLM
organization, a local store retaining every artifact, and a menubar log with click-to-copy and delete.
Only the PRD's non-goals (§8) are out.

## Problem Statement

Gustavo thinks by talking. His workflow is to dictate into ChatGPT, wait, paste the transcript into a
custom GPT that "organizes" it, wait again, and copy the result back. It costs a browser tab, two
round trips, and a lot of copy-paste per thought.

Worse, it does not do what he asks. The reference output silently downgraded a prohibition into a
recommendation (`não pode` → `não deve`), inserted qualifiers he never said, and "repaired" a slip by
guessing his intent. Every product in this market (AudioPen, Voicenotes, Wispr Flow, superwhisper)
does the same thing by default: it **summarizes or restyles** — it compresses your speech and hands
back its own words.

He wants a tool that **reorganizes and preserves**: cleans speech into readable text without ever
changing what was said, running locally and asynchronously so he can speak and collect the result
later.

## Solution

A **macOS menubar app**. Press a hotkey (Right-Option double-tap), speak for as long as you want, press
it again. The app records the audio, transcribes it locally, and organizes the text through two LLM
passes governed by a strict **fidelity contract** — the promise, written down and testable, that the
tool reorganizes but never invents. The result lands in a log as a **log item**; a notification tells
you it is ready with a one-click `Copiar`. Click any item in the log and its final text is on your
clipboard. Nothing is typed at the cursor; the pipeline is asynchronous.

Every artifact of an item (mp3, raw transcript, annotated pass-1 text, final text) is retained on
disk, because the retained trail is the only way to audit that the LLM held the contract.

The differentiator is the contract, and the contract is the product. It is deliverable because of the
**two-pass architecture** (ADR-0001): a single prompt cannot express "annotate, then apply the
annotations" — which is exactly what preserving speech while deleting only false starts requires — and
that capability gap is what decided build over buy.

## User Stories

### Capture

1. As a user, I want a global hotkey that works while any app is focused, so that I can start a
   thought without switching windows.
2. As a user, I want Right-Option double-tap to start recording and the same double-tap to stop it, so
   that one gesture drives the whole capture.
3. As a user, I want the hotkey to **not** be Control, so that macOS dictation stays available on its
   own Control double-tap as an offline fallback.
4. As a user, I want to speak for as long as I want with no recording cap, so that a long braindump is
   never cut off mid-thought.
5. As a user, I want the menubar icon to show that the mic is live while recording, so that I trust the
   app is actually capturing.
6. As a user, I want a running clock while recording, so that I know a long recording is still going
   and have not left the mic on by accident.
7. As a user, I want my double-tap to also pass through to the app I am typing in (it is harmless), so
   that the app needs only Input Monitoring and never Accessibility.
8. As a user, I never want the app to be able to read text I type, so that a global keystroke monitor
   is not a keylogger — it watches modifier flags only.
9. As a user, I want to trigger a new recording even while earlier items are still processing, so that
   the hotkey never refuses me.

### Transcription and organization

10. As a user, I want my audio transcribed locally with Whisper, so that transcription costs nothing
    per utterance and needs no upload.
11. As a user, I want the transcript organized into clean, readable, paragraphed text, so that a raw
    spoken braindump becomes something I can paste.
12. As a user, I want fillers, false starts, repetitions, and superseded self-corrections removed, so
    that the noise of thinking-out-loud is gone.
13. As a user, I want every completed idea preserved even if it looks tangential, so that the tool
    never summarizes away something I meant to say.
14. As a user, I want modal force preserved (`não pode` stays a prohibition, `acho que` stays a hedge),
    so that the strength of what I said is never quietly changed.
15. As a user, I want no semantically-weighted word inserted that I did not say, so that the output is
    my meaning, not the model's embellishment.
16. As a user, I want a fumbled-but-plausible passage left as I said it, so that the tool never
    "repairs" a slip by guessing my intent, even when the guess would be right.
17. As a user, I want technical identifiers formatted as inline code (`barra sync` → `` `/sync` ``) and
    product names capitalized (`chat GPT` → `ChatGPT`), so that the output reads as technical writing.
18. As a user, I want a span that is not plausible Portuguese kept verbatim and **marked** `[? ... ?]`,
    so that a transcription error is flagged for me to fix, never silently replaced with something
    fluent and wrong.
19. As a user, I want only the final pass-2 text to be copyable as final, so that I never paste a
    half-organized intermediate by mistake.

### The log and getting the text

20. As a user, I want each recording to become a log item I can see, so that I have a list of my
    thoughts and their state.
21. As a user, I want a macOS notification when an item is ready, with a `Copiar` button that copies
    the final text straight from the banner, so that I collect a thought without opening the app.
22. As a user, I want to click a ready item in the log to copy its final text, so that I can grab it
    later from the app too.
23. As a user, I want a short preview (a few lines, not one, not the whole thing) of each ready item,
    so that I can tell items apart without opening each one.
24. As a user, I want to see what is happening right now (recording clock; queued / transcribing /
    organizing with stage and progress), so that the async pipeline is legible.
25. As a user, I want to delete a log item, so that I can discard a thought I do not want kept.
26. As a user, I want delete to go to the macOS Trash, so that I can recover an item I removed by
    mistake.
27. As a user, I want a notification per ready item rather than a batched one, so that each carries its
    own `Copiar`.

### Failure, cancellation, and recovery

28. As a user, I want an item that broke to stay in the log marked `failed` with the reason, so that a
    dead thought is not silently lost.
29. As a user, I want to retry a failed item from the stage it died at, reusing what was already
    produced, so that a transient failure costs me one click, not a re-recording.
30. As a user, I want a manual "stop processing" control on an in-flight item, so that I can abort work
    I no longer want without force-quitting.
31. As a user, I want a stopped item marked `cancelled` (distinct from `failed`) and retryable, so that
    I can resume it later.
32. As a user, I want a too-short accidental tap discarded silently, so that a fat-fingered double-tap
    does not litter the log.
33. As a user, I want a long-but-silent recording to fail cleanly with `no_speech`, so that an empty
    recording does not produce a hallucinated transcript.
34. As a user, I want items left mid-pipeline by a crash/quit/sleep to be recovered on next launch
    (marked `failed`/`interrupted`, retryable where there is something to resume), so that a crash
    never leaves a stuck item.
35. As a user, I want quitting the app to never hang, so that in-flight processing is cancelled
    cleanly and I am not blocked.
36. As a user, I want a `failed` item to raise the menubar icon (it is persistent and easy to miss),
    so that I notice something needs me even after I walked away.

### First run and prerequisites

37. As a user, I want the app to check its prerequisites at launch (the three binaries present,
    `claude` logged in, Whisper model downloaded, Input Monitoring granted), so that I learn what is
    missing instead of hitting a silent failure.
38. As a user, I want a missing prerequisite shown as a degraded state with a path to fix it (a
    deep-link to the right Settings pane), never a blocking modal, so that the app is still usable.
39. As a user, I want the one thing preflight can fix for me — the Whisper model download — offered as
    a click, so that first run is not a manual shell chore.
40. As a user, I want a preflight failure to never block the hotkey: the recording still happens and
    lands as a retryable `failed` item, so that I never lose a thought to a missing dependency.

## Implementation Decisions

### Form factor and dependencies

- **Native Swift macOS menubar app.** Not a fork (VoiceInk is GPL — read, never copy, per
  `CLAUDE.md`), not a CLI, not a Hammerspoon script.
- **No third-party package for storage or Whisper/LLM.** The heavy lifts are external binaries
  (below); storage is plain files (ADR-0003). Permissive dependencies (MIT/Apache/BSD/ISC) are allowed
  if a real need appears; copyleft is forbidden.
- **Two build settings are fixed, not open:** App Sandbox **off** (ADR-0002), and every build **signed
  with a stable identity + fixed bundle id** (ADR-0005). A self-signed cert suffices; the machine's
  revoked Apple Development cert must not be used.

### The pipeline (ADR-0002)

- Shell out to three binaries, **all by absolute path**: `mlx_whisper` (transcription), `ffmpeg`
  (encode), `claude` (both LLM passes). Pinned invocations live in the two shell-out contract docs
  under `docs/research/`.
- **Audio**: record native wav to a temp file (streamed, O(1) RAM) → `ffmpeg` encode to
  **mono / 16 kHz / 64 kbps mp3** → feed the mp3 to `mlx_whisper` → keep the mp3, delete the wav. The
  mp3 is the recording, the transcriber input, and the retained artifact at once, so the kept file
  reproduces production exactly. 16 kHz is the exact acceptance-set sample format (Whisper discards
  >8 kHz; 32 kHz was rejected as leaving the verified baseline).
- **A dual guard gates recording** before transcription: a minimum-duration check and an energy floor.
  A short tap is discarded silently (story 32); a long-but-silent recording fails `no_speech` (story
  33). This exists because `mlx_whisper` hallucinates (`E aí`) on silence.
- **Organization is two `claude` calls** (ADR-0001): pass 1 annotates with the `pass1.txt` prompt,
  pass 2 rewrites with the `pass2.txt` prompt. `--effort low` is mandatory; there is no fallback model,
  only retry. The starting prompts are `.scratch/dictation-tool/bakeoff/twopass/pass1.txt` and
  `pass2.txt`.
- **Error detection is structural, never fidelity.** The app never judges the contract at runtime;
  fluent-but-wrong output flows to `organized`, and the retained trail + acceptance set catch drift
  offline. Gates: transcription = output file exists and is non-empty (`mlx_whisper` exits 0 always);
  each pass = `is_error` or empty output.
- **No app-imposed timeout** ships. A dead network makes `claude` hang ~179 s/try; the answer is the
  manual "stop processing" control (story 30), not an auto-timeout. `reason: timeout` is reserved in
  the schema but nothing produces it.

### Storage and the item state machine (ADR-0003, ADR-0006)

- Plain files, **one directory per item** under `Application Support/speech-logger/items/<sortable-name>/`;
  no database. Each holds `audio.mp3`, three text stages, `pass1.txt`, and `meta.json`.
- `meta.json` carries an **explicit `state`**, `created` + per-transition timestamps, duration, an
  `error` object, and `schemaVersion`. Every write is temp+rename; the content file is written before
  `state` flips.
- **Canonical states** (supersedes `PRD.md` §5's four-state table): `recording` → `queued` →
  `transcribing` → `organizing` → `organized` (terminal), plus `failed` and `cancelled` (terminal
  off-ramps).
  - `failed` carries `error: { stage, reason, detail, at }`; `cancelled` carries
    `stoppedAt: { stage, at }`.
  - `stage` ∈ `recording | transcription | pass1 | pass2`; `reason` ∈ `no_speech | empty_output |
    cli_error | missing_binary | interrupted | timeout`.
- **The invariant**: final text = pass-2 output only, present only in `organized`. Nothing partial is
  ever copyable as final.
- **Retry is manual, resuming from the failed/stopped stage**, reusing retained artifacts. No
  auto-retry. A `recording`-stage death has nothing to resume (delete only).
- **Delete → macOS Trash** (`FileManager.trashItem`). **Retention is manual only** — no automatic
  expiry, no cap.
- **Boot recovery**: any non-terminal item with no live process → `failed`/`interrupted` (retryable,
  except a `recording` orphan which has nothing to resume). Graceful quit marks in-flight processing
  `cancelled` and kills subprocesses; quit while recording discards the recording silently.

### Concurrency (ADR-0006)

- Recording is **exclusive**; transcription is a **single serial FIFO lane** (items wait in `queued`);
  organization is **unbounded parallel**, drip-fed by the lane. The hotkey never refuses a recording.
- Retries reuse the same lanes (transcription → serial, organization → parallel).

### The hotkey and permissions (ADR-0004, ADR-0005)

- **Right-Option double-tap, keyCode 61, 300 ms window**, hard-coded, no rebind in the MVP. Captured
  via `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`, gated by
  `CGPreflightListenEventAccess()`; mask the flag word to `0x207F` first.
- Costs **Input Monitoring only**. The app **cannot swallow** the double-tap (passthrough) and is
  **structurally incapable of reading typed text** (`.flagsChanged` only) — promote this to a product
  guarantee.
- Denied permission **degrades** (menubar "needs permission" state + deep-link to the Settings pane,
  auto-recover on focus), never a modal. Trust `CGPreflightListenEventAccess()`, never the Settings
  toggle (it lies after a bad rebuild). Preflight is a launch-time read; re-check on focus/panel-open.

### First-run preflight

- A **uniform launch-time gate**, not a wizard, reusing the degrade pattern. Checks: three binaries
  present (`stat`-presence only, absolute paths), `claude` logged in (presence of
  `~/.claude/.credentials.json`, never a burned API call), Whisper model downloaded, Input Monitoring
  granted.
- **The Whisper model download is the one thing preflight fixes** — a user-clicked `mlx_whisper` run
  without `HF_HUB_OFFLINE=1`. Everything else is check-and-report.
- **Preflight never blocks the hotkey.** A missing prerequisite at capture time records the item →
  `failed`/`missing_binary` (retryable). Reporting = the aggregate `failed` icon tier + per-check
  detail in the panel.

### UI: menubar icon, panel, notification

- **Menubar icon** = strict priority ladder, one glyph: `recording` > `failed` > `processing` >
  `idle`. It does **not** signal "ready". Literal artwork is a cosmetic implementation choice.
- **The ready signal is a macOS notification** — one per `organized` item, with a `Copiar` button that
  copies the final text straight from the banner and a `Dispensar` alongside. It never opens the app.
  No batching (parallel-organized items may stack).
- **The panel** (menubar dropdown) has three sections:
  - *Acontecendo agora* — recording clock; queued / transcribing / organizing with stage and progress.
    Makes the lane model the hero.
  - *Prontos* — green dot + a preview **clamped to ~3 lines / a char cap** (not one line, not the full
    text) + click-to-copy the pass-2 text.
  - *Precisam de você* — `failed` (amber + reason + retry) and `cancelled` (grey + retry).
- Prototype the panel decisions were reacted to:
  `https://claude.ai/code/artifact/656e3947-dad7-4887-9f54-1298080493d0`.

## Testing Decisions

**What makes a good test here**: it exercises **external behavior at a seam**, never an implementation
detail. The single most valuable seam is the **pipeline boundary**, and the two heavy stages already
have pinned, documented contracts to test against.

- **Highest seam — the organization stage as a pure function of text.** Pass 1 and pass 2 are
  `(transcript, prompt) → text` over the `claude` shell-out. Test them by feeding the **acceptance
  set** (`.scratch/dictation-tool/assets/acceptance-set.md`: four cases, three real recordings, each
  with a hand-approved expected output) through the real two-pass pipeline and judging the output
  against the **fidelity contract** by its four checks: idea count, new-word diff, modal check, slip
  check. This is the product's regression suite. It is **developer-run and offline** — the app never
  judges fidelity at runtime.
  - Known failure modes the suite must keep catching: Sonnet keeps false starts; Haiku completes them
    and drops details; every model over-marks noise, swallowing good neighbours into the `[? ?]` span;
    `se profissional` must be **marked, not repaired** (a model that rewrites it fails regardless of
    the rest).
- **Transcription seam.** Test the `mlx_whisper` wrapper's contract, not Whisper's accuracy: success =
  output file exists and is non-empty (it exits 0 on failure), silence triggers the dual guard, the
  pinned command is used. A wrong model does not fail loudly — it lies — so assert the model actually
  used.
- **State machine.** Test transitions and the invariant (final text = pass-2 only, present only in
  `organized`) as behavior over `meta.json`: each state, each off-ramp (`failed` reason values,
  `cancelled`), boot recovery of an orphaned item, and that `temp+rename` never leaves a half-written
  content file visible.
- **Concurrency.** Test the lane rules as observable behavior: recording is exclusive, the hotkey
  never refuses, transcription serializes (FIFO via `queued`), organization runs parallel, quit
  cancels in-flight without blocking.
- **Hotkey detection logic.** The flag-masking (`0x207F`) and the 300 ms double-tap window are pure
  logic over synthetic `flagsChanged` events and should be unit-tested directly — this is where the
  "detector silently never fires" bug lives.
- **Prior art**: none in-repo yet (greenfield). The acceptance-set-as-regression-suite pattern is the
  established one and should anchor the test layout.

## Out of Scope

The PRD's non-goals (§8) plus the map's explicit exclusions:

- **Typing at the cursor.** Not a dictation replacement; Apple's dictation keeps that job and Control.
- **Custom vocabulary / glossary.** Deferred knowingly — misheard names (`eBurn`) keep coming out
  wrong, which is exactly why the `[? ?]` marking rule is the only defence against transcription error.
- **Offline / local LLMs.** `gemma3:4b` was tested and froze on the prohibitions; cloud (via the
  `claude` subscription) is fine. Privacy is not a constraint.
- **Reprocessing as a feature.** Re-running a stored transcript is a debug affordance only, not
  user-facing.
- **Long-form braindump to a saved markdown document.** The original framing, dropped.
- **Windows, Linux, and languages beyond pt-BR with technical English.**
- **The final product name.** `speech logger` is the working title; renaming is a later chore.
- **Prompt calibration.** `pass1`/`pass2` are good enough for the MVP; tuning them against the
  acceptance set is implementation work, not a scope decision.
- **Build vs buy / measuring the superwhisper baseline.** Closed by `PRD.md` §10.
- **Distribution: notarization, `.dmg`, auto-update.** The MVP runs from a local signed build on one
  machine. (Code **signing** for TCC stability is in scope and decided — ADR-0005.)

## Further Notes

- **The one open build prerequisite** before an editor opens: procure a usable signing identity (a
  self-signed code-signing cert, or a non-revoked Developer identity — the machine's Apple Development
  cert is revoked and makes XProtect trash the app). The Xcode project scaffold and deployment target
  are the remaining scaffolding question; no third-party package is pulled in for storage.
- **The retained trail is the evidence, not decoration.** Retaining `pass1.txt` (amending `PRD.md` §5)
  is what makes the two-pass contract auditable end to end. Discarding the trail discards the proof the
  contract held.
- **"Zero marginal cost" is a subscription claim, not an infinite one**: ~$0.02 of subscription quota
  per utterance, no dollars.
</content>
