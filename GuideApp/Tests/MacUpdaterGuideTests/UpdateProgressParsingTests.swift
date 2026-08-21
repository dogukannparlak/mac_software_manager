import XCTest
@testable import MacUpdaterGuide

/// Parsing tests for `UpdateProgress.parse(raw:modified:now:)` - the cache
/// "v1|state|phase|item|index|total" format the shell engine writes and this
/// app reads on every menu-bar tick. See CACHE_FORMAT.md for the schema both
/// sides are required to agree on. Exercised directly against raw strings
/// (see the doc comment on `parse` for why it is split out from `load()`),
/// no filesystem involved.
final class UpdateProgressParsingTests: XCTestCase {

    /// The exact example from CACHE_FORMAT.md - `tests/cache_format.bats`
    /// asserts the shell's `progress_write` produces this same literal
    /// string, so this test and that one are the two halves of one
    /// producer/consumer agreement check.
    static let canonicalLine = "v1|running|brew-upgrade|awscli|3|8"

    func testParsesTheCanonicalExampleFromCacheFormatDoc() {
        let progress = UpdateProgress.parse(raw: Self.canonicalLine, modified: Date())
        XCTAssertEqual(progress?.state, .running)
        XCTAssertEqual(progress?.phase, .brewUpgrade)
        XCTAssertEqual(progress?.item, "awscli")
        XCTAssertEqual(progress?.index, 3)
        XCTAssertEqual(progress?.total, 8)
    }

    func testMinimalThreeFieldLineParses() {
        let progress = UpdateProgress.parse(raw: "v1|done|complete", modified: Date())
        XCTAssertEqual(progress?.state, .done)
        XCTAssertEqual(progress?.phase, .complete)
        XCTAssertEqual(progress?.item, "")
        XCTAssertNil(progress?.index)
        XCTAssertNil(progress?.total)
    }

    func testMissingVersionFieldFailsToParse() {
        // Pre-marker format (what every line looked like before this fix) -
        // must not be silently reinterpreted as state="v1".
        XCTAssertNil(UpdateProgress.parse(raw: "running|brew-upgrade|awscli|3|8", modified: Date()))
    }

    func testUnrecognizedVersionFailsToParse() {
        // A future incompatible format bump - fails closed rather than
        // parsing v2's fields as if they were v1's.
        XCTAssertNil(UpdateProgress.parse(raw: "v2|running|brew-upgrade|awscli|3|8", modified: Date()))
    }

    func testVersionOnlyLineFailsToParse() {
        XCTAssertNil(UpdateProgress.parse(raw: "v1", modified: Date()))
        XCTAssertNil(UpdateProgress.parse(raw: "v1|running", modified: Date()))
    }

    func testEmptyStringFailsToParse() {
        XCTAssertNil(UpdateProgress.parse(raw: "", modified: Date()))
    }

    func testUnknownStateFailsToParse() {
        // Not `.done`: an unreadable state must never come back as a
        // successful update.
        XCTAssertNil(UpdateProgress.parse(raw: "v1|bogus-state|complete", modified: Date()))
    }

    /// The gap the version marker alone does not cover: a newer toolkit that
    /// keeps writing v1 lines and adds a state token this build has never
    /// heard of. The version check passes, so the state field is the only
    /// thing standing between that line and a green tick on a run whose
    /// outcome is unknown.
    func testNewStateTokenWithinV1FailsToParse() {
        XCTAssertNil(UpdateProgress.parse(raw: "v1|paused|brew-upgrade|awscli|3|8", modified: Date()))
    }

    func testEmptyStateFieldFailsToParse() {
        XCTAssertNil(UpdateProgress.parse(raw: "v1||complete", modified: Date()))
    }

    func testUnknownPhaseFallsBackToUnknown() {
        let progress = UpdateProgress.parse(raw: "v1|running|some-new-phase-not-yet-known", modified: Date())
        XCTAssertEqual(progress?.phase, .unknown)
    }

    func testNonNumericIndexAndTotalBecomeNil() {
        let progress = UpdateProgress.parse(raw: "v1|running|analyze|item|not-a-number|also-not", modified: Date())
        XCTAssertNil(progress?.index)
        XCTAssertNil(progress?.total)
    }

    func testTrailingNewlineAndWhitespaceAreTrimmed() {
        let progress = UpdateProgress.parse(raw: "  v1|done|complete  \n", modified: Date())
        XCTAssertEqual(progress?.state, .done)
        XCTAssertEqual(progress?.phase, .complete)
    }

    func testFreshRunningStateStaysRunning() {
        let now = Date()
        let recent = now.addingTimeInterval(-60) // 1 minute ago, well under any window
        let progress = UpdateProgress.parse(raw: "v1|running|analyze", modified: recent, now: now)
        XCTAssertEqual(progress?.state, .running)
    }

    func testStaleRunningStateIsPromotedToFailed() {
        // A run that died without writing a final state would otherwise leave
        // the UI claiming to be busy forever - this is the safety net.
        let now = Date()
        let stale = now.addingTimeInterval(-(UpdateProgress.staleAfterQuick + 60))
        let progress = UpdateProgress.parse(raw: "v1|running|analyze", modified: stale, now: now)
        XCTAssertEqual(progress?.state, .failed)
    }

