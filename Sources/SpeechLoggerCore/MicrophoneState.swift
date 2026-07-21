import Foundation

/// The microphone as the device itself reports it: present, permitted, unmuted, gained.
///
/// A dead microphone is a **device fact, not an acoustic one**. It is queried from the
/// hardware rather than inferred from a recording that came back silent — silence has
/// two causes that want opposite outcomes (an accidental key press, a muted mic) and
/// the audio cannot tell them apart (#37).
///
/// The concrete query lives in the app target (AVFoundation + CoreAudio); this target
/// stays pure, so preflight is a function of its inputs and an unusable device is
/// testable without one.
///
/// **Accepted residual:** a device that is present, unmuted and gained but receiving
/// nothing — an interface with nothing plugged in, a covered mic, the wrong input
/// selected — reads as `usable` here. Detecting it would mean inferring from silence
/// again, which is the thing being removed.
public enum MicrophoneState: Sendable, Equatable, CaseIterable {
    /// Present, permitted, unmuted and gained. The only state that records.
    case usable
    /// The microphone grant is denied, restricted, or not yet decided. Either way the
    /// mic cannot open right now.
    case permissionDenied
    /// No input device at all: nothing to open.
    case noDevice
    /// A device is there and permitted, but muted or at zero input gain. It would
    /// capture nothing, which is the case that used to be discovered too late.
    case silenced

    public var isUsable: Bool { self == .usable }
}
