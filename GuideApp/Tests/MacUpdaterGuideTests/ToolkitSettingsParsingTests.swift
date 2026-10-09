@testable import MacUpdaterGuide
import XCTest

/// Tests for `ToolkitSettings.apply(key:value:)` - the `settings.conf`
/// key/value mapping the shell engine's own strict `KEY="value"` writer and
/// this reader are required to agree on. Exercised directly against a fresh
/// `ToolkitSettings` instance (see the doc comment on `apply` for why it is
/// internal), never through `load()`/`save()` - those go through
/// ToolkitPaths' real, non-injectable `~/Library/Application Support/...`
/// location, which a test must not read from or write into.
///
/// `ToolkitSettings.init()` itself still calls `load()` once (a harmless
/// read - if this machine happens to have a real settings.conf, its values
/// would leak into the instance's starting state), so every test below
/// exercises one key by setting a known starting value on just that
/// property first, then asserts only what `apply` did to it - never
/// asserting on a property `apply` was not given a key for.
final class ToolkitSettingsParsingTests: XCTestCase {

    // MARK: - PREFERRED_TERMINAL

    func testRecognizedTerminalValueIsApplied() {
        let settings = ToolkitSettings()
        settings.preferredTerminal = .terminal
        settings.apply(key: "PREFERRED_TERMINAL", value: "iTerm2")
        XCTAssertEqual(settings.preferredTerminal, .iTerm2)
    }

    func testUnrecognizedTerminalValueLeavesThePreviousValueUnchanged() {
        let settings = ToolkitSettings()
        settings.preferredTerminal = .warp
        settings.apply(key: "PREFERRED_TERMINAL", value: "NotARealTerminal")
        XCTAssertEqual(settings.preferredTerminal, .warp)
    }

    // MARK: - MAS_ENABLED / AUTOSTART / CLEANUP_ENABLED / AUTO_INSTALL_APPS ("1"/"0" flags)

    func testFlagValueOneIsTrue() {
        let settings = ToolkitSettings()
        settings.masEnabled = false
        settings.apply(key: "MAS_ENABLED", value: "1")
        XCTAssertTrue(settings.masEnabled)
    }

    func testFlagValueZeroIsFalse() {
        let settings = ToolkitSettings()
        settings.masEnabled = true
        settings.apply(key: "MAS_ENABLED", value: "0")
        XCTAssertFalse(settings.masEnabled)
    }

    func testFlagValueAnythingOtherThanOneIsFalse() {
        // The shell writes exactly "1" or "0", but a hand-edited or corrupt
        // file could contain anything - only a literal "1" means on.
        let settings = ToolkitSettings()
        settings.autostart = true
        settings.apply(key: "AUTOSTART", value: "yes")
        XCTAssertFalse(settings.autostart)
    }

    func testCleanupEnabledFlagIsApplied() {
        let settings = ToolkitSettings()
        settings.cleanupEnabled = true
        settings.apply(key: "CLEANUP_ENABLED", value: "0")
        XCTAssertFalse(settings.cleanupEnabled)
    }

    func testAutoInstallAppsFlagIsApplied() {
        let settings = ToolkitSettings()
        settings.autoInstallApps = false
        settings.apply(key: "AUTO_INSTALL_APPS", value: "1")
        XCTAssertTrue(settings.autoInstallApps)
    }

    func testOtherSourcesFlagIsApplied() {
        let settings = ToolkitSettings()
        settings.otherSourcesEnabled = true
        settings.apply(key: "OTHER_SOURCES_ENABLED", value: "0")
        XCTAssertFalse(settings.otherSourcesEnabled)
        settings.apply(key: "OTHER_SOURCES_ENABLED", value: "1")
        XCTAssertTrue(settings.otherSourcesEnabled)
    }

    // MARK: - UPDATE_BRANCH

    func testRecognizedChannelValueIsApplied() {
        let settings = ToolkitSettings()
        settings.channel = .stable
        settings.apply(key: "UPDATE_BRANCH", value: "develop")
        XCTAssertEqual(settings.channel, .beta)
    }

    func testUnrecognizedChannelValueLeavesThePreviousValueUnchanged() {
        let settings = ToolkitSettings()
        settings.channel = .beta
        settings.apply(key: "UPDATE_BRANCH", value: "not-a-real-branch")
        XCTAssertEqual(settings.channel, .beta)
    }

    // MARK: - CODEBERG_USERNAME

    func testCodebergUsernameIsAppliedVerbatim() {
        let settings = ToolkitSettings()
        settings.codebergUsername = ""
        settings.apply(key: "CODEBERG_USERNAME", value: "someuser")
        XCTAssertEqual(settings.codebergUsername, "someuser")
    }

    func testCodebergUsernamePlaceholderValueBecomesEmpty() {
        // The setup script ships this literal placeholder when no mirror is
        // configured - it must read as "not configured" (empty), never as a
        // literal username to try connecting to.
        let settings = ToolkitSettings()
        settings.codebergUsername = "someuser"
        settings.apply(key: "CODEBERG_USERNAME", value: "YOUR_CODEBERG_USERNAME")
        XCTAssertEqual(settings.codebergUsername, "")
    }

    // MARK: - Unknown keys

    func testUnknownKeyIsIgnoredWithoutAffectingAnyProperty() {
        let settings = ToolkitSettings()
        settings.masEnabled = true
        settings.apply(key: "SOME_FUTURE_SETTING_THIS_BUILD_DOES_NOT_KNOW_ABOUT", value: "1")
        XCTAssertTrue(settings.masEnabled)
    }
}
