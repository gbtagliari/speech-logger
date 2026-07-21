import Foundation
import os

/// The calibration hook (#46): with `SPEECH_LOGGER_ENERGY_DUMP` set to a directory,
/// write a finished recording's window sequence there, one file per recording, so a
/// real recording can be read back and replayed as a test fixture. The guard's
/// thresholds are swept against measured audio rather than argued into place, and
/// this is what produces the numbers.
///
///     SPEECH_LOGGER_ENERGY_DUMP=/tmp/energy ./SpeechLogger.app/Contents/MacOS/SpeechLogger
///
/// A file and not a log line: a minute of speech is 3000 windows, and `os_log`
/// truncates a string argument long before that. It lives apart from `AudioRecorder`
/// so capture changes for one reason and diagnostics for another.
///
/// The write is synchronous on the caller (the main actor, at the end of a
/// recording). That is deliberate and bounded: the hook is off unless the env var is
/// set, and turning it on is a calibration session, not normal use.
struct EnergyDump {
    private let log = Logger(subsystem: "app.speech-logger", category: "energy-dump")
    private let directory: URL?

    /// Reads the environment once. Absent or empty var means the hook is off, and
    /// `write` becomes a no-op.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let path = environment["SPEECH_LOGGER_ENERGY_DUMP"]
        directory = (path?.isEmpty == false) ? URL(fileURLWithPath: path!, isDirectory: true) : nil
    }

    /// One newline-separated file of window energies, named by the wall clock so a
    /// calibration session's recordings stay in order.
    func write(_ energies: [Float], at now: Date = Date()) {
        guard let directory else { return }
        let url = directory.appendingPathComponent("energy-\(Int(now.timeIntervalSince1970 * 1000)).csv")
        let body = energies.map { String(format: "%.6f", $0) }.joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url, options: .atomic)
            log.notice("\(energies.count, privacy: .public) window(s) -> \(url.path, privacy: .public)")
        } catch {
            log.error("energy dump failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
