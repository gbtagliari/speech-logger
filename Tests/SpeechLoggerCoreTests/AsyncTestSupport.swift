import Foundation

/// Poll `condition` until it holds or the timeout elapses (then throw). Lets a test
/// wait for a lane to actually reach a state before acting on it, without a fixed
/// sleep. Shared by the lane and controller suites (the async equivalent of the
/// `SampleFixtures`/`AcceptanceFixtures` shared helpers).
func waitUntil(
    timeout: Double = 5,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    struct WaitTimeout: Error {}
    throw WaitTimeout()
}
