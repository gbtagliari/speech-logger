// The gate for the capture device policy (#69, front 2). Outside the app on purpose: it answers
// whether an AVAudioEngine input can be bound to the built-in mic while the system default input
// is a Bluetooth headset, without the headset entering HFP.
//
//   swiftc -O scripts/probes/capture-device-probe.swift -o /tmp/capture-device-probe
//   /tmp/capture-device-probe [--control] [--runs N]
//
// `--auhal` captures through a HAL output unit set to the built-in mic before it is initialized,
// never opening the default input. `--control` leaves the engine on the system default input, to show the HFP switch the
// measurement is meant to catch. `TAP=hw|nil` installs the tap at the node's input format or with
// no format instead of its output format. Needs the microphone grant for the terminal running it.
// Results and the rejection they led to: docs/adr/0010-capture-device-policy-rejected.md.

import AVFoundation
import CoreAudio
import Foundation

// MARK: - CoreAudio

struct Device {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    let hasInput: Bool
    let hasOutput: Bool

    var transportLabel: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeBluetooth: "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        default: "other(\(transport))"
        }
    }
    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

func address(
    _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var addr = address(selector, scope)
    guard AudioObjectHasProperty(object, &addr) else { return nil }
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
    }
    return status == noErr ? value : nil
}

func name(of device: AudioDeviceID) -> String {
    var addr = address(kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let name else { return "?" }
    return name.takeRetainedValue() as String
}

func hasStreams(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
    var addr = address(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
}

func devices() -> [Device] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.map {
        Device(
            id: $0, name: name(of: $0),
            transport: scalar($0, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0,
            hasInput: hasStreams($0, kAudioObjectPropertyScopeInput),
            hasOutput: hasStreams($0, kAudioObjectPropertyScopeOutput))
    }
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    scalar(AudioObjectID(kAudioObjectSystemObject), selector, AudioDeviceID(kAudioObjectUnknown))
        .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
}

/// What the headset's output is doing: its nominal rate (A2DP runs at 44.1/48 kHz, HFP at 16 kHz
/// or lower) and whether anyone is running its input (HFP is the only profile with a mic).
func headsetLine(_ all: [Device], named headset: String) -> String {
    all.filter { $0.name == headset }.map { device in
        let rate = scalar(device.id, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0
        let running = scalar(device.id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)) ?? 0
        let role = device.hasInput ? "in" : device.hasOutput ? "out" : "-"
        return "\(role)#\(device.id) \(Int(rate)) Hz running=\(running)"
    }.joined(separator: " | ")
}

// MARK: - One run

struct RunResult {
    let startBlocked: Double
    let firstFrame: Double?
    let formats: [String]
    let headsetSamples: [String]
}

final class FirstFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var at: Double?
    private var formats: [String] = []
    func note(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if at == nil { at = CACurrentMediaTime() }
        let label = "\(Int(buffer.format.sampleRate)) Hz/\(buffer.format.channelCount) ch"
        if formats.last != label { formats.append(label) }
    }
    var read: (Double?, [String]) { lock.lock(); defer { lock.unlock() }; return (at, formats) }
}

func run(bindingTo device: AudioDeviceID?, headset: String, seconds: Double) -> RunResult {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if let device {
        do {
            try input.auAudioUnit.setDeviceID(device)
        } catch { print("  binding failed: \(error)") }
    }
    let first = FirstFrame()
    let format = input.outputFormat(forBus: 0)
    print("  node: hw \(input.inputFormat(forBus: 0)) out \(format)")
    let tapFormat: AVAudioFormat? = switch ProcessInfo.processInfo.environment["TAP"] {
    case "hw": input.inputFormat(forBus: 0)
    case "nil": nil
    default: format
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { @Sendable buffer, _ in
        first.note(buffer)
    }
    engine.prepare()
    let t0 = CACurrentMediaTime()
    do { try engine.start() } catch { print("  start failed: \(error)") }
    let startBlocked = CACurrentMediaTime() - t0

    var samples: [String] = []
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        samples.append(headsetLine(devices(), named: headset))
    }
    input.removeTap(onBus: 0)
    engine.stop()
    let (at, formats) = first.read
    return RunResult(
        startBlocked: startBlocked, firstFrame: at.map { $0 - t0 }, formats: formats,
        headsetSamples: samples)
}

// MARK: - One run, AUHAL

/// What the input callback needs, reached through `inRefCon`: a C callback captures nothing.
final class HALCapture: @unchecked Sendable {
    let unit: AudioUnit
    let channels: UInt32
    let lock = NSLock()
    var firstFrameAt: Double?
    var frames: UInt64 = 0
    var renderErrors = 0
    init(unit: AudioUnit, channels: UInt32) { self.unit = unit; self.channels = channels }
}

func check(_ status: OSStatus, _ what: String) -> Bool {
    if status != noErr { print("  \(what) failed: OSStatus \(status)") }
    return status == noErr
}

let halInputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frameCount, _ in
    let capture = Unmanaged<HALCapture>.fromOpaque(refCon).takeUnretainedValue()
    let list = AudioBufferList.allocate(maximumBuffers: Int(capture.channels))
    defer { free(list.unsafeMutablePointer) }
    for index in 0..<Int(capture.channels) {
        // Null data asks the unit to supply its own buffers.
        list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
    }
    let status = AudioUnitRender(capture.unit, flags, timeStamp, bus, frameCount, list.unsafeMutablePointer)
    capture.lock.lock()
    if status == noErr {
        if capture.firstFrameAt == nil { capture.firstFrameAt = CACurrentMediaTime() }
        capture.frames += UInt64(frameCount)
    } else {
        capture.renderErrors += 1
    }
    capture.lock.unlock()
    return noErr
}

