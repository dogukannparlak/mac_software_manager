@testable import MacUpdaterGuide
import XCTest

/// Pure decision-logic tests for `ToolkitController.ProcessOutcome`.
///
/// This is the type that fixed the "Swift silently swallows a script's exit
/// code" bug: `run(script:arguments:)` used to discard the process's real
/// termination status entirely, so a crashed or non-zero-exiting update
/// looked identical to a successful one in the UI. These tests lock in the
/// `succeeded`/`summary` classification no matter how the plumbing around it
/// changes.
final class ProcessOutcomeTests: XCTestCase {

    func testCleanExitZeroSucceeds() {
        let outcome = ToolkitController.ProcessOutcome(exitCode: 0, reason: .exit, stderr: "")
        XCTAssertTrue(outcome.succeeded)
    }

    func testNonZeroExitFails() {
        let outcome = ToolkitController.ProcessOutcome(exitCode: 1, reason: .exit, stderr: "")
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.summary, "Process exited with status 1.")
    }

    func testExitZeroWithStderrStillSucceeds() {
        // A script can print a harmless warning to stderr and still exit 0 -
        // that must not be classified as a failure.
        let outcome = ToolkitController.ProcessOutcome(exitCode: 0, reason: .exit, stderr: "warning: something minor")
        XCTAssertTrue(outcome.succeeded)
    }

    func testStderrTakesPriorityInSummaryWhenPresent() {
        let outcome = ToolkitController.ProcessOutcome(exitCode: 1, reason: .exit, stderr: "brew: command not found")
        XCTAssertEqual(outcome.summary, "brew: command not found")
    }

    func testUncaughtSignalFails() {
        let outcome = ToolkitController.ProcessOutcome(exitCode: 9, reason: .uncaughtSignal, stderr: "")
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.summary, "Process terminated by signal 9.")
    }

    func testUncaughtSignalWithStderrPrefersStderr() {
        let outcome = ToolkitController.ProcessOutcome(exitCode: 11, reason: .uncaughtSignal, stderr: "Segmentation fault")
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.summary, "Segmentation fault")
    }

    func testExitZeroWithUncaughtSignalReasonIsNotConfusedForSuccess() {
        // Belt-and-suspenders: 'succeeded' checks both fields, not just the
        // exit code, since a killed process can still report status 0 on
        // some platforms depending on how it was terminated.
        let outcome = ToolkitController.ProcessOutcome(exitCode: 0, reason: .uncaughtSignal, stderr: "")
        XCTAssertFalse(outcome.succeeded)
    }
}
