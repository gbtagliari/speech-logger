import AVFoundation
import AppKit
import CoreAudio
import SpeechLoggerCore

/// The microphone as the device reports it: the grant, the presence of an input, and
/// whether that input is muted or at zero gain (#45).
///
/// Two sources, in the order a recording would hit them: TCC, then CoreAudio for the
/// device the capture will record from and its mute and volume. `SpeechLoggerCore` takes
/// the answer as a value, so preflight and `RecordingCoordinator` stay testable without
/// hardware.
///
/// **Every unknown reads as usable.** A device that does not implement the mute or
/// volume property is common (many USB mics, AirPods), and the cost of the two errors
/// is not symmetric: a false "unusable" refuses a recording the user could have made
/// and costs them the thought, while a false "usable" costs a recording that comes back
/// empty — the state of the world before this check existed.
enum Microphone {
    /// Query the device now. Cheap enough for the main actor and for the start of every
    /// recording: a TCC read, a device enumeration, and two CoreAudio property reads.
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

        // The device the capture will record from, not the system default (#75): a muted
        // headset mic must not block a recording made from the built-in mic.
        guard let device = InputDevices.resolve().choice?.device else { return .noDevice }
        let id = AudioDeviceID(device.id)
        if isMuted(id) || isGainless(id) { return .silenced }
        return .usable
    }

    /// Open System Settings straight to the Microphone privacy pane. The anchored
    /// legacy form, the same one `InputMonitoring.openSettings` already relies on.
    static func openPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Open System Settings straight to Sound, where the input device and its volume
    /// live: the pane that owns a muted or gainless mic.
    ///
    /// The identifier is verified, not assumed — it is the `CFBundleIdentifier` of
    /// `/System/Library/ExtensionKit/Extensions/Sound.appex` (macOS 26.5). A settings
    /// deep-link that silently opens nothing is worse than offering no button at all.
    static func openSoundSettings() {
        open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - CoreAudio

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

    /// Read one input-scoped property of `device` on the main element, or nil when the
    /// device does not implement it. Input scope is what mute and volume are asked in,
    /// and they are the only two readers. `mElement` is the master control; per-channel
    /// volume without a master reads as absent, which lands on "usable" by design.
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
