import AVFoundation
import AudioToolbox
import CoreAudio
import SpeechLoggerCore
import Synchronization

/// One Core Audio HAL output unit (AUHAL) capturing one input device into a `CaptureState`
/// (#75, ADR-0011). Disposable: one per capture attempt, never reused.
///
/// **The device is set before the unit is initialized**, so the unit opens only that device
/// and never the system default input. That is the whole reason this exists instead of
/// `AVAudioEngine`, whose `inputNode` opens the default input the moment it is touched and
/// pulls a Bluetooth headset into HFP before any rebind (ADR-0010).
///
/// The input callback runs on the HAL's real-time IO thread and does not allocate: it renders
/// into an `AVAudioPCMBuffer` preallocated at open and hands that buffer, uncopied, to the
/// accumulator, which converts every buffer to the capture format.
final class CaptureUnit: @unchecked Sendable {
    struct OpenError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed: OSStatus \(status)" }
    }

    private static let inputElement: AudioUnitElement = 1
    private static let outputElement: AudioUnitElement = 0
    /// Floor for the render buffer, in case the unit reports a smaller slice than it renders.
    private static let minimumRenderFrames: AVAudioFrameCount = 4096

    private let unit: AudioUnit
    private let state: CaptureState
    /// Owned by the IO thread once the unit starts. The main actor touches it again only
    /// after `AudioOutputUnitStop` has returned.
    private let buffer: AVAudioPCMBuffer
    private let renderErrorCount = Atomic<Int>(0)

    var isRunning: Bool {
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        return status == noErr && running != 0
    }

    /// A device whose rate changed under the unit shows up here, not as a stop: the client
    /// format no longer matches and every render fails until the unit is rebuilt.
    var renderErrors: Int { renderErrorCount.load(ordering: .relaxed) }

    /// The device's format as the unit read it at open, for the log.
    var format: AVAudioFormat { buffer.format }

    /// Build, bind, initialize and start a unit on `device`. Every step that fails disposes
    /// of what was built and throws, so a failed open holds no device.
    static func open(device: AudioDeviceID, into state: CaptureState) throws(OpenError) -> CaptureUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw OpenError(step: "finding the HAL output unit", status: kAudioUnitErr_InvalidElement)
        }
        var maybeUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &maybeUnit), "creating the unit")
        guard let unit = maybeUnit else {
            throw OpenError(step: "creating the unit", status: kAudioUnitErr_FailedInitialization)
        }
        do throws(OpenError) {
            return try configure(unit, device: device, state: state)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private static func configure(
        _ unit: AudioUnit, device: AudioDeviceID, state: CaptureState
    ) throws(OpenError) -> CaptureUnit {
        var on: UInt32 = 1
        var off: UInt32 = 0
        try setProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputElement, &on, "enabling input")
        try setProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputElement, &off, "disabling output")
        var id = device
        try setProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, "binding the device")

        // The AUHAL does not resample input, so the client side must run at the device's rate.
        var hardware = AudioStreamBasicDescription()
        try getProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputElement, &hardware, "reading the device format")
        guard let format = clientFormat(rate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame) else {
            throw OpenError(step: "building the client format", status: kAudioUnitErr_FormatNotSupported)
        }
        var client = format.streamDescription.pointee
        try setProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputElement, &client, "setting the client format")

        var maxFrames: UInt32 = 0
        try getProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, "reading the slice size")
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(maxFrames, minimumRenderFrames)) else {
            throw OpenError(step: "allocating the render buffer", status: kAudioUnitErr_FailedInitialization)
        }

        let capture = CaptureUnit(unit: unit, state: state, buffer: buffer)
        // Unretained: the recorder holds the capture for longer than the unit lives, since
        // `dispose` stops and disposes the unit before the capture can be released.
        var callback = AURenderCallbackStruct(
            inputProc: inputCallback, inputProcRefCon: Unmanaged.passUnretained(capture).toOpaque())
        try setProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, "installing the input callback")
        try check(AudioUnitInitialize(unit), "initializing the unit")
        do throws(OpenError) {
            try check(AudioOutputUnitStart(unit), "starting the unit")
        } catch {
            AudioUnitUninitialize(unit)
            throw error
        }
        return capture
    }

    private init(unit: AudioUnit, state: CaptureState, buffer: AVAudioPCMBuffer) {
        self.unit = unit
        self.state = state
        self.buffer = buffer
    }

    /// Stop the unit and **release the device**. `AudioOutputUnitStop` returns once the IO
    /// thread is out of the callback, so nothing touches `state` after this.
    func dispose() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Float32, non-interleaved, at the device's own rate and channel count. Past two
    /// channels AVFoundation needs a layout to describe the format at all.
    private static func clientFormat(rate: Float64, channels: UInt32) -> AVAudioFormat? {
        guard rate > 0, channels > 0 else { return nil }
        if channels <= 2 {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)
        else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }

    // MARK: - The IO thread

    fileprivate func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timeStamp: UnsafePointer<AudioTimeStamp>, _ frames: UInt32
    ) {
        guard frames <= buffer.frameCapacity else {
            renderErrorCount.add(1, ordering: .relaxed)
            return
        }
        // Setting the length also sizes every channel's `mDataByteSize` for the render.
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timeStamp, Self.inputElement, frames, buffer.mutableAudioBufferList)
        guard status == noErr else {
            renderErrorCount.add(1, ordering: .relaxed)
            return
        }
        state.append(buffer)
    }

    // MARK: - Property plumbing

    private static func check(_ status: OSStatus, _ step: String) throws(OpenError) {
        guard status == noErr else { throw OpenError(step: step, status: status) }
    }

    private static func setProperty<T: BitwiseCopyable>(
        _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
        _ element: AudioUnitElement, _ value: inout T, _ step: String
    ) throws(OpenError) {
        try check(
            AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)), step)
    }

    private static func getProperty<T: BitwiseCopyable>(
        _ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
        _ element: AudioUnitElement, _ value: inout T, _ step: String
    ) throws(OpenError) {
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioUnitGetProperty(unit, property, scope, element, &value, &size), step)
    }
}

/// A C callback captures nothing, so the capture rides in through `refCon`.
private let inputCallback: AURenderCallback = { refCon, flags, timeStamp, _, frames, _ in
    Unmanaged<CaptureUnit>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, frames)
    return noErr
}
