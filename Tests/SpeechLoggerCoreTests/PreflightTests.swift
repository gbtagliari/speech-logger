import Foundation
import Testing

@testable import SpeechLoggerCore

/// The launch-time gate (SPEC "First-run preflight"): four things checked, every
/// failure reported rather than fixed, and the one exception (the model download)
/// carrying a fix the user can click.
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

    private func report(_ world: World, inputMonitoringGranted: Bool = true) -> PreflightReport {
        Preflight.run(configuration: world.configuration, inputMonitoringGranted: inputMonitoringGranted)
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
        let report = Preflight.run(configuration: configuration, inputMonitoringGranted: false)
        #expect(report.failures.count == PreflightCheck.allCases.count)
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

    /// "The Whisper model download is the one thing preflight fixes"; everything else
    /// is check-and-report (a binary or a `claude login` is the user's terminal, not
    /// ours to run).
    @Test("only the model download and the permission pane carry a fix")
    func onlyTwoChecksAreFixable() {
        #expect(PreflightCheck.whisperModel.fix == .downloadWhisperModel)
        #expect(PreflightCheck.inputMonitoring.fix == .openInputMonitoringSettings)
        for check in [PreflightCheck.mlxWhisper, .ffmpeg, .claude, .claudeLogin] {
            #expect(check.fix == nil)
        }
    }

    @Test("every check has a title and a detail to show", arguments: PreflightCheck.allCases)
    func everyCheckIsPresentable(check: PreflightCheck) {
        #expect(!check.title.isEmpty)
        #expect(!check.detail.isEmpty)
    }
}
