import AVFoundation
import AppKit
import CoreAudio
import SpeechLoggerCore

/// The microphone as the device reports it: the grant, the presence of an input, and
/// whether that input is muted or at zero gain (#45).
///
/// Three sources, in the order a recording would hit them: TCC, then AVFoundation for
/// the device, then CoreAudio for mute and volume — the last two are not exposed by
/// AVFoundation at all. `SpeechLoggerCore` takes the answer as a value, so preflight
/// and `RecordingCoordinator` stay testable without hardware.
///
/// **Every unknown reads as usable.** A device that does not implement the mute or
/// volume property is common (many USB mics, AirPods), and the cost of the two errors
/// is not symmetric: a false "unusable" refuses a recording the user could have made
/// and costs them the thought, while a false "usable" costs a recording that comes back
/// empty — the state of the world before this check existed.
enum Microphone {
    /// Query the device now. Cheap enough for the main actor and for the start of every
    /// recording: a TCC read, a device lookup, and two CoreAudio property reads.
    static var state: MicrophoneState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .denied, .restricted:
            return .permissionDenied
        case .notDetermined:
            // Undecided is the archetypal unknown, so it reads as usable: refusing here
            // would report "denied" for a decision nobody has made, send the user to a
            // pane the app is not listed in yet, and step in front of the one path that
            // still prompts (`AudioRecorder.start`).
            break
        @unknown default:
            break
        }

        // Two answers to "is there a mic", and they can disagree: AVFoundation
        // enumerates capture devices, while `AVAudioEngine`'s input node follows the
        // *default input device*, which is the one CoreAudio names. Only agreement that
        // there is nothing counts as nothing — a disagreement is an unknown, and an
        // unknown reads as usable rather than refusing a recording that might work.
        let captureDevice = AVCaptureDevice.default(for: .audio)
        let inputDevice = defaultInputDevice
        guard captureDevice != nil || inputDevice != nil else { return .noDevice }

        // Mute and gain are knowable only through CoreAudio. With no default input
        // device to ask, they stay unknown, which is again read as usable.
        guard let inputDevice else { return .usable }
        if isMuted(inputDevice) || isGainless(inputDevice) { return .silenced }
        return .usable
    }

    /// Open System Settings straight to the Microphone privacy pane.
    static func openPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Open System Settings straight to Sound, where the input device and its volume
    /// live — the pane that owns a muted or gainless mic.
    static func openSoundSettings() {
        open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - CoreAudio

    /// The system's current default input device, or nil when there is none.
    private static var defaultInputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// The input is muted. A device with no mute property is not muted.
    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        guard let mute = property(kAudioDevicePropertyMute, of: device, initial: UInt32(0))
        else { return false }
        return mute != 0
    }

    /// The input volume is at zero, so the device would capture nothing. A device with
    /// no volume property (many USB mics) reads as gained.
    private static func isGainless(_ device: AudioDeviceID) -> Bool {
        guard let volume = property(kAudioDevicePropertyVolumeScalar, of: device, initial: Float32(1))
        else { return false }
        // Scalar volume is 0…1. Compare against a floor rather than to zero exactly:
        // the value is a float the driver computed, not one we set.
        return volume <= 0.0001
    }

    /// Read one input-scope property, on the main element, or nil when the device does
    /// not implement it. `mElement` is the master control; per-channel volume without a
    /// master reads as absent, which lands on "usable" by design.
    ///
    /// The size the driver actually wrote is checked, not assumed: a short write with
    /// `noErr` would otherwise leave the tail of `value` unread-from-the-driver, and a
    /// garbage volume below the floor would refuse a recording on a working microphone.
    /// `initial` is the value that survives a partial read being rejected — chosen as
    /// the *usable* reading of each property, so every escape hatch here agrees.
    private static func property<T>(
        _ selector: AudioObjectPropertySelector, of device: AudioDeviceID, initial: T
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        let expected = UInt32(MemoryLayout<T>.size)
        var size = expected
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, size == expected else { return nil }
        return value
    }
}
