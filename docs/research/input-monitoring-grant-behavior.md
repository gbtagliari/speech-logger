# Input Monitoring: the denied state, and what a rebuild does to the grant

Closes the two open questions the global-hotkey research
([`global-hotkey-capture-macos.md`](./global-hotkey-capture-macos.md), "Open questions") could not
answer from an agent session, because both require a **Finder launch** so TCC attributes the grant to
the app bundle (`app.speechlogger.probe`) instead of the terminal that `exec`'d it.

Measured 2026-07-15 on macOS 26.5.x (Tahoe), arm64, with an instrumented `LSUIElement` `.app`
(App Sandbox off) double-clicked from Finder. The app recorded each API's return at launch (before
requesting anything), counted delivered `flagsChanged` events, ran the right-Option double-tap
detector, and logged its own code-signing designated requirement (DR) + cdhash on every launch. All
values below are **[observed]** first-hand this session unless marked otherwise. The harness is
throwaway (built under the session scratchpad; installed at `.probe/`, gitignored).

## A. The denied state, from each API

TCC attributed to the app bundle (Finder launch), with Input Monitoring **not** granted:

| API | denied | granted |
|---|---|---|
| `CGPreflightListenEventAccess()` | **false** | true |
| `AXIsProcessTrusted()` | false | false (never needed — Accessibility is not required) |
| `IOHIDCheckAccess(.listenEvent)` | **`unknown`** (no TCC record) / **`denied`** (record exists but does not match this client) | `granted` |
| `NSEvent.addGlobalMonitorForEvents(.flagsChanged)` | **non-nil** | non-nil |
| `CGEvent.tapCreate(.listenOnly)` | **non-nil** | non-nil |
| global `flagsChanged` events delivered | **0** | flow immediately |

Consequences, all decided for #12:

- **Fail-silent is confirmed.** When denied, `addGlobalMonitorForEvents` returns a live, non-nil
  monitor that simply never fires — indistinguishable from "the user hasn't pressed the key yet."
- **`CGEvent.tapCreate(.listenOnly)` returns non-nil even when denied.** The `CGEvent.h` header
  ("NULL when unpermitted") is **wrong** on this OS, and the one contradicting run #4 saw was not a
  fluke. **Never use `tapCreate`'s return as a permission check.** Neither listener API self-reports
  permission; the only reliable gate is `CGPreflightListenEventAccess()`.
- **`IOHIDCheckAccess` distinguishes two denied sub-states**: `unknown` = no TCC record for this
  client at all; `denied` = a record exists but does not match (e.g. after the DR changed under a
  rebuild — see B). Useful signal, but `CGPreflightListenEventAccess()` remains the gate.

## B. A rebuild voids the grant iff it changes the designated requirement

TCC matches a client on its **designated requirement (DR)**, not its path. Both rebuild directions
were proven end-to-end this session by granting, rebuilding, and reading a fresh process:

| Signing | DR | granted at | rebuilt to | relaunch preflight |
|---|---|---|---|---|
| **ad-hoc** (`codesign -s -`) | `cdhash H"…"` — **is the code hash** | cdhash `eb3893dd` | cdhash `560a06bb` | **false — grant DIED** |
| **stable identity** | `identifier "…" and certificate leaf = H"…"` — **independent of cdhash** | cdhash `a231d1a8` | cdhash `e68dcbdf` | **true — grant SURVIVED, no prompt** |

**An ad-hoc rebuild silently voids the Input Monitoring grant every time** (the ad-hoc DR *is* the
cdhash, which changes on every build). **A build signed with a stable identity + fixed bundle id
keeps the grant across rebuilds**, because the DR keys off the identifier and certificate, not the
bits. So **"sign with a stable identity + fixed bundle id" is a hard build requirement** for this
project — without it, every `swift build` during development re-triggers the permission dance.

Two practical notes on *which* identity:

- **A self-signed code-signing certificate is sufficient**, and was what proved the survival case
  above. TCC's DR match does **not** require the certificate to be trusted/Developer-ID — an untrusted
  self-signed cert (`CSSMERR_TP_NOT_TRUSTED`) yields a stable `certificate leaf = H"…"` DR that TCC
  honors. This is the zero-cost option for a local personal tool.
- **A *revoked* certificate is worse than ad-hoc.** Signing with the machine's Apple Development
  "Entrega Digital" cert (`T59HNF76UY`) made **Gatekeeper/XProtect flag the app as malware and move
  it to Trash** on launch. `spctl -a -t exec` reports `CSSMERR_TP_CERT_REVOKED` for it, even though
  `security find-identity -v` lists it as valid. A revoked signature on a keystroke-monitoring app is
  exactly what XProtect nukes. Ad-hoc launches fine (a locally built, non-quarantined app is not
  Gatekeeper-assessed); a revoked signature is not. Use a self-signed cert (or a genuine, non-revoked
  Developer identity), never a revoked one.

## Extra findings, all for #12 (first-run UX)

1. **The System Settings toggle lies.** After a DR-invalidating (ad-hoc) rebuild, System Settings →
   Privacy → Input Monitoring shows the app present with its toggle **ON**, while
   `CGPreflightListenEventAccess()` is **false** and no events flow. Never treat the Settings toggle
   as ground truth; trust only `CGPreflightListenEventAccess()`.

2. **`CGPreflightListenEventAccess()` is a launch-time read, not a live poll.** Within one running
   process it returned `false` at launch and again 6 minutes later *while global events were being
   delivered* (the double-tap detector fired repeatedly); a **fresh process** read the correct `true`.
   The value does **not** update live when the user grants mid-session. This **corrects** the
   global-hotkey doc's suggestion to "re-check `CGPreflightListenEventAccess()` on
   `didBecomeActive`/a timer" to detect a grant or revocation — it did not update live here. Detect
   "grant landed" by **relaunching** or by observing **event flow**, not by polling preflight.

3. **No second prompt once any decision exists.** With any prior TCC decision recorded (even a stale,
   mismatched one), `CGRequestListenEventAccess()` returns `false` **immediately, without prompting**.
   Only System Settings — or `tccutil reset ListenEvent app.speechlogger.probe` — reopens it.
   Onboarding must **deep-link to the Settings pane**, never rely on re-prompting. Removing the entry
   with the pane's "–" left the record as `denied` (not absent): `IOHIDCheckAccess` stayed `denied`
   and no prompt returned; a real reset needs `tccutil`.

4. **Granting in the pane may need a relaunch to be observed**, per finding 2 — which is why macOS's
   own "Quit & Reopen" affordance exists.

## What this pins for the build

- **Sign every build with a stable identity + fixed bundle id** (`app.speechlogger.probe`). A
  self-signed code-signing cert is enough; do not ship an ad-hoc build for daily use, and never sign
  with a revoked cert. This is now a hard requirement, not a preference. Obtaining a usable identity
  (self-signed cert in the login keychain, or a non-revoked Developer identity) is a prerequisite the
  project setup must satisfy.
- **App Sandbox stays off** (unchanged, from #3).
- The first-run/degraded-state UI (#12) must gate on `CGPreflightListenEventAccess()` read at launch,
  deep-link to the Settings pane, and use event flow (not a preflight poll) as the "it's working now"
  signal.
