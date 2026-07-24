import SpeechLoggerCore

/// The CoreAudio conformer for `SampleRateReconciler`'s device seam (#59): reads and
/// forces the default input device's nominal sample rate through `Microphone`. The
/// reconciliation decision it drives is unit-tested against a fake; this thin adapter is
/// the only part that touches hardware.
struct CoreAudioInputDevice: InputDeviceRate {
    var nominalSampleRate: Double? { Microphone.defaultInputSampleRate }

    func setNominalSampleRate(_ rate: Double) -> Double? {
        Microphone.forceDefaultInputSampleRate(rate)
    }
}
