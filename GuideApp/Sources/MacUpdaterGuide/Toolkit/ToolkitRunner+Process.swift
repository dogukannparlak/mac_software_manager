import Foundation

/// Spawning toolkit processes and reporting how they ended - the plumbing
/// every run in the other files goes through.
extension ToolkitController {

    // MARK: - Process helper

    /// What a toolkit process invocation actually did, instead of assuming it
    /// worked because it ran. A crash, a timeout, or any non-zero exit all
    /// count as failure here, whatever the shell script's own progress file
    /// (which a killed or crashed process never gets to update) says.
    ///
    /// Internal (not private) so ProcessOutcomeTests/ToolkitRunnerRunTests can
    /// construct and exercise it directly via '@testable import'.
    struct ProcessOutcome: Sendable {
        let exitCode: Int32
        let reason: Process.TerminationReason
        let stderr: String
        /// What the run printed on stdout, captured only where a caller asked
        /// for it (`startProcess(captureStandardOutput:)`).
        ///
        /// Normally nulled: a bulk run prints megabytes of brew output that
        /// nothing reads. The exception is an action whose whole answer is a
        /// line on stdout - `scan_migration` says "A cache refresh is already
        /// running." there and exits 1, and without this the app sees an
        /// exit code with no explanation and calls a busy lock a crash.
        /// Defaulted so every existing construction still compiles.
        var stdout: String = ""

        var succeeded: Bool { reason == .exit && exitCode == 0 }

        var summary: String {
            if !stderr.isEmpty { return stderr }
            if reason == .uncaughtSignal { return "Process terminated by signal \(exitCode)." }
            return "Process exited with status \(exitCode)."
        }
    }

    /// Records a failed *bulk* process invocation using the same state
    /// ProgressBanner already renders for a failed update, so a crash is
    /// exactly as visible as a script-reported failure - never a silent no-op.
    ///
    /// `endedTheWatchedRun` marks the one caller whose process *is* the run
    /// the progress watch is following: the watch is now waiting on something
    /// that can never write again, so it gets stopped here and its
    /// end-of-run work done in its place. Every other caller (a dry run, a
    /// launcher that never opened its terminal) must leave a watch that
    /// belongs to some other run running - its next poll puts the real state
    /// back on the banner by itself.
    ///
    /// `startedAt` is when this process was launched, and is what makes an
    /// entry in the progress file attributable to it. The launcher paths pass
    /// it because they have no progress watch of their own to date an entry
    /// against; `endedTheWatchedRun` uses the watch's own start instead.
    func reportFailure(_ outcome: ProcessOutcome,
                       startedAt: Date? = nil,
                       endedTheWatchedRun: Bool = false) {
        // Deliberately not routed through `report`/`lastFailure`: this writes
        // the failure into `progress` below, which ProgressBanner already
        // renders. Doing both would put the same error on screen twice.
        let processError = UpdateProgress(
            state: .failed, phase: .processError, item: outcome.summary, index: nil, total: nil
        )

        // The script may already have recorded a more precise ending than "the
        // process exited non-zero" - "3 of 8 failed", or a launcher naming the
        // Automation permission macOS refused. Prefer it, because the shell
        // writes a phase this app can word in the user's language while
        // `outcome.summary` is raw shell English. But only when *this* run
        // wrote it: an older entry describes some earlier run and must never
        // be shown as this one's outcome.
        let recordedSince = endedTheWatchedRun ? watchStartedAt : startedAt
        let ownEnding = recordedSince.flatMap { started -> UpdateProgress? in
            guard let latest = UpdateProgress.load(),
                  latest.state == .failed,
                  latest.modified >= started else { return nil }
            return latest
        }

        if endedTheWatchedRun {
            // Nothing more can reach the progress file now, so the watch must
            // not go on spending its startup window overwriting this failure -
            // and neither may a later re-read of the entry it left behind.
            stopProgressWatch()
            resolvedRunAt = Date()
            progress = ownEnding ?? processError
            // Whatever the run managed to do before dying still counts, and
            // the queue the watch would have drained on its way out is no
            // longer waiting on anything.
            snapshot = UpdateSnapshot.load()
            drainQueue()
        } else {
            progress = ownEnding ?? processError
        }

        // The process died outright - no need to wait for the progress watch
        // to go quiet, the row can flip to "failed" immediately. Only
        // relevant for a terminal-mode single-item run; the headless
        // concurrent path resolves through `finishActiveItem` instead.
        if let active = activeSingleItem {
            itemStatuses[active.id] = .failed
            endFractionSimulation(for: active.id)
            activeSingleItem = nil
            activeSingleItemStartedAt = nil
            scheduleStatusClear(for: active.id)
        }
    }

