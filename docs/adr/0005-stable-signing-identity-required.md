# ADR-0005 — A stable code-signing identity is a hard build requirement

Status: accepted
Date: 2026-07-15

## Context

The app needs the Input Monitoring grant (ADR-0004) to function at all. During development the app is
rebuilt constantly. The question the research ticket answered: does the grant survive a rebuild?

The denied state is **fail-silent** — both `addGlobalMonitorForEvents` and `tapCreate(.listenOnly)`
return non-nil when Input Monitoring is denied (the `CGEvent.h` header claiming they return NULL is
wrong), and zero events simply flow. `CGPreflightListenEventAccess()` is the **only** reliable gate.

## Decision

**Sign every build with a stable code-signing identity and a fixed bundle id.** This is a hard build
requirement, not a distribution nicety.

- macOS keys the TCC grant to the app's **designated requirement (DR)**. An **ad-hoc** signature has a
  DR of `cdhash`, which changes on every rebuild, so **an ad-hoc rebuild voids the grant every time**.
  A stable-identity signature has a DR of `identifier + cert`, which is stable across rebuilds, so
  **the grant survives**.
- A **self-signed** code-signing certificate is sufficient. A **revoked** cert is worse than none — it
  makes XProtect trash the app. (The machine's Apple Development cert is revoked; a fresh self-signed
  cert must be procured.)

## Consequences

- Distribution (notarization, `.dmg`, auto-update) stays out of scope, but **signing for TCC stability
  is in scope and decided.** A self-signed, non-quarantined local build launches without notarization.
- Three UX facts this hands to first-run/preflight:
  1. The macOS Settings toggle **lies** — it can show ON while preflight reads false after a bad
     rebuild. Trust `CGPreflightListenEventAccess()`, never the toggle.
  2. Preflight is a **launch-time read**, not a live poll (this corrects the ADR-0004 research doc).
  3. Once any grant decision exists, macOS shows **no second prompt** — the app must deep-link to the
     Settings pane instead of re-requesting.
- Procuring a usable signing identity is the one open build prerequisite before an editor opens. Full
  contract: [`docs/research/input-monitoring-grant-behavior.md`](../research/input-monitoring-grant-behavior.md).
</content>
