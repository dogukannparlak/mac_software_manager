import XCTest
@testable import MacUpdaterGuide

/// Cross-language format agreement for the `migration_candidates` cache entry
/// (CACHE_FORMAT.md).
///
/// This file and `tests/migration.bats` assert against the exact same
/// canonical line - the shell suite produces it from the real writer
/// (`migration_scan`), this one parses it with the real reader. A change to
/// either side that the other does not match breaks a test on whichever side
/// is now stale, which is the whole point: neither half imports the other's
/// parser.
final class MigrationCandidateParsingTests: XCTestCase {

    /// The canonical example, used verbatim by both test suites.
    private static let canonical =
        "v1|AltTab|/Applications/AltTab.app|com.lwouis.alt-tab-macos|11.5.0|alt-tab|11.5.0|artifact|adoptable|https://alt-tab.app/"

    // MARK: - The canonical record

    func testParsesTheCanonicalExampleFromCacheFormatDoc() {
        let candidate = MigrationCandidate.parse(raw: Self.canonical)
        XCTAssertEqual(candidate?.appName, "AltTab")
        XCTAssertEqual(candidate?.appPath, "/Applications/AltTab.app")
        XCTAssertEqual(candidate?.bundleID, "com.lwouis.alt-tab-macos")
        XCTAssertEqual(candidate?.installedVersion, "11.5.0")
        XCTAssertEqual(candidate?.token, "alt-tab")
        XCTAssertEqual(candidate?.caskVersion, "11.5.0")
        XCTAssertEqual(candidate?.match, .artifact)
        XCTAssertEqual(candidate?.state, .adoptable)
        XCTAssertEqual(candidate?.homepage, "https://alt-tab.app/")
    }

    func testFormatVersionMatchesTheOneThisSuitePinsTo() {
        // If the shell side bumps MIGRATION_FORMAT_VERSION, this and
        // CACHE_FORMAT.md must be bumped in the same change - otherwise the
        // document describes a format nothing produces anymore.
        XCTAssertEqual(MigrationCandidate.formatVersion, "v1")
    }

    func testTheCanonicalLineHasTheDocumentedFieldCount() {
        XCTAssertEqual(
            Self.canonical.components(separatedBy: "|").count,
            MigrationCandidate.fieldCount
        )
    }

    func testTrailingNewlineIsNotPartOfTheLastField() {
        // The shell writes with `print`, so every line on disk ends in one.
        let candidate = MigrationCandidate.parse(raw: Self.canonical + "\n")
        XCTAssertEqual(candidate?.homepage, "https://alt-tab.app/")
    }

    func testTheAppNameIsTheIdentityBecauseItIsWhatMigrateAppTakes() {
        // `migrate_app <app_name> <token>` - the row is keyed on the app, not
        // on the cask it would become.
        XCTAssertEqual(MigrationCandidate.parse(raw: Self.canonical)?.id, "AltTab")
    }

    // MARK: - Failing closed

    func testAnUnrecognisedVersionIsRejected() {
        // Same rule as UpdateProgress and ItemRunResult: a format this build
        // does not know is "no usable record", never a partially-understood
        // one. A v2 line could mean anything in any position.
        let raw = Self.canonical.replacingOccurrences(of: "v1|", with: "v2|")
        XCTAssertNil(MigrationCandidate.parse(raw: raw))
    }

    func testAMissingVersionMarkerIsRejected() {
        let raw = String(Self.canonical.dropFirst(3))
        XCTAssertNil(MigrationCandidate.parse(raw: raw))
    }

    func testAShortLineIsRejected() {
        XCTAssertNil(MigrationCandidate.parse(raw: "v1|AltTab|/Applications/AltTab.app|artifact"))
    }

    func testALineWithAnExtraFieldIsRejected() {
        // Checked exactly rather than as a minimum: a longer line is a newer
        // format that happens to start with "v1", and reading the first ten
        // fields of it would be guessing at what the writer meant.
        XCTAssertNil(MigrationCandidate.parse(raw: Self.canonical + "|extra"))
    }

    func testAnEmptyLineIsRejected() {
        XCTAssertNil(MigrationCandidate.parse(raw: ""))
    }

    func testARecordWithNoAppNameIsRejected() {
        // The app name is what `migrate_app` is invoked with; a blank one is
        // not something any button could act on.
        let raw = Self.canonical.replacingOccurrences(of: "|AltTab|", with: "||")
        XCTAssertNil(MigrationCandidate.parse(raw: raw))
    }

