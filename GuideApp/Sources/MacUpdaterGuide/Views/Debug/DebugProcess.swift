import Foundation
import Observation

/// Running a command *and watching it print*, which is the one thing the
/// app's own runner deliberately cannot do.
///
/// `ToolkitController.run(script:arguments:)` sends stdout to
/// `FileHandle.nullDevice` on purpose - a bulk run prints megabytes nothing
/// in the app reads - and hands back a single `ProcessOutcome` once the
/// process has already exited. Both are exactly right for the app and
/// exactly wrong for this page, whose whole subject is the output as it
/// arrives. So this is a second, debug-only runner rather than a change to
/// the first: nothing in `Toolkit/` moves to make the Debug page possible.
///
/// English-only string literals - see the header of `DebugView.swift`.
@MainActor
@Observable
final class DebugProcessRunner {

    /// What a finished run left behind, kept so the panel can show the last
    /// result after the console has scrolled on.
    struct Outcome: Sendable {
        let exitCode: Int32
        let reason: Process.TerminationReason
        let duration: TimeInterval

        var succeeded: Bool { reason == .exit && exitCode == 0 }

        var summary: String {
            let seconds = String(format: "%.2fs", duration)
            if reason == .uncaughtSignal { return "killed by signal \(exitCode) after \(seconds)" }
            return "exit \(exitCode) in \(seconds)"
        }
    }

    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private(set) var lastOutcome: Outcome?
    /// What is on the command line right now, so the panel can say what the
    /// Stop button would stop.
    private(set) var runningDescription: String?

    private var process: Process?

    /// Launches `executable` and streams both pipes into `log` as they are
    /// written. Returns immediately; the run reports itself through the log.
    ///
    /// Single-flight: this page is for looking at one thing at a time, and
    /// two engine runs would interleave in the console with no way to tell
    /// whose line was whose.
    func run(executable: URL, arguments: [String], log: DebugLog) {
        guard !isRunning else {
            log.note("Already running - stop it first.")
            return
        }

        let description = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        let started = Date()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Handlers before `run()`, for the reason `StderrDrain` documents: a
        // process that fills a 64 KB pipe nobody is reading blocks inside
        // write() and never exits.
        stream(stdoutPipe, into: log, as: .stdout)
        stream(stderrPipe, into: log, as: .stderr)

        process.terminationHandler = { [weak self] finished in
            let outcome = Outcome(
                exitCode: finished.terminationStatus,
                reason: finished.terminationReason,
                duration: Date().timeIntervalSince(started)
            )
            Task { @MainActor in
                self?.finish(outcome, log: log)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            log.note("Could not launch: \(error.localizedDescription)")
            return
        }

        self.process = process
        isRunning = true
        startedAt = started
        runningDescription = description
        lastOutcome = nil
        log.note("$ \(description)")
    }

    /// SIGTERM to the script's direct children first and then to the script
    /// itself - the same two-step `ToolkitController.terminateWithChildren`
    /// uses, and for the same reason: killing the zsh process alone does not
    /// stop the brew/mas/curl it is sitting in front of. Duplicated rather
    /// than shared because that method is private to the controller, and
    /// this page exists to test the app, not to make the app grow API for
    /// it.
    func stop(log: DebugLog) {
        guard let process, process.isRunning else { return }
        log.note("Stopping…")

        let pkill = Process()
        pkill.executableURL = URL(filePath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()

        process.terminate()
    }

    private func finish(_ outcome: Outcome, log: DebugLog) {
        isRunning = false
        startedAt = nil
        runningDescription = nil
        lastOutcome = outcome
        process = nil
        log.note(outcome.summary)
    }

    /// Appends to the log until end of file, then lets go of the handle.
    private func stream(_ pipe: Pipe, into log: DebugLog, as stream: DebugLog.Stream) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // Empty means every write end is closed: the process and
            // anything it spawned are done printing.
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // `String(decoding:)` and not the failable `String(bytes:encoding:)`
            // SwiftLint prefers: a read can end in the middle of a multi-byte
            // character, and the failable initializer answers nil for the
            // whole chunk rather than replacing the one broken character.
            // Dropping a console line because a UTF-8 sequence straddled a
            // 64 KB boundary is the wrong trade for a live log.
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: chunk, as: UTF8.self)
            Task { @MainActor in
                log.append(text, stream: stream)
            }
        }
    }
}

/// One-shot capture of a short command's output - `brew --version` and its
/// like, for the Environment table.
///
/// Separate from `DebugProcessRunner` because the question is different:
/// nothing here is watched while it runs, there is nothing to stop, and the
/// caller wants a value rather than a scrollback.
enum DebugCommand {

    struct Result: Sendable {
        let output: String
        let exitCode: Int32
        let launched: Bool

        var succeeded: Bool { launched && exitCode == 0 }
    }

    /// Runs `executable` and returns everything it printed on either pipe.
    ///
    /// stdout and stderr are merged: a version probe that writes its answer
    /// to stderr (several do) still has an answer, and keeping them apart
    /// here would mean a blank row next to a working binary.
    static func capture(executable: URL, arguments: [String]) async -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            return Result(output: "", exitCode: -1, launched: false)
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let drain = OutputDrain(draining: pipe)

            process.terminationHandler = { finished in
                continuation.resume(returning: Result(
                    output: drain.text(),
                    exitCode: finished.terminationStatus,
                    launched: true
                ))
            }

            do {
                try process.run()
            } catch {
                drain.stopDraining()
                continuation.resume(returning: Result(output: error.localizedDescription, exitCode: -1, launched: false))
            }
        }
    }

    /// The first of `paths` that is executable.
    ///
    /// A GUI app inherits launchd's `PATH`, not the login shell's, so
    /// `/usr/bin/env brew` finds nothing however well Homebrew is set up -
    /// which is exactly the confusion this table exists to clear up. The
    /// candidates are Homebrew's two documented prefixes.
    static func locate(_ paths: [String]) -> URL? {
        paths.lazy
            .map { URL(filePath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }
}

/// Reads a pipe while the process is still writing to it, and keeps what it
/// read.
///
/// The same shape as `StderrDrain` (ToolkitRunner.swift) and for the same
/// reason - an unread 64 KB pipe deadlocks the writer - but that one is
/// private to its file and captures a single stream. This is not worth
/// exporting from `Toolkit/` for a debug page.
private final class OutputDrain: @unchecked Sendable {

    private let pipe: Pipe
    private let lock = NSLock()
    private var buffer = Data()
    private var isDone = false
    private let done = DispatchSemaphore(value: 0)

    init(draining pipe: Pipe) {
        self.pipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self.markDone()
                return
            }
            self.append(chunk)
        }
    }

    /// Bounded wait, like `StderrDrain.text()`: end of file may never come
    /// if a grandchild inherited the descriptor, and a missing last line
    /// costs far less than a hung page.
    func text(waitingUpTo timeout: TimeInterval = 2) -> String {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        // Lossy on purpose - see the note in `stream(_:into:as:)`.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stopDraining() {
        pipe.fileHandleForReading.readabilityHandler = nil
        markDone()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
    }

    private func markDone() {
        lock.lock()
        let wasDone = isDone
        isDone = true
        lock.unlock()
        if !wasDone { done.signal() }
    }
}