    /// Starts the one shared bulk-run process and tracks it in `bulkProcess`
    /// for `cancelUpdate()`, reporting a crash/non-zero exit through the same
    /// path a script-reported failure uses - unless we just cancelled it
    /// ourselves, in which case that state was already written.
    ///
    /// `onFinished` lets a caller do its own end-of-run work (re-reading a
    /// cache entry the run wrote, wording a failure of its own) without
    /// duplicating the cancel/failure handling above. It runs after that
    /// handling, and only when the run was not cancelled.
    func startBulkProcess(
        script: URL,
        arguments: [String],
        captureStandardOutput: Bool = false,
        onFinished: ((ProcessOutcome) -> Void)? = nil
    ) {
        bulkProcess = startProcess(
            script: script,
            arguments: arguments,
            captureStandardOutput: captureStandardOutput
        ) { [weak self] outcome in
            guard let self else { return }
            self.bulkProcess = nil
            guard !self.cancelledBulkRun else {
                self.cancelledBulkRun = false
                return
            }
            if let onFinished {
                onFinished(outcome)
            } else if !outcome.succeeded {
                self.reportFailure(outcome, endedTheWatchedRun: true)
            }
        }
    }

    /// For actions with no row or bulk state to update on completion (a dry
    /// run) - just report a crash if the process fails to launch or exits
    /// non-zero, the same as `startBulkProcess` without anywhere to stash
    /// the `Process` afterward.
    func runFireAndForget(script: URL, arguments: [String]) {
        _ = startProcess(
            script: script,
            arguments: arguments,
            extraEnvironment: ["GUIDEAPP_NO_SHARED_PROGRESS": "1"]
        ) { [weak self] outcome in
            if !outcome.succeeded { self?.reportFailure(outcome) }
        }
    }

    /// Starts a process and returns immediately, without waiting for it to
    /// exit - the process's own lifetime, not this call returning, is what
    /// tells the caller when the run is done. `onExit` runs on the main actor
    /// once it has terminated one way or another (including a launch failure,
    /// reported through the same `ProcessOutcome` shape).
    ///
    /// The caller decides what "done" means for it - a shared bulk slot, a
    /// per-item slot in `activeProcesses`, or nothing at all - this only
    /// owns the `Process`/`Pipe` plumbing common to all three.
    func startProcess(
        script: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        captureStandardOutput: Bool = false,
        onExit: @escaping (ProcessOutcome) -> Void
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [script.path(percentEncoded: false)] + arguments
        // Drained the same way stderr is, and for the same reason: an
        // unattended full pipe blocks the writer. See StderrDrain. Bound with
        // `let` because the termination handler below captures it, and a
        // captured `var` is an error under the Swift 6 language mode.
        let stdoutPipe: Pipe? = captureStandardOutput ? Pipe() : nil
        process.standardOutput = stdoutPipe ?? FileHandle.nullDevice
        let stdoutDrain = stdoutPipe.map { StderrDrain(draining: $0) }
        if !extraEnvironment.isEmpty {
            // Setting `environment` at all replaces the inherited one, not
            // merges with it - has to start from the real one (PATH, HOME,
            // ...) or the script cannot find `brew`/`mas`/etc.
            process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
        }
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // Started before the process is, so the pipe is never left full and
        // unattended - see StderrDrain for what happens when it is.
        let stderrDrain = StderrDrain(draining: stderrPipe)

        process.terminationHandler = { finished in
            let outcome = ProcessOutcome(
                exitCode: finished.terminationStatus,
                reason: finished.terminationReason,
                stderr: stderrDrain.text(),
                stdout: stdoutDrain?.text() ?? ""
            )
            Task { @MainActor in onExit(outcome) }
        }

        do {
            try process.run()
            return process
        } catch {
            // Nothing was ever spawned, so nothing will ever write to those
            // pipes or close them: stop reading rather than leave a reader
            // waiting on a process that does not exist.
            stderrDrain.stopDraining()
            stdoutDrain?.stopDraining()
            onExit(ProcessOutcome(exitCode: -1, reason: .uncaughtSignal, stderr: error.localizedDescription))
            return nil
        }
    }

