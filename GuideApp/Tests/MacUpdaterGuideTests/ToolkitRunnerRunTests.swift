import XCTest
@testable import MacUpdaterGuide

/// End-to-end tests for `ToolkitController.run(script:arguments:)`, exercised
/// through a real `Process`/`Pipe` against a tiny fixture script - the same
/// shape production uses ("run zsh against this script with these args"),
/// not just the pure `ProcessOutcome` decision logic covered separately in
/// ProcessOutcomeTests. This is the direct regression test for the bug this
/// function was rewritten to fix: exit code and stderr used to be discarded
/// entirely.
final class ToolkitRunnerRunTests: XCTestCase {

    /// Writes an executable zsh fixture script with the given body and
    /// returns its URL. Cleaned up by the caller via `addTeardownBlock`.
    private func makeFixture(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolkit-runner-fixture-\(UUID().uuidString).sh")
        let contents = "#!/bin/zsh\n" + body + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSuccessfulScriptReportsSucceeded() async throws {
        let fixture = try makeFixture("exit 0")
        let outcome = await ToolkitController.run(script: fixture, arguments: [])
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.exitCode, 0)
    }

    func testNonZeroExitIsCapturedExactly() async throws {
        let fixture = try makeFixture("exit 3")
        let outcome = await ToolkitController.run(script: fixture, arguments: [])
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.exitCode, 3)
    }

    func testStderrIsCaptured() async throws {
        let fixture = try makeFixture(#"echo "boom" >&2; exit 1"#)
        let outcome = await ToolkitController.run(script: fixture, arguments: [])
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.stderr, "boom")
    }

    func testStdoutIsNotMixedIntoTheOutcome() async throws {
        // standardOutput is intentionally discarded (nulled) - stdout noise
        // from a script must never leak into the failure summary.
        let fixture = try makeFixture(#"echo "this goes to stdout, not stderr"; exit 0"#)
        let outcome = await ToolkitController.run(script: fixture, arguments: [])
        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.stderr, "")
    }

    func testArgumentsAreForwardedToTheScript() async throws {
        let fixture = try makeFixture(#"[[ "$1" == "hello" && "$2" == "world" ]] || { echo "args mismatch: $*" >&2; exit 1; }"#)
        let outcome = await ToolkitController.run(script: fixture, arguments: ["hello", "world"])
        XCTAssertTrue(outcome.succeeded, outcome.stderr)
    }

    func testMissingScriptIsReportedAsFailureNotACrash() async throws {
        // run() must catch process.run() throwing (e.g. file does not exist)
        // and still return a ProcessOutcome, never let the error propagate
        // uncaught - a launch failure is exactly the "silent failure" class
        // of bug this rewrite targets.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sh")
        let outcome = await ToolkitController.run(script: missing, arguments: [])
        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(outcome.summary.isEmpty)
    }
}
