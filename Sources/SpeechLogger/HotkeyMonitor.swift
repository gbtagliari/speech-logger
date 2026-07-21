import AppKit
import SpeechLoggerCore

/// Installs the global `.flagsChanged` monitor and feeds events to a
/// `HotkeyDetector`, calling `onGesture` with whatever the grammar recognized —
/// a double-tap that starts a recording, or the gesture that ends one (ADR-0004,
/// #42). Matching `.flagsChanged` **only** — never `.keyDown` — is the privacy
/// bound: the app is structurally incapable of reading typed text, and it is also
/// what makes the push-to-talk hold free, since a release is a `flagsChanged` too.
///
/// The monitor is gated on `CGPreflightListenEventAccess()`; when denied it fails
/// silently (a non-nil monitor that never fires), so installing it would look
/// identical to "no key pressed yet". We therefore do not install it at all when
/// the permission is absent, and report that up so the UI can degrade.
@MainActor final class HotkeyMonitor {
    private var detector = HotkeyDetector()
    private var monitor: Any?
    private let onGesture: @MainActor (HotkeyGesture) -> Void
    /// Whether the mic is live, read fresh on every event: "recording wins the key"
    /// is decided against the recording that actually exists, not one the detector
    /// assumed started.
    private let isRecording: @MainActor () -> Bool

    init(
        isRecording: @escaping @MainActor () -> Bool,
        onGesture: @escaping @MainActor (HotkeyGesture) -> Void
    ) {
        self.isRecording = isRecording
        self.onGesture = onGesture
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
        let gesture = detector.handle(
            keyCode: Int64(event.keyCode),
            flags: UInt64(event.modifierFlags.rawValue),
            now: event.timestamp,
            isRecording: isRecording())
        if let gesture { onGesture(gesture) }
    }
}
