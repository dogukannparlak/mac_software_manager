import XCTest
@testable import MacUpdaterGuide

/// Parsing tests for the four cache formats `UpdateSnapshot` turns into the
/// main update list - `brew_outdated`, `mas_outdated`, `manual_updates`,
/// `app_updates` - plus the `ignored_apps.conf` filter applied to all of
/// them. See CACHE_FORMAT.md for the schemas the shell writer and this
/// reader are required to agree on. Exercised directly against in-memory
/// lines/text (see the doc comment on each `lines:`/`parse(text:)` entry
/// point for why it is split out from the disk-reading version), no
/// filesystem involved - the same reasoning UpdateProgressParsingTests uses.
final class UpdateSnapshotParsingTests: XCTestCase {

    // MARK: - homebrewItems (brew_outdated: src|token|installed|current|pinned)

    static let canonicalCaskLine = "cask|alt-tab|11.4.3|11.4.4|0"

    func testParsesTheCanonicalCaskExampleFromCacheFormatDoc() {
        let items = UpdateSnapshot.homebrewItems(lines: [Self.canonicalCaskLine], ignoring: IgnoreList())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.source, .cask)
        XCTAssertEqual(items.first?.id, "brew:alt-tab")
        XCTAssertEqual(items.first?.currentVersion, "11.4.3")
        XCTAssertEqual(items.first?.newVersion, "11.4.4")
        XCTAssertEqual(items.first?.link?.absoluteString, "https://formulae.brew.sh/cask/alt-tab")
    }

    func testFormulaLineIsDistinguishedFromCask() {
        let items = UpdateSnapshot.homebrewItems(lines: ["formula|awscli|2.1|2.2|0"], ignoring: IgnoreList())
        XCTAssertEqual(items.first?.source, .formula)
        XCTAssertEqual(items.first?.link?.absoluteString, "https://formulae.brew.sh/formula/awscli")
    }

    func testPinnedPackageIsExcluded() {
        // Field 5 ("pinned") = "1" - a pinned package is deliberately held
        // back and must not show up as needing an update.
        let items = UpdateSnapshot.homebrewItems(lines: ["formula|awscli|2.1|2.2|1"], ignoring: IgnoreList())
        XCTAssertTrue(items.isEmpty)
    }

    func testIgnoredCaskIsExcluded() {
        let ignored = IgnoreList.parse(text: "cask|alt-tab|AltTab\n")
        let items = UpdateSnapshot.homebrewItems(lines: [Self.canonicalCaskLine], ignoring: ignored)
        XCTAssertTrue(items.isEmpty)
    }

    func testIgnoredFormulaTokenDoesNotAccidentallyMatchACaskWithTheSameToken() {
        // The ignore check for Homebrew items only looks at cask ignores
        // (`ignored.contains(type: "cask", ...)`) - a formula ignore entry
        // must not suppress a cask with the same token, or vice versa.
        let ignored = IgnoreList.parse(text: "formula|alt-tab|AltTab\n")
        let items = UpdateSnapshot.homebrewItems(lines: [Self.canonicalCaskLine], ignoring: ignored)
        XCTAssertEqual(items.count, 1)
    }

    func testTooFewFieldsIsSkipped() {
        let items = UpdateSnapshot.homebrewItems(lines: ["cask|alt-tab|11.4.3"], ignoring: IgnoreList())
        XCTAssertTrue(items.isEmpty)
    }

    func testMalformedLinesAreSkippedButValidOnesStillParse() {
        let items = UpdateSnapshot.homebrewItems(
            lines: ["not-enough-fields", Self.canonicalCaskLine],
            ignoring: IgnoreList()
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "alt-tab")
    }

    // MARK: - appStoreItems (raw `mas outdated`: "123456 App Name (1.0 -> 1.1)")

    func testParsesAStandardMasOutdatedLine() {
        let items = UpdateSnapshot.appStoreItems(
            lines: ["361285480 Keynote (13.2 -> 13.3)"],
            ignoring: IgnoreList()
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "mas:361285480")
        XCTAssertEqual(items.first?.name, "Keynote")
        XCTAssertEqual(items.first?.currentVersion, "13.2")
        XCTAssertEqual(items.first?.newVersion, "13.3")
        XCTAssertEqual(items.first?.link?.absoluteString, "https://apps.apple.com/app/id361285480")
    }

    func testAppNameContainingParenthesesStillParsesCorrectly() {
        // The version pair is read from the *last* "(...)" group specifically
        // so a name like "Things 3 (for Mac)" does not get misread as the
        // version field.
        let items = UpdateSnapshot.appStoreItems(
            lines: ["12345 Things 3 (for Mac) (3.1 -> 3.2)"],
            ignoring: IgnoreList()
        )
        XCTAssertEqual(items.first?.name, "Things 3 (for Mac)")
        XCTAssertEqual(items.first?.currentVersion, "3.1")
        XCTAssertEqual(items.first?.newVersion, "3.2")
    }

    func testSingleVersionInParenthesesBecomesTheNewVersionOnly() {
        let items = UpdateSnapshot.appStoreItems(lines: ["12345 SomeApp (2.0)"], ignoring: IgnoreList())
        XCTAssertEqual(items.first?.currentVersion, "?")
        XCTAssertEqual(items.first?.newVersion, "2.0")
    }

    func testMissingParenthesesFallsBackToUnknownVersions() {
        let items = UpdateSnapshot.appStoreItems(lines: ["12345 SomeApp"], ignoring: IgnoreList())
        XCTAssertEqual(items.first?.name, "SomeApp")
        XCTAssertEqual(items.first?.currentVersion, "?")
        XCTAssertEqual(items.first?.newVersion, "?")
    }

    func testNonNumericLeadingTokenIsSkipped() {
        let items = UpdateSnapshot.appStoreItems(lines: ["not-an-id SomeApp (1.0 -> 1.1)"], ignoring: IgnoreList())
        XCTAssertTrue(items.isEmpty)
    }

    func testIgnoredAppStoreIdIsExcluded() {
        let ignored = IgnoreList.parse(text: "mas|361285480|Keynote\n")
        let items = UpdateSnapshot.appStoreItems(
            lines: ["361285480 Keynote (13.2 -> 13.3)"],
            ignoring: ignored
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testBlankLineIsSkipped() {
        let items = UpdateSnapshot.appStoreItems(lines: [""], ignoring: IgnoreList())
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - manualItems (manual_updates: name|local|remote|appID)

    static let canonicalManualLine = "Keynote|13.2|13.3|361285480"

    func testParsesTheCanonicalManualExampleFromCacheFormatDoc() {
        let items = UpdateSnapshot.manualItems(lines: [Self.canonicalManualLine], ignoring: IgnoreList())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.source, .manual)
        XCTAssertEqual(items.first?.id, "manual:361285480")
        XCTAssertEqual(items.first?.name, "Keynote")
        XCTAssertEqual(items.first?.link?.absoluteString, "https://apps.apple.com/app/id361285480")
    }

    func testIgnoredManualAppIdIsExcluded() {
        // manualItems checks the ignore list under the "mas" type, the same
        // as appStoreItems - both represent the same underlying App Store id.
        let ignored = IgnoreList.parse(text: "mas|361285480|Keynote\n")
        let items = UpdateSnapshot.manualItems(lines: [Self.canonicalManualLine], ignoring: ignored)
        XCTAssertTrue(items.isEmpty)
    }

    func testManualItemTooFewFieldsIsSkipped() {
        let items = UpdateSnapshot.manualItems(lines: ["Keynote|13.2|13.3"], ignoring: IgnoreList())
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - selfUpdatingItems (app_updates: method|name|local|remote|url|signature)

    static let canonicalSparkleLine =
        "sparkle|AltTab|6.18.0|6.19.0|https://github.com/lwouis/alt-tab-macos/releases/tag/v6.19.0|"

    func testParsesTheCanonicalSparkleExampleFromCacheFormatDoc() {
        let items = UpdateSnapshot.selfUpdatingItems(lines: [Self.canonicalSparkleLine], ignoring: IgnoreList())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.source, .sparkle)
        XCTAssertEqual(items.first?.id, "app:AltTab")
        XCTAssertEqual(items.first?.currentVersion, "6.18.0")
        XCTAssertEqual(items.first?.newVersion, "6.19.0")
        XCTAssertEqual(items.first?.link?.absoluteString, "https://github.com/lwouis/alt-tab-macos/releases/tag/v6.19.0")
    }

    func testGithubMethodMapsToGithubSource() {
        let items = UpdateSnapshot.selfUpdatingItems(
            lines: ["github|SomeApp|1.0|2.0|https://github.com/owner/repo/releases|"],
            ignoring: IgnoreList()
        )
        XCTAssertEqual(items.first?.source, .github)
    }

    func testUnrecognizedMethodFallsBackToSparkle() {
        // Only "github" is special-cased; any other method string (including
        // a future one this build does not know about) reads as sparkle
        // rather than being dropped - matches UpdateProgress's "unknown ->
        // fall back to a safe default" approach for non-versioned fields.
        let items = UpdateSnapshot.selfUpdatingItems(
            lines: ["some-future-method|SomeApp|1.0|2.0|https://example.com|"],
            ignoring: IgnoreList()
        )
        XCTAssertEqual(items.first?.source, .sparkle)
    }

    func testMissingUrlFieldProducesNilLink() {
        let items = UpdateSnapshot.selfUpdatingItems(lines: ["sparkle|SomeApp|1.0|2.0"], ignoring: IgnoreList())
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items.first?.link)
    }

    func testIgnoredSparkleAppIsExcluded() {
        let ignored = IgnoreList.parse(text: "sparkle|AltTab|AltTab\n")
        let items = UpdateSnapshot.selfUpdatingItems(lines: [Self.canonicalSparkleLine], ignoring: ignored)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - IgnoreList.parse (ignored_apps.conf: type|id|name)

    func testIgnoreListParsesTypeIdAndName() {
        let list = IgnoreList.parse(text: "cask|alt-tab|AltTab\n")
        XCTAssertTrue(list.contains(type: "cask", id: "alt-tab"))
        XCTAssertEqual(list.entries.first?.name, "AltTab")
    }

    func testIgnoreListNameDefaultsToIdentifierWhenOmitted() {
        let list = IgnoreList.parse(text: "cask|alt-tab\n")
        XCTAssertTrue(list.contains(type: "cask", id: "alt-tab"))
        XCTAssertEqual(list.entries.first?.name, "alt-tab")
    }

    func testIgnoreListSkipsLinesWithTooFewFields() {
        let list = IgnoreList.parse(text: "cask\n")
        XCTAssertTrue(list.entries.isEmpty)
    }

    func testIgnoreListDoesNotMatchAcrossDifferentTypes() {
        let list = IgnoreList.parse(text: "cask|alt-tab|AltTab\n")
        XCTAssertFalse(list.contains(type: "formula", id: "alt-tab"))
    }

    func testIgnoreListHandlesMultipleLines() {
        let list = IgnoreList.parse(text: "cask|alt-tab|AltTab\nmas|361285480|Keynote\n")
        XCTAssertTrue(list.contains(type: "cask", id: "alt-tab"))
        XCTAssertTrue(list.contains(type: "mas", id: "361285480"))
        XCTAssertEqual(list.entries.count, 2)
    }
}
