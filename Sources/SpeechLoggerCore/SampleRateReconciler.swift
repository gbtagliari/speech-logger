import Foundation

/// The default input device's sample rate, read and forced. The concrete impl
/// (CoreAudio) lives in the app target; a fake drives the reconciliation decision in
/// tests without hardware.
///
/// `setNominalSampleRate` is the recovery #54 was missing. Under microphone contention
/// `AVAudioEngine` pins its input node to a 44.1 kHz fallback while the device runs at
/// another rate and then delivers zero frames, and neither an engine rebuild nor a full
/// process restart clears it — only forcing the device to re-publish its format does
/// (#59). Writing the nominal rate is that force.
public protocol InputDeviceRate: Sendable {
    /// The rate the device reports it is running, or nil when there is no device or it
    /// does not report one. The *device's* rate, not the engine's — the second opinion
    /// the engine's cached format is confronted with.
    var nominalSampleRate: Double? { get }

    /// Force the device's nominal sample rate, making it re-publish its format so a
    /// freshly built engine resolves its input node against a live rate instead of the
    /// cached fallback. Returns the rate the device reports *after* the write, or nil if
    /// the device would not accept it.
    func setNominalSampleRate(_ rate: Double) -> Double?
}

/// What reconciling the engine against the device came to.
public enum SampleRateReconciliation: Equatable, Sendable {
    /// The engine already agreed with the device, or the device rate is unknown: no
    /// force was attempted, and the caller records against the engine as it stands.
    case notNeeded
    /// The rates disagreed and the device accepted a force to this rate. The caller
    /// rebuilds the engine so its input node re-resolves against the re-published format.
    case forced(Double)
    /// The rates disagreed but the device would not accept the force. Carries the device
    /// rate anyway: the caller still re-points the AUHAL at the device and rebuilds — the
    /// recovery does not hinge on the write having taken — and needs the rate to check
    /// the result against. If it still disagrees, the fail-visible path (#54) takes over.
    case failed(Double)
}

/// Decides whether the audio engine's input rate disagrees with the device's actual
/// rate and, when it does, forces the device to re-publish so the two can agree (#59).
///
/// It carries no hardware knowledge of its own: given the rate the engine resolved to,
/// it reads the device's rate and either leaves things alone, forces the device, or
/// reports that the force was refused. The force is a real side effect — a device write
/// — but it, and the read-back that judges it, sit behind `InputDeviceRate`, so the
/// whole flow is driven by a fake in tests and only the CoreAudio conformer and the
/// engine rebuild it triggers need real hardware.
public struct SampleRateReconciler: Sendable {
    private let device: any InputDeviceRate
    /// How far the engine's rate may sit from the device's and still be believed. Both
    /// are doubles the drivers computed, so this is a float comparison, not a tolerance
    /// for genuinely different rates: the failure it catches is 44100 against 16000, not
    /// 48000.0 against 47999.9.
    private let tolerance: Double

    public init(device: any InputDeviceRate, tolerance: Double = 1) {
        self.device = device
        self.tolerance = tolerance
    }

    /// Confront `engineRate` — what `AVAudioEngine` resolved its input node to — with
    /// the device, and force the device to re-publish when they disagree.
    public func reconcile(engineRate: Double) -> SampleRateReconciliation {
        // No device rate to compare against is an unknown, and an unknown is believed:
        // the same rule the microphone check follows for a property it cannot read.
        guard let deviceRate = device.nominalSampleRate, deviceRate > 0 else {
            return .notNeeded
        }
        guard !agree(engineRate, deviceRate) else { return .notNeeded }

        // Force the device to the rate it is actually running, so a freshly built engine
        // resolves against a re-published format instead of the stale fallback. The
        // read-back is the truth, not the value we asked for: a device that reports back
        // a rate still at odds with itself has not been reconciled.
        guard let forced = device.setNominalSampleRate(deviceRate),
            agree(forced, deviceRate)
        else { return .failed(deviceRate) }
        return .forced(forced)
    }

    private func agree(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