    /// Internal (not private) so ToolkitRunnerRunTests can call it directly
    /// with a small fixture script, exercising the real Process/Pipe plumbing
    /// rather than just the ProcessOutcome decision logic.
    static func run(script: URL, arguments: [String]) async -> ProcessOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutcome, Never>) in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = [script.path(percentEncoded: false)] + arguments
            process.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            let stderrDrain = StderrDrain(draining: stderrPipe)

            process.terminationHandler = { finished in
                continuation.resume(returning: ProcessOutcome(
                    exitCode: finished.terminationStatus,
                    reason: finished.terminationReason,
                    stderr: stderrDrain.text()
                ))
            }

            do {
                try process.run()
            } catch {
                stderrDrain.stopDraining()
                continuation.resume(returning: ProcessOutcome(
                    exitCode: -1,
                    reason: .uncaughtSignal,
                    stderr: error.localizedDescription
                ))
            }
        }
    }
}

/// Reads a child process's stderr *while it is still running*, and keeps the
/// tail of what it read.
///
/// A pipe is a fixed-size buffer - 64 KB here. A process that writes past
/// that into a pipe nobody is reading blocks inside `write()` and stays
/// blocked: it never exits, so `terminationHandler` never runs, so a reader
/// that only starts there never starts at all. Each side ends up waiting for
/// the other, permanently, and the run hangs with no error and no exit.
/// `brew cleanup --prune=all` and `mas upgrade` (lib/run_modes.sh) are the
/// two calls whose stderr is not already redirected into `progress_tap`, and
/// on a machine with a lot to clean up or update either can print well past
/// 64 KB.
///
/// Only the last `limit` bytes survive. This text is shown in a failure
/// banner, where what matters is how the run ended - not every line it
/// printed on the way there - and an unbounded buffer would be one more way
/// for a chatty script to take the app down.
/// Internal rather than private to this file: `UninstallPlan` runs a process
/// of its own that has nothing to do with the progress banner, and a second
/// hand-rolled pipe drain is exactly the kind of thing that gets one of the
/// two bug fixes above and not the other.
final class StderrDrain: @unchecked Sendable {

    /// Far more than a failure needs to explain itself, and small enough to
    /// hand to a text view without a second thought.
    private static let limit = 16 * 1024

    /// Says so when the head was dropped, so a truncated tail is never read
    /// as the whole story.
    private static let truncationNotice = "[... earlier output dropped ...]\n"

    private let pipe: Pipe
    private let lock = NSLock()
    private var buffer = Data()
    private var droppedHead = false
    private var isDone = false
    private let done = DispatchSemaphore(value: 0)

    /// Begins draining `pipe` on the reader queue Foundation manages for it.
    /// Call this *before* launching the process: the point is that no write
    /// ever finds the pipe full with nobody reading.
    init(draining pipe: Pipe) {
        self.pipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            // Empty means end of file: every write end is closed, so the
            // process and anything it spawned are done printing.
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self.markDone()
                return
            }
            self.append(chunk)
        }
    }

    /// The stderr of a process that has exited, as far as it could be read.
    ///
    /// Waits for end of file first, because the last writes can still be in
    /// flight when the process dies. The wait is bounded: end of file may
    /// genuinely never come - a grandchild that inherited the descriptor
    /// keeps the write end open after its parent exits - and a missing last
    /// line of a log costs far less than another permanent hang.
    func text(waitingUpTo timeout: TimeInterval = 2) -> String {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard droppedHead, !text.isEmpty else { return text }
        return Self.truncationNotice + text
    }

    /// Gives up on the pipe - for the caller whose process never launched, so
    /// nothing will ever write to it or close it.
    func stopDraining() {
        pipe.fileHandleForReading.readabilityHandler = nil
        markDone()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > Self.limit {
            buffer.removeFirst(buffer.count - Self.limit)
            droppedHead = true
        }
    }

    private func markDone() {
        lock.lock()
        let wasDone = isDone
        isDone = true
        lock.unlock()
        // `signal()` once only: `text()` waits once, and a stray extra count
        // would let a later wait through before its own read had finished.
        if !wasDone { done.signal() }
    }
}
