import XCTest
@testable import MacUpdaterGuide

/// Cross-language format agreement for the engine's contract record
/// (CACHE_FORMAT.md, "Engine contract").
///
/// This file and tests/cache_format.bats assert against the exact same
/// canonical example line, so a change to the shell writer (`engine_write()`,
/// lib/cache.sh) or to this reader that drifts from the document fails a test
/// on whichever side is now wrong.
///
/// The incident behind the record: GuideApp was pointed at an engine that
/// predated `result_write`, asked it for a single-item result it could never
/// file, silently fell back to re-reading a cache that dead run had not
/// refreshed, and put "failed" on a `brew upgrade` the user had just watched
/// succeed. Nothing anywhere said the two halves disagreed.
final class EngineContractParsingTests: XCTestCase {

    /// The canonical example, used verbatim by both test suites.
    private static let canonical = "v1|1755400000|1|1.5.0"
    private static let canonicalDate = Date(timeIntervalSince1970: 1_755_400_000)

    // MARK: - Parsing

    func testParsesTheCanonicalExampleFromCacheFormatDoc() {
        let record = EngineContract.parse(raw: Self.canonical)
        XCTAssertEqual(record?.recordedAt, Self.canonicalDate)
        XCTAssertEqual(record?.contract, 1)
        XCTAssertEqual(record?.release, "1.5.0")
        XCTAssertEqual(record?.meetsRequirement, true)
    }

    func testFormatVersionMatchesTheOneThisSuitePinsTo() {
        // If the shell side bumps ENGINE_FORMAT_VERSION, this and
        // CACHE_FORMAT.md must be bumped in the same change - otherwise the
        // document describes a format nothing produces anymore.
        XCTAssertEqual(EngineContract.formatVersion, "v1")
    }

    func testTheRequiredContractIsTheOneTheShellSideDeclares() {
        // The mirror of ENGINE_CONTRACT in lib/cache.sh. Raising one without
        // the other means either an app asking for something no engine
        // writes, or an engine promising something no reader checks.
        XCTAssertEqual(EngineContract.required, 1)
    }

    func testTrailingNewlineIsNotPartOfTheRelease() {
        // The shell writes with `print -r --`, so every record on disk ends
        // in a newline.
        XCTAssertEqual(EngineContract.parse(raw: Self.canonical + "\n")?.release, "1.5.0")
    }

    func testAnEmptyReleaseStillParses() {
        // The release is a diagnostic, never part of the decision: an engine
        // whose version could not be read still has a contract to declare.
        let record = EngineContract.parse(raw: "v1|1755400000|1|")
        XCTAssertEqual(record?.contract, 1)
        XCTAssertEqual(record?.release, "")
    }

    // MARK: - Failing closed

    func testAnUnknownVersionIsRejectedRatherThanGuessedAt() {
        // A v2 record may mean anything; reading its third field as this
        // format's contract number is exactly the mistake the marker exists
        // to prevent.
        XCTAssertNil(EngineContract.parse(raw: "v2|1755400000|9|2.0.0"))
    }

    func testAVersionlessLineIsRejected() {
        XCTAssertNil(EngineContract.parse(raw: "1755400000|1|1.5.0"))
    }

    func testAShortLineIsRejected() {
        XCTAssertNil(EngineContract.parse(raw: "v1|1755400000|1"))
    }

    func testALongLineIsRejected() {
        // A field appended without a version bump is an incompatible change
        // the marker did not announce.
        XCTAssertNil(EngineContract.parse(raw: "v1|1755400000|1|1.5.0|extra"))
    }

    func testAnUndateableTimestampIsRejected() {
        // Without a usable timestamp there is no way to tell this record from
        // one an engine that is no longer installed left behind.
        XCTAssertNil(EngineContract.parse(raw: "v1|whenever|1|1.5.0"))
    }

    func testANonNumericContractIsRejected() {
        XCTAssertNil(EngineContract.parse(raw: "v1|1755400000|one|1.5.0"))
    }

    func testGarbageIsRejected() {
        XCTAssertNil(EngineContract.parse(raw: ""))
        XCTAssertNil(EngineContract.parse(raw: "not a record at all"))
    }

    // MARK: - What the contract number decides

