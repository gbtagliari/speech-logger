<picture>
  <source media="(prefers-color-scheme: dark)" srcset="brand/svg/lockup-horizontal-dark.svg">
  <img src="brand/svg/lockup-horizontal.svg" width="320" alt="speech-logger">
</picture>

A macOS menubar app that turns speech into organized text.

Press a hotkey, talk for as long as you want, press it again. The app records, transcribes,
and reorganizes the text for readability **without changing its meaning**. The result lands in
a log; click an entry and its text is on your clipboard.

That is **braindump** mode: nothing is typed at the cursor and the pipeline is asynchronous, so you
speak, go back to work, and collect the text when it is ready.

A second mode, **dictation**, is specified but not yet built: hold the same hotkey instead of releasing
it, and the raw transcript is pasted where your cursor already is, with no LLM in the way. It is for
the other kind of speech — a short throwaway instruction you read and fix in two seconds.

## Why it exists

Every tool on the market either transcribes verbatim or "improves" your words: summarizing,
restyling, swapping in better synonyms, quietly repairing what it thinks you meant. Both miss
the point. The goal here is to strip the fillers, false starts and repetition, and to punctuate
and reorder into something readable, while every idea, every hedge, and every modal ("cannot"
never becomes "should not") survives intact.

That fidelity contract is the whole product. Delivering it is what decided the two-pass
architecture (ADR-0001), and it is enforced by an acceptance set of real recordings.

## A personal project

This is a personal project, built to study two things.

The first is the product. [Wispr Flow](https://wisprflow.ai/) is the reference point: it types
into your cursor as you speak, which is the right shape for a short instruction and the wrong
one for thinking out loud. Braindump mode is the alternative — talk for five minutes, walk away,
collect readable text later — and dictation mode is the concession that Flow's shape wins for
the short case. Building it is how I find out whether that split actually holds up in daily use.

The second is the workflow. The repo is run with
[`mattpocock/skills`](https://github.com/mattpocock/skills), on the theory that a real project
with real issues is the only honest way to test whether an agent-skill setup survives past the
demo. The `docs/agents/` wiring, the triage labels, and the ADR discipline are part of that
experiment, not just furniture.

Neither makes this a product. See Contributions.

## Status

Early implementation. The project scaffold builds and launches as a menubar app (issue #14);
the pipeline is not built yet. Scope lives in the GitHub issues, the vocabulary in
`CONTEXT.md`, and the load-bearing decisions in `docs/adr/`.

## Development

Native Swift macOS menubar app, macOS 15+, generated with [Tuist](https://tuist.dev)
(`Project.swift` is the source of truth; the `.xcodeproj`/`.xcworkspace` are gitignored). No
third-party package links into the app; the heavy lifts are external binaries (ADR-0002).

First-time setup and build:

```sh
scripts/create-signing-identity.sh   # one-time: self-signed cert for stable signing (ADR-0005)
tuist generate                       # produces SpeechLogger.xcworkspace
tuist test                           # run the test suite
tuist build SpeechLogger             # build the app
scripts/verify-signing.sh            # assert sandbox-off + stable designated requirement
```

The self-signed identity is what keeps the Input Monitoring grant alive across rebuilds; a
local, non-quarantined build launches without notarization. See `docs/adr/` for the decisions.

## Brand

The mark is a **microphone capsule whose interior is three lines of organized text** — the
product's promise in one drawing. It is single-color `currentColor`, so it inherits the menubar
tint and survives to 16 px. Neutrals carry a slight indigo bias rather than being pure gray, and
there is exactly **one** accent; the semantic colors are separate and map to real item states.

| Token | Light | Dark |
|---|---|---|
| Indigo · accent | `#5257CE` | `#8B90F0` |
| Indigo · deep | `#3C41B0` | — |
| Ink | `#171922` | `#ECEDF4` |
| Slate | `#656A7E` | `#9AA0B4` |
| Hairline | `#E4E6EF` | `#2A2D3A` |
| Paper | `#F5F6FA` | `#101119` |
| Surface | `#FFFFFF` | `#191B25` |

| Item state | Light | Dark |
|---|---|---|
| Recording | `#E5484D` | `#FF6166` |
| Processing | `#5257CE` | `#8B90F0` |
| Failed | `#D9820A` | `#F0A83A` |
| Ready | `#2F9E68` | `#4FBF88` |

Full system — menubar glyph family, lockups, app icon, typography, usage rules:
[`brand/DESIGN_SYSTEM.md`](brand/DESIGN_SYSTEM.md).

## License

**PolyForm Noncommercial 1.0.0** (see `LICENSE.md`). Source-available, not open source.
Read, study, fork and modify it freely for any noncommercial purpose. Commercial use requires
a separate license from the author.

## Contributions

Closed. Issues, pull requests and comments are limited to collaborators. The repo is public to
be read, not to be built by committee.
