# Global modifier double-tap capture on macOS

What it costs to notice a double-tap of right-Option from a background menubar app, and which
API to use.

Verified on this machine (2026-07-14): **macOS 26.5.1 (Tahoe, build 25F80)**, Apple Swift 6.3.3,
arm64. Two independent harnesses were run: a **live `LSUIElement` `.app`** (never frontmost) that
logged 162 real `flagsChanged` events, and a **permission/tap matrix probe**. Where they disagreed
with a header doc comment, **the observation wins and the header is called out as stale.**

Claims are tagged **[observed]** (a real event went through it), **[measured]** (an API returned
this here), **[header]** (quoted from an SDK header on this machine), **[Apple]**
(developer.apple.com), or **[open]** (untested — listed in [Open questions](#open-questions--must-be-tested-by-a-human)).

VoiceInk and the other GPL prior art were **not** read, not even for ideas. The API choice below
comes from Apple DTS and first-hand measurement, so there is nothing to launder.

## The trap, first

Lead with this, because it is silent, it is the kind of bug that eats a day, and the obvious code is
the wrong code.

**The raw flag word is not just the device bits.** Every `flagsChanged` event also carries the
*general* modifier bit (option `0x80000`, shift `0x20000`, control `0x40000`, command `0x100000`)
**and** `NX_NONCOALSESCEDMASK` (`0x100`), which is set on essentially every event — an
all-modifiers-released event is `0x00000100`, not zero. **[observed]**

So the natural way to ask "is any *other* modifier held?" is always true:

```swift
let othersHeld = flags & ~NX_DEVICERALTKEYMASK != 0    // WRONG — always true
// right-Option alone  = 0x00080140
// 0x00080140 & ~0x40  = 0x00080100  != 0              // the general bit + noncoalesced survive
```

Written that way, the detector **never fires, and never errors.** It was silent across 162 real
events. **[observed]**

**The fix: mask down to the device bits before testing anything.**

```swift
let deviceMask: UInt64 = 0x207F     // union of all 8 device-dependent modifier bits
let device = flags & deviceMask
let isDown     = device & 0x40 != 0        // right-Option is down
let othersHeld = device & ~0x40 != 0       // a real combo — not our gesture
```

After the fix: three deliberate double-taps produced **exactly three** detections, and a slow single
tap produced none. **[observed]**

Every one of the nine observed raw flag words decomposes against the `IOLLEvent.h` constants with
**zero leftover bits**, so this model of the word is complete, not approximate.

## The recommendation

**`NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`, gated by an explicit
`CGPreflightListenEventAccess()` check. It costs Input Monitoring and nothing else.**

```swift
guard CGPreflightListenEventAccess() else { /* onboarding: request, then System Settings */ }

NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
    handle(keyCode: Int64(event.keyCode),                 // 61 = right Option
           flags: UInt64(event.modifierFlags.rawValue))   // carries the device bits
}
```

Why this and not a `CGEventTap`:

- **It delivers exactly the same data.** The two APIs were run side by side against the same events:
  identical `keyCode`, identical raw flag word, **event for event, 162/162 and 14/14 across runs**.
  Crucially `NSEvent`'s `modifierFlags.rawValue` **does carry the device-dependent bits** — it is not
  reduced to the general `.option`/`.shift` flags. **[observed]**
- **The only thing a `CGEventTap` adds is the ability to *consume* the event — and this app must not
  consume it.** Suppressing the keypress requires `.defaultTap`, which costs an **Accessibility**
  prompt (see below). Avoiding that prompt is the whole point.
- **It is materially less machinery**: no `CFMachPort`, no run-loop source, no
  `kCGEventTapDisabledByTimeout` recovery path, no "keep the callback under the timeout" discipline.
- Neither API reports its own permission state reliably, so **you must preflight explicitly either
  way** — and `CGPreflightListenEventAccess()` is independent of which listener you choose. This is
  the argument that flipped the recommendation: the "a tap fails loudly, `NSEvent` fails silently"
  reasoning does not survive contact with [Open question A](#a-the-unpermitted-path-is-untested).

Apple DTS prefers `CGEventTap` (below) **on TCC-legibility grounds, not capability grounds**. An
explicit preflight call answers that. If the app ever needs to swallow the hotkey, move to
`CGEventTap` + `.defaultTap` and budget the Accessibility prompt.

## The permission line: listening is cheap, *swallowing* is not

This is the question the PRD hangs on, and it is settled.

**A passive keyboard listener needs Input Monitoring (`kTCCServiceListenEvent`) ONLY. Accessibility
is not required.** **[observed]**

The live harness ran 45 s as an `LSUIElement` app that was **never frontmost**, and received **162
global `flagsChanged` events**, with `AXIsProcessTrusted() == false` checked **both before the monitor
was installed and after the run ended**. The only privilege held was Input Monitoring
(`CGPreflightListenEventAccess() == true`). Both `NSEvent` and the listen-only `CGEventTap` delivered
throughout.

**The PRD's claim holds: no Accessibility prompt.** But its stated *reason* is wrong, and the
difference matters. Synthesis is a separate axis with its own gate (`CGRequestPostEventAccess`). The
line that actually decides Input-Monitoring-vs-Accessibility is:

> **do you merely observe the event stream, or can you alter it?**

Independently measured, in one process holding Input Monitoring with Accessibility denied, varying
only the tap option: **[measured]**

```
CGPreflightListenEventAccess() : true     // Input Monitoring
AXIsProcessTrusted()           : false    // Accessibility — NOT granted
IOHIDCheckAccess(.listenEvent) : granted

  kCGHIDEventTap              / listenOnly -> OK (created)
  kCGHIDEventTap              / defaultTap -> nil (REFUSED)
  kCGSessionEventTap          / listenOnly -> OK (created)
  kCGSessionEventTap          / defaultTap -> nil (REFUSED)
  kCGAnnotatedSessionEventTap / listenOnly -> OK (created)
  kCGAnnotatedSessionEventTap / defaultTap -> nil (REFUSED)
```

The only variable that moves the answer is **`listenOnly` vs `defaultTap`**, not the location.

**The product consequence, which is a real decision and not a trivium: the app cannot swallow the
double-tap.** Both right-Option presses also reach whatever app is frontmost. Right-Option alone is
inert in most apps, so this is very likely fine — but it is a choice, and reversing it costs the
Accessibility prompt the product exists to avoid. (That granting Accessibility is specifically what
unblocks `.defaultTap` is **[open]** — only the refusal-without-it was measured.)

### Both headers are stale on this. Do not trust them.

`CGEvent.h:269-279` **[header]** still tells the pre-10.15 story, and is wrong twice:

> ```
> Taps may only be placed at `kCGHIDEventTap' by a process running as the root user. NULL is
> returned for other users.
>
> Taps placed at `kCGHIDEventTap', `kCGSessionEventTap', `kCGAnnotatedSessionEventTap', or on a
> specific process may only receive key up and down events if access for assistive devices is
> enabled (Preferences Accessibility panel, Keyboard view) or the caller is enabled for assistive
> device access, as by `AXMakeProcessTrusted'. If the tap is not permitted to monitor these events
> when the tap is created, then the appropriate bits in the mask are cleared. If that results in an
> empty mask, then NULL is returned.
> ```

- "**root user**" is false today: a `kCGHIDEventTap` listen-only tap was created as **uid 501**. **[measured]**
- "**assistive devices / AXMakeProcessTrusted**" predates the 10.15 split of Input Monitoring out of
  Accessibility. **[observed]**

`NSEvent.h:541` **[header]** carries the same residue:

> "Use +addGlobal to install an event monitor that receives copies of events posted to other
> applications. Events are delivered asynchronously to your app and **you can only observe the event;
> you cannot modify or otherwise prevent the event from being delivered** to its original target
> application. **Key-related events may only be monitored if accessibility is enabled or if your
> application is trusted for accessibility access (see AXIsProcessTrusted in AXUIElement.h).**"

The first half is true, and is exactly why `NSEvent` is safe for us: it *cannot* consume. **The
sentence about accessibility is stale** — 162 keyboard events were delivered to a global `NSEvent`
monitor with `AXIsProcessTrusted() == false`. **[observed]**

Flag this loudly, because the stale sentence is repeated everywhere, including in paraphrases of
Apple's own guidance ("CGEventTap needs Input Monitoring whereas NSEvent global monitors need
Accessibility"). **On macOS 26.5.1 that is not what happens.** If this ever regresses, re-test it first.

### The permission APIs, and which of them prompt

`CGEvent.h:398-408` **[header]** — the doc comments say it outright:

```c
/* Checks whether the current process already has event listening access */
CG_EXTERN bool CGPreflightListenEventAccess(void) API_AVAILABLE(macos(10.15));
/* Requests event listening access if absent, potentially prompting */
CG_EXTERN bool CGRequestListenEventAccess(void) API_AVAILABLE(macos(10.15));
/* Checks whether the current process already has event synthesizing access */
CG_EXTERN bool CGPreflightPostEventAccess(void) API_AVAILABLE(macos(10.15));
/* Requests event synthesizing access if absent, potentially prompting */
CG_EXTERN bool CGRequestPostEventAccess(void) API_AVAILABLE(macos(10.15));
```

| API | Permission | Prompts? |
|---|---|---|
| `CGPreflightListenEventAccess()` | Input Monitoring | **No** — safe at every launch. [header] + [measured] |
| `CGRequestListenEventAccess()` | Input Monitoring | **Yes**, once. [header] |
| `AXIsProcessTrusted()` | Accessibility | **No**. [measured] |
| `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` | Accessibility | **Yes** — the prompt we are avoiding. **Never call it.** |
| `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` | Input Monitoring | **No** — "a check, not a request". [header] + [measured: `granted`] |
| `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` | Input Monitoring | **Yes**. [header] |

`IOHIDCheckAccess` agreed with `CGPreflightListenEventAccess` here (`granted` / `true`), consistent
with both reading the same `kTCCServiceListenEvent` record. Use the CG pair; it is the one DTS points at.

TCC prompts once per client, ever. If the user declines, `CGRequestListenEventAccess()` returns
`false` forever without re-prompting and only System Settings can fix it. **[open]** — standard TCC
behaviour, not tested here. Onboarding should therefore be: preflight → request once → otherwise show
an "open System Settings" affordance rather than re-asking. Feeds **#12**.

## The options, and what each costs

| API | Modifier-only presses? | Can consume? | Permission | Failure when unpermitted |
|---|---|---|---|---|
| **`NSEvent.addGlobalMonitorForEvents(.flagsChanged)`** | **Yes** [observed] | **No, by design** [header] | **Input Monitoring** [observed] | Non-nil monitor, no events. Silent. **[open]** |
| `CGEventTap` `.listenOnly` + `flagsChanged` | **Yes** [observed] | No | **Input Monitoring** [observed] | Header says `nil`; contradicted once. **[open]** |
| `CGEventTap` `.defaultTap` | Yes | **Yes** | **Accessibility** (+ Input Monitoring) | `nil` at creation [measured] |
| Carbon `RegisterEventHotKey` | **No** — cannot bind modifier-only | n/a | **None** | n/a |
| `IOHIDManager` (raw HID) | Yes, as raw HID usage pages | No | Input Monitoring | device open fails |

### Carbon `RegisterEventHotKey` cannot do modifier-only

From `CarbonEvents.h:15427-15490` **[header]** (the file is ISO-8859 encoded, so a plain UTF-8 `grep`
**silently finds nothing** in it — use `grep -a`, or conclude the opposite of the truth):

```c
/*  RegisterEventHotKey()
 *    inHotKeyCode:      The virtual key code of the key to watch
 *    inHotKeyModifiers: The keyboard modifiers to look for. On Mac OS X 10.3 or
 *                       later, you may pass zero.
 */
extern OSStatus
RegisterEventHotKey(UInt32 inHotKeyCode, UInt32 inHotKeyModifiers,
                    EventHotKeyID inHotKeyID, EventTargetRef inTarget,
                    OptionBits inOptions, EventHotKeyRef *outRef)
                    AVAILABLE_MAC_OS_X_VERSION_10_0_AND_LATER;
```

The API is shaped as *(a key) + (modifiers held while it is pressed)*. There is no way to express "no
key, just a modifier." And hot keys dispatch out of the raw key-down stream: the
`kEventClassKeyboard` kinds are `kEventRawKeyDown = 1`, `kEventRawKeyUp = 3`,
**`kEventRawKeyModifiersChanged = 4`**, `kEventHotKeyPressed = 5` (`CarbonEvents.h:4494-4499`).
Modifier presses arrive as `RawKeyModifiersChanged`, **never** as `RawKeyDown`, so a hot key has
nothing to match against.

**And it does not fail.** `RegisterEventHotKey(kVK_RightOption, modifiers: 0, …)` returns **`noErr`**
**[measured]**. It cheerfully accepts a registration that can never fire. (That it never fires is
**[open]** — but it follows directly from the dispatch path.)

Its one real virtue: **it needs no TCC permission at all.** If the hotkey were ever allowed to be an
ordinary key combo (⌥⌘D rather than double-tap-⌥), Carbon would give a **zero-permission app** and
this entire document would be moot. That is a genuine product lever, worth naming to **#5**. Quinn's
caveat still applies **[Apple]**: *"it's intimately tied to the legacy Carbon toolbox and thus I
can't honestly recommend it."*

### What Apple DTS actually says

Quinn ("The Eskimo!"), [forum thread 735223](https://developer.apple.com/forums/thread/735223) **[Apple]**:

> "Of the remaining options, I prefer `CGEventTap` because of its interactions with TCC."
> "**To listen for keyboard events you'll need the Input Monitoring privilege.**"
> "One reason I like `CGEventTap` is that it's clearly associated with the APIs to determine whether
> you have that privilege (`CGPreflightListenEventAccess`) and to request that privilege
> (`CGRequestListenEventAccess`)."

The privilege sentence is the load-bearing one, and it matches what we observed. His *preference* for
`CGEventTap` is about TCC legibility, which an explicit preflight call gives us anyway.

### IOHIDManager

Works, needs Input Monitoring, and delivers raw HID usage pages instead of cooked modifier state — so
we would re-implement left/right decoding, the "Modifier Keys…" remapping, and per-device quirks
ourselves. No upside for this job. Not pursued.

## Left vs right Option: two mechanisms, both confirmed

**Use `keyCode` to identify *which* key moved, and the device bit to determine *down vs up*.**

**1. Virtual key codes** — `Carbon.HIToolbox/Events.h:271-280` **[header]**; public, stable `kVK_*`
constants, unchanged since 10.0. Observed values match. **[observed]**

| Key | `kVK_` constant | hex | dec | seen live? |
|---|---|---|---|---|
| Right Command | `kVK_RightCommand` | `0x36` | 54 | yes |
| Left Command | `kVK_Command` | `0x37` | 55 | yes |
| Left Shift | `kVK_Shift` | `0x38` | 56 | yes |
| Caps Lock | `kVK_CapsLock` | `0x39` | 57 | — |
| **Left Option** | **`kVK_Option`** | **`0x3A`** | **58** | **yes** |
| Left Control | `kVK_Control` | `0x3B` | 59 | yes |
| Right Shift | `kVK_RightShift` | `0x3C` | 60 | yes |
| **Right Option** | **`kVK_RightOption`** | **`0x3D`** | **61** | **yes** |
| Right Control | `kVK_RightControl` | `0x3E` | 62 | **no — header only** |
| Fn | `kVK_Function` | `0x3F` | 63 | — |

**Right-Option (61) is cleanly distinguishable from left-Option (58).** **[observed]**

**2. Device-dependent flag bits** — `IOKit/hidsystem/IOLLEvent.h:253-261` **[header]**, verbatim
(including Apple's own editorial):

```c
/* device-dependent (really?) */

#define	NX_DEVICELCTLKEYMASK	0x00000001
#define	NX_DEVICELSHIFTKEYMASK	0x00000002
#define	NX_DEVICERSHIFTKEYMASK	0x00000004
#define	NX_DEVICELCMDKEYMASK	0x00000008
#define	NX_DEVICERCMDKEYMASK	0x00000010
#define	NX_DEVICELALTKEYMASK	0x00000020
#define	NX_DEVICERALTKEYMASK	0x00000040
#define NX_DEVICERCTLKEYMASK	0x00002000
```

Left Option `0x20`, right Option `0x40`. **Note the asymmetry: right Control is `0x2000`, not
adjacent to left Control's `0x1`.** Anyone "completing the pattern" by guessing `0x2` will silently
mis-detect it. Union of all eight = **`0x207F`**, the `deviceMask` from the top of this document.

**Observed raw flag words** — each decomposes against the header constants with **zero leftover
bits**, confirming the model is complete: **[observed]**

| Event | raw word | `& 0x207F` | general bit | noncoalesced |
|---|---|---|---|---|
| right Option | `0x00080140` | `0x0040` | `ALTERNATE 0x80000` | `0x100` |
| left Option | `0x00080120` | `0x0020` | `ALTERNATE 0x80000` | `0x100` |
| left Shift | `0x00020102` | `0x0002` | `SHIFT 0x20000` | `0x100` |
| right Shift | `0x00020104` | `0x0004` | `SHIFT 0x20000` | `0x100` |
| left Control | `0x00040101` | `0x0001` | `CONTROL 0x40000` | `0x100` |
| left Command | `0x00100108` | `0x0008` | `COMMAND 0x100000` | `0x100` |
| right Command | `0x00100110` | `0x0010` | `COMMAND 0x100000` | `0x100` |
| **all released** | **`0x00000100`** | `0x0000` | — | `0x100` |
| right Shift + right Option | `0x000A0144` | `0x0044` | `SHIFT` + `ALTERNATE` | `0x100` |

**Stability caveat.** These bits are real `#define`s in a shipping SDK header, so they are not
folklore — but they are **not surfaced in `CGEventFlags`**. `CGEventTypes.h:82-99` defines only the
*device-independent* masks (`kCGEventFlagMaskAlternate = NX_ALTERNATEMASK`, …) and states "Any bits
not specified are reserved for future use." **[header]** They are present in the raw word at runtime,
have not moved in twenty years, and Apple's own left/right remapping UI depends on the distinction —
so treat them as **de-facto stable** and **isolate them behind one small function**, so a future macOS
break has exactly one site to fix.

## Double-tap: no system API, and no readable system window

**No macOS API reports a modifier double-tap.** Not `NSEvent`, not `CGEvent`, not Carbon. macOS's own
double-tap features (double-tap-Control for dictation) are implemented privately.

**There is no readable system preference for the double-tap window.** Searched `com.apple.HIToolbox`,
`com.apple.speech.recognition.AppleSpeechRecognition.prefs`, `com.apple.symbolichotkeys`, and
`NSGlobalDomain`. `AppleDictationAutoEnable = 1` is a bare on/off flag — **no window, no threshold**.
Nothing else exposes one. **[measured]**

The nearest thing is a **decoy**: `NSEvent.doubleClickInterval` reads `0.5 s` here **[measured]**, but
`NSEvent.h:531` **[header]** scopes it explicitly to the mouse — *"the time in which a second **click**
must occur in order to be considered a doubleClick."* Apple never documents it as applying to
modifier taps. Do not grab it just because it is nearby and has the right shape.

**So the window is ours to choose, and it is a real open decision for #5.** 300 ms was used in the
live harness and felt right (three deliberate double-taps → exactly three detections; a slow single
tap → none) **[observed]**. Above ~500 ms it starts catching accidental drum-rolls; below ~200 ms it
gets hard to hit deliberately. **Make it configurable, default 300 ms.**

### The algorithm

The thing that actually bites: **press and release are BOTH `flagsChanged`.** There is no separate
up/down event type — direction comes from the mask. And see [the trap](#the-trap-first): mask to
`0x207F` first.

```swift
private let rOptKeyCode: Int64  = 61        // kVK_RightOption
private let rOptBit: UInt64     = 0x40      // NX_DEVICERALTKEYMASK
private let deviceMask: UInt64  = 0x207F    // union of the 8 device bits

var lastTapAt: CFTimeInterval = 0
var wasDown = false
let window: CFTimeInterval = 0.30           // configurable; no system value exists

func onFlagsChanged(keyCode: Int64, flags: UInt64, now: CFTimeInterval) -> Bool {
    guard keyCode == rOptKeyCode else { return false }   // some other modifier moved

    let device = flags & deviceMask                      // <-- the trap. Do this first.
    let isDown = device & rOptBit != 0                   // direction, from the mask
    defer { wasDown = isDown }
    guard isDown, !wasDown else { return false }         // RISING EDGE only

    // right-Option as part of a combo (⌥⇧, ⌥⌘…) is not our gesture
    if device & ~rOptBit != 0 { lastTapAt = 0; return false }

    if now - lastTapAt <= window { lastTapAt = 0; return true }   // FIRE
    lastTapAt = now
    return false
}
```

| Edge case | Behaviour |
|---|---|
| **Key held down / key repeat** | The `!wasDown` rising-edge guard collapses it to one tap. Without it you get spammed. |
| **Other modifier combined** (⌥⇧, ⌥⌘) | `device & ~rOptBit` resets the timer. Verified against the observed combo word `0x000A0144`. |
| **Second tap held down** | Fires on the second *press*, not its release. Push-to-talk would be a different gesture, needing the falling edge too. |
| **Another modifier taps between our two taps** | The `keyCode` guard ignores it; our timer keeps running. Arguably it should cancel — cheap to add, a judgement call for #5. |
| **A character key typed between the two taps** | **We cannot see it.** See below. |
| **Timestamps** | Use `CACurrentMediaTime()` (monotonic) or the event's own `.timestamp`. **Never `Date()`** — wall-clock, and it jumps on NTP sync. |

### The privacy bound is the mask

To cancel the gesture when a letter is typed between the two Option taps, the listener would have to
also match `.keyDown` — at which point **the app receives every keystroke the user types in every
application.** For a local-and-private dictation logger that is a bad trade for a marginal gesture
improvement.

Matching `.flagsChanged` only means the app is **structurally incapable** of reading typed text. That
belongs in the PRD as a guarantee, not left as an accident of implementation.

## Failure modes

### The tap-disable path (only if you use `CGEventTap`)

Not applicable to the `NSEvent` recommendation, but documented because it is the main hidden cost of
the tap, and because it would decide the design if we ever switch.

`CGEventTypes.h:128-132` **[header]**:

```c
/* Out of band event types. These are delivered to the event tap callback
   to notify it of unusual conditions that disable the event tap. */
kCGEventTapDisabledByTimeout = 0xFFFFFFFE,
kCGEventTapDisabledByUserInput = 0xFFFFFFFF
```

`kCGEventTapDisabledByTimeout` means the system decided your callback was too slow and **cut you out
of the event stream.** The tap object stays alive and valid; it just goes deaf. These arrive **as the
`type` argument of the callback**, not as a `flagsChanged` event, so a callback that only
pattern-matches modifiers drops them on the floor and never notices it has died.

```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    CGEvent.tapEnable(tap: myTap, enable: true)   // resurrect
    return nil
}
```

**In practice it never fired**: across every run, `CGEventTapIsEnabled == true` at the end, and
neither disable reason was ever delivered. **[observed]** So this is a latent hazard, not an observed
one — but a slow callback earns it, which is why a tap callback must never record audio, touch the
filesystem, or hop actors inline. The timeout threshold is undocumented and unmeasured. **[open]**

### Permission revoked while running

**[open]**. Expected: the stream simply goes quiet, with no callback and no error. Cheap defence:
re-check `CGPreflightListenEventAccess()` on `NSApplication.didBecomeActive` and on a low-frequency
timer, and surface an explicit "Input Monitoring was turned off" state in the menubar rather than
appearing merely broken. Feeds **#8**.

## Open questions — must be tested by a human

> **RESOLVED 2026-07-15** (issue #13, Finder-launch test) →
> [`input-monitoring-grant-behavior.md`](./input-monitoring-grant-behavior.md). Both answered:
> **A.** the denied path is fail-silent — `addGlobalMonitorForEvents` **and**
> `CGEvent.tapCreate(.listenOnly)` both return **non-nil when denied** (the `CGEvent.h` "NULL when
> unpermitted" header is wrong), zero events flow, so `CGPreflightListenEventAccess()` is the only
> gate. **B.** an **ad-hoc** rebuild voids the grant every time (DR = cdhash); a build signed with a
> **stable identity + fixed bundle id** keeps it (DR = identifier + cert). A self-signed cert
> suffices; a *revoked* cert makes XProtect trash the app. **Correction to this doc:** polling
> `CGPreflightListenEventAccess()` on a timer/`didBecomeActive` does **not** see a mid-session change
> — it is a launch-time read; relaunch or watch event flow instead.

Both feed the **first-run preflight ticket (#12)** directly, and neither could be tested from an agent
session. **They are the two things standing between this document and a complete answer.**

The blocker was the same for both: the harness had to be `exec`'d directly (LaunchServices `open` is
blocked in this environment, error `-54`), so **TCC attributed everything to the *responsible
process* — the user's terminal (Ghostty) — which already holds Input Monitoring.** Every measurement
above was therefore taken by a process that had *inherited* a grant. **The denied state was never
seen.**

### A. The unpermitted path is untested

**Nothing here verifies what happens with no permission**, so the fail-silent behaviour that the whole
preflight design assumes is **assumed, not known**.

- `NSEvent.addGlobalMonitorForEvents` is expected to return a **non-nil** monitor and simply never
  fire — no error, no nil, indistinguishable from "the user hasn't pressed the key yet." The non-nil
  return is confirmed **[measured]**; the never-fires-when-denied half is **[open]**.
- `CGEventTap` is documented to return `NULL` when the mask empties out (`CGEvent.h`, quoted above).
  **But this was contradicted once:** `CGEvent.tapCreate(listenOnly)` returned a **non-nil** tap in a
  run where `CGPreflightListenEventAccess()` reported `false`. That run was under a sandbox that may
  simply have blocked the TCC query, so it is **not clean evidence** — but it is enough that
  "`tapCreate` fails loudly" **must not be relied on** until someone tests it properly. This is
  precisely why the recommendation leans on an explicit `CGPreflightListenEventAccess()` gate rather
  than on either API's self-reporting.

**Test:** build the app, do **not** grant Input Monitoring (or revoke it), launch from Finder, and
record what `CGPreflightListenEventAccess()`, `addGlobalMonitorForEvents`, and `CGEvent.tapCreate`
each return and deliver.

### B. Does a local rebuild silently void the Input Monitoring grant?

Also untestable from here (everything was attributed to the terminal, never to the app's own bundle
id). This is **a big deal for daily development** — the developer will rebuild constantly.

What *can* be substantiated, and was **[measured]** directly:

**TCC matches a client against its designated requirement (DR), not its path.** For an **ad-hoc**
signature (`codesign -s -`, i.e. what a local unsigned build effectively gets), **the DR literally is
the code hash**:

```
build #1:  designated => cdhash H"23732e0fdd0bdc511ba67d6c2b75c4ca898fdf05"
build #2:  designated => cdhash H"086f4a4cacc732710eb95ac6bba69a7cb56be87b"
```

Recompile → the cdhash changes → the DR changes. An ad-hoc signature also has **no stable Team ID** to
fall back on. So the grant is expected to stop matching **on every single rebuild**.

**The mitigation, measured to work.** Sign with a **real identity** and a **stable bundle identifier**;
the DR then keys off the identifier and the certificate rather than the bits. Two *different* binaries:

```
$ codesign -f -s "Apple Development: …" -i app.speechlogger.probe  <build #1>   # CDHash=0e744f68…
$ codesign -f -s "Apple Development: …" -i app.speechlogger.probe  <build #2>   # CDHash=e6850056…

both:  designated => identifier "app.speechlogger.probe" and anchor apple generic
                     and certificate leaf[subject.CN] = "Apple Development: … (T59HNF76UY)"
                     and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
```

**Identical DR across two different binaries.** The bits changed; the identity did not. **[measured]**

This machine already has four usable identities (`security find-identity -v -p codesigning`, under the
Entrega Digital team), so the mitigation costs nothing.

**Be precise about what this does and does not prove:** it proves the *DR* is stable, and TCC is
documented to match on the DR. It does **not** prove end-to-end that the grant survives, because the
grant was never attributed to the app bundle in the first place.

**The clean test the developer should run (five minutes, and it closes both A and B):**

1. Build the `.app`, sign it ad-hoc, put it at a fixed path, and **double-click it in Finder** — not
   `exec`. A Finder launch is what makes TCC attribute the grant to *the app* rather than to the
   terminal.
2. Grant Input Monitoring when prompted. Confirm the double-tap fires.
3. **Rebuild, ad-hoc sign again, relaunch.** Does it still work, has it gone silently deaf, or does
   System Settings now show a second entry?
4. Repeat with a stable Apple Development identity + fixed bundle id. Expect the grant to survive.

Until step 3 is run, "ad-hoc rebuilds void the grant" is a **well-founded expectation, not a fact.**

## Consequences for the app

1. **`NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`.** Mask `flagsChanged` **only** —
   never `.keyDown`, which is the privacy bound.
2. **The permission is Input Monitoring.** Accessibility is not required and must never be requested.
   **Never call `AXIsProcessTrustedWithOptions(prompt: true)`.**
3. **Gate on `CGPreflightListenEventAccess()` explicitly** (it never prompts). Do not rely on either
   listening API to report its own permission state — see open question A.
4. **Mask the flag word to `0x207F` before testing any bit.** The naive test never fires, silently.
5. Detect the double-tap yourself: keyCode `61`, device bit `0x40`, **rising edge**, ~300 ms
   configurable window. No system API and no system preference offers this.
6. **Sign every build with a stable identity and a fixed bundle id.** An ad-hoc DR is the cdhash, and
   it changes on every rebuild.
7. Accept that the double-tap **also reaches the frontmost app**. Swallowing it costs an Accessibility
   prompt — a product decision, not an implementation detail.
8. Do not use Carbon `RegisterEventHotKey` for a modifier-only gesture: it returns `noErr` and never
   fires. (It remains the **zero-permission** answer if the hotkey may ever be an ordinary key combo.)
9. If the app ever switches to `CGEventTap`, handle `kCGEventTapDisabledByTimeout` /
   `…ByUserInput` and re-enable, and keep the callback trivial.
