# ADR-0001 — Two-pass LLM organization: annotate, then rewrite

Status: accepted
Date: 2026-07-15

## Context

The product's promise is the fidelity contract: reorganize speech for readability without changing
what was said. The single hardest operation under that contract is deciding what to **delete** (a
false start, a repetition, a superseded self-correction) without touching anything else.

The bake-off (closed map, tickets 06/10) established that **no model reliably deletes a false start
in a single pass**, at any prompt version: Sonnet leaves the fragment in place; Haiku "helps" by
finishing the abandoned sentence, inventing a word. A model asked to identify *and* rewrite in one
shot cannot hold the contract — it decides what to cut while it is busy rewriting, and the two jobs
interfere.

A bought tool's post-processing is a single text box: one prompt, one model, one pass. It
structurally cannot express annotate-then-rewrite. This capability gap is what decided build over
buy (`PRD.md` §10).

## Decision

Organize in **two separate LLM calls**:

- **Pass 1 — annotate.** The model marks four things and rewrites nothing: `<del>` false starts,
  `<dup>` repetitions, `<old>` superseded corrections, `<noise>` ASR garbage. Every input word
  reappears in output, in order, marked or not. When in doubt, it does not mark.
- **Pass 2 — rewrite.** The model applies the marks mechanically (delete `<del>`/`<dup>`/`<old>`;
  keep `<noise>` verbatim and swap the tags for the `[? ... ?]` mark), then punctuates, paragraphs,
  fixes orthography/agreement, and formats technical identifiers. It may delete **nothing** that was
  not marked, insert no semantically-weighted word, and never change modal force.

Asked only to *identify*, a model identifies well. Asked only to *apply* a marking, it applies it.
Splitting the job is the fix.

The working prompts are `.scratch/dictation-tool/bakeoff/twopass/pass1.txt` and `pass2.txt` — good
enough for the MVP. Calibrating them is implementation tuning, not an architectural decision.

## Consequences

- Two `claude` invocations per item, serialized (pass 2 consumes pass 1's output). Latency is not a
  requirement, so this is free.
- **Pass 1's annotated output is retained** (`pass1.txt`), which makes the contract auditable end to
  end — you can see exactly what was marked for deletion (ADR-0003).
- The final copyable text is **pass-2 output only**. Nothing partial is ever copyable as final.
- Correctness is verified offline against the acceptance set, never judged by a third LLM at runtime.
</content>
