# ADR-0009 — The acceptance set is a sampled measurement, not a test

Status: accepted
Date: 2026-07-21

## Context

The acceptance set (issue #18) shipped as `AcceptanceSetTests`, a unit test that ran the real
two-pass pipeline and judged live model output against the fidelity contract. That made it the
only test in the suite that shelled out to `claude`: eight billed calls per run, and a verdict
drawn from a nondeterministic source.

It behaved accordingly. The suite failed intermittently and was carried as "flaky" — the failure
rate turned out to be ~49% on one case, which is not flakiness but a defect the harness could not
express (ADR-0008). A single sample cannot distinguish "the prompt is broken half the time" from
"unlucky run", so the signal was read as noise for as long as it was sampled once per run.

It also had two failure modes of its own:

- It self-skipped when `claude`, credentials, or the `.scratch/` transcripts were absent, so a
  clean worktree reported green having run nothing.
- Tuist's selective-testing cache would report `no tests to run`, which also looks like a pass.

Mocking it was considered and rejected: with a canned organizer the judge passes trivially and the
suite asserts nothing. It would have been green throughout the ~49% defect.

## Decision

Split the two things the suite had fused.

- **Offline, in the test suite.** `FidelityJudge` is tested by `FidelityJudgeTests` against
  synthetic hand-written candidates, including one shaped like the role-collapse reply. The
  `claude` shell-out contract is tested through an injected `SubprocessRunning` seam, covering the
  full output matrix (success, cli error, non-zero exit, empty result, non-JSON, unlaunchable
  binary) with no binary and no network.
- **Live, outside the test suite.** The acceptance set moves to `DriftCheck`, a command-line
  target. It samples the real pipeline N times per case and reports a **rate**, not a pass/fail.

`DriftCheck` is a `commandLineTool` rather than a second test target on purpose: an executable
cannot be picked up by `tuist test` even by accident.

No test in the repo calls an external API. The remaining gated tests shell out to `mlx_whisper`
and `ffmpeg`, which are local and free.

## Consequences

- `tuist test` is offline, deterministic and free: 225 tests, ~18 s.
- Nothing triggers the drift check automatically. It is **run manually**, deliberately, after
  touching a prompt or the pinned model:

  ```
  tuist run DriftCheck --samples 10
  tuist run DriftCheck --samples 20 --case caso-01 --out /tmp/drift
  ```

  This is a real reduction in automatic coverage, accepted because the check costs money and takes
  about a minute, and because its previous "automatic" form was actively misleading.
- Exit status: 0 clean, 1 violations found, 2 toolchain gate unmet. It refuses to run and says why
  rather than skipping silently. Note `tuist run` surfaces any non-zero exit as its own error; read
  the status from the built binary directly.
- `--out` persists every sampled candidate. The judge is deterministic and offline, so saved
  candidates can be re-judged for free without re-sampling the model.
- `FidelityJudge.swift` stays in the test target, where it is covered, and is compiled into
  `DriftCheck` by an explicit source reference rather than duplicated.
- The drift check still needs the recorded transcripts in `.scratch/`, so it only runs on a machine
  that has them. Unlike before, it says so and exits 2 instead of reporting a green.
