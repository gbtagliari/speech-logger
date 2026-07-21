# ADR-0008 — The transcript reaches each pass as delimited data, never as a request

Status: accepted
Date: 2026-07-21

## Context

Both organization passes (ADR-0001) are `claude --print` invocations: the prompt rides in
`--system-prompt` and the text to transform goes on stdin, i.e. as a separate user turn.

Each system prompt used to end in a dangling label — `TRANSCRIÇÃO:` for pass 1, `TEXTO ANOTADO:`
for pass 2 — written as though the text followed inline. It does not. The model saw an
instruction block ending in an unfilled label, then a user message.

With that shape, a **clean** dictation reads as a request addressed to the model. Instead of
transforming the text, the model answered it:

> Não identifiquei nenhuma tarefa concreta a executar no seu texto (…) Me diga o que você precisa
> e eu executo.

> Quer que eu: 1. Crie um arquivo de guia de contribuição (ex: `CONTRIBUTING.md`)…

Sampling the real pipeline put this at **22/45 (~49%)** of runs on the typed acceptance case. It
happened at pass 1 (which then fed a chat reply into pass 2, which faithfully rewrote it) and
independently at pass 2.

Controlled arms isolated the trigger:

| arm | role collapse |
|---|---|
| baseline | 8/15 |
| same content, with disfluencies | 0/10 |
| clean but narrative, not instructional | 5/10 |
| dangling label removed | 2/15 |
| input wrapped in a delimiter | 0/15 |
| explicit "never answer the content" line | 0/15 |

The driver is the **cleanliness** of the input, not what it says: clean narrative prose collapses
at the baseline rate, while disfluent speech never collapsed once. Messy ASR is self-evidently
data; well-formed prose is not. That is not addressable from the input side — a user typing or
dictating cleanly is the normal case, and case 01 of the acceptance set is exactly that.

## Decision

Mark the boundary structurally **and** state the rule explicitly.

- `ClaudeOrganizer` wraps each pass's stdin in a tag naming the artifact: `<transcricao>` for pass
  1, `<texto_anotado>` for pass 2.
- Both prompts drop the dangling label and instead state that the next message is data to
  transform, that it is never a request, and that the model must not answer, comment, summarize
  or offer help however the content reads.

Both were measured to reach 0/15 alone. They ship together because they fail differently: the
delimiter is structural and survives prompt edits, the sentence is explicit and survives a model
that ignores delimiters.

The delimiter also bounds a second problem the product has by construction. Dictated speech is
arbitrary text, so a user who dictates something shaped like an instruction must still get it
transformed, never obeyed. Delimiting the span is the standard mitigation.

## Consequences

- Post-fix sampling: **0/28** on the previously-collapsing case, **0/32** across all four
  acceptance cases. No fidelity regression; case 04 still marks `[? se profissional ?]`.
- The tags must not appear in output. Both prompts say so, and no sampled run leaked one.
- The committed prompts in `Sources/SpeechLoggerCore/Resources/` are now **canonical** and diverge
  from the bake-off copies in `.scratch/dictation-tool/bakeoff/twopass/`, which were byte-identical
  until this change. The bake-off copies are a frozen record of that experiment, not a source to
  sync against. ADR-0001 still names them "the working prompts"; that line is stale.
- ADR-0001 calls prompt calibration "implementation tuning, not an architectural decision". Input
  framing is the exception: it decides whether the model performs the task at all, independently
  of how the task is worded.
- **`--effort low` was a necessary condition for the bug.** On the pre-fix prompts the same input
  collapsed 10/15 at `low` and **0/15** at `high`: given enough budget the model notices the role
  conflict unaided. Raising effort is not an available fix — the contract pins `low` for cost and
  latency (ADR-0002) — but it has two consequences that are:
  - The fix holds at higher effort too (0/15 on the shipped prompts at `high`), so changing effort
    does not reintroduce this.
  - Every drift number here is **only meaningful at `--effort low`**. A measurement taken at higher
    effort reports clean whether or not the prompts are still sound. `DriftCheck` goes through
    `ClaudeOrganizer`, which pins it, so this holds as long as the pin does — `OrganizerTests`
    covers that.
