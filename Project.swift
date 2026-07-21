import ProjectDescription

// Single source of truth for the Xcode project. The generated `.xcodeproj` /
// `.xcworkspace` are disposable (gitignored); regenerate with `tuist generate`.

let bundleIdPrefix = "app.speech-logger"
let deploymentTargets: DeploymentTargets = .macOS("15.0")

// Signing (ADR-0005): a stable, self-signed identity keeps the app's designated
// requirement constant across rebuilds, so the Input Monitoring (TCC) grant
// survives. Create the identity with `scripts/create-signing-identity.sh`.
//
// These live on the app *target* base, not the project base: Tuist's recommended
// default settings inject `CODE_SIGN_IDENTITY = -` (ad-hoc) at the target level,
// which would shadow a project-level value and give the app a cdhash designated
// requirement that changes on every rebuild. The macosx-scoped key is set too
// because Xcode prefers the sdk-scoped variant when both are present.
//
// Sandbox is off (ADR-0002, via the entitlements file) and hardened runtime is
// off — this is a local, non-quarantined build, never notarized.
let appSigningSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": "speech-logger-selfsigned",
    "CODE_SIGN_IDENTITY[sdk=macosx*]": "speech-logger-selfsigned",
    "DEVELOPMENT_TEAM": "",
    "ENABLE_HARDENED_RUNTIME": "NO",
    // App icon: compiled from Resources/Assets.xcassets (AppIcon.appiconset).
    // The app is accessory (LSUIElement, no Dock icon), but the icon still shows
    // in Finder, the installer, and notifications.
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
]

let project = Project(
    name: "SpeechLogger",
    settings: .settings(base: ["SWIFT_VERSION": "6.0"]),
    targets: [
        .target(
            name: "SpeechLogger",
            destinations: .macOS,
            product: .app,
            bundleId: "\(bundleIdPrefix).SpeechLogger",
            deploymentTargets: deploymentTargets,
            infoPlist: .extendingDefault(with: [
                // Accessory app: no Dock icon, menubar only.
                "LSUIElement": true,
                "CFBundleName": "speech logger",
                "CFBundleDisplayName": "speech logger",
                // Required to record audio (AVAudioEngine triggers the mic TCC prompt).
                // Input Monitoring (the hotkey) has no usage-description key; it is
                // gated at runtime via CGPreflightListenEventAccess (ADR-0004).
                "NSMicrophoneUsageDescription":
                    "speech logger records your speech to transcribe it locally.",
            ]),
            sources: ["Sources/SpeechLogger/**"],
            // Asset catalog holding the app icon (AppIcon.appiconset).
            resources: ["Sources/SpeechLogger/Resources/**"],
            entitlements: .file(path: "Support/SpeechLogger.entitlements"),
            dependencies: [.target(name: "SpeechLoggerCore")],
            settings: .settings(base: appSigningSettings)
        ),
        .target(
            name: "SpeechLoggerCore",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "\(bundleIdPrefix).SpeechLoggerCore",
            deploymentTargets: deploymentTargets,
            sources: ["Sources/SpeechLoggerCore/**"],
            // The two organization prompts (ADR-0001), bundled so the shipped app
            // can load them at runtime via `Prompts.bundled()` (`Bundle.module`).
            // These are canonical. They started as copies of the bake-off prompts in
            // `.scratch/.../twopass/*.txt` and diverged from them in ADR-0008; that
            // directory is a frozen record of the bake-off, not a source to sync with.
            resources: ["Sources/SpeechLoggerCore/Resources/**"]
        ),
        .target(
            name: "SpeechLoggerCoreTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "\(bundleIdPrefix).SpeechLoggerCoreTests",
            deploymentTargets: deploymentTargets,
            sources: ["Tests/SpeechLoggerCoreTests/**"],
            dependencies: [.target(name: "SpeechLoggerCore")]
        ),
        // The prompt-drift measurement (issue #18). A command-line tool, *not* a test
        // target: it runs the real two-pass pipeline, so every sample makes billed
        // `claude` calls. Being an executable means `tuist test` cannot run it even by
        // accident, which is the point — the unit tests stay offline and free.
        // Run it deliberately: `tuist run DriftCheck --samples 10`.
        .target(
            name: "DriftCheck",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "\(bundleIdPrefix).DriftCheck",
            deploymentTargets: deploymentTargets,
            sources: [
                "Sources/DriftCheck/**",
                // The judge is the single source of truth for the fidelity contract.
                // It is compiled into both this tool and the test target (where
                // `FidelityJudgeTests` covers it offline) rather than duplicated.
                "Tests/SpeechLoggerCoreTests/FidelityJudge.swift",
            ],
            dependencies: [.target(name: "SpeechLoggerCore")]
        ),
    ],
    // Autogenerated schemes leave the test target unattached to any test action,
    // so `tuist test` finds nothing. This explicit scheme wires the unit tests in.
    schemes: [
        .scheme(
            name: "SpeechLoggerCoreTests",
            shared: true,
            buildAction: .buildAction(targets: ["SpeechLoggerCoreTests"]),
            testAction: .targets(["SpeechLoggerCoreTests"])
        )
    ]
)
