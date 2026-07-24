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

    /// The default input device's nominal sample rate, or nil when there is no device
    /// or it does not report one.
    ///
    /// The rate the *device* is running at, which is not always the rate `AVAudioEngine`
    /// binds its input node to: under contention the engine falls back to 44.1 kHz while
    /// the device runs at something else, and then delivers nothing (#54). This is the
    /// second opinion that makes that disagreement visible before a recording opens
    /// against it.
    static var defaultInputSampleRate: Double? {
        guard let device = defaultInputDevice,
            // Global scope: the nominal rate belongs to the device, not to its input
            // streams, and the input-scoped read the mute and volume checks use is not
            // guaranteed to answer for it.
            let rate = property(
                kAudioDevicePropertyNominalSampleRate, of: device,
                scope: kAudioObjectPropertyScopeGlobal, initial: Float64(0)),
            rate > 0
        else { return nil }
        return rate
    }

    /// Force the default input device's nominal sample rate, so the device re-publishes
    /// its format and a freshly built engine resolves its input node against a live rate
    /// instead of the 44.1 kHz fallback it cached under contention (#59). Returns the
    /// rate the device reports *after* the write, or nil when there is no device or it
    /// will not accept the rate.
    ///
    /// Global scope, to match the read: the nominal rate belongs to the device, not to
    /// its input streams. Settability is checked before the write — a device that does
    /// not let its rate be set answers nil rather than swallowing an error — and the
    /// truth returned is the read-back, not the value asked for, because the write can
    /// report `noErr` on a device that never actually reconciled.
    static func forceDefaultInputSampleRate(_ rate: Double) -> Double? {
        guard let device = defaultInputDevice else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
            AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
            settable.boolValue
        else { return nil }
        var value = Float64(rate)
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { return nil }
        return defaultInputSampleRate
    }

    /// The system's current default input device id, for the one caller that must reach
    /// the hardware directly — the AUHAL re-resolution in `AudioRecorder` (#59). Every
    /// other question about the device is answered by the readers above.
    static var defaultInputDeviceID: AudioDeviceID? { defaultInputDevice }

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

    /// Read one property of `device` on the main element, or nil when the device does
    /// not implement it. The scope defaults to input, which is what mute and volume are
    /// asked in. `mElement` is the master control; per-channel volume without a
    /// master reads as absent, which lands on "usable" by design.
    ///
    /// The size the driver actually wrote is checked, not assumed: a short write with
    /// `noErr` would otherwise leave the tail of `value` unread-from-the-driver, and a
    /// garbage volume below the floor would refuse a recording on a working microphone.
    /// `initial` is the value that survives a partial read being rejected — chosen as
    /// the *usable* reading of each property, so every escape hatch here agrees.
    private static func property<T>(
        _ selector: AudioObjectPropertySelector, of device: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeInput, initial: T
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
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
