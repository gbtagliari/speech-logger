import Testing

@testable import SpeechLoggerCore

/// A fake input device: the rate it reports is set by the test, the force is recorded
/// and answered with a configurable read-back, so the whole reconciliation flow — the
/// decision, the force, and believing the read-back over the value asked for — is
/// exercised without hardware (#59).
private final class FakeInputDevice: InputDeviceRate, @unchecked Sendable {
    var reported: Double?
    /// What `setNominalSampleRate` reports back. Defaults to echoing the requested rate
    /// (a device that accepts the force); a test simulating a device that refuses sets
    /// it to something else or nil.
    var readBackAfterSet: ((Double) -> Double?)?
    private(set) var forcedTo: [Double] = []

    init(reported: Double?) { self.reported = reported }

    var nominalSampleRate: Double? { reported }

    func setNominalSampleRate(_ rate: Double) -> Double? {
        forcedTo.append(rate)
        // No closure set → the device accepts the force and echoes it. A closure is
        // believed even when it returns nil (a device that rejects the force outright),
        // so it must not collapse into the echo default.
        if let readBackAfterSet { return readBackAfterSet(rate) }
        return rate
    }
}

@Suite("Sample-rate reconciliation (#59)")
struct SampleRateReconcilerTests {
    @Test("Agreeing rates need no force")
    func agreeingRatesNeedNoForce() {
        let device = FakeInputDevice(reported: 48000)
        let reconciler = SampleRateReconciler(device: device)

        #expect(reconciler.reconcile(engineRate: 48000) == .notNeeded)
        #expect(device.forcedTo.isEmpty)
    }

    @Test("Rates within tolerance still agree")
    func ratesWithinToleranceAgree() {
        let device = FakeInputDevice(reported: 48000)
        let reconciler = SampleRateReconciler(device: device, tolerance: 1)

        #expect(reconciler.reconcile(engineRate: 47999.5) == .notNeeded)
        #expect(device.forcedTo.isEmpty)
    }

    @Test("An unknown device rate is believed, not forced")
    func unknownDeviceRateIsBelieved() {
        let device = FakeInputDevice(reported: nil)
        let reconciler = SampleRateReconciler(device: device)

        #expect(reconciler.reconcile(engineRate: 44100) == .notNeeded)
        #expect(device.forcedTo.isEmpty)
    }

    @Test("A non-positive device rate reads as unknown")
    func nonPositiveDeviceRateReadsAsUnknown() {
        let device = FakeInputDevice(reported: 0)
        let reconciler = SampleRateReconciler(device: device)

        #expect(reconciler.reconcile(engineRate: 44100) == .notNeeded)
        #expect(device.forcedTo.isEmpty)
    }

    @Test("The 44.1 kHz fallback against a 16 kHz device forces the device rate")
    func fallbackAgainstDeviceForcesTheDeviceRate() {
        // The live-captured failure (#59): engine pinned at 44100, device at 16000.
        let device = FakeInputDevice(reported: 16000)
        let reconciler = SampleRateReconciler(device: device)

        #expect(reconciler.reconcile(engineRate: 44100) == .forced(16000))
        #expect(device.forcedTo == [16000])
    }

    @Test("A device that reports back a rate still at odds is a failed force")
    func deviceThatWillNotTakeTheForceFails() {
        // The force is accepted at the API level but the read-back is still the stale
        // fallback: the device never reconciled, so this is not a recovery.
        let device = FakeInputDevice(reported: 16000)
        device.readBackAfterSet = { _ in 44100 }
        let reconciler = SampleRateReconciler(device: device)

        // `.failed` still carries the device rate, so the recorder can re-point the AUHAL
        // and check the result against it even when the write did not take.
        #expect(reconciler.reconcile(engineRate: 44100) == .failed(16000))
        #expect(device.forcedTo == [16000])
    }

    @Test("A device that rejects the force outright is a failed force")
    func deviceThatRejectsTheForceFails() {
        let device = FakeInputDevice(reported: 16000)
        device.readBackAfterSet = { _ in nil }
        let reconciler = SampleRateReconciler(device: device)

        #expect(reconciler.reconcile(engineRate: 44100) == .failed(16000))
    }
}
