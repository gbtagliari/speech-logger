import AppKit
import SpeechLoggerCore

/// Installs the global `.flagsChanged` monitor and feeds events to a
/// `HotkeyDetector`, calling `onToggle` on a recognized right-Option double-tap
/// (ADR-0004). Matching `.flagsChanged` **only** — never `.keyDown` — is the
/// privacy bound: the app is structurally incapable of reading typed text.
///
/// The monitor is gated on `CGPreflightListenEventAccess()`; when denied it fails
/// silently (a non-nil monitor that never fires), so installing it would look
/// identical to "no key pressed yet". We therefore do not install it at all when
/// the permission is absent, and report that up so the UI can degrade.
@MainActor final class HotkeyMonitor {
    private var detector = HotkeyDetector()
    private var monitor: Any?
    private let onToggle: @MainActor () -> Void

    init(onToggle: @escaping @MainActor () -> Void) {
        self.onToggle = onToggle
    }

    /// Install the monitor if Input Monitoring is granted. Returns whether it is
    /// now active. Idempotent: a second call while active is a no-op.
    @discardableResult
    func start() -> Bool {
        guard InputMonitoring.isGranted else { return false }
        guard monitor == nil else { return true }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            // Global monitors are delivered on the main thread.
            MainActor.assumeIsolated { self?.handle(event) }
        }
        return true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // `event.timestamp` is monotonic seconds since boot — the clock the detector
        // wants (never wall-clock, which jumps on NTP sync).
        let fired = detector.handle(
            keyCode: Int64(event.keyCode),
            flags: UInt64(event.modifierFlags.rawValue),
            now: event.timestamp)
        if fired { onToggle() }
    }
}
