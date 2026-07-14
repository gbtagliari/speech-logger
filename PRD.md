# PRD: voice braindump to organized text (working title pending)

Status: **approved to build**. Derived from the wayfinder map in
[`.scratch/dictation-tool/`](.scratch/dictation-tool/map.md), which reached its verdict on 2026-07-13.
Every decision below traces to a resolved ticket there.

> The name `speech-flow` is **burned** (taken on npm, PyPI, by a live STT API company, and colliding with
> Wispr Flow, the category leader). Naming is an open item, not a decision.

---

## 1. The problem

Gustavo thinks by talking. His current workflow is: dictate into ChatGPT with the mic button, wait, paste
the transcript into a custom GPT that "organizes" it, wait again, copy the result back. It works, and it
costs a browser tab, two round trips and a lot of copy-paste per thought.

Worse, **it does not actually do what he asks it to do**. The reference output from that custom GPT,
inspected in ticket 01, silently downgraded a prohibition into a recommendation (`não pode` became
`não deve`), inserted qualifiers he never said (`diretamente`, `correspondente`), and repaired one of his
slips by guessing his intent. The guess was right. It is still a violation: the tool changed what he said
while claiming not to.

## 2. What we are building

A **macOS menubar app**. Press a hotkey, speak for as long as you want, press it again. The app records,
transcribes locally, organizes the text with an LLM, and drops the result in a log. Click a log entry and
its text is on your clipboard.

It is **not** a dictation replacement. Nothing is typed at the cursor, and the pipeline is asynchronous:
you speak, go back to work, and collect the text when it is ready.

### The differentiator

Every product in this market (AudioPen, Voicenotes, Wispr Flow, the whole braindump app cluster)
**summarizes or restyles**: it compresses your speech and hands back its own words. This one
**reorganizes and preserves**. That promise is written down as a contract, and the contract is the product.

## 3. The fidelity contract

Full text: [`.scratch/dictation-tool/assets/fidelity-contract.md`](.scratch/dictation-tool/assets/fidelity-contract.md).

**The rule**: adjust the speech for readability and for the speaker's tone (clear, direct, brief). Never
change what was said.

**Allowed**: strip fillers and false starts; punctuate and paragraph (one idea per paragraph); reorder into
a logical sequence; collapse a repeated idea into its clearest formulation; apply an explicit
self-correction and drop the superseded half; fix orthography and agreement; format technical identifiers
as inline code, including spoken notation (`barra sync` becomes `` `/sync` ``).

**Forbidden**:

- **Changing modal force.** `não pode` (prohibition) never becomes `não deve` (recommendation). Hedging is
  meaning: `acho que a gente tem que X` never becomes `a gente tem que X`.
- **Inserting words that carry semantic weight** the speaker did not say. Connectives, articles and
  prepositions are fine. Qualifiers, intensifiers and hedges are not.
- **Inferring intent.** A fumbled but comprehensible phrase stays fumbled, *even when the model is certain
  what was meant*. Fixing the grammar is allowed; fixing the idea is not.
- **Summarizing.** No completed idea may disappear, however tangential it looks. Only false starts,
  repetitions and superseded self-corrections may be dropped.
- Adding headings, bullets, framing or transitions that were not spoken. Swapping the speaker's words for
  better synonyms. Em-dashes and emoji.

**ASR noise**: when a span is not plausible Portuguese, it is transcription error, not speech. It is kept
verbatim **and marked** (`[? ... ?]`) so the user can find it. It is never repaired. This rule was written
after Whisper turned `se é proporcional` into `se profissional`, a span **no model could recover from
context** but every model would happily replace with something fluent and wrong.

The test for the whole contract is one question: *could a human have said this and meant it?* If yes, hands
off.

## 4. Architecture

```
hotkey (double-tap, NOT Control)
  -> record mic to mp3 (16 kHz mono, ffmpeg)
  -> transcribe locally (mlx_whisper, whisper-large-v3-turbo, --language pt)
  -> PASS 1: annotate (LLM). Marks <del> false starts, <dup> repetitions,
             <old> superseded corrections, <noise> ASR garbage. Rewrites nothing.
  -> PASS 2: rewrite (LLM). Applies the marks mechanically, then punctuates,
             paragraphs, fixes grammar, formats identifiers. Touches nothing unmarked.
  -> log entry, ready to copy
```

**Two passes, not one.** This is the load-bearing architectural decision and the reason this tool exists
rather than a $8/month subscription. Ticket 06 established that **no model reliably deletes a false start
in a single pass**, at any prompt version: Sonnet leaves the fragment, Haiku finishes the sentence for you
by inventing a word. Ticket 10 established that splitting the job fixes it. Asked only to *identify*, a
model identifies well. Asked only to *apply* a marking, it applies it. What it cannot do is decide what to
delete while it is busy rewriting.

