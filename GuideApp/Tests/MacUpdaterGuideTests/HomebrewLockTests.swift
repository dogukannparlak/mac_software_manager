import XCTest
@testable import MacUpdaterGuide

/// Which rows share Homebrew's lock. Two `brew upgrade`s at once can collide
/// on a package or a dependency, so the queue lets only these go one at a time.
final class HomebrewLockTests: XCTestCase {

    private func item(_ source: UpdateSource) -> UpdateItem {
        UpdateItem(id: "x", source: source, name: "x", currentVersion: "1", newVersion: "2", link: nil)
    }

    func testFormulaeAndCasksShareTheLock() {
        XCTAssertTrue(item(.formula).usesHomebrewLock)
        XCTAssertTrue(item(.cask).usesHomebrewLock)
    }

    func testEverythingElseRunsFreely() {
        for source in [UpdateSource.appStore, .manual, .sparkle, .github] {
            XCTAssertFalse(item(source).usesHomebrewLock, "\(source)")
        }
    }
}
