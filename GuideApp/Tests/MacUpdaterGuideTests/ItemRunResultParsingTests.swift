@testable import MacUpdaterGuide
import XCTest

/// Cross-language format agreement for a single-item run's result record
/// (CACHE_FORMAT.md, "Single-item run results").
///
/// This file and tests/cache_format.bats assert against the exact same
/// canonical example line, so a change to the shell writer
/// (`result_write()`, lib/cache.sh) or to this reader that drifts from the
/// document fails a test on whichever side is now wrong.
final class ItemRunResultParsingTests: XCTestCase {

    /// The canonical example, used verbatim by both test suites.
    private static let canonical = "v1|1755400000|cask|alt-tab|AltTab|fail|still-outdated"

    // MARK: - Parsing

    func testParsesTheCanonicalExampleFromCacheFormatDoc() {
        let result = ItemRunResult.parse(raw: Self.canonical)
        XCTAssertEqual(result?.recordedAt, Date(timeIntervalSince1970: 1_755_400_000))
        XCTAssertEqual(result?.kind, "cask")
        XCTAssertEqual(result?.id, "alt-tab")
        XCTAssertEqual(result?.name, "AltTab")
        XCTAssertEqual(result?.status, .fail)
        XCTAssertEqual(result?.reason, .stillOutdated)
        XCTAssertEqual(result?.succeeded, false)
    }

    func testFormatVersionMatchesTheOneThisSuitePinsTo() {
        // If the shell side bumps RESULT_FORMAT_VERSION, this and
        // CACHE_FORMAT.md must be bumped in the same change - otherwise the
        // document describes a format nothing produces anymore.
        XCTAssertEqual(ItemRunResult.formatVersion, "v1")
    }

    func testASuccessfulRunHasNothingToExplain() {
        let result = ItemRunResult.parse(raw: "v1|1755400000|brew|awscli|awscli|ok|")
        XCTAssertEqual(result?.status, .ok)
        XCTAssertEqual(result?.reason, RunReason.none)
        XCTAssertEqual(result?.succeeded, true)
    }

    func testAMissingVersionIsRejected() {
        // Fails closed, the same as UpdateProgress: an unversioned line is a
        // format this build cannot vouch for, not a run to report an outcome
        // for.
        XCTAssertNil(ItemRunResult.parse(raw: "1755400000|cask|alt-tab|AltTab|fail|still-outdated"))
    }

    func testAnUnrecognizedVersionIsRejected() {
        XCTAssertNil(ItemRunResult.parse(raw: "v2|1755400000|cask|alt-tab|AltTab|fail|still-outdated"))
    }

    func testAnUnrecognizedStatusIsRejected() {
        // The whole point of the record is its verdict. A newer toolkit
        // adding a status token without bumping the version must not be read
        // as either outcome - reporting nothing is recoverable, reporting
        // the wrong thing is not.
        XCTAssertNil(ItemRunResult.parse(raw: "v1|1755400000|cask|alt-tab|AltTab|partial|"))
    }

    func testAShortLineIsRejected() {
        XCTAssertNil(ItemRunResult.parse(raw: "v1|1755400000|cask|alt-tab|fail"))
    }

    func testAnUnparseableTimestampIsRejected() {
        // The timestamp decides which run a record belongs to; a record that
        // cannot be dated cannot be attributed.
        XCTAssertNil(ItemRunResult.parse(raw: "v1|never|cask|alt-tab|AltTab|fail|still-outdated"))
    }

    func testAnUnknownReasonStillFailsTheItem() {
        // A reason is a label to print, not the verdict - so an unfamiliar
        // token from a newer toolkit falls back rather than voiding a record
        // that says plainly that the update did not happen.
        let result = ItemRunResult.parse(raw: "v1|1755400000|mas|497799835|Xcode|fail|sandbox-melted")
        XCTAssertEqual(result?.status, .fail)
        XCTAssertEqual(result?.reason, .unknown)
    }

    func testSurroundingWhitespaceIsTolerated() {
        XCTAssertEqual(ItemRunResult.parse(raw: Self.canonical + "\n"),
                       ItemRunResult.parse(raw: Self.canonical))
    }

    // MARK: - Which row a record belongs to

    func testHomebrewKindsMapToTheBrewItemID() {
        XCTAssertEqual(record(kind: "cask", id: "alt-tab").candidateItemIDs, ["brew:alt-tab"])
        XCTAssertEqual(record(kind: "brew", id: "awscli").candidateItemIDs, ["brew:awscli"])
    }

    func testMasKindMatchesBothAppStoreAndManualRows() {
        // One shell kind covers two sources: what `mas outdated` reports and
        // what the iTunes lookup found because mas missed it. Both are
        // updated by the same command with the same numeric id, so a record
        // has to be able to answer for either row.
        let result = record(kind: "mas", id: "497799835")
        XCTAssertTrue(result.matches(itemID: "mas:497799835"))
        XCTAssertTrue(result.matches(itemID: "manual:497799835"))
        XCTAssertFalse(result.matches(itemID: "brew:497799835"))
    }

    func testAppKindMatchesTheSelfUpdatingRow() {
        XCTAssertTrue(record(kind: "app", id: "AltTab").matches(itemID: "app:AltTab"))
    }

    func testAnUnknownKindMatchesNothing() {
        // Rather than attach a record to the wrong row: no match means the
        // caller falls back to its own check, which is the safe direction.
        XCTAssertEqual(record(kind: "flatpak", id: "alt-tab").candidateItemIDs, [])
        XCTAssertFalse(record(kind: "flatpak", id: "alt-tab").matches(itemID: "brew:alt-tab"))
    }

