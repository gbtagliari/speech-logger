# ADR-0003 — Storage: plain files, one directory per item, no database

Status: accepted
Date: 2026-07-15

## Context

Every artifact of a log item is retained — the mp3, the raw transcript, the annotated pass-1 text,
and the final text — because the retained trail is the only way to audit that the LLM held the
fidelity contract. The question is how to store it. The domain is a **flat list, always read whole**;
there are no relational queries, no joins, no search. Items are also written concurrently (recording
one while others transcribe/organize).

## Decision

Store each item as its own **directory** of plain files under
`Application Support/speech-logger/items/<sortable-name>/`. No SQLite, no third-party storage package.

Each item directory holds:

- `audio.mp3` — the recording, the transcriber input, and the retained artifact at once.
- Three text stages: raw transcript, `pass1.txt` (the annotated pivot), and the final text.
- `meta.json` — an **explicit `state` field** (not inferred from file presence — only an explicit
  field can represent `recording` and `failed`), `created` plus per-transition timestamps, duration,
  an `error` object, and `schemaVersion`.

Rules:

- The directory name is a **ULID-style timestamp-sortable** id (a random `UUIDv4` cannot order).
- Every write is **temp + rename**; the content file is written **before** `state` flips. No central
  index, so there is nothing to keep consistent across items.
- **Delete goes to the macOS Trash** (`FileManager.trashItem`), recoverable.
- **Retention is manual only** — no automatic expiry, no cap in the MVP. Discarding the trail
  discards the evidence the contract held.

## Consequences

- A relational store's query power would sit entirely idle; isolated directories buy the concurrency
  model (ADR-0006) for free — no shared writer, no lock.
- `pass1.txt` is retained alongside the final text, so the two-pass contract is auditable end to end.
- Disk grows unbounded on the retained mp3s; accepted, mitigated only by the visible running clock and
  manual delete.
- `meta.json`'s `schemaVersion` is the migration seam if the shape ever changes.
</content>
