import XCTest
@testable import MacUpdaterGuide

/// Tests for `PipeConfig.load`/`save` - the shared reader/writer behind
/// `tracked_apps.conf` and `app_token_map.conf` (TrackedAppsStore,
/// TokenMapStore). Exercised against real files in a temp directory, the
/// same "real Process/Pipe, real file I/O, but sandboxed to a throwaway
/// location" shape ToolkitRunnerRunTests uses - `load`/`save` already take a
/// `URL` directly, so no production code needed to change for this one.
final class PipeConfigTests: XCTestCase {

    /// A throwaway file URL under the system temp directory. Cleaned up by
    /// the caller via `addTeardownBlock`, same as ToolkitRunnerRunTests'
    /// `makeFixture`.
    private func makeConfigURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeconfig-test-\(UUID().uuidString).conf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - load

    func testLoadReturnsEmptyArrayWhenFileDoesNotExist() {
        let url = makeConfigURL()
        XCTAssertEqual(PipeConfig.load(url, fieldCount: 3), [])
    }

    func testLoadParsesPipeDelimitedFields() throws {
        let url = makeConfigURL()
        try "AltTab|sparkle|https://example.com/appcast.xml\n".write(to: url, atomically: true, encoding: .utf8)

        let entries = PipeConfig.load(url, fieldCount: 3)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0][0], "AltTab")
        XCTAssertEqual(entries[0][1], "sparkle")
        XCTAssertEqual(entries[0][2], "https://example.com/appcast.xml")
    }

    func testLoadTrimsWhitespaceAroundFields() throws {
        let url = makeConfigURL()
        try "  AltTab  |  sparkle  \n".write(to: url, atomically: true, encoding: .utf8)

        let entries = PipeConfig.load(url, fieldCount: 2)
        XCTAssertEqual(entries[0][0], "AltTab")
        XCTAssertEqual(entries[0][1], "sparkle")
    }

    func testLoadSkipsCommentAndBlankLines() throws {
        let url = makeConfigURL()
        try "# a comment\n\nAltTab|sparkle\n".write(to: url, atomically: true, encoding: .utf8)

        let entries = PipeConfig.load(url, fieldCount: 2)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0][0], "AltTab")
    }

    func testLoadSkipsLinesWithAnEmptyFirstField() throws {
        // An empty first field means no key to match against - not a usable
        // entry, whatever the remaining fields say.
        let url = makeConfigURL()
        try "|sparkle\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(PipeConfig.load(url, fieldCount: 2).isEmpty)
    }

    func testLoadPadsShortLinesUpToFieldCount() throws {
        let url = makeConfigURL()
        try "AltTab\n".write(to: url, atomically: true, encoding: .utf8)

        let entries = PipeConfig.load(url, fieldCount: 3)
        XCTAssertEqual(entries[0].fields, ["AltTab", "", ""])
    }

    func testLoadTruncatesLongLinesDownToFieldCount() throws {
        let url = makeConfigURL()
        try "AltTab|sparkle|url|extra-field\n".write(to: url, atomically: true, encoding: .utf8)

        let entries = PipeConfig.load(url, fieldCount: 3)
        XCTAssertEqual(entries[0].fields, ["AltTab", "sparkle", "url"])
    }

    // MARK: - save

    func testSaveThenLoadRoundTripsEntries() {
        let url = makeConfigURL()
        let entries = [
            ConfigEntry(fields: ["AltTab", "sparkle", "https://example.com/appcast.xml"]),
            ConfigEntry(fields: ["Keka", "github", "owner/keka"])
        ]

        XCTAssertTrue(PipeConfig.save(entries, to: url, header: "# header\n"))

        let loaded = PipeConfig.load(url, fieldCount: 3)
        XCTAssertEqual(loaded.map(\.fields), entries.map(\.fields))
    }

    func testSaveWritesTheGivenHeader() throws {
        let url = makeConfigURL()
        PipeConfig.save([], to: url, header: "# Mac Software Manager Configuration\n")

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("# Mac Software Manager Configuration\n"))
    }

    func testSaveAddsATrailingNewlineToAHeaderThatIsMissingOne() throws {
        let url = makeConfigURL()
        PipeConfig.save([], to: url, header: "# no trailing newline")

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents, "# no trailing newline\n")
    }

    func testSaveStripsAPipeEmbeddedInAFieldSoItCannotSplitTheLine() throws {
        // The shell reads this file back with the same '|' delimiter - a
        // literal pipe surviving into a field would silently shift every
        // field after it when the shell parses the line.
        let url = makeConfigURL()
        PipeConfig.save([ConfigEntry(fields: ["App|Name", "github", "owner/repo"])], to: url, header: "")

        let entries = PipeConfig.load(url, fieldCount: 3)
        XCTAssertEqual(entries[0][0], "App Name")
    }

    func testSaveOmitsEntriesWithAnEmptyFirstField() throws {
        let url = makeConfigURL()
        PipeConfig.save([ConfigEntry(fields: ["", "github", "owner/repo"])], to: url, header: "")

        // No entry survives the empty-first-field filter, so load() sees
        // nothing but a blank line - the same "no usable entries" outcome as
        // an empty file.
        XCTAssertTrue(PipeConfig.load(url, fieldCount: 3).isEmpty)
    }

    func testSaveSetsOwnerOnlyPermissions() throws {
        let url = makeConfigURL()
        PipeConfig.save([ConfigEntry(fields: ["AltTab", "sparkle"])], to: url, header: "")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let permissions = attributes[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}
