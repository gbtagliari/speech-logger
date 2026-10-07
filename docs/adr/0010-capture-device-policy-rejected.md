# ADR-0010 — No capture device policy: AVAudioEngine cannot avoid a Bluetooth default input

Status: rejected (the policy); accepted (this record). Rejection superseded by ADR-0011
Date: 2026-10-05

## Context

On macOS 27 a Bluetooth headset that is the default input costs 4–5 s before audio flows (the
A2DP → HFP switch), drops the headset's playback to 16 kHz mono while the app holds the mic, and
changes sample rate mid-capture (#69). Issue #69 proposed a **capture device policy**: when the
default input is Bluetooth and a built-in mic exists, bind the capture to the built-in mic and
leave the system default untouched, so the headset never enters HFP.

The issue gated that policy on a probe (`scripts/probes/capture-device-probe.swift`): bind an
`AVAudioEngine` input to the built-in mic while the default input is the headset, and show
(a) audio flows in under 0.5 s, (b) the headset stays A2DP, (c) no `NSException` on tap install.

## Decision

The policy is not built. The probe failed (b) and (c).

Measured on macOS 27.0, soundcore Life Q30, `AVAudioEngine` input bound with
`inputNode.auAudioUnit.setDeviceID(builtIn)`:

- **(b) fails.** `engine.inputNode` opens the system default input the moment it is first
  touched, before any device can be set on it. The headset's output went from 44.1 kHz (A2DP) to
  16 kHz (HFP) on every bound run, the same switch the control run (no binding) produced.
- **The binding does not reliably hold.** In some bound runs the buffers arrived at 16 kHz with the
  headset's input running: the audio came from the headset, not the built-in mic.
- **(c) fails.** After the rebind, the node's `outputFormat` stays at the headset's rate while its
  `inputFormat` reports the built-in mic's 48 kHz. Which of the two a tap accepts depends on the
  headset's state: the hardware format works while the headset is already in HFP and raises
  "format mismatch" while it is idle in A2DP. No format read off the node is safe in both states.
- (a) passes when the bind holds: first frame ~0.14 s from the built-in mic.

## Consequences

- Front 1 of #69 stands alone: a Bluetooth capture is correct (format-safe, ADR-0002 amendment)
  but slow, and it still degrades the headset's playback while recording.
- The microphone checks and the failure's device name keep referring to the system default input.
- Avoiding the headset needs a capture path that never opens the default input: a Core Audio HAL
  unit (AUHAL) or an `AVCaptureSession` bound to the built-in device from creation. Either is a new
  spec, not a tweak to this one, and must clear the same probe before it is built.

## Follow-up (2026-10-05): AUHAL clears the probe

`capture-device-probe --auhal` captures through a HAL output unit (`kAudioUnitSubType_HALOutput`,
input enabled, output disabled) set to the built-in mic before `AudioUnitInitialize`, so the
default input is never opened. Same machine and headset, idle in A2DP, 5 of 5 runs:

- (a) first frame 0.054–0.064 s (48 kHz mono, ~145k frames in 3 s, no render errors).
- (b) the headset's output stayed at 44.1 kHz and its input never ran. The unbound control, run
  right after, still switched it to 16 kHz HFP.
- (c) there is no `installTap`, so the #55 `NSException` cannot occur.

The policy is viable on an AUHAL capture path. Building it means replacing the recorder's
`AVAudioEngine` and is a new spec.

Built in #75: see ADR-0011.
