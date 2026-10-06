import Foundation

/// How an input device is attached, as Core Audio reports it. Only Bluetooth matters to
/// the policy; the rest are kept apart so the log can say what the device was.
public enum InputTransport: String, Sendable, Equatable {
    case builtIn = "built-in"
    case bluetooth
    case bluetoothLE = "bluetooth-le"
    case usb
    case virtual
    case other

    public var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }
}

/// An input device the capture could record from. `id` is the Core Audio `AudioDeviceID`.
public struct InputDevice: Sendable, Equatable {
    public let id: UInt32
    /// As the device names itself, or nil when it publishes no name.
    public let name: String?
    public let transport: InputTransport

    public init(id: UInt32, name: String?, transport: InputTransport) {
        self.id = id
        self.name = name
        self.transport = transport
    }
}

/// The device a capture records from, and why the policy picked it.
public struct CaptureDeviceChoice: Sendable, Equatable {
    public enum Reason: String, Sendable {
        case defaultInput = "default input"
        case avoidingBluetooth = "avoiding Bluetooth"
        case bluetoothOnly = "Bluetooth is the only input"
    }

    public let device: InputDevice
    public let reason: Reason

    public init(device: InputDevice, reason: Reason) {
        self.device = device
        self.reason = reason
    }
}

/// Which input device a capture records from (#75, ADR-0011).
///
/// A Bluetooth default input is avoided when a built-in mic exists: opening it pulls the
/// headset from A2DP into HFP, which costs 4–5 s before audio flows, drops its playback to
/// 16 kHz mono, and changes rate mid-capture (#69). Any other default input is a choice the
/// user made and is honored. The system default is never changed.
///
/// Automatic, with no setting, and evaluated fresh at the start of every capture.
public struct CaptureDevicePolicy: Sendable {
    public init() {}

    /// Nil only when there is no default input, which the microphone check reports as no
    /// device.
    public func choose(defaultInput: InputDevice?, inputs: [InputDevice]) -> CaptureDeviceChoice? {
        guard let defaultInput else { return nil }
        guard defaultInput.transport.isBluetooth else {
            return CaptureDeviceChoice(device: defaultInput, reason: .defaultInput)
        }
        guard let builtIn = inputs.first(where: { $0.transport == .builtIn }) else {
            return CaptureDeviceChoice(device: defaultInput, reason: .bluetoothOnly)
        }
        return CaptureDeviceChoice(device: builtIn, reason: .avoidingBluetooth)
    }
}