    func testARecordWithNoTokenIsRejected() {
        let raw = Self.canonical.replacingOccurrences(of: "|alt-tab|", with: "||")
        XCTAssertNil(MigrationCandidate.parse(raw: raw))
    }

    // MARK: - match

    func testEveryDocumentedMatchResolves() {
        let expected: [String: MigrationCandidate.Match] = [
            "override": .override,
            "artifact": .artifact,
            "bundle": .bundle,
            "token": .token
        ]
        for (raw, match) in expected {
            let line = Self.canonical.replacingOccurrences(of: "|artifact|", with: "|\(raw)|")
            XCTAssertEqual(MigrationCandidate.parse(raw: line)?.match, match, "match \(raw)")
        }
    }

    func testAnUnknownMatchIsRejectedRatherThanGuessedAt() {
        // Deliberately unlike `state`. A match token this build does not know
        // says nothing about whether the pairing was verified, and both
        // guesses are wrong in a way the user pays for: "verified" offers an
        // unrelated cask with no warning, "unverified" second-guesses a
        // hand-written mapping.
        let line = Self.canonical.replacingOccurrences(of: "|artifact|", with: "|fingerprint|")
        XCTAssertNil(MigrationCandidate.parse(raw: line))
    }

    func testOnlyTheNameDerivedMatchIsUnverified() {
        // CACHE_FORMAT.md: the UI marks anything that is not evidence about
        // the application itself. `override` counts because a person wrote it.
        XCTAssertTrue(MigrationCandidate.Match.override.isVerified)
        XCTAssertTrue(MigrationCandidate.Match.artifact.isVerified)
        XCTAssertTrue(MigrationCandidate.Match.bundle.isVerified)
        XCTAssertFalse(MigrationCandidate.Match.token.isVerified)
    }

    // MARK: - state

    func testEveryDocumentedStateResolves() {
        let expected: [String: MigrationCandidate.State] = [
            "adoptable": .adoptable,
            "version-mismatch": .versionMismatch,
            "no-app-artifact": .noAppArtifact,
            "needs-root": .needsRoot,
            "target-mismatch": .targetMismatch,
            "deprecated": .deprecated
        ]
        for (raw, state) in expected {
            let line = Self.canonical.replacingOccurrences(of: "|adoptable|", with: "|\(raw)|")
            XCTAssertEqual(MigrationCandidate.parse(raw: line)?.state, state, "state \(raw)")
        }
    }

    func testAnUnknownStateFallsBackRatherThanLosingTheRecord() {
        // Unlike `match`: a state is a label plus which section the row files
        // under, and rejecting the record over it would hide an app the user
        // can see on disk. The record survives; the row just is not actionable.
        let line = Self.canonical.replacingOccurrences(of: "|adoptable|", with: "|some-new-state|")
        let candidate = MigrationCandidate.parse(raw: line)
        XCTAssertEqual(candidate?.state, .unknown)
        XCTAssertEqual(candidate?.appName, "AltTab")
    }

    func testAnUnknownStateIsNeverOfferedAsActionable() {
        // The rule CACHE_FORMAT.md states outright: an unknown value means the
        // record is from a newer engine and must be shown as not actionable,
        // never as `adoptable`.
        XCTAssertFalse(MigrationCandidate.State.unknown.isAdoptable)
        XCTAssertFalse(MigrationCandidate.State.unknown.needsConfirmation)
        XCTAssertTrue(MigrationCandidate.State.unknown.isBlocked)
    }

    func testTheThreeSectionsPartitionEveryState() {
        // The page draws exactly three lists off these, so every state has to
        // land in exactly one of them - a state in none of them disappears
        // from the page entirely.
        let all: [MigrationCandidate.State] = [
            .adoptable, .versionMismatch, .noAppArtifact,
            .needsRoot, .targetMismatch, .deprecated, .unknown
        ]
        for state in all {
            let sections = [state.isAdoptable, state.needsConfirmation, state.isBlocked]
            XCTAssertEqual(sections.filter { $0 }.count, 1, "\(state) should be in exactly one section")
        }
    }