A bought tool's custom prompt is a text box: one prompt, one model, one pass. It structurally cannot
express annotate-then-rewrite. That is the capability gap that decided build over buy.

Working prompts (a starting point, not finished): `.scratch/dictation-tool/bakeoff/twopass/pass1.txt` and
`pass2.txt`.

**Models**: Claude, via the existing Claude Code subscription. Marginal cost per utterance is therefore
zero. Sonnet did the best work in the bake-off; Haiku is a candidate for pass 1 if latency ever matters.

## 5. Domain model

A **log item** is a state machine. The list shows only its current representation:

| State | What the item is |
|---|---|
| `recording` | no content yet (a running clock) |
| `recorded` | the mp3 |
| `transcribed` | the raw transcript |
| `organized` (terminal) | the final text |

A **local DB** retains every artifact of an item (mp3, raw transcript, final text), even though the list
only ever displays the current one. **Delete** purges the item and everything under it.

Retaining the raw transcript is what makes the contract auditable: it is the only way to check that the LLM
did not drift. Re-running a stored transcript through a different prompt is a debugging affordance that
falls out for free. It is **not** a user-facing feature.

## 6. Interaction

- **Double-tap hotkey** starts recording. The same hotkey stops it. The menubar icon reflects the state.
- **The hotkey is not Control.** Control double-tap belongs to macOS dictation, which stays available as
  the offline fallback. Candidates: right-Option double-tap, or a modifier chord.
- **Click a log entry**, its final text goes to the clipboard. Pasting is the user's job. Nothing is
  injected at the cursor, so no accessibility permission for synthetic keystrokes and no "the text landed
  in the wrong window" failure.
- Latency is **not** a requirement. Processing time proportional to the audio is fine.

## 7. Acceptance criteria

The regression suite is [`.scratch/dictation-tool/assets/acceptance-set.md`](.scratch/dictation-tool/assets/acceptance-set.md):
four cases, three of them real recordings (`samples/`), each with a hand-written expected output. **Every
prompt change is judged against it.** It is the only thing standing between "organizes" and "invents".

How to judge an output:

1. **Idea count.** Enumerate completed ideas in the transcript and in the output. Any loss is a failure,
   except a false start, a duplicate, or a superseded self-correction.
2. **New-word diff.** Every word in the output that is not in the transcript must be a connective, an
   article or punctuation.
3. **Modal check.** Every modal verb and hedge survives with the same force.
4. **Slip check.** A fumbled but plausible passage is still fumbled in the output.

Known failure modes to watch, all observed: Sonnet keeps false starts; Haiku completes them, drops details
(`às sete horas da noite` vanished) and once flipped a subject (`fica aguardando` to `fico aguardando`);
every model over-marks noise, swallowing good neighbouring words into the `[? ?]` span.

## 8. Non-goals

- **Typing at the cursor.** Not a dictation replacement. Apple's dictation keeps that job and the Control
  key.
- **Custom vocabulary / glossary.** Deliberately deferred. Consequence, accepted knowingly: misheard names
  (`eBurn`) keep coming out wrong, which makes the `[? ?]` marking rule the only defence against
  transcription error.
- **Offline operation and local LLMs.** `gemma3:4b` was tested and is out: it read the prohibitions and
  froze, editing almost nothing. No network, no tool.
- **Privacy as a constraint.** It is not one. Cloud is fine.
- **Reprocessing as a feature.** Debug affordance only.
- **Long-form braindump to a saved markdown document.** The original framing, dropped.
- **Windows, Linux, and languages beyond pt-BR with technical English.**

## 9. Open questions

- **Form factor**: native Swift menubar app, a fork of VoiceInk or OpenWhispr (both ship the hotkey,
  recording and local Whisper already), or a CLI driven by Hammerspoon.
- **The hotkey**, concretely, and how to capture a double-tap on macOS.
- **Failure states**: what the log shows when an item dies mid-pipeline (no network, model error, garbage
  out), and whether it retries.
- **Retention**: the DB keeps every mp3 forever. Nobody has said for how long that is worth doing.
- **Prompt calibration**: pass 1 under-marks repetitions (it missed `com o time, o time do Packers`), pass 2
  under-strips fillers (`Puts`, `sei lá`, `aí` survived). Both are tuning, not architecture.
- **The name.**

## 10. What we knowingly skipped

**The off-the-shelf baseline was never measured.** superwhisper (local Whisper, a Custom Mode where the
post-processing prompt is yours, roughly $8/month) was the strongest buy candidate and it was never
installed. The decision to build rests on the two-pass capability gap, which is a sound argument, but if
superwhisper would have covered most of the need for $8, that fact was available and was skipped
deliberately. Recorded here so it is not relitigated later as an oversight.