/// A HAL output unit with output disabled and input enabled, set to `device` before it is
/// initialized, so the system default input is never opened.
func runHAL(device: AudioDeviceID, headset: String, seconds: Double) -> RunResult {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else {
        print("  no HAL output component"); return RunResult(startBlocked: 0, firstFrame: nil, formats: [], headsetSamples: [])
    }
    var maybeUnit: AudioUnit?
    guard check(AudioComponentInstanceNew(component, &maybeUnit), "instance"), let unit = maybeUnit else {
        return RunResult(startBlocked: 0, firstFrame: nil, formats: [], headsetSamples: [])
    }
    defer { AudioComponentInstanceDispose(unit) }

    var on: UInt32 = 1, off: UInt32 = 0
    let size32 = UInt32(MemoryLayout<UInt32>.size)
    _ = check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, size32), "enable input")
    _ = check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, size32), "disable output")
    var id = device
    _ = check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)), "current device")

    // The device side of the input element, then the client side set to float at that rate.
    var hardware = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    _ = check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &asbdSize), "device format")
    let channels = max(1, hardware.mChannelsPerFrame)
    var client = AudioStreamBasicDescription(
        mSampleRate: hardware.mSampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
        mBitsPerChannel: 32, mReserved: 0)
    _ = check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, asbdSize), "client format")

    let capture = HALCapture(unit: unit, channels: channels)
    let refCon = Unmanaged.passRetained(capture)
    defer { refCon.release() }
    var callback = AURenderCallbackStruct(inputProc: halInputCallback, inputProcRefCon: refCon.toOpaque())
    _ = check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")

    let t0 = CACurrentMediaTime()
    _ = check(AudioUnitInitialize(unit), "initialize")
    _ = check(AudioOutputUnitStart(unit), "start")
    let startBlocked = CACurrentMediaTime() - t0

    var samples: [String] = []
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        samples.append(headsetLine(devices(), named: headset))
    }
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)

    capture.lock.lock(); defer { capture.lock.unlock() }
    let format = "\(Int(hardware.mSampleRate)) Hz/\(channels) ch, \(capture.frames) frames, \(capture.renderErrors) render errors"
    return RunResult(
        startBlocked: startBlocked, firstFrame: capture.firstFrameAt.map { $0 - t0 }, formats: [format],
        headsetSamples: samples)
}

// MARK: - Main

let arguments = CommandLine.arguments
let control = arguments.contains("--control")
let hal = arguments.contains("--auhal")
let runs = arguments.firstIndex(of: "--runs").flatMap { Int(arguments[$0 + 1]) } ?? 5

print("mic grant: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized)")
let all = devices()
for device in all {
    print("device #\(device.id) \(device.name) [\(device.transportLabel)] in=\(device.hasInput) out=\(device.hasOutput)")
}
guard let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
      let defaultInputDevice = all.first(where: { $0.id == defaultInput }) else {
    print("no default input"); exit(1)
}
print("default input: \(defaultInputDevice.name) [\(defaultInputDevice.transportLabel)]")
if let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
    print("default output: \(name(of: output))")
}
guard defaultInputDevice.isBluetooth else { print("default input is not Bluetooth; nothing to probe"); exit(1) }
guard let builtIn = all.first(where: { $0.hasInput && $0.transport == kAudioDeviceTransportTypeBuiltIn }) else {
    print("no built-in input"); exit(1)
}
let headset = defaultInputDevice.name
print("mode: \(control ? "CONTROL (system default input)" : hal ? "AUHAL on \(builtIn.name)" : "engine bound to \(builtIn.name)")")
print("headset before: \(headsetLine(all, named: headset))")

for index in 1...runs {
    let result = hal
        ? runHAL(device: builtIn.id, headset: headset, seconds: 3)
        : run(bindingTo: control ? nil : builtIn.id, headset: headset, seconds: 3)
    let first = result.firstFrame.map { String(format: "%.3f s", $0) } ?? "never"
    print(String(format: "run %d: start blocked %.3f s, first frame %@, formats %@", index,
                 result.startBlocked, first, result.formats.joined(separator: " -> ")))
    for sample in result.headsetSamples { print("  headset: \(sample)") }
    // Released between runs, as the app does, so each run starts from the idle headset.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
}
print("headset after: \(headsetLine(devices(), named: headset))")