    // MARK: - Which run a record belongs to

    func testARecordFromBeforeTheRunStartedIsNotThisRunsOutcome() {
        // An earlier run of the same item that nobody consumed - one started
        // from a terminal window, one cancelled after it had already
        // reported - must not answer for the run asking now.
        let result = record(kind: "cask", id: "alt-tab", at: 1_755_400_000)
        let startedAt = Date(timeIntervalSince1970: 1_755_400_600)
        XCTAssertFalse(result.belongs(toRun: "brew:alt-tab", startedAt: startedAt))
    }

    func testARecordWrittenInTheSameSecondTheRunStartedStillCounts() {
        // The record's timestamp is whole seconds while the run's start date
        // is not, so an instant run can date its record one second "before"
        // the run that wrote it.
        let result = record(kind: "cask", id: "alt-tab", at: 1_755_400_000)
        let startedAt = Date(timeIntervalSince1970: 1_755_400_000.6)
        XCTAssertTrue(result.belongs(toRun: "brew:alt-tab", startedAt: startedAt))
    }

    func testARecordForAnotherItemNeverBelongsToThisRun() {
        let result = record(kind: "cask", id: "rectangle", at: 1_755_400_000)
        let startedAt = Date(timeIntervalSince1970: 1_755_399_000)
        XCTAssertFalse(result.belongs(toRun: "brew:alt-tab", startedAt: startedAt))
    }

    // MARK: - Wording

    func testEveryWordedReasonRendersInBothLanguages() {
        let worded: [RunReason] = [
            .stillOutdated, .timedOut, .masDisabled, .masMissing, .notPending,
            .notInstalled, .setappManaged, .noDirectDownload, .downloadFailed,
            .extractFailed, .verifyFailed, .replaceFailed
        ]
        for reason in worded {
            for language in AppLanguage.allCases {
                let text = reason.label?[language] ?? ""
                XCTAssertFalse(text.isEmpty, "\(reason) renders nothing in \(language)")
                XCTAssertFalse(text.contains(reason.rawValue), "\(language) shows the raw token for \(reason)")
            }
        }
    }

    func testTheReasonsWithNothingToAddCarryNoWording() {
        // Not an oversight: a successful run has nothing to explain, an
        // unknown token has no copy here, and "command-failed" says only
        // what its output already says in full.
        for reason in [RunReason.none, .unknown, .commandFailed] {
            XCTAssertNil(reason.label, "\(reason) should leave the printed output to speak for itself")
        }
    }

    // MARK: - Helpers

    private typealias RunReason = ItemRunResult.Reason

    private func record(kind: String, id: String, at epoch: TimeInterval = 1_755_400_000) -> ItemRunResult {
        ItemRunResult(
            recordedAt: Date(timeIntervalSince1970: epoch),
            kind: kind,
            id: id,
            name: id,
            status: .fail,
            reason: .stillOutdated
        )
    }

    // MARK: - Migration runs (kind "migrate")

    func testAMigrationRunIsKeyedOnTheCaskToken() {
        // `migrate_app` is invoked with the app name but files its result
        // under the token it was moving to, which is what the Move to Homebrew
        // page keys its row on.
        XCTAssertEqual(record(kind: "migrate", id: "alt-tab").candidateItemIDs, ["migrate:alt-tab"])
        XCTAssertTrue(record(kind: "migrate", id: "alt-tab").matches(itemID: "migrate:alt-tab"))
    }

    func testAMigrationRecordDoesNotMatchTheCaskUpdateRow() {
        // Same token, different thing: "brew:alt-tab" is the row for updating
        // an installed cask, "migrate:alt-tab" is the row for handing an
        // unmanaged app over to it. One record must never resolve the other.
        XCTAssertFalse(record(kind: "migrate", id: "alt-tab").matches(itemID: "brew:alt-tab"))
        XCTAssertFalse(record(kind: "cask", id: "alt-tab").matches(itemID: "migrate:alt-tab"))
    }

    func testEveryMigrationReasonResolvesAndIsWorded() {
        // The seven stable tokens lib/migrate.sh files (CACHE_FORMAT.md). A
        // token with no copy would fall back to showing raw shell output,
        // which for these is the one thing that does not explain them.
        let expected: [String: ItemRunResult.Reason] = [
            "cask-not-found": .caskNotFound,
            "no-app-artifact": .noAppArtifact,
            "needs-root": .needsRoot,
            "target-mismatch": .targetMismatch,
            "adopt-version-mismatch": .adoptVersionMismatch,
            "install-failed": .installFailed,
            "restored-after-failure": .restoredAfterFailure
        ]
        for (raw, reason) in expected {
            let line = "v1|1755400000|migrate|alt-tab|AltTab|fail|\(raw)"
            let parsed = ItemRunResult.parse(raw: line)
            XCTAssertEqual(parsed?.reason, reason, "reason \(raw)")
            XCTAssertNotNil(parsed?.reason.label, "reason \(raw) needs wording")
        }
    }

    func testAMigrationReasonFromANewerToolkitStillParses() {
        // A reason is a label, not a verdict: the record is still the run's
        // account of itself and the status is still readable.
        let parsed = ItemRunResult.parse(raw: "v1|1755400000|migrate|alt-tab|AltTab|fail|some-new-reason")
        XCTAssertEqual(parsed?.reason, .unknown)
        XCTAssertEqual(parsed?.status, .fail)
    }
}
