import Foundation

/// The captured result of a finished subprocess: its termination status and the
/// bytes it wrote. `stdout` is empty when the caller discarded it.
struct SubprocessResult: Sendable {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

/// A subprocess that could not be launched (binary absent / not executable). The
/// only failure `runSubprocess` throws — a launched process that then exits
/// non-zero is a normal result the caller judges, not an error here.
struct SubprocessLaunchError: Error {
    let message: String
}

/// A thread-safe holder so a task-cancellation handler can terminate a running
/// `Process`. The launch and the cancellation race: whichever runs second still
/// terminates the process (the handler sets `cancelled`; `adopt` honours it, and
/// vice versa), so no cancel is ever lost between the two.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
        if cancelled, process.isRunning { process.terminate() }
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

/// Launch a binary by absolute path, await its exit, and return its status and
/// captured output. **If the surrounding task is cancelled the process is sent
/// SIGTERM** — this is the seam behind the manual "stop processing" control and the
/// graceful quit (ADR-0006, SPEC "Storage and the item state machine"): the lanes
/// run each item's shell-out in a task they can cancel, and cancelling it kills the
/// long-running `mlx_whisper`/`claude` rather than waiting out its ~179 s hang.
///
/// `stdout`/`stderr` are read once, after exit — the shell-out contracts keep both
/// well under the pipe buffer (claude's JSON is ~2 KB; mlx_whisper's stdout is
/// discarded and its stderr is a capped progress tail), so reading post-exit never
/// deadlocks. Throws `SubprocessLaunchError` only if the process cannot start.
func runSubprocess(
    executable: String,
    arguments: [String],
    environment: [String: String],
    stdin: Data? = nil,
    discardStdout: Bool = false
) async throws(SubprocessLaunchError) -> SubprocessResult {
    let handle = ProcessHandle()
    do {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SubprocessResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe = stdin != nil ? Pipe() : nil
            process.standardOutput = discardStdout ? FileHandle.nullDevice : stdoutPipe
            process.standardError = stderrPipe
            if let stdinPipe { process.standardInput = stdinPipe }

            process.terminationHandler = { finished in
                let out = discardStdout
                    ? Data()
                    : ((try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data())
                let err = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: SubprocessResult(
                    terminationStatus: finished.terminationStatus, stdout: out, stderr: err))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: SubprocessLaunchError(message: "\(error)"))
                return
            }
            // Now running: expose it to the cancellation handler. `adopt` terminates
            // immediately if a cancel already fired between `run` and here.
            handle.adopt(process)

            // Feed stdin (a few KB, under the pipe buffer, so this never blocks on the
            // reader) and close it, or the child waits forever on EOF.
            if let stdin, let stdinPipe {
                let writer = stdinPipe.fileHandleForWriting
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }
        } onCancel: {
            handle.terminate()
        }
    } catch let error as SubprocessLaunchError {
        throw error
    } catch {
        // Unreachable: the continuation only ever throws `SubprocessLaunchError`.
        // Present so the untyped continuation collapses back to the typed throw.
        throw SubprocessLaunchError(message: "\(error)")
    }
}