    func testStaleButNotRunningStateIsUnaffected() {
        // Staleness promotion only applies to "running" - a "done" or
        // "failed" entry from long ago must not be reinterpreted.
        let now = Date()
        let stale = now.addingTimeInterval(-(UpdateProgress.staleAfterLong + 60))
        let progress = UpdateProgress.parse(raw: "v1|done|complete", modified: stale, now: now)
        XCTAssertEqual(progress?.state, .done)
    }

    // MARK: - How long a quiet run gets before it counts as dead

    func testALongDownloadIsStillRunningPastTheQuickWindow() {
        // The bug this guards: one 15-minute window covered every phase, so
        // an App Store download - which writes nothing until it finishes, and
        // is allowed to run for MAS_UPGRADE_TIMEOUT (7200s) - was reported as
        // a failed update while it was still downloading. Worse than the
        // wrong banner: ToolkitController reads the same "not running" and
        // releases its per-item queue on top of the live run.
        let now = Date()
        let quiet = now.addingTimeInterval(-(UpdateProgress.staleAfterQuick + 60))
        for phase in ["mas-upgrade", "brew-upgrade", "install-app", "single"] {
            let progress = UpdateProgress.parse(raw: "v1|running|\(phase)", modified: quiet, now: now)
            XCTAssertEqual(progress?.state, .running, "\(phase) was declared dead at the quick window")
        }
    }

    func testALongDownloadDoesEventuallyGoStale() {
        // Generous is not forever: a heartbeat-era toolkit stops stamping the
        // file the moment its run dies, so nothing living ever reaches here.
        let now = Date()
        let ancient = now.addingTimeInterval(-(UpdateProgress.staleAfterLong + 60))
        let progress = UpdateProgress.parse(raw: "v1|running|mas-upgrade", modified: ancient, now: now)
        XCTAssertEqual(progress?.state, .failed)
    }

    func testBookkeepingPhasesGetTheQuickWindow() {
        // These write as they step through work, so silence is already odd.
        let now = Date()
        let quiet = now.addingTimeInterval(-(UpdateProgress.staleAfterQuick + 60))
        for phase in ["starting", "brew-update", "analyze", "cleanup", "verify"] {
            let progress = UpdateProgress.parse(raw: "v1|running|\(phase)", modified: quiet, now: now)
            XCTAssertEqual(progress?.state, .failed, "\(phase) should not get the long window")
        }
    }

    // The two migration phases (lib/migrate.sh, via the scan_migration and
    // migrate_app actions). CACHE_FORMAT.md:45 lists both in the recognised
    // set, so a build that fell through to `.unknown` for either would be
    // behind its own document - and would inherit the long staleness window
    // with it.
    func testScanMigrationPhaseParsesAndIsNamed() {
        let progress = UpdateProgress.parse(raw: "v1|running|scan-migration|||", modified: Date())
        XCTAssertEqual(progress?.phase, .scanMigration)
        XCTAssertEqual(progress?.title(for: .english), "Looking for apps Homebrew could manage")
        XCTAssertEqual(progress?.title(for: .turkish), "Homebrew'in yönetebileceği uygulamalar aranıyor")
    }

    func testMigratePhaseParsesAndNamesTheApp() {
        let progress = UpdateProgress.parse(raw: "v1|running|migrate|AltTab||", modified: Date())
        XCTAssertEqual(progress?.phase, .migrate)
        XCTAssertEqual(progress?.title(for: .english), "Moving to Homebrew")
        XCTAssertEqual(progress?.title(for: .turkish), "Homebrew'e taşınıyor")
        XCTAssertEqual(progress?.detail(for: .english), "AltTab")
    }

    // Both step through work and write as they go - the scan moves app to app,
    // a migration is one `brew install --cask --adopt` Homebrew reports on. A
    // dead run of either must be caught in the quick window: until these cases
    // existed both fell through to `.unknown` and took the 2h15m one, which
    // left a dead scan looking live for hours with `startOrQueue` holding
    // every queued row behind it.
    func testMigrationPhasesGetTheQuickStalenessWindow() {
        let now = Date()
        let quiet = now.addingTimeInterval(-(UpdateProgress.staleAfterQuick + 60))
        for phase in ["scan-migration", "migrate"] {
            let progress = UpdateProgress.parse(raw: "v1|running|\(phase)", modified: quiet, now: now)
            XCTAssertEqual(progress?.state, .failed, "\(phase) should not get the long window")
        }
    }

    func testAPhaseThisBuildDoesNotKnowGetsTheLongWindow() {
        // From a newer writer: there is nothing to base "should have written
        // by now" on, and calling a live run dead is the costlier mistake.
        let now = Date()
        let quiet = now.addingTimeInterval(-(UpdateProgress.staleAfterQuick + 60))
        let progress = UpdateProgress.parse(raw: "v1|running|some-new-phase", modified: quiet, now: now)
        XCTAssertEqual(progress?.phase, .unknown)
        XCTAssertEqual(progress?.state, .running)
    }

