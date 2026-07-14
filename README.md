# speech-logger

_Working title. The name is an open question, not a decision (see `PRD.md`)._

A macOS menubar app that turns speech into organized text.

Press a hotkey, talk for as long as you want, press it again. The app records, transcribes,
and reorganizes the text for readability **without changing its meaning**. The result lands in
a log; click an entry and its text is on your clipboard.

It is not a dictation tool. Nothing is typed at the cursor, and the pipeline is asynchronous.

## Why it exists

Every tool on the market either transcribes verbatim or "improves" your words: summarizing,
restyling, swapping in better synonyms, quietly repairing what it thinks you meant. Both miss
the point. The goal here is to strip the fillers, false starts and repetition, and to punctuate
and reorder into something readable, while every idea, every hedge, and every modal ("cannot"
never becomes "should not") survives intact.

That fidelity contract is the whole product. It is specified in `PRD.md` and enforced by an
acceptance set of real recordings.

## Status

Pre-implementation. `PRD.md` is approved; there is no code yet.

## License

**PolyForm Noncommercial 1.0.0** (see `LICENSE.md`). Source-available, not open source.
Read, study, fork and modify it freely for any noncommercial purpose. Commercial use requires
a separate license from the author.

## Contributions

Closed. Issues, pull requests and comments are limited to collaborators. The repo is public to
be read, not to be built by committee.
