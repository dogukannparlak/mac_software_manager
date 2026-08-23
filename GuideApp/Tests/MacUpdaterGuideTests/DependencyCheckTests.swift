@testable import MacUpdaterGuide
import XCTest

/// The two halves of the setup sheet that can be wrong without anything
/// crashing: what it decides a dependency's state is, and how it reads the
/// installer's progress lines.
///
/// Neither half is exercised by running the app on a developer's Mac, because
/// that Mac has Homebrew, an engine and mas - the states that matter are the
/// ones nobody here can reproduce by launching it. So the decisions are pure
/// functions taking what the probe found rather than doing the finding, and
/// this is where the missing/outdated/failed cases actually get looked at.
final class DependencyCheckTests: XCTestCase {

    // MARK: - Homebrew and mas

    func testBrewAndMasFollowTheirBinary() {
        XCTAssertEqual(DependencyCheck.brewState(path: nil), .missing)
        XCTAssertEqual(DependencyCheck.masState(path: nil), .missing)
        XCTAssertEqual(
            DependencyCheck.brewState(path: "/opt/homebrew/bin/brew"),
            .satisfied(detail: "/opt/homebrew/bin/brew")
        )
        XCTAssertEqual(
            DependencyCheck.masState(path: "/opt/homebrew/bin/mas"),
            .satisfied(detail: "/opt/homebrew/bin/mas")
        )
    }

    // MARK: - Reading the states as a whole

    func testOnlyRequiredDependenciesOpenTheSheet() {
        let masOnly: [Dependency: DependencyState] = [
            .homebrew: .satisfied(detail: "/opt/homebrew/bin/brew"),
            .mas: .missing
        ]

        XCTAssertFalse(
            DependencyCheck.hasBlockingGap(masOnly),
            "a missing optional dependency must not put a setup sheet in front of a working install"
        )
        XCTAssertTrue(DependencyCheck.hasBlockingGap([.homebrew: .missing]))
        XCTAssertTrue(DependencyCheck.hasBlockingGap([.homebrew: .failed("could not read it")]))
    }

    /// `checking` is the state every row starts in. Treating it as a gap would
    /// flash the sheet open on every launch on the way to finding out that
    /// nothing is wrong.
    func testCheckingIsNotAGap() {
        XCTAssertFalse(DependencyCheck.hasBlockingGap([.homebrew: .checking, .mas: .checking]))
    }

    /// The button says "install what's missing", so it means all of it - the
    /// optional row included, in row order.
    func testInstallableCoversOptionalRowsInDeclarationOrder() {
        let states: [Dependency: DependencyState] = [
            .homebrew: .missing,
            .mas: .missing
        ]

        XCTAssertEqual(DependencyCheck.installable(from: states), [.homebrew, .mas])
    }

    // MARK: - What installs itself

    /// The engine is not a dependency and must never become one again: it
    /// ships inside the app and runs from there, so listing it as something to
    /// install would be the app offering to install itself.
    func testTheEngineIsNotADependency() {
        XCTAssertEqual(Dependency.allCases, [.homebrew, .mas])
    }

    /// Homebrew is the one row whose button does not install anything here -
    /// it opens Terminal, because its installer wants a password this app
    /// will not collect.
    func testOnlyHomebrewIsInstalledOutsideTheApp() {
        XCTAssertFalse(Dependency.homebrew.isInstalledInApp)
        XCTAssertTrue(Dependency.mas.isInstalledInApp)
    }

    /// The engine sources every one of these by name and exits on the first
    /// one it cannot read, so a duplicate or an empty entry here is a run that
    /// dies on its first line. tests/engine_resources.bats checks the list
    /// against LIB_NAMES in the engine itself.
    func testBundledLibraryManifestIsWellFormed() {
        let names = BundledEngine.libraryNames

        XCTAssertEqual(Set(names).count, names.count, "duplicate entry in the bundled library manifest")
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertTrue(names.contains("utils"), "the engine cannot start without utils.sh")
        XCTAssertFalse(
            names.contains(where: { $0.contains("/") || $0.contains(".sh") }),
            "these are bare names - the engine appends the directory and the extension itself"
        )
    }

    // MARK: - AppleScript

    /// The Homebrew command goes into an AppleScript string literal. Both
    /// escapes have to happen, and nothing else may be touched - `$(...)` and
    /// the URL are shell syntax that mangling here would break.
    func testEscapesOnlyWhatAppleScriptNeeds() {
        XCTAssertEqual(
            BootstrapInstaller.appleScriptEscaped(#"say "hi""#),
            #"say \"hi\""#
        )
        XCTAssertEqual(
            BootstrapInstaller.appleScriptEscaped(#"back\slash"#),
            #"back\\slash"#
        )

        let escaped = BootstrapInstaller.appleScriptEscaped(BootstrapInstaller.homebrewInstallCommand)
        XCTAssertTrue(escaped.contains(#"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"#))
        XCTAssertFalse(escaped.contains(#" ""#), "every quote in the command must have been escaped")
    }
}
