@testable import MacUpdaterGuide
import XCTest

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

    func testStderrBiggerThanThePipeBufferDoesNotHangTheRun() throws {
        // A pipe holds 64 KB. A process that writes more than that into one
        // nobody is reading blocks in write() and never exits, so a reader
        // that only starts in terminationHandler never starts - the run hangs
        // for good. Kept synchronous with an explicit timeout so that hang
        // fails this test instead of stalling the whole suite.
        let fixture = try makeFixture(#"""
        for i in {1..4000}; do
          print -u2 "line $i: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        done
        print -u2 "LAST-LINE-OF-STDERR"
        exit 7
        """#)

        let finished = expectation(description: "run(script:arguments:) returns")
        Task {
            let outcome = await ToolkitController.run(script: fixture, arguments: [])
            XCTAssertEqual(outcome.exitCode, 7)
            // The tail is the part worth keeping: it is where a failing run
            // says what actually went wrong.
            XCTAssertTrue(
                outcome.stderr.hasSuffix("LAST-LINE-OF-STDERR"),
                "last line of stderr missing, got: ...\(outcome.stderr.suffix(120))"
            )
            // ~280 KB was printed; only a bounded tail of it is kept, so one
            // chatty script cannot balloon the app's memory or the banner.
            XCTAssertLessThan(outcome.stderr.utf8.count, 64 * 1024)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 60)
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
