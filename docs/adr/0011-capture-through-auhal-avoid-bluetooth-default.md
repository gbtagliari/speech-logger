# ADR-0011 — Capture through AUHAL, and record from the built-in mic when the default input is Bluetooth

Status: accepted
Date: 2026-10-06
Supersedes: ADR-0010's rejection of the capture device policy

## Context

On macOS 27 a Bluetooth headset that is the default input costs 4–5 s before audio flows (the A2DP
→ HFP switch), drops the headset's playback to 16 kHz mono while the app holds the mic, and
changes sample rate mid-capture (#69). The opening words of a short dictation are lost, and every
recording degrades the user's music.

ADR-0010 rejected avoiding the headset on `AVAudioEngine`: `inputNode` opens the system default
input the moment it is touched, so the headset enters HFP before any rebind, and the tap format
that works depends on the headset's state. Its follow-up showed a Core Audio HAL output unit
(AUHAL) set to the built-in mic before `AudioUnitInitialize` never opens the default input.

## Decision

**The recorder captures through an AUHAL, not `AVAudioEngine`** (#75). One unit per capture
attempt, input enabled and output disabled, its current device set before initialization. The
client format is Float32 non-interleaved at the device's own rate and channel count (the AUHAL does
not resample input). The input callback renders into a buffer preallocated at open and hands it,
uncopied, to the unchanged capture accumulator (`CaptureState`), which converts to 16 kHz mono.
The unit is disposed at `stop` and at every rebuild, so between captures no device is held.

**A capture device policy picks the device** (`CaptureDevicePolicy`, a pure value):

| Default input | Built-in input exists | Capture from | Reason |
|---|---|---|---|
| Bluetooth / Bluetooth LE | yes | built-in | avoiding Bluetooth |
| Bluetooth / Bluetooth LE | no | default input | Bluetooth is the only input |
| anything else | — | default input | default input |
| none | — | nothing (`noDevice`) | — |

- **Automatic, no setting.** The only cost of avoiding Bluetooth is a worse mic than a headset
  boom, and the measured costs of using it (latency, degraded playback, rate flip) are paid on every
  recording. A user who wants a specific mic picks a non-Bluetooth default, which is honored.
- **Fresh per capture**, never cached: a device plugged in between recordings is reflected. Every
  rebuild within a capture binds the same chosen device.
- **The system default input is never changed**, so other apps keep the input the user chose.
- The microphone checks (presence, mute, zero volume) and the device named on a failed capture
  refer to the **chosen** device. Each capture logs the chosen device, the default input and the
  reason.

**The watchdog (`CaptureWatchdog`, #63) is reused as is.** Its two signals are now the unit's
`kAudioOutputUnitProperty_IsRunning` and frame arrival. A rate change under a running unit shows as
render errors with the unit still running; the flowing stall catches it and the rebuild reads the
new format.

## Probe results (macOS 27.0, soundcore Life Q30, `capture-device-probe --watched`)

- **Built-in mic, rate changed mid-run** (48 → 44.1 kHz at 2 s, 2 of 2 runs): the unit kept
  reporting running, renders failed (57–67 errors), the flowing stall fired 1.26–1.29 s after the
  change, one rebuild opened at 44.1 kHz and frames resumed. No give-up.
- **Bluetooth-bound fallback** (3 of 3 runs): first frame 0.100–0.147 s, 16 kHz mono, 0 rebuilds,
  0 render errors. Measured with the headset already in HFP (another process held its input); the
  cold A2DP → HFP case is in the manual matrix.
- Built-in mic with the headset idle in A2DP: ADR-0010's follow-up (first frame 0.054–0.064 s,
  headset stayed at 44.1 kHz, 5 of 5 runs).

## Consequences

- `AVAudioNode.installTap` (deprecated in the macOS 27 SDK) is gone from the app, and with it the
  #55 `NSException`: the `ObjCExceptionBridge` target had no caller left and was removed.
- A rate change costs about 1.3 s of audio (the flowing stall plus the rebuild). The capture
  survives at the correct speed (the accumulator converts each buffer from its own format).
- **Engine restart** keeps its name and `RecordingCapture.engineRestarts` keeps its field, so
  stored items and the guard are untouched; the "engine" is now the capture unit.
- The unit is opened on the main actor, as the engine was. Pre-warming and an off-main open are
  out of scope.
- Still to verify by hand (manual matrix in #75): the cold Bluetooth-only fallback latency, a
  headset disconnected mid-braindump, and the headset returning to A2DP at stop.
