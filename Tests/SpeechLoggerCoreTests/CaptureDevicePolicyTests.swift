import Testing

@testable import SpeechLoggerCore

/// The capture device policy replays without a Bluetooth headset: the decision is a
/// function of the default input and the device list (#75).
struct CaptureDevicePolicyTests {
    private let policy = CaptureDevicePolicy()

    private static let builtIn = InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn)
    private static let headset = InputDevice(id: 2, name: "soundcore Life Q30", transport: .bluetooth)
    private static let buds = InputDevice(id: 3, name: "LE buds", transport: .bluetoothLE)
    private static let usb = InputDevice(id: 4, name: "USB mic", transport: .usb)
    private static let loopback = InputDevice(id: 5, name: "Loopback", transport: .virtual)

    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let defaultInput: InputDevice?
        let inputs: [InputDevice]
        let expected: CaptureDeviceChoice?
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(
            label: "Bluetooth default + built-in present -> built-in",
            defaultInput: headset, inputs: [builtIn, headset],
            expected: CaptureDeviceChoice(device: builtIn, reason: .avoidingBluetooth)),
        Case(
            label: "Bluetooth LE default + built-in present -> built-in",
            defaultInput: buds, inputs: [buds, builtIn],
            expected: CaptureDeviceChoice(device: builtIn, reason: .avoidingBluetooth)),
        Case(
            label: "Bluetooth default and no built-in -> Bluetooth",
            defaultInput: headset, inputs: [headset, usb],
            expected: CaptureDeviceChoice(device: headset, reason: .bluetoothOnly)),
        Case(
            label: "USB default -> USB",
            defaultInput: usb, inputs: [builtIn, usb, headset],
            expected: CaptureDeviceChoice(device: usb, reason: .defaultInput)),
        Case(
            label: "virtual default -> virtual",
            defaultInput: loopback, inputs: [builtIn, loopback],
            expected: CaptureDeviceChoice(device: loopback, reason: .defaultInput)),
        Case(
            label: "built-in default -> built-in",
            defaultInput: builtIn, inputs: [builtIn, headset],
            expected: CaptureDeviceChoice(device: builtIn, reason: .defaultInput)),
        Case(
            label: "no default input -> no device",
            defaultInput: nil, inputs: [builtIn, headset],
            expected: nil),
        Case(
            label: "empty device list with a default -> the default input",
            defaultInput: usb, inputs: [],
            expected: CaptureDeviceChoice(device: usb, reason: .defaultInput)),
    ]

    @Test(arguments: cases)
    func choosesTheCaptureDevice(_ testCase: Case) {
        #expect(policy.choose(defaultInput: testCase.defaultInput, inputs: testCase.inputs) == testCase.expected)
    }
}
