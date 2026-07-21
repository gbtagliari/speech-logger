import Foundation
import SpeechLoggerCore

/// `DriftCheck` — the prompt-drift measurement for the acceptance set (issue #18).
///
/// This is a **tool, not a test**, and deliberately lives outside every test target:
/// it runs the real two-pass pipeline, so each sample makes two billed `claude` calls
/// and its verdict is nondeterministic by construction. Run it on purpose, after
/// touching a prompt or the pinned model.
///
/// It reports a *rate over N samples* rather than a single pass/fail. That distinction
/// is the whole point: a failure mode that fires ~45% of the time reads as "flaky" when
/// sampled once, and as a plain defect when sampled twenty times.
///
///     tuist run DriftCheck --samples 10
///     tuist run DriftCheck --samples 20 --case caso-01 --out /tmp/drift
///
/// Exit status is 0 when every case is clean, 1 when any case shows a violation, and
/// 2 when the toolchain gate is unmet — so it can gate a release check without ever
/// gating `tuist test`. Note `tuist run` reports any non-zero exit as a Tuist error;
/// to read the status cleanly, run the built binary from `Build/Products` directly.

// MARK: - Arguments

struct Options {
    var samples = 5
    var caseID: String?
    var outputDirectory: URL?
    /// Concurrent pipelines. Each is two sequential `claude` calls.
    var concurrency = 4
}

func parseOptions(_ argv: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < argv.count {
        let flag = argv[index]
        let value = index + 1 < argv.count ? argv[index + 1] : nil
        switch flag {
        case "--samples", "-n":
            options.samples = value.flatMap(Int.init) ?? options.samples
            index += 2
        case "--case":
            options.caseID = value
            index += 2
        case "--out":
            options.outputDirectory = value.map { URL(fileURLWithPath: $0) }
            index += 2
        case "--jobs":
            options.concurrency = value.flatMap(Int.init) ?? options.concurrency
            index += 2
        default:
            index += 1
        }
    }
    return options
}

// MARK: - Sampling

/// One sampled run of the pipeline, already judged.
struct Sample: Sendable {
    let caseID: String
    let index: Int
    let pass1: String
    let final: String
    let checks: [FidelityCheck]

    var violations: [FidelityCheck] { checks.filter { !$0.passed } }
    var isRed: Bool { !violations.isEmpty }
}

/// Run the real pipeline once and judge the result.
func sample(_ acceptanceCase: AcceptanceCase, index: Int) async -> Sample? {
    do {
        let organizer = try AcceptanceCases.organizer()
        let (pass1, final) = try await organizer.organize(acceptanceCase.transcript)
        return Sample(
            caseID: acceptanceCase.id, index: index, pass1: pass1, final: final,
            checks: FidelityJudge.judge(candidate: final, case: acceptanceCase))
    } catch {
        FileHandle.standardError.write(Data("  \(acceptanceCase.id)#\(index): ERROR \(error)\n".utf8))
        return nil
    }
}

/// Sample every case `count` times, at most `concurrency` pipelines in flight.
func collect(cases: [AcceptanceCase], count: Int, concurrency: Int) async -> [Sample] {
    let work = cases.flatMap { one in (0..<count).map { (one, $0) } }
    var collected: [Sample] = []

    await withTaskGroup(of: Sample?.self) { group in
        var next = 0
        for _ in 0..<min(concurrency, work.count) {
            let (one, index) = work[next]
            group.addTask { await sample(one, index: index) }
            next += 1
        }
        while let finished = await group.next() {
            if let finished {
                collected.append(finished)
                let mark = finished.isRed
                    ? "RED  " + finished.violations
                        .map { "\($0.name): \($0.violations.joined(separator: "; "))" }
                        .joined(separator: " | ")
                    : "green"
                print("  \(finished.caseID)#\(finished.index): \(mark)")
            }
            if next < work.count {
                let (one, index) = work[next]
                group.addTask { await sample(one, index: index) }
                next += 1
            }
        }
    }
    return collected
}

// MARK: - Reporting

let checkNames = ["idea count", "new-word diff", "modal check", "slip check"]

func report(_ samples: [Sample], cases: [AcceptanceCase]) {
    print("\n\("case".padding(toLength: 10, withPad: " ", startingAt: 0)) samples   red   " +
        checkNames.map { $0.padding(toLength: 14, withPad: " ", startingAt: 0) }.joined())

    for one in cases {
        let mine = samples.filter { $0.caseID == one.id }
        guard !mine.isEmpty else { continue }
        let red = mine.filter(\.isRed).count
        let perCheck = checkNames.map { name in
            let hits = mine.filter { $0.violations.contains { $0.name == name } }.count
            return "\(hits)".padding(toLength: 14, withPad: " ", startingAt: 0)
        }.joined()
        print("\(one.id.padding(toLength: 10, withPad: " ", startingAt: 0)) "
            + "\(mine.count)".padding(toLength: 9, withPad: " ", startingAt: 0)
            + "\(red)".padding(toLength: 6, withPad: " ", startingAt: 0) + perCheck)
    }

    let red = samples.filter(\.isRed).count
    let rate = samples.isEmpty ? 0 : Int((Double(red) / Double(samples.count) * 100).rounded())
    print("\noverall: \(red)/\(samples.count) red (\(rate)%)")
}

/// Persist every sample so a red one can be read rather than guessed at. The judge is
/// deterministic and offline, so saved candidates can be re-judged for free.
func save(_ samples: [Sample], to directory: URL) throws {
    for one in samples {
        let caseDirectory = directory.appendingPathComponent(one.caseID, isDirectory: true)
        try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        let stem = String(format: "%03d.%@", one.index, one.isRed ? "red" : "green")
        try one.pass1.write(
            to: caseDirectory.appendingPathComponent("\(stem).pass1.txt"), atomically: true, encoding: .utf8)
        try one.final.write(
            to: caseDirectory.appendingPathComponent("\(stem).final.txt"), atomically: true, encoding: .utf8)
    }
    print("samples written to \(directory.path)")
}

// MARK: - Entry point

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

if let reason = AcceptanceCases.unavailableReason {
    FileHandle.standardError.write(Data("drift check cannot run: \(reason)\n".utf8))
    exit(2)
}

let selected = AcceptanceCases.cases.filter { options.caseID == nil || $0.id == options.caseID }
guard !selected.isEmpty else {
    FileHandle.standardError.write(Data("no case matches \(options.caseID ?? "")\n".utf8))
    exit(2)
}

let calls = selected.count * options.samples * 2
print("drift check: \(selected.count) case(s) x \(options.samples) samples = \(calls) billed claude calls\n")

let samples = await collect(
    cases: selected, count: options.samples, concurrency: options.concurrency)
report(samples, cases: selected)

if let directory = options.outputDirectory {
    try save(samples, to: directory)
}

exit(samples.contains(where: \.isRed) ? 1 : 0)
