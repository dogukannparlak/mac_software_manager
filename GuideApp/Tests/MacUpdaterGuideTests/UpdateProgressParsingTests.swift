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

    func testUnknownStateFallsBackToDone() {
        let progress = UpdateProgress.parse(raw: "v1|bogus-state|complete", modified: Date())
        XCTAssertEqual(progress?.state, .done)
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
        let recent = now.addingTimeInterval(-60) // 1 minute ago, well under staleAfter
        let progress = UpdateProgress.parse(raw: "v1|running|analyze", modified: recent, now: now)
        XCTAssertEqual(progress?.state, .running)
    }

    func testStaleRunningStateIsPromotedToFailed() {
        // A run that died without writing a final state would otherwise leave
        // the UI claiming to be busy forever - this is the safety net.
        let now = Date()
        let stale = now.addingTimeInterval(-(UpdateProgress.staleAfter + 60))
        let progress = UpdateProgress.parse(raw: "v1|running|analyze", modified: stale, now: now)
        XCTAssertEqual(progress?.state, .failed)
    }

    func testStaleButNotRunningStateIsUnaffected() {
        // Staleness promotion only applies to "running" - a "done" or
        // "failed" entry from long ago must not be reinterpreted.
        let now = Date()
        let stale = now.addingTimeInterval(-(UpdateProgress.staleAfter + 60))
        let progress = UpdateProgress.parse(raw: "v1|done|complete", modified: stale, now: now)
        XCTAssertEqual(progress?.state, .done)
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
