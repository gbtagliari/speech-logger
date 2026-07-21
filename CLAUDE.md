# speech-logger

A macOS menubar app that turns speech into organized text, asynchronously. See `CONTEXT.md`.

## License constraint

Licensed **PolyForm Noncommercial 1.0.0** (source-available, not OSI open source). See `LICENSE.md`.

Consequence when adding code or dependencies: **do not vendor or copy copyleft (GPL/AGPL/LGPL)
source into this repo.** Copyleft would force the derivative to be GPL, which permits the
commercial use this license exists to gate. VoiceInk, named in the prior art as a fork candidate,
is GPL — read it for ideas, never copy its code. Permissive dependencies (MIT, Apache-2.0, BSD,
ISC) are fine.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, via the `gh` CLI. The repo is public but closed to
outside contribution (interaction limit `collaborators_only`, expires 2027-01-14), so external
PRs are not a triage surface. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles use their default label strings. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `CONTEXT.md` and one `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Handoffs

Session handoff documents go in `.scratch/handoffs/`, named `YYYY-MM-DD-<slug>.md` — not in
the OS temp directory. `.scratch/` is gitignored, so they stay local and out of the repo
while remaining next to the work they describe.