    func testAHeartbeatedEntryNeverGoesStale() {
        // What lib/cache.sh's stamper buys: the entry is touched every
        // PROGRESS_HEARTBEAT_INTERVAL seconds for as long as the run lives,
        // so however long the phase takes, its age stays at one interval.
        let now = Date()
        let justStamped = now.addingTimeInterval(-15)
        let progress = UpdateProgress.parse(raw: "v1|running|mas-upgrade", modified: justStamped, now: now)
        XCTAssertEqual(progress?.state, .running)
    }

    func testCompletionWithFailuresParsesItsCounts() {
        // What run_mode_system writes through progress_write_completion when
        // the verify pass found items still outdated: index = how many
        // failed, total = how many were attempted.
        let progress = UpdateProgress.parse(raw: "v1|failed|complete-with-failures||5|12", modified: Date())
        XCTAssertEqual(progress?.state, .failed)
        XCTAssertEqual(progress?.phase, .completeWithFailures)
        XCTAssertEqual(progress?.index, 5)
        XCTAssertEqual(progress?.total, 12)
    }

    func testCompletionWithFailuresDetailNamesTheFailureCount() {
        // "5 of 12" alone would read as progress through a batch - the point
        // of this phase is that the banner says what those numbers mean.
        let progress = UpdateProgress.parse(raw: "v1|failed|complete-with-failures||5|12", modified: Date())
        XCTAssertEqual(progress?.title(for: .english), "Finished with errors")
        XCTAssertEqual(progress?.detail(for: .english), "5 of 12 failed")
    }

    func testCompletionWithFailuresDetailFallsBackToTheCountAloneWithoutATotal() {
        let progress = UpdateProgress.parse(raw: "v1|failed|complete-with-failures||5|", modified: Date())
        XCTAssertEqual(progress?.detail(for: .english), "5 failed")
    }

    // The exact lines launch_in_terminal_or_report (lib/utils.sh) writes when
    // the terminal a run was supposed to happen in never opened - asserted
    // verbatim here and in tests/launch_in_terminal.bats, so a change to
    // either side that the other does not match breaks a test.
    func testTerminalPermissionPhaseParses() {
        let progress = UpdateProgress.parse(raw: "v1|failed|terminal-permission|Terminal||", modified: Date())
        XCTAssertEqual(progress?.state, .failed)
        XCTAssertEqual(progress?.phase, .terminalPermission)
        XCTAssertEqual(progress?.item, "Terminal")
    }

    func testTerminalPermissionDetailNamesWhereToGrantIt() {
        // The whole reason this phase exists rather than a raw stderr quote:
        // the one launch failure with a fix has to say what the fix is, in the
        // reader's language. The shell writes only the app name.
        let progress = UpdateProgress.parse(raw: "v1|failed|terminal-permission|iTerm2||", modified: Date())
        XCTAssertEqual(progress?.title(for: .english), "Terminal permission needed")
        XCTAssertEqual(
            progress?.detail(for: .english),
            "Allow iTerm2 under System Settings > Privacy & Security > Automation"
        )
        XCTAssertEqual(progress?.title(for: .turkish), "Terminal izni gerekli")
        XCTAssertEqual(
            progress?.detail(for: .turkish),
            "iTerm2 için Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon'dan izin verin"
        )
    }

    func testLaunchFailedPhaseParsesAndNamesTheTerminal() {
        let progress = UpdateProgress.parse(raw: "v1|failed|launch-failed|Ghostty||", modified: Date())
        XCTAssertEqual(progress?.state, .failed)
        XCTAssertEqual(progress?.phase, .launchFailed)
        XCTAssertEqual(progress?.title(for: .english), "Could not open the terminal")
        XCTAssertEqual(progress?.detail(for: .english), "Ghostty")
    }

    // A launch failure is not a phase that waits on a download - a reader must
    // not hold a run open for 2h15m over an entry saying nothing ever started.
    func testLaunchPhasesGetTheQuickStalenessWindow() {
        let now = Date()
        let quiet = now.addingTimeInterval(-(UpdateProgress.staleAfterQuick + 60))
        for phase in ["launch-failed", "terminal-permission"] {
            let progress = UpdateProgress.parse(raw: "v1|running|\(phase)", modified: quiet, now: now)
            XCTAssertEqual(progress?.state, .failed, "\(phase) should not get the long window")
        }
    }

    func testProcessErrorPhaseRoundTripsFromToolkitRunnersFailureState() {
        // ToolkitController writes exactly this shape (state=failed,
        // phase=process-error) when a process crashes/exits non-zero -
        // confirms the cache-file format and the in-memory failure state
        // agree on the same encoding.
        let progress = UpdateProgress.parse(raw: "v1|failed|process-error|Process exited with status 1.", modified: Date())
        XCTAssertEqual(progress?.state, .failed)
        XCTAssertEqual(progress?.phase, .processError)
        XCTAssertEqual(progress?.item, "Process exited with status 1.")
    }
}
