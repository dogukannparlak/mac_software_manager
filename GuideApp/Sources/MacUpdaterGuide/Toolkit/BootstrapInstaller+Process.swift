import Foundation

/// The plumbing the setup sheet's installs run on: processes whose output
/// reaches the screen while they are still working.

extension BootstrapInstaller {

    // MARK: - Running a process with its output on screen

    /// Runs a command and reports every line it prints as it prints it,
    /// returning how it ended.
    ///
    /// `-1` means it never started or died on a signal, which the callers
    /// treat the same way as any other bad ending - what they need from this
    /// is "did it work", and the reason is already in the log by then.
    ///
    /// stdout and stderr share one pipe on purpose: the log in the sheet is
    /// meant to read like the terminal window this replaces, and two pipes
    /// drained separately interleave in whatever order the reader queues
    /// happen to fire.
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        emit: @escaping @Sendable (BootstrapEvent) -> Void
    ) async -> Int32 {
        let box = ProcessBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                let process = Process()
                process.executableURL = URL(filePath: executable)
                process.arguments = arguments
                // Nothing here is interactive; an inherited descriptor would
                // let a stray prompt block forever, and /dev/null turns that
                // into an immediate end of file instead.
                process.standardInput = FileHandle.nullDevice

                if !environment.isEmpty {
                    // Setting `environment` replaces the inherited one rather
                    // than merging into it, so it has to start from the real
                    // one or the child loses HOME, PATH and the rest.
                    process.environment = ProcessInfo.processInfo.environment
                        .merging(environment) { _, new in new }
                }

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                // Started before the process is: a 64 KB pipe nobody is
                // reading blocks the writer, and `brew install` prints past
                // that on a machine with work to do.
                let streamer = LineStreamer(reading: pipe) { line in
                    emit(.log(line))
                }

                process.terminationHandler = { finished in
                    streamer.waitForEnd()
                    let status = finished.terminationReason == .exit ? finished.terminationStatus : -1
                    continuation.resume(returning: status)
                }

                do {
                    try process.run()
                    box.adopt(process)
                } catch {
                    streamer.stop()
                    emit(.log(error.localizedDescription))
                    continuation.resume(returning: -1)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }

    /// Runs a command purely for what it prints, with nothing reaching the
    /// log - `shasum`, whose single line of output is an answer rather than
    /// progress, and putting it on screen would say nothing to anybody.
    static func capture(executable: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            let collected = TextBox()
            let streamer = LineStreamer(reading: pipe) { line in
                collected.append(line)
            }

            process.terminationHandler = { finished in
                streamer.waitForEnd()
                let succeeded = finished.terminationReason == .exit && finished.terminationStatus == 0
                continuation.resume(returning: succeeded ? collected.text() : nil)
            }

            do {
                try process.run()
            } catch {
                streamer.stop()
                continuation.resume(returning: nil)
            }
        }
    }
}

/// The lines `capture` collected, in something the reader queue and the
/// termination handler can both reach - a captured `var` across those two is
/// an error under the Swift 6 language mode, and a data race before that.
private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Somewhere for a cancellation handler to reach the process.
///
/// `withTaskCancellationHandler` can fire before the process exists, while it
/// is running, or after it has already exited, and its handler runs on
/// whichever thread cancelled - so the reference has to be shared, locked, and
/// safe to terminate through at any of those moments. A cancel that arrives
/// early is remembered rather than lost: the process is killed the instant it
/// is adopted, which is what stops a cancelled install from leaving `brew`
/// running with nobody watching it.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        let cancelledAlready = isCancelled
        self.process = process
        lock.unlock()
        if cancelledAlready { process.terminate() }
    }

    func terminate() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }
}

/// Reads a pipe *while the process is still writing to it* and hands over one
/// whole line at a time.
///
/// Deliberately not `StderrDrain`, which the update runs use: that keeps the
/// last 16 KB so a failure banner can quote how a run ended, and hands it over
/// once, afterwards. Here the output is the progress - a `brew install` that
/// prints nothing for thirty seconds looks identical to one that has hung -
/// so every line has to reach the screen at the moment it is written, and
/// nothing may be dropped from the middle of it.
///
/// The last chunk before end of file often has no trailing newline; it is
/// flushed as its own line rather than discarded, because that is where a
/// failing command's final word usually is.
final class LineStreamer: @unchecked Sendable {

    private let handle: FileHandle
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    private var partial = Data()
    private var isDone = false
    private let done = DispatchSemaphore(value: 0)

    init(reading pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
        self.handle = pipe.fileHandleForReading
        self.onLine = onLine

        handle.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            // Empty means every write end is closed: the process and anything
            // it spawned have finished printing.
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self.flushRemainder()
                self.markDone()
                return
            }
            self.consume(chunk)
        }
    }

    /// Waits for end of file, bounded.
    ///
    /// The last writes can still be in flight when the process exits, and end
    /// of file may genuinely never arrive - a grandchild that inherited the
    /// descriptor keeps the write end open after its parent is gone. A missing
    /// final line of log costs far less than a sheet that never finishes.
    func waitForEnd(timeout: TimeInterval = 2) {
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Gives up on a pipe nothing will ever write to or close - the process
    /// that failed to launch.
    func stop() {
        handle.readabilityHandler = nil
        markDone()
    }

    private func consume(_ chunk: Data) {
        var lines: [String] = []

        lock.lock()
        partial.append(chunk)
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            lines.append(Self.text(from: line))
        }
        lock.unlock()

        // Outside the lock: the handler runs on Foundation's reader queue and
        // hops to the main actor, and holding a lock across that is how a
        // reader queue stops reading.
        for line in lines { onLine(line) }
    }

    private func flushRemainder() {
        lock.lock()
        let remainder = partial
        partial = Data()
        lock.unlock()

        guard !remainder.isEmpty else { return }
        let line = Self.text(from: remainder)
        if !line.isEmpty { onLine(line) }
    }

    /// A carriage return with no newline is a progress bar redrawing itself in
    /// place (setup_mac.sh's scan does exactly this). Keeping only what
    /// follows the last one turns a line that would otherwise arrive as a
    /// hundred copies of itself into the one state it ended on.
    private static func text(from data: Data) -> String {
        let decoded = String(decoding: data, as: UTF8.self)
        let lastFrame = decoded.components(separatedBy: "\r").last ?? decoded
        return lastFrame.trimmingCharacters(in: .whitespaces)
    }

    private func markDone() {
        lock.lock()
        let wasDone = isDone
        isDone = true
        lock.unlock()
        // Signalled once only: a stray extra count would let a later wait
        // through before its own read had finished.
        if !wasDone { done.signal() }
    }
}
