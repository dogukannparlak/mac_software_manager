@testable import MacUpdaterGuide
import XCTest

/// `OtherPackage.parse` against the `other_packages` / `other_outdated` cache
/// lines the engine writes (lib/updaters.sh, section 3c2; CACHE_FORMAT.md).
final class OtherPackageParsingTests: XCTestCase {

    func testEverySourceIsParsedWithItsFields() {
        let packages = OtherPackage.parse(packages: [
            "npm|@anthropic-ai/claude-code|2.0.14|",
            "pipx|black|24.4.2|",
            "go|gopls|0.16.2|golang.org/x/tools/gopls",
            "local|claude|2.0.14|/Users/me/.local/share/claude/versions/2.0.14/claude",
            "app|agy|1.2.0|/Applications/Antigravity.app",
            "pkg|com.example.driver|3.1|/"
        ], outdated: [])

        XCTAssertEqual(packages.map(\.source), [.npm, .pipx, .go, .local, .app, .pkg])
        XCTAssertEqual(packages[0].name, "@anthropic-ai/claude-code")
        XCTAssertEqual(packages[0].version, "2.0.14")
        XCTAssertNil(packages[0].location)
        XCTAssertEqual(packages[2].location, "golang.org/x/tools/gopls")
        XCTAssertEqual(packages[4].location, "/Applications/Antigravity.app")
    }

    func testOutdatedVersionIsJoinedByNameAndSource() {
        let packages = OtherPackage.parse(
            packages: ["npm|typescript|5.4.5|", "pipx|typescript|1.0|"],
            outdated: ["npm|typescript|5.4.5|5.6.3"]
        )

        XCTAssertEqual(packages[0].latestVersion, "5.6.3")
        XCTAssertTrue(packages[0].isOutdated)
        // Same name, different source: not the same package.
        XCTAssertNil(packages[1].latestVersion)
        XCTAssertFalse(packages[1].isOutdated)
    }

    func testAnUnknownSourceOrAShortLineIsSkipped() {
        let packages = OtherPackage.parse(packages: [
            "gem|rails|7.1|",
            "npm|only-two",
            "npm||1.0|",
            "uv|ruff|0.6.0|"
        ], outdated: [])

        XCTAssertEqual(packages.map(\.name), ["ruff"])
    }

    func testDuplicatesKeepTheFirstLine() {
        let packages = OtherPackage.parse(
            packages: ["cargo|ripgrep|14.1.0|", "cargo|ripgrep|13.0.0|"],
            outdated: []
        )

        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages[0].version, "14.1.0")
    }

    func testOnlyPackageManagersAreUpdatable() {
        XCTAssertTrue(PackageSource.npm.isUpdatable)
        XCTAssertTrue(PackageSource.go.isUpdatable)
        XCTAssertFalse(PackageSource.pkg.isUpdatable)
        XCTAssertFalse(PackageSource.local.isUpdatable)
        XCTAssertFalse(PackageSource.app.isUpdatable)
    }
}
