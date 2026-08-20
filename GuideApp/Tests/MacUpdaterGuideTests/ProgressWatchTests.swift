import XCTest
@testable import MacUpdaterGuide

/// Phase logic of the progress watch (`ProgressWatch`), stepped against an
/// injected clock rather than a live poll loop - the decisions here are pure,
/// so no `Task`, no sleeping, and no `cache/progress` file are needed.
///
/// The bug these cover: the watch used to have one phase, the silence
/// counter, and it started counting the moment the run was *requested*. On a
/// machine with no `cache/progress` file to read yet, four silent polls
/// (2.8 seconds) passed long before Terminal.app had opened - so every
/// terminal-mode update was reported as failed while it was still starting.
final class ProgressWatchTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// The nth poll of the loop, at `ProgressWatch.pollInterval` apart.
    private func tick(_ n: Int) -> Date {
        start.addingTimeInterval(0.7 * Double(n))
    }

    private func entry(_ state: UpdateProgress.State,
                       _ phase: UpdateProgress.Phase,
                       writtenAt: Date) -> UpdateProgress {
        UpdateProgress(state: state, phase: phase, item: "", index: nil, total: nil, modified: writtenAt)
    }

    // MARK: - Startup phase

    func testSilenceBeforeTheRunStartsIsNotAFinishedRun() {
        var watch = ProgressWatch(startedAt: start)

        // Well past the four quiet polls that used to end the run, and still
        // inside the startup window: the script has not written anything yet
        // because the terminal window is still opening.
        for n in 1...30 {
            XCTAssertEqual(watch.step(latest: nil, now: tick(n)), .awaitingStart,
                           "poll \(n) (\(0.7 * Double(n))s in) must still be waiting for the run to start")
        }
    }

    func testAnEarlierRunsLeftoverEntryDoesNotEndTheStartupPhase() {
        var watch = ProgressWatch(startedAt: start)
        // Yesterday's "done|complete" is still sitting in cache/progress.
        let leftover = entry(.done, .complete, writtenAt: start.addingTimeInterval(-86_400))

        for n in 1...10 {
            XCTAssertEqual(watch.step(latest: leftover, now: tick(n)), .awaitingStart,
                           "poll \(n) read an earlier run's result as this run's")
        }

        // And the real run, once it finally writes, is picked up normally.
        XCTAssertEqual(watch.step(latest: entry(.running, .starting, writtenAt: tick(11)), now: tick(11)), .observed)
    }

    func testTheStartupWindowEndsWithAnExplicitFailure() {
        var watch = ProgressWatch(startedAt: start, startupTimeout: 90)

        XCTAssertEqual(watch.step(latest: nil, now: start.addingTimeInterval(89.9)), .awaitingStart)
        XCTAssertEqual(watch.step(latest: nil, now: start.addingTimeInterval(90)), .neverStarted)
    }

    func testAcquireLockCanBlockForTwentySecondsWithoutTrippingTheWatch() {
        // update_system.1h.sh waits up to 20s on acquire_lock before it writes
        // its first "running" line - the startup window has to outlast that.
        var watch = ProgressWatch(startedAt: start)

        XCTAssertEqual(watch.step(latest: nil, now: start.addingTimeInterval(20)), .awaitingStart)
        XCTAssertEqual(
            watch.step(latest: entry(.running, .starting, writtenAt: start.addingTimeInterval(20.5)),
                       now: start.addingTimeInterval(20.7)),
            .observed
        )
    }

    // MARK: - Live phase

    func testSilenceOnlyCountsOnceTheRunHasBeenSeen() {
        var watch = ProgressWatch(startedAt: start)
        let running = entry(.running, .brewUpgrade, writtenAt: tick(1))

        XCTAssertEqual(watch.step(latest: running, now: tick(1)), .observed)

        let done = entry(.done, .complete, writtenAt: tick(2))
        for n in 2...4 {
            XCTAssertEqual(watch.step(latest: done, now: tick(n)), .observed,
                           "quiet poll \(n - 1) of \(ProgressWatch.quietTicksToFinish) ended the run too early")
        }
        XCTAssertEqual(watch.step(latest: done, now: tick(5)), .finished)
    }

    func testAGapWhileRunningResetsTheSilenceCounter() {
        var watch = ProgressWatch(startedAt: start)

        XCTAssertEqual(watch.step(latest: entry(.running, .analyze, writtenAt: tick(1)), now: tick(1)), .observed)
        // Two polls that miss the file (it is replaced by a rename, so a read
        // can land between the unlink and the mv), then it is back.
        XCTAssertEqual(watch.step(latest: nil, now: tick(2)), .observed)
        XCTAssertEqual(watch.step(latest: nil, now: tick(3)), .observed)
        XCTAssertEqual(watch.step(latest: entry(.running, .brewUpgrade, writtenAt: tick(4)), now: tick(4)), .observed)

        // Counter is back to zero: three more quiet polls still are not enough.
        for n in 5...7 {
            XCTAssertEqual(watch.step(latest: nil, now: tick(n)), .observed, "poll \(n) ignored the reset")
        }
        XCTAssertEqual(watch.step(latest: nil, now: tick(8)), .finished)
    }

    func testARunThatFinishesBeforeItIsEverSeenRunningStillResolves() {
        // Short single-item runs can write "running" and their result between
        // two polls. The entry is this run's own (written after the watch
        // began), so it ends the run rather than the startup window doing it.
        var watch = ProgressWatch(startedAt: start)
        let done = entry(.done, .complete, writtenAt: tick(1))

        for n in 1...3 {
            XCTAssertEqual(watch.step(latest: done, now: tick(n)), .observed)
        }
        XCTAssertEqual(watch.step(latest: done, now: tick(4)), .finished)
    }

    func testAFailedEndingIsAnEndingNotAFailureToStart() {
        var watch = ProgressWatch(startedAt: start)
        let failed = entry(.failed, .completeWithFailures, writtenAt: tick(1))

        for n in 1...3 {
            XCTAssertEqual(watch.step(latest: failed, now: tick(n)), .observed)
        }
        XCTAssertEqual(watch.step(latest: failed, now: tick(4)), .finished)
    }
}
