# ADR-0007 — Dictation mode pastes at the cursor: Accessibility, and what that revokes

Status: accepted
Date: 2026-07-20

## Context

The app gains a **second mode**. Two speech acts, not two moods: a short throwaway instruction (a prompt
for an agent — you read the result in two seconds and fix it) and a **braindump** (thought being formed,
which needs the fidelity contract). Opposite requirements; no single LLM prompt serves both.

**Dictation** is push-to-talk, raw STT with no LLM, delivered **at the cursor**. That delivery is exactly
what the product declared a non-goal ("typing at the cursor") and what ADR-0004 promoted from an
implementation detail to a product guarantee. Revoking an ADR is an explicit act, not the side effect of
shipping a feature — hence this one.

The facts this decision rests on come from map [#25](https://github.com/gbtagliari/speech-logger/issues/25):
the hotkey grammar ([#27](https://github.com/gbtagliari/speech-logger/issues/27)), the paste mechanism and
where it breaks ([#28](https://github.com/gbtagliari/speech-logger/issues/28)), the concurrency question
([#29](https://github.com/gbtagliari/speech-logger/issues/29)), failure handling
([#30](https://github.com/gbtagliari/speech-logger/issues/30)), the latency floor
([#33](https://github.com/gbtagliari/speech-logger/issues/33)) and the passthrough verification
([#35](https://github.com/gbtagliari/speech-logger/issues/35)).

## Decision

**Dictation pastes at the cursor with a synthetic `Cmd+V` (`CGEventPost`), and the app therefore requires
the Accessibility permission — for the paste only.**

- **Capture does not change.** Push-to-talk is press and release, both `flagsChanged`, so the hold is free:
  no `.keyDown`, no Accessibility. ADR-0004's capture decision stands in full, mask and all.
- **No manual-`Cmd+V` fallback.** Auto-copy plus "you press `Cmd+V`" was rejected because it is a **race
  with no signal**: paste before the transcript lands and you paste the *old* clipboard, silently, and an
  old clipboard is usually plausible text. A wrong paste that looks right is worse than no paste.
- **`AXUIElement` is not the mechanism.** System-wide `AXFocusedUIElement` returned `noValue` on 100% of
  targets (#28), so there is no reading of the focused field, and the secure-field guard by AX subrole is
  dead code: macOS hides secure fields from AX entirely.

### What this revokes in ADR-0004

The guarantee **"the app is structurally incapable of reading typed text"** is downgraded. With
Accessibility granted, the capability exists; what remains is that the app **chooses not to** use it.
Impossibility becomes a promise. The promise is kept by the same rules as before, now as policy rather than
as a consequence of the permission set:

- Match on **`.flagsChanged` only, never `.keyDown`.**
- No `defaultTap` event tap for capture. (#35 registered an unverified idea — a `.defaultTap` could swallow
  the passthrough at the source — and it stays unused: it would spend the Accessibility grant on reading the
  event stream, which is precisely the line this ADR is holding.)

Also corrected: ADR-0004 justified right-Option over left with *"left Option is the pt-BR accent modifier"*.
The keyboard in use is **ABC, not ABNT** (#35), so that sentence describes a layout that is not the one
being typed on. The choice of right-Option stands — it is inert during typing on this layout too — but the
stated reason was wrong and is not repeated here.

### What this revokes in the product's non-goals

- **"Typing at the cursor. Not a dictation replacement."** Revoked. It was not wrong reasoning applied to
  bad facts; it was correct reasoning applied to a **one-mode product**. The new information is that there
  are two speech acts with opposite requirements, and the second one is worthless without cursor delivery.
  Apple's dictation keeps the Control key, not the job.
- **"Nothing is injected at the cursor."** Holds for **braindump**, falls for **dictation**. Braindump
  delivery stays clipboard-on-click, and for the original reason: it is asynchronous, so the app cannot
  know where the cursor will be when the text is ready. Auto-pasting a braindump 40 seconds later remains a
  non-goal (the "empty diagonal" ruled out of scope on the map).

### What does not change in ADR-0006

Nothing. #29 closed with dictation as an ordinary item on the **serial FIFO transcription lane**: it does
not jump the queue, does not preempt, and gets no parallel lane. Recording stays exclusive — while a
recording is in flight, any gesture on the key only stops it. Recorded here because #31 was written
expecting a change, and the absence of one is itself the finding.

## Consequences

- **Accessibility is a dictation-only prerequisite, and its absence degrades rather than kills** (#30):
  without it the app still records, transcribes, creates the item and writes the clipboard — only the
  auto-paste is lost. Surfaced as a per-capability banner, never a modal, never blocking the hotkey.
  Braindump remains fully usable on Input Monitoring alone.
- **The grant survives rebuilds**, given the stable signing identity of ADR-0005:
  `AXIsProcessTrusted` stayed `true` across a rebuild with no re-grant (#28). Without ADR-0005 this decision
  would cost a re-authorization per build.
- **Password fields: native is safe, web is not.** macOS drops the synthetic paste into a native secure
  field; a web or Electron password field is neither protected nor detectable (#28). Residual risk,
  knowingly accepted.
- **The clipboard is written on every dictation and never restored.** It is the recovery net for every
  failure mode the paste has (#29, #30) — if nothing lands, `Cmd+V` gets it back. The cost is that dictation
  burns the clipboard, and the accepted mirror of the rejected auto-copy: the write is silent.
- **`CGPreflightListenEventAccess()` gains a sibling.** Accessibility is checked with `AXIsProcessTrusted`,
  at launch and again at paste time; the state can change between the two.
- The Carbon `RegisterEventHotKey` lever from ADR-0004 — the zero-permission answer if the hotkey ever
  becomes an ordinary combo — is now worth less: it retires Input Monitoring, not Accessibility, and after
  this ADR the app holds both.