    func testAnEngineDeclaringExactlyWhatIsNeededIsEnough() {
        let record = EngineContract(recordedAt: .now, contract: EngineContract.required, release: "1.5.0")
        XCTAssertTrue(record.meetsRequirement)
    }

    func testANewerEngineIsAlwaysEnough() {
        // Contracts are additive: a higher number writes everything a lower
        // one did. An app must never refuse an engine for being ahead of it.
        let record = EngineContract(recordedAt: .now, contract: EngineContract.required + 5, release: "2.0.0")
        XCTAssertTrue(record.meetsRequirement)
    }

    func testAnEngineBelowTheRequirementIsNotEnough() {
        let record = EngineContract(recordedAt: .now, contract: EngineContract.required - 1, release: "1.4.0")
        XCTAssertFalse(record.meetsRequirement)
    }

    // MARK: - Which run a record can answer for

    func testARecordWrittenAfterTheRunStartedAnswersForIt() {
        let started = Date()
        let record = EngineContract(recordedAt: started.addingTimeInterval(3), contract: 1, release: "1.5.0")
        XCTAssertTrue(record.covers(runStartedAt: started))
    }

    func testARecordASecondOldIsStillThisRunsBecauseTheStampIsWholeSeconds() {
        // Same slack, and the same reason for it, as
        // ItemRunResult.belongs(toRun:startedAt:): the shell stamps whole
        // seconds, the run's start date does not.
        let started = Date()
        let record = EngineContract(recordedAt: started.addingTimeInterval(-1), contract: 1, release: "1.5.0")
        XCTAssertTrue(record.covers(runStartedAt: started))
    }

    func testARecordFromBeforeTheRunDoesNotVouchForIt() {
        // The downgrade case: a new engine wrote this, someone put an old one
        // back, and the old one cannot rewrite it. Reading it as current
        // would have the app trusting an engine that is no longer installed -
        // the same shape as the incident that prompted all of this.
        let started = Date()
        let record = EngineContract(recordedAt: started.addingTimeInterval(-3600), contract: 1, release: "1.5.0")
        XCTAssertFalse(record.covers(runStartedAt: started))
    }

    // MARK: - What the user is told

    func testAnEngineThatSaidNothingIsExplainedInBothLanguages() {
        // The incident's own case: no record at all. Whatever else the banner
        // says, it may not be empty and it may not leak a placeholder.
        let reason = ToolkitController.ActionFailure.Reason.engineContract(found: nil)
        for language in AppLanguage.allCases {
            let text = reason.text(for: language)
            XCTAssertEqual(text, UIStrings.engineContractMissingDetail[language])
            XCTAssertFalse(text.isEmpty, "\(language) says nothing")
        }
    }

    func testAnOlderContractIsNamedInBothLanguages() {
        let reason = ToolkitController.ActionFailure.Reason.engineContract(found: 0)
        for language in AppLanguage.allCases {
            let text = reason.text(for: language)
            XCTAssertFalse(text.contains("%1$d"), "\(language) leaked its format placeholder")
            XCTAssertFalse(text.contains("%2$d"), "\(language) leaked its format placeholder")
            XCTAssertTrue(text.contains("v0"), "\(language) does not say what the engine declared")
            XCTAssertTrue(text.contains("v\(EngineContract.required)"),
                          "\(language) does not say what this app needs")
        }
    }

    func testTheTwoEngineMessagesAreNotTheSameSentence() {
        // "declared an older contract" and "declared nothing" are different
        // diagnoses and lead to the same fix by different routes; a reader
        // who reports one should not be shown the other.
        let missing = ToolkitController.ActionFailure.Reason.engineContract(found: nil)
        let old = ToolkitController.ActionFailure.Reason.engineContract(found: 0)
        for language in AppLanguage.allCases {
            XCTAssertNotEqual(missing.text(for: language), old.text(for: language))
        }
    }

    func testTheBannerTitleSaysTheEngineIsTheProblem() {
        let failure = ToolkitController.ActionFailure(
            action: .engineOutdated,
            subject: nil,
            reason: .engineContract(found: nil)
        )
        XCTAssertEqual(failure.title(for: .english), UIStrings.actionFailedEngineOutdated.en)
        for language in AppLanguage.allCases {
            XCTAssertFalse(failure.title(for: language).isEmpty)
            XCTAssertFalse(failure.title(for: language).contains("%@"))
        }
    }
}
