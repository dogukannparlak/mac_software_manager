import Foundation

/// The phase logic behind `ToolkitController.startProgressWatch()`, kept as a
/// plain value type so a test can step it with an injected clock instead of
/// waiting on a live `Task` polling a real file.
///
/// A run does not begin writing to `cache/progress` the moment the app asks
/// for it. In terminal mode Terminal.app has to open first; either way
/// `acquire_lock` (update_system.1h.sh) can block for up to 20 seconds before
/// the script writes its first "running" line. So the watch runs in two
/// phases:
///
/// 1. *Startup* - poll until something of this run's own shows up, giving up
///    with an explicit failure once `startupTimeout` has passed. Counting
///    silence as "the run finished" here is what used to report a perfectly
///    healthy update as failed 2.8 seconds after the button was pressed, on
///    any machine with no `cache/progress` file yet to read.
/// 2. *Live* - the silence counter: once the run has been seen, that many
///    consecutive non-running polls mean it is over and its results can be
///    re-read.
struct ProgressWatch {

    /// What one poll means for the run as a whole.
    enum Step: Equatable {
        /// Startup phase: nothing of this run's is on disk yet. Keep polling,
        /// and show nothing but "starting" - whatever is in the file belongs
        /// to an earlier run.
        case awaitingStart
        /// This run wrote the entry being looked at. Show it, keep polling.
        case observed
        /// Seen running, then quiet long enough to be over. Re-read the
        /// results and stop.
        case finished
        /// The startup window elapsed with nothing of this run's ever
        /// appearing. Stop, and say so.
        case neverStarted
    }

    /// How often `ToolkitController` polls the progress file. Part of this
    /// type so the silence counter below can be read as a duration.
    static let pollInterval: Duration = .milliseconds(700)

    /// Consecutive non-running polls before a live run counts as over -
    /// roughly 2.8 seconds at `pollInterval`, enough for the script to finish
    /// writing its last line.
    static let quietTicksToFinish = 4

    /// How long the run gets to produce its first line before the watch calls
    /// it a failure to start. Generous on purpose: it has to cover opening a
    /// terminal window plus the 20-second `acquire_lock` wait, and the cost of
    /// being wrong here is a healthy run reported as failed.
    static let startupTimeout: TimeInterval = 90

    private let startedAt: Date
    private let startupTimeout: TimeInterval
    /// Set once anything this run wrote has been seen - the switch from the
    /// startup phase to the silence counter. One-way: a run that goes quiet
    /// afterwards is a finishing run, not one that never started.
    private var sawRun = false
    private var quietTicks = 0

    init(startedAt: Date, startupTimeout: TimeInterval = ProgressWatch.startupTimeout) {
        self.startedAt = startedAt
        self.startupTimeout = startupTimeout
    }

    /// Feeds one poll of the progress file in, with the time it happened.
    /// `latest` is `nil` when there is no readable progress file at all.
    mutating func step(latest: UpdateProgress?, now: Date) -> Step {
        if latest?.isRunning == true {
            sawRun = true
            quietTicks = 0
            return .observed
        }

        // A finished entry counts as this run's only if it was written after
        // the watch began; anything older is an earlier run's leftover, and
        // ending the startup phase on one would put that run's outcome on
        // this one. A short run that finishes between two polls, never seen
        // in the "running" state, does land here - and is a real ending.
        if !sawRun, let latest, latest.modified >= startedAt {
            sawRun = true
        }

        guard sawRun else {
            return now.timeIntervalSince(startedAt) >= startupTimeout ? .neverStarted : .awaitingStart
        }

        quietTicks += 1
        return quietTicks >= Self.quietTicksToFinish ? .finished : .observed
    }
}
