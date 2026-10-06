import CoreAudio
import SpeechLoggerCore

/// The machine's input devices as Core Audio lists them, and the one a capture records
/// from (`CaptureDevicePolicy`, #75).
///
/// Read fresh on every call and never cached: a device plugged in or unplugged between
/// recordings has to be reflected in the next one.
enum InputDevices {
    /// The device the next capture records from, with the policy's reason, and the system
    /// default input it was chosen against (for the log).
    struct Resolution {
        let choice: CaptureDeviceChoice?
        let defaultInput: InputDevice?
    }

    private static let policy = CaptureDevicePolicy()

    static func resolve() -> Resolution {
        let defaultInput = defaultInputID.map(device)
        return Resolution(
            choice: policy.choose(defaultInput: defaultInput, inputs: all), defaultInput: defaultInput)
    }

    private static var all: [InputDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).map(device)
    }

    private static var defaultInputID: AudioDeviceID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return id
    }

    private static func device(_ id: AudioDeviceID) -> InputDevice {
        InputDevice(id: id, name: name(of: id), transport: transport(of: id))
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transport(of id: AudioDeviceID) -> InputTransport {
        var address = globalAddress(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth: return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    /// `Unmanaged` because this property answers with a `CFString` the caller owns:
    /// `takeRetainedValue` consumes that +1.
    private static func name(of id: AudioDeviceID) -> String? {
        var address = globalAddress(kAudioObjectPropertyName)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name else { return nil }
        let string = name.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}

extension InputDevice {
    /// How the recorder's log names a device: its name and transport, or its transport alone.
    var logLabel: String { "\(name ?? "unnamed") [\(transport.rawValue)]" }
}
