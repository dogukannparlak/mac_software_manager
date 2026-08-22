@testable import MacUpdaterGuide
import XCTest

/// Round-trip tests for `DebugFixtures`: everything the Debug page can write
/// has to be readable by the parser that will actually read it.
///
/// The point is narrow and worth stating. A fixture that the real parser
/// rejects is worse than no fixture at all - the Debug page would show an
/// empty screen and the person using it would go looking for the bug in the
/// app. So every generator here is fed straight into the production reader
/// for its format, and the assertions are about what came back out, never
/// about the string in between.
///
/// The generators are pure by design (no filesystem, no clock except where a
/// format carries a timestamp), which is what lets all of this run without
/// touching `~/Library/Application Support` at all.
final class DebugFixturesTests: XCTestCase {

    // MARK: - brew_outdated → UpdateSnapshot.homebrewItems

    func testBrewOutdatedFixtureParsesAsCasksAndFormulae() {
        let raw = DebugFixtures.brewOutdated(casks: 3, formulae: 2, style: .plain, includePinned: false)
        let items = UpdateSnapshot.homebrewItems(lines: lines(raw), ignoring: IgnoreList())

        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items.filter { $0.source == .cask }.count, 3)
        XCTAssertEqual(items.filter { $0.source == .formula }.count, 2)
    }

    func testBrewOutdatedFixtureCarriesBothVersionsAndAnIDPrefix() {
        let raw = DebugFixtures.brewOutdated(casks: 1, formulae: 0, style: .plain)
        let item = UpdateSnapshot.homebrewItems(lines: lines(raw), ignoring: IgnoreList()).first

        XCTAssertNotNil(item)
        XCTAssertTrue(item?.id.hasPrefix("brew:") == true)
        XCTAssertFalse(item?.currentVersion.isEmpty ?? true)
        XCTAssertFalse(item?.newVersion.isEmpty ?? true)
        XCTAssertNotEqual(item?.currentVersion, item?.newVersion)
    }

    /// The pinned row exists so the reader's own filter gets exercised - if
    /// this stops being dropped, the fixture has stopped testing anything.
    func testPinnedFormulaInTheFixtureIsDroppedByTheReader() {
        let raw = DebugFixtures.brewOutdated(casks: 0, formulae: 3, style: .plain, includePinned: true)
        XCTAssertEqual(lines(raw).count, 3)

        let items = UpdateSnapshot.homebrewItems(lines: lines(raw), ignoring: IgnoreList())
        XCTAssertEqual(items.count, 2)
    }

    func testEveryNameStyleStillProducesParseableBrewLines() {
        for style in DebugFixtures.NameStyle.allCases {
            let raw = DebugFixtures.brewOutdated(casks: 2, formulae: 2, style: style, includePinned: false)
            let items = UpdateSnapshot.homebrewItems(lines: lines(raw), ignoring: IgnoreList())
            XCTAssertEqual(items.count, 4, "style \(style.rawValue) produced unreadable lines")
        }
    }

    /// Every one of these formats is pipe-delimited and no field may contain
    /// a pipe; the engine strips them at each writer. A fixture that emitted
    /// one would generate a record the engine cannot produce.
    func testNoGeneratedNameContainsAPipe() {
        for style in DebugFixtures.NameStyle.allCases {
            for index in 0..<40 {
                XCTAssertFalse(DebugFixtures.name(index, style: style).contains("|"))
                XCTAssertFalse(DebugFixtures.token(index, style: style).contains("|"))
            }
        }
    }

    // MARK: - mas_outdated → UpdateSnapshot.appStoreItems

    func testMasOutdatedFixtureParsesWithBothVersions() {
        let raw = DebugFixtures.masOutdated(count: 4, style: .plain)
        let items = UpdateSnapshot.appStoreItems(lines: lines(raw), ignoring: IgnoreList())

        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first?.source, .appStore)
        XCTAssertNotEqual(items.first?.currentVersion, "?")
        XCTAssertNotEqual(items.first?.newVersion, "?")
    }

    func testMasOutdatedFixtureSurvivesUnicodeNames() {
        let raw = DebugFixtures.masOutdated(count: 3, style: .unicode)
        let items = UpdateSnapshot.appStoreItems(lines: lines(raw), ignoring: IgnoreList())

        XCTAssertEqual(items.count, 3)
        // The name is everything between the id and the version parenthesis;
        // an emoji in it must not swallow the version.
        XCTAssertNotEqual(items.first?.newVersion, "?")
    }

    // MARK: - manual_updates → UpdateSnapshot.manualItems

    func testManualUpdatesFixtureParses() {
        let raw = DebugFixtures.manualUpdates(count: 3, style: .plain)
        let items = UpdateSnapshot.manualItems(lines: lines(raw), ignoring: IgnoreList())

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first?.source, .manual)
        XCTAssertTrue(items.first?.id.hasPrefix("manual:") == true)
    }

    // MARK: - app_updates → UpdateSnapshot.selfUpdatingItems

    func testAppUpdatesFixtureAlternatesSparkleAndGitHub() {
        let raw = DebugFixtures.appUpdates(count: 4, style: .plain)
        let items = UpdateSnapshot.selfUpdatingItems(lines: lines(raw), ignoring: IgnoreList())

        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.filter { $0.source == .sparkle }.count, 2)
        XCTAssertEqual(items.filter { $0.source == .github }.count, 2)
    }

    /// The signature field is written empty, which puts a trailing separator
    /// on the line - the shape a `components(separatedBy:)` reader is most
    /// likely to get wrong.
    func testAppUpdatesFixtureKeepsTheTrailingEmptySignatureField() {
        let raw = DebugFixtures.appUpdates(count: 1, style: .plain)
        let line = lines(raw)[0]

        XCTAssertEqual(line.components(separatedBy: "|").count, 6)
        XCTAssertTrue(line.hasSuffix("|"))
        XCTAssertNotNil(UpdateSnapshot.selfUpdatingItems(lines: [line], ignoring: IgnoreList()).first?.link)
    }

    // MARK: - Empty entries

    func testZeroCountsProduceGenuinelyEmptyFiles() {
        XCTAssertTrue(DebugFixtures.brewOutdated(casks: 0, formulae: 0, style: .plain).isEmpty)
        XCTAssertTrue(DebugFixtures.masOutdated(count: 0, style: .plain).isEmpty)
        XCTAssertTrue(DebugFixtures.manualUpdates(count: 0, style: .plain).isEmpty)
        XCTAssertTrue(DebugFixtures.appUpdates(count: 0, style: .plain).isEmpty)
    }

    // MARK: - progress → UpdateProgress.parse

    func testProgressFixtureMatchesTheCanonicalLineFromCacheFormatDoc() {
        let raw = DebugFixtures.progress(state: "running", phase: "brew-upgrade", item: "awscli", index: 3, total: 8)
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), UpdateProgressParsingTests.canonicalLine)
    }

    func testProgressFixtureParsesForEveryPhaseTheShellCanWrite() {
        for phase in DebugProgressSimulator.phaseTokens {
            let raw = DebugFixtures.progress(state: "running", phase: phase, item: "alt-tab")
            let parsed = UpdateProgress.parse(raw: raw, modified: Date())

            XCTAssertNotNil(parsed, "phase \(phase) produced an unreadable line")
            XCTAssertNotEqual(parsed?.phase, .unknown, "phase \(phase) fell through to .unknown")
        }
    }

    func testProgressFixtureParsesForEveryState() {
        for state in DebugProgressSimulator.stateTokens {
            let parsed = UpdateProgress.parse(
                raw: DebugFixtures.progress(state: state, phase: "complete"),
                modified: Date()
            )
            XCTAssertEqual(parsed?.state.rawValue, state)
        }
    }

    func testProgressFixtureWritesAbsentCountsAsEmptyFields() {
        let raw = DebugFixtures.progress(state: "running", phase: "cleanup")
        // Six fields either way: an absent item, index and total are three
        // empty fields, not three fields left off the end.
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines), "v1|running|cleanup|||")

        let parsed = UpdateProgress.parse(raw: raw, modified: Date())
        XCTAssertNil(parsed?.index)
        XCTAssertNil(parsed?.total)
    }

    func testEverySimulatorFrameParses() {
        for script in DebugProgressSimulator.Script.allCases {
            for frame in script.frames {
                let parsed = UpdateProgress.parse(raw: frame.line, modified: Date())
                XCTAssertNotNil(parsed, "\(script.rawValue) frame \(frame.id) is unreadable")
                XCTAssertNotEqual(parsed?.phase, .unknown, "\(script.rawValue) frame \(frame.id) has an unknown phase")
            }
        }
    }

    /// The failure ending carries counts that mean failed/attempted, not
    /// progress - a script that got those the wrong way round would be
    /// testing the banner against a state the engine never writes.
    func testFailureScriptEndsOnCompleteWithFailuresCarryingCounts() {
        let last = DebugProgressSimulator.Script.runWithFailures.frames.last
        let parsed = last.flatMap { UpdateProgress.parse(raw: $0.line, modified: Date()) }

        XCTAssertEqual(parsed?.state, .failed)
        XCTAssertEqual(parsed?.phase, .completeWithFailures)
        XCTAssertEqual(parsed?.index, 2)
        XCTAssertEqual(parsed?.total, 4)
    }

    // MARK: - results → ItemRunResult.parse

    func testResultFixtureMatchesTheCanonicalLineFromCacheFormatDoc() {
        let raw = DebugFixtures.result(
            kind: "cask",
            id: "alt-tab",
            name: "AltTab",
            status: "fail",
            reason: "still-outdated",
            at: Date(timeIntervalSince1970: 1_755_400_000)
        )
        XCTAssertEqual(
            raw.trimmingCharacters(in: .whitespacesAndNewlines),
            "v1|1755400000|cask|alt-tab|AltTab|fail|still-outdated"
        )
    }

    func testResultFixtureParsesForEveryKind() {
        for kind in ["brew", "cask", "mas", "app", "migrate"] {
            let raw = DebugFixtures.result(kind: kind, id: "alt-tab", name: "AltTab", status: "ok", reason: "")
            let parsed = ItemRunResult.parse(raw: raw)

            XCTAssertEqual(parsed?.kind, kind)
            XCTAssertEqual(parsed?.status, .ok)
            XCTAssertFalse(parsed?.candidateItemIDs.isEmpty ?? true, "kind \(kind) mapped to no row")
        }
    }

    func testResultFixtureParsesEveryDocumentedFailureReason() {
        let reasons = [
            "still-outdated", "timeout", "command-failed", "mas-disabled", "mas-missing",
            "not-pending", "not-installed", "setapp-managed", "no-direct-download",
            "download-failed", "extract-failed", "verify-failed", "replace-failed",
            "cask-not-found", "no-app-artifact", "needs-root", "target-mismatch",
            "adopt-version-mismatch", "install-failed", "restored-after-failure"
        ]

        for reason in reasons {
            let raw = DebugFixtures.result(kind: "cask", id: "alt-tab", name: "AltTab", status: "fail", reason: reason)
            let parsed = ItemRunResult.parse(raw: raw)

            XCTAssertEqual(parsed?.status, .fail)
            XCTAssertEqual(parsed?.reason.rawValue, reason, "\(reason) fell back to .unknown")
        }
    }

    func testSuccessfulResultFixtureHasSevenFieldsWithAnEmptyReason() {
        let raw = DebugFixtures.result(kind: "brew", id: "ripgrep", name: "ripgrep", status: "ok", reason: "")
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")

        XCTAssertEqual(fields.count, 7)
        XCTAssertEqual(fields.last, "")
        XCTAssertEqual(ItemRunResult.parse(raw: raw)?.reason, ItemRunResult.Reason.none)
    }

    // MARK: - notifications → NotificationRequest.parse

    func testNotificationFixtureMatchesTheCanonicalLineFromCacheFormatDoc() {
        let raw = DebugFixtures.notification(
            title: DebugFixtures.notificationTitle,
            subtitle: "Update Complete",
            body: "3 package(s) updated successfully."
        )
        XCTAssertEqual(
            raw.trimmingCharacters(in: .whitespacesAndNewlines),
            NotificationRequestParsingTests.canonicalLine
        )
    }

    func testNotificationFixtureKeepsEmptyFieldsReadable() {
        let raw = DebugFixtures.notification(title: DebugFixtures.notificationTitle, subtitle: "", body: "")
        let parsed = NotificationRequest.parse(raw: raw)

        XCTAssertEqual(parsed?.title, DebugFixtures.notificationTitle)
        XCTAssertEqual(parsed?.subtitle, "")
        XCTAssertEqual(parsed?.body, "")
    }

    // MARK: - engine → EngineContract.parse

    func testEngineContractFixtureParsesAndDecidesTheSameWayTheReaderDoes() {
        let below = EngineContract.parse(raw: DebugFixtures.engineContract(contract: 0, release: "1.4.0"))
        XCTAssertEqual(below?.contract, 0)
        XCTAssertFalse(below?.meetsRequirement ?? true)
        XCTAssertFalse(below?.supportsMigration ?? true)

        let migration = EngineContract.parse(
            raw: DebugFixtures.engineContract(contract: EngineContract.migrationContract, release: "1.5.0")
        )
        XCTAssertTrue(migration?.meetsRequirement ?? false)
        XCTAssertTrue(migration?.supportsMigration ?? false)
    }

    // MARK: - Helpers

    /// The same split `UpdateSnapshot.contents(of:)` performs on a cache file
    /// before handing the lines to a parser.
    private func lines(_ raw: String) -> [String] {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
