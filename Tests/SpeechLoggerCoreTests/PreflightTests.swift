import Foundation
import Testing

@testable import SpeechLoggerCore

/// The launch-time gate: four things checked, every failure reported rather than
/// fixed, and the one exception (the model download) carrying a fix the user can click.
struct PreflightTests {
    /// A world where everything is satisfied: real files on disk for the three
    /// binaries and the credentials, and a hub holding the model's weights.
    private struct World {
        let root: URL
        let configuration: PreflightConfiguration

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("preflight-\(UUID().uuidString)", isDirectory: true)
            let bin = root.appendingPathComponent("bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for name in ["mlx_whisper", "ffmpeg", "claude"] {
                try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent(name))
            }

            let credentials = root.appendingPathComponent(".claude/.credentials.json")
            try FileManager.default.createDirectory(
                at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: credentials)

            let hub = root.appendingPathComponent("hub", isDirectory: true)
            try HubFixture.create(at: hub)

            configuration = PreflightConfiguration(
                paths: ToolchainPaths(
                    mlxWhisper: bin.appendingPathComponent("mlx_whisper").path,
                    ffmpeg: bin.appendingPathComponent("ffmpeg").path,
                    claude: bin.appendingPathComponent("claude").path),
                credentials: credentials,
                cache: WhisperModelCache(hub: hub))
        }

        func remove(_ relativePath: String) throws {
            try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func report(
        _ world: World,
        inputMonitoringGranted: Bool = true,
        accessibilityGranted: Bool = true,
        microphone: MicrophoneState = .usable
    ) -> PreflightReport {
        Preflight.run(
            configuration: world.configuration,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted,
            microphone: microphone)
    }

    // MARK: - The happy path

    @Test("everything present and granted satisfies preflight")
    func allSatisfied() throws {
        let world = try World()
        defer { world.tearDown() }
        let report = report(world)
        #expect(report.isSatisfied)
        #expect(report.failures.isEmpty)
        #expect(report.results.count == PreflightCheck.allCases.count)
    }

    // MARK: - Each check fails on its own

    @Test(
        "a missing binary fails its own check and nothing else",
        arguments: [
            ("bin/mlx_whisper", PreflightCheck.mlxWhisper),
            ("bin/ffmpeg", PreflightCheck.ffmpeg),
            ("bin/claude", PreflightCheck.claude),
        ])
    func missingBinaryFailsItsCheck(path: String, check: PreflightCheck) throws {
        let world = try World()
        defer { world.tearDown() }
        try world.remove(path)
        #expect(report(world).failures.map(\.check) == [check])
    }

    /// Login is the presence of the credentials file, never a `claude` call: the SPEC
    /// forbids burning one to answer a launch-time question.
    @Test("an absent credentials file fails the login check")
    func missingCredentialsFailsLogin() throws {
        let world = try World()
        defer { world.tearDown() }
        try world.remove(".claude/.credentials.json")
        #expect(report(world).failures.map(\.check) == [.claudeLogin])
    }

    @Test("an uncached model fails the model check")
    func uncachedModelFails() throws {
        let world = try World()
        defer { world.tearDown() }
        try world.remove("hub")
        #expect(report(world).failures.map(\.check) == [.whisperModel])
    }

    @Test("denied Input Monitoring fails its check")
    func deniedInputMonitoringFails() throws {
        let world = try World()
        defer { world.tearDown() }
        #expect(report(world, inputMonitoringGranted: false).failures.map(\.check) == [.inputMonitoring])
    }

    /// Injected the same way the Input Monitoring grant is, so the report stays a pure
    /// function of its configuration and the trust query is never called globally.
    @Test("a withheld Accessibility grant fails its check")
    func deniedAccessibilityFails() throws {
        let world = try World()
        defer { world.tearDown() }
        #expect(report(world, accessibilityGranted: false).failures.map(\.check) == [.accessibility])
    }

    /// The device query is injected as a value, the way the Input Monitoring grant is,
    /// so an unusable microphone is testable with no real microphone involved.
    @Test(
        "an unusable microphone fails its own check and nothing else",
        arguments: [
            (MicrophoneState.permissionDenied, PreflightCheck.microphonePermission),
            (.noDevice, .microphoneDevice),
            (.silenced, .microphoneLevel),
        ])
    func unusableMicrophoneFailsItsCheck(state: MicrophoneState, check: PreflightCheck) throws {
        let world = try World()
        defer { world.tearDown() }
        #expect(report(world, microphone: state).failures.map(\.check) == [check])
    }

    @Test("a usable microphone fails none of the three device checks")
    func usableMicrophoneFailsNothing() throws {
        let world = try World()
        defer { world.tearDown() }
        #expect(report(world, microphone: .usable).isSatisfied)
    }

    /// The three microphone rows read one query, so they can never contradict each
    /// other: the user is told *which* device problem they have, never several at once.
    @Test("at most one microphone check fails, whatever the device state",
          arguments: MicrophoneState.allCases)
    func microphoneChecksNeverCollide(state: MicrophoneState) throws {
        let world = try World()
        defer { world.tearDown() }
        let microphoneFailures = report(world, microphone: state).failures
            .filter { PreflightCheck.microphoneChecks.contains($0.check) }
        #expect(microphoneFailures.count == (state.isUsable ? 0 : 1))
    }

    /// Every check that *can* fail at once does. The three microphone rows are one
    /// query, so only the one matching the device state is among them.
    @Test("every check fails at once on a bare machine")
    func nothingInstalled() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let configuration = PreflightConfiguration(
            paths: ToolchainPaths(
                mlxWhisper: missing.appendingPathComponent("mlx_whisper").path,
                ffmpeg: missing.appendingPathComponent("ffmpeg").path,
                claude: missing.appendingPathComponent("claude").path),
            credentials: missing.appendingPathComponent(".credentials.json"),
            cache: WhisperModelCache(hub: missing))
        let report = Preflight.run(
            configuration: configuration, inputMonitoringGranted: false,
            accessibilityGranted: false, microphone: .noDevice)
        let expected = PreflightCheck.allCases.count - PreflightCheck.microphoneChecks.count + 1
        #expect(report.failures.count == expected)
        #expect(report.failures.map(\.check).contains(.microphoneDevice))
        #expect(!report.isSatisfied)
    }

    // MARK: - How failures surface

    /// Input Monitoring keeps its own glyph tier (it is the hotkey, and it has a
    /// one-click fix); every other prerequisite aggregates into the `failed` tier.
    @Test("a denied permission is a permission problem, not an aggregate failure")
    func permissionSurfacesOnItsOwnTier() throws {
        let world = try World()
        defer { world.tearDown() }
        let report = report(world, inputMonitoringGranted: false)
        #expect(report.needsPermission)
        #expect(!report.hasFailedPrerequisite)
    }

    /// A microphone problem is not the hotkey being deaf, so it does not take the lock
    /// tier: it aggregates into `failed` with every other missing prerequisite, and the
    /// banner is where it says which one.
    @Test("a microphone problem raises the aggregate failed tier, not the lock",
          arguments: [MicrophoneState.permissionDenied, .noDevice, .silenced])
    func microphoneSurfacesOnFailedTier(state: MicrophoneState) throws {
        let world = try World()
        defer { world.tearDown() }
        let report = report(world, microphone: state)
        #expect(report.hasFailedPrerequisite)
        #expect(!report.needsPermission)
    }

    /// Accessibility is not the hotkey going deaf — braindump is whole without it, and
    /// only the auto-paste is lost — so it takes no tier of its own. It aggregates with
    /// every other missing prerequisite, and the banner is where it says which one and
    /// what specifically stops working.
    @Test("a withheld Accessibility grant raises the aggregate failed tier, not the lock")
    func accessibilitySurfacesOnFailedTier() throws {
        let world = try World()
        defer { world.tearDown() }
        let report = report(world, accessibilityGranted: false)
        #expect(report.hasFailedPrerequisite)
        #expect(!report.needsPermission)
    }

    @Test("a missing prerequisite raises the aggregate failed tier, not the lock")
    func prerequisiteSurfacesOnFailedTier() throws {
        let world = try World()
        defer { world.tearDown() }
        try world.remove("bin/ffmpeg")
        let report = report(world)
        #expect(report.hasFailedPrerequisite)
        #expect(!report.needsPermission)
    }

    @Test("a satisfied report raises neither tier")
    func satisfiedRaisesNothing() throws {
        let world = try World()
        defer { world.tearDown() }
        let report = report(world)
        #expect(!report.hasFailedPrerequisite)
        #expect(!report.needsPermission)
    }

    // MARK: - The fixes

    /// "The Whisper model download is the one thing preflight fixes"; the rest of the
    /// fixes open the Settings pane that owns the problem. Everything else is
    /// check-and-report (a binary or a `claude login` is the user's terminal, not ours
    /// to run, and plugging in a microphone is not something a pane does either).
    @Test("only the model download and the Settings panes carry a fix")
    func onlyTheOwnedProblemsAreFixable() {
        #expect(PreflightCheck.whisperModel.fix == .downloadWhisperModel)
        #expect(PreflightCheck.inputMonitoring.fix == .openInputMonitoringSettings)
        #expect(PreflightCheck.accessibility.fix == .openAccessibilitySettings)
        #expect(PreflightCheck.microphonePermission.fix == .openMicrophoneSettings)
        #expect(PreflightCheck.microphoneLevel.fix == .openSoundSettings)
        for check in [PreflightCheck.mlxWhisper, .ffmpeg, .claude, .claudeLogin, .microphoneDevice] {
            #expect(check.fix == nil)
        }
    }

    /// The marriage between the device states and the panel's rows. Every unusable
    /// state must name a row, or a recording would be refused with nothing on screen
    /// to say why.
    @Test("every unusable device state names the row that reports it",
          arguments: MicrophoneState.allCases)
    func everyUnusableStateNamesARow(state: MicrophoneState) {
        if state.isUsable {
            #expect(state.failingCheck == nil)
        } else {
            #expect(state.failingCheck != nil)
            #expect(PreflightCheck.microphoneChecks.contains(state.failingCheck!))
        }
    }

    @Test("every check has a title and a detail to show", arguments: PreflightCheck.allCases)
    func everyCheckIsPresentable(check: PreflightCheck) {
        #expect(!check.title.isEmpty)
        #expect(!check.detail.isEmpty)
    }

    /// The banner must name the auto-paste specifically, never a generic "something is
    /// wrong" — which would be a lie, since braindump is entirely fine without the
    /// grant. Asserted on the copy itself because the copy *is* the requirement.
    @Test("the Accessibility row names the dictation paste, and says what still works")
    func accessibilityRowNamesTheAutoPaste() {
        let detail = PreflightCheck.accessibility.detail
        #expect(detail.contains("ditado"))
        #expect(detail.contains("cola"))
        #expect(detail.contains("clipboard"))
    }
}
