@testable import MacUpdaterGuide
import XCTest

/// The decisions behind the app's self-update (`AppRelease.swift`): which
/// version is newer, which release is installable, and what a checksum file
/// says. `AppUpdater` only acts on these answers, so a wrong one here is an
/// update offered that should not be - or a downgrade.
final class AppReleaseTests: XCTestCase {

    // MARK: - Versions

    func testVersionsCompareNumericallyNotAsText() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9.0")), try XCTUnwrap(AppVersion("1.10.0")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.6.0")), try XCTUnwrap(AppVersion("1.6.1")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.6.9")), try XCTUnwrap(AppVersion("2.0")))
    }

    func testTagPrefixAndMissingComponentsDoNotChangeTheVersion() throws {
        XCTAssertEqual(try XCTUnwrap(AppVersion("v1.6.0")), try XCTUnwrap(AppVersion("1.6.0")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.6")), try XCTUnwrap(AppVersion("1.6.0")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("1.6.0-beta.1")), try XCTUnwrap(AppVersion("1.6.0")))
    }

    func testGarbageIsNotAVersion() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1..2"))
    }

    // MARK: - Releases

    private func release(
        tag: String = "v1.7.0",
        draft: Bool = false,
        prerelease: Bool = false,
        assets: [String] = ["MacUpdaterGuide-1.7.0-macOS-universal.zip",
                            "MacUpdaterGuide-1.7.0-macOS-universal.dmg",
                            "SHA256SUMS.txt"]
    ) throws -> AppRelease {
        let assetJSON = assets.map {
            #"{"name":"\#($0)","size":10,"browser_download_url":"https://example.com/\#($0)"}"#
        }.joined(separator: ",")
        let json = """
        {"tag_name":"\(tag)","html_url":"https://github.com/o/r/releases/tag/\(tag)",
         "draft":\(draft),"prerelease":\(prerelease),"assets":[\(assetJSON)]}
        """
        return try AppRelease.decode(Data(json.utf8))
    }

    private let current = AppVersion("1.6.0")!

    func testNewerCompleteReleaseIsInstallable() throws {
        let release = try release()
        XCTAssertTrue(release.isInstallable(over: current, appName: "MacUpdaterGuide"))
        XCTAssertEqual(release.appArchive(appName: "MacUpdaterGuide")?.name,
                       "MacUpdaterGuide-1.7.0-macOS-universal.zip")
        XCTAssertEqual(release.checksumFile?.name, "SHA256SUMS.txt")
    }

    func testSameOrOlderReleaseIsNeverInstalled() throws {
        XCTAssertFalse(try release(tag: "v1.6.0").isInstallable(over: current, appName: "MacUpdaterGuide"))
        XCTAssertFalse(try release(tag: "v1.5.0").isInstallable(over: current, appName: "MacUpdaterGuide"))
    }

    func testDraftsAndPrereleasesAreNeverInstalled() throws {
        XCTAssertFalse(try release(draft: true).isInstallable(over: current, appName: "MacUpdaterGuide"))
        XCTAssertFalse(try release(prerelease: true).isInstallable(over: current, appName: "MacUpdaterGuide"))
    }

    func testReleaseWithoutChecksumFileIsNeverInstalled() throws {
        let release = try release(assets: ["MacUpdaterGuide-1.7.0-macOS-universal.zip"])
        XCTAssertFalse(release.isInstallable(over: current, appName: "MacUpdaterGuide"))
    }

    func testReleaseWithOnlyADiskImageIsNeverInstalled() throws {
        let release = try release(assets: ["MacUpdaterGuide-1.7.0-macOS-universal.dmg", "SHA256SUMS.txt"])
        XCTAssertFalse(release.isInstallable(over: current, appName: "MacUpdaterGuide"))
    }

    // MARK: - Checksums

    func testChecksumListReadsShasumOutputInBothModes() {
        let hashA = String(repeating: "a", count: 64)
        let hashB = String(repeating: "B", count: 64)
        let text = """
        \(hashA)  MacUpdaterGuide-1.7.0-macOS-universal.zip
        \(hashB) *MacUpdaterGuide-1.7.0-macOS-universal.dmg

        not a checksum line
        abc  too-short.zip
        """
        let sums = ChecksumList.parse(text)
        XCTAssertEqual(sums.count, 2)
        XCTAssertEqual(sums["MacUpdaterGuide-1.7.0-macOS-universal.zip"], hashA)
        // Lowercased, to compare with what `sha256(of:)` produces.
        XCTAssertEqual(sums["MacUpdaterGuide-1.7.0-macOS-universal.dmg"], hashB.lowercased())
    }

    func testFileHashMatchesKnownDigest() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "apprelease-\(UUID().uuidString).txt")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(
            try ChecksumList.sha256(of: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - Installer helper

    /// The helper runs after the app has quit, so a syntax error in it would
    /// fail with nobody watching. `zsh -n` parses without running anything.
    func testHelperScriptParses() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "install-\(UUID().uuidString).sh")
        let script = await MainActor.run { AppUpdater.helperScript }
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-n", file.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