    func testOnlyAdoptableIsActionableWithoutConfirmation() {
        XCTAssertTrue(MigrationCandidate.State.adoptable.isAdoptable)
        XCTAssertTrue(MigrationCandidate.State.versionMismatch.needsConfirmation)
        for state in [MigrationCandidate.State.noAppArtifact, .needsRoot, .targetMismatch, .deprecated] {
            XCTAssertTrue(state.isBlocked, "\(state) must not be offered as a move")
        }
    }

    // MARK: - Optional fields

    func testAnEmptyInstalledVersionIsAllowed() {
        // Real case: lghub's Info.plist has no CFBundleShortVersionString, and
        // the engine writes the field empty rather than inventing one.
        let line = "v1|lghub|/Applications/lghub.app|com.logi.ghub||logitech-g-hub|2026.5|override|no-app-artifact|https://www.logitechg.com/"
        let candidate = MigrationCandidate.parse(raw: line)
        XCTAssertEqual(candidate?.installedVersion, "")
        XCTAssertEqual(candidate?.match, .override)
        XCTAssertEqual(candidate?.state, .noAppArtifact)
    }

    func testANonHttpsHomepageProducesNoLink() {
        // The engine only writes https homepages, so anything else is a record
        // this build should not be turning into a clickable link.
        let line = Self.canonical.replacingOccurrences(
            of: "https://alt-tab.app/", with: "javascript:alert(1)"
        )
        XCTAssertNil(MigrationCandidate.parse(raw: line)?.homepageURL)
    }

    func testTheCaskPageLinkIsBuiltFromTheToken() {
        // The one thing an unverified row gives the user to check with.
        XCTAssertEqual(
            MigrationCandidate.parse(raw: Self.canonical)?.caskPageURL?.absoluteString,
            "https://formulae.brew.sh/cask/alt-tab"
        )
    }

    // MARK: - Whole payloads

    func testParseAllSkipsABadLineWithoutLosingTheGoodOnes() {
        // One unreadable line must not take the rest of the page with it: the
        // entry is a list of independent records, and an app the user can see
        // on disk should not vanish because a different app's line came from a
        // newer engine.
        let payload = [
            Self.canonical,
            "v2|FromTheFuture|/Applications/X.app|x|1|x|1|artifact|adoptable|",
            "v1|Rectangle|/Applications/Rectangle.app|com.knollsoft.Rectangle|0.75|rectangle|0.84|bundle|version-mismatch|https://rectangleapp.com/"
        ].joined(separator: "\n")

        let candidates = MigrationCandidate.parseAll(payload)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.appName), ["AltTab", "Rectangle"])
        XCTAssertEqual(candidates[1].state, .versionMismatch)
        XCTAssertEqual(candidates[1].match, .bundle)
    }

    func testParseAllIgnoresBlankLines() {
        // The writer ends the payload with a newline.
        XCTAssertEqual(MigrationCandidate.parseAll(Self.canonical + "\n").count, 1)
        XCTAssertEqual(MigrationCandidate.parseAll("").count, 0)
    }

    // MARK: - How the run reports back

    @MainActor
    func testAMigrationRunIsTrackedUnderTheCaskToken() {
        // `migrate_app` files its result with kind "migrate" and the cask
        // token as the id, so the row waiting on it has to be keyed the same
        // way - see ItemRunResult.candidateItemIDs.
        guard let candidate = MigrationCandidate.parse(raw: Self.canonical) else {
            return XCTFail("canonical line should parse")
        }
        let item = ToolkitController.migrationItem(for: candidate)
        XCTAssertEqual(item.id, "migrate:alt-tab")
        XCTAssertEqual(item.name, "AltTab")
    }

    @MainActor
    func testTheRowIdPrefixIsTheOneTheResultRecordResolvesTo() {
        // Three places have to agree on this string: the row id the page
        // tracks, the id `ItemRunResult` maps a "migrate" record onto, and the
        // prefix `recover(from:)` uses to tell a migration row from an update
        // row before it re-runs it in a terminal. Drift in any one of them
        // means a finished run never finds its row, or the recovery button
        // re-runs a migration as a package update.
        let record = ItemRunResult(
            recordedAt: Date(timeIntervalSince1970: 1_755_400_000),
            kind: "migrate",
            id: "alt-tab",
            name: "AltTab",
            status: .fail,
            reason: .installFailed
        )
        XCTAssertEqual(
            record.candidateItemIDs,
            [ToolkitController.migrationItemPrefix + "alt-tab"]
        )
    }
}
