# ADR-0006 — Concurrency: exclusive recording, serial transcription, parallel organization

Status: accepted
Date: 2026-07-15

## Context

The pipeline is asynchronous: the user can trigger a new recording while earlier items are still
transcribing or organizing. The app needs one coherent rule for what the hotkey does mid-flight and
how many pipeline stages may run at once. Two facts from the shell-out research constrain it:
`mlx_whisper` run twice concurrently only buys ~20% (serializing is nearly free), while `claude`
organization parallelizes cleanly.

## Decision

Three lanes with different concurrency:

- **Recording is exclusive.** One mic; the hotkey toggles the *current* capture (start if idle, stop
  if recording). Recording never overlaps.
- **Transcription is a single serial FIFO lane.** Items that finished recording wait in the `queued`
  state until the lane is free. Serializing costs ~20% and removes all contention.
- **Organization is unbounded parallel**, drip-fed by the transcription lane. No cap is needed — the
  serial lane upstream is the natural backpressure.

Rules that fall out:

- **The hotkey never refuses a new recording.** Its behavior depends only on whether you are currently
  recording (stop) or not (start). The transcription queue is unbounded.
- **The menubar icon is a strict priority ladder**, one state wins the glyph:
  `recording` > `failed` > `processing` (= `queued`/`transcribing`/`organizing`) > `idle`.
- **Quit never blocks.** Graceful quit marks in-flight processing items `cancelled` (resume from stage
  next launch) and kills their subprocesses; a crash/force-kill falls through to boot recovery as
  `failed`/`interrupted`; quit **while recording** discards the in-progress recording silently (a
  recording has nothing to resume).
- Retries reuse the same lanes: a transcription retry goes to the serial lane, an organization retry
  runs parallel.

## Consequences

- This **adds the `queued` state** to the item state machine (ADR-0003, `CONTEXT.md`).
- Isolated item directories (ADR-0003) make parallel organization safe with no shared writer.
- `cancelled` (this ADR and the failure-states decision) is distinct from `failed`; it shows in the
  panel but does **not** drive the menubar icon.
- The live pipeline (`queued`/`transcribing`/`organizing`) is the hero of the panel's *Acontecendo
  agora* section.
</content>
