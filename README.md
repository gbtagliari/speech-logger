# speech-logger

_Working title. The name is an open question, not a decision._

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

## License

**PolyForm Noncommercial 1.0.0** (see `LICENSE.md`). Source-available, not open source.
Read, study, fork and modify it freely for any noncommercial purpose. Commercial use requires
a separate license from the author.

## Contributions

Closed. Issues, pull requests and comments are limited to collaborators. The repo is public to
be read, not to be built by committee.
