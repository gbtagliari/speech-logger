# ADR-0002 — Shell out to mlx_whisper, ffmpeg, and claude as subprocesses

Status: accepted
Date: 2026-07-15

## Context

The app needs local transcription and LLM organization. Both capabilities already exist as
command-line tools the user has installed and logged in: `mlx_whisper` (Apple-silicon Whisper) and
the `claude` CLI (Claude Code, billed against an existing subscription). Re-implementing either in
Swift would be a large, pointless effort.

## Decision

The app invokes external binaries as subprocesses rather than linking libraries or calling APIs:

- **`mlx_whisper`** for transcription (`whisper-large-v3-turbo`, `--language pt`,
  `--condition-on-previous-text False`).
- **`ffmpeg`** for audio encode (native wav → mp3). It is a **third** required binary: `mlx_whisper`
  itself shells out to `ffmpeg` to decode audio, and the app also calls it directly to produce the
  retained mp3.
- **`claude`** for both LLM passes (`--print --model claude-sonnet-5 --effort low
  --system-prompt <file> --tools "" --safe-mode --no-session-persistence --output-format json`,
  transcript on stdin).

Two hard constraints, both verified and both non-negotiable:

1. **App Sandbox must stay OFF.** The sandbox rewrites `HOME`, so the `claude` CLI cannot find
   `~/.claude/.credentials.json` and dies "Not logged in".
2. **All three binaries are invoked by absolute path.** None of them is on a GUI-launched app's
   `PATH`.

## Consequences

- **Marginal cost per utterance is ~$0.02 of subscription quota** — no dollars, but finite quota.
  "Zero marginal cost" is a subscription claim, not an infinite one.
- The app hard-depends on all three binaries being installed and `claude` being logged in. Preflight
  checks presence; runtime catches the rest. Acceptable — this is a personal tool.
- **`--effort low` is mandatory** on `claude`: unset, pass 1 burns ~14× the tokens/time/cost and goes
  nondeterministic. **Haiku is not a fallback** (it ignores `--effort low`, running slower and more
  expensively than Sonnet); there is no fallback model, only retry.
- Error handling differs per binary: `mlx_whisper` exits 0 on every failure, so success = output file
  exists and is non-empty; `claude`'s exit code is trustworthy but `subtype` always says "success", so
  gate on `is_error`. Neither has a built-in timeout (a dead network makes `claude` hang ~179 s/try).
- Full contracts: [`docs/research/mlx-whisper-shell-out-contract.md`](../research/mlx-whisper-shell-out-contract.md)
  and [`docs/research/claude-cli-shell-out-contract.md`](../research/claude-cli-shell-out-contract.md).
</content>
