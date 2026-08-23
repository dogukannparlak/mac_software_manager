@testable import MacUpdaterGuide
import XCTest

/// End-to-end tests for `UninstallPlan`, run through a real `Process` against
/// a fixture script that prints the same `ITEM|`/`RESULT|` lines uninstall.sh
/// does.
///
/// The contract worth defending here is the one the Uninstall page relies on:
/// the app must be able to say something truthful about every box that was
/// ticked, and it must never claim a step ran that the script never mentioned.
/// A parser that silently drops a line turns that into a page reporting
/// success for something it did not do.
final class UninstallPlanTests: XCTestCase {

    private func makeFixture(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uninstall-fixture-\(UUID().uuidString).sh")
        try ("#!/bin/zsh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var appBundle: URL { URL(filePath: "/Applications/Fixture.app") }

    // MARK: - Flags

    /// The flags are the raw values, so the enum and the script can never
    /// drift apart by a typo in a hand-written string.
    func testFlagsMatchTheScriptsOptionNames() {
        XCTAssertEqual(UninstallStep.app.flag, "--app")
        XCTAssertEqual(UninstallStep.loginItem.flag, "--login-item")
        XCTAssertEqual(UninstallStep.mas.flag, "--mas")
    }

    // MARK: - list

    func testListParsesPresenceAndDetail() async throws {
        let fixture = try makeFixture("""
        echo 'ITEM|data|yes|/Users/x/Library/Application Support/MacSoftwareUpdater'
        echo 'ITEM|app|no|/Applications/MacUpdaterGuide.app'
        """)

        let items = await UninstallPlan.list(script: fixture, appBundle: appBundle)

        let data = try XCTUnwrap(items.first { $0.step == .data })
        XCTAssertTrue(data.isPresent)
        XCTAssertTrue(data.detail.hasSuffix("MacSoftwareUpdater"))

        let app = try XCTUnwrap(items.first { $0.step == .app })
        XCTAssertFalse(app.isPresent)
    }

    /// A step the script never mentioned still gets a row, reported as absent.
    /// Dropping it would make the list shrink between refreshes, which reads
    /// as a bug rather than as "there is nothing there".
    func testEveryStepIsReturnedInDeclarationOrderEvenWhenUnreported() async throws {
        let fixture = try makeFixture("echo 'ITEM|data|yes|/tmp/whatever'")

        let items = await UninstallPlan.list(script: fixture, appBundle: appBundle)

        XCTAssertEqual(items.map(\.step), UninstallStep.allCases)
        XCTAssertEqual(items.filter(\.isPresent).map(\.step), [.data])
    }

    func testUnknownKeysAndNoiseAreIgnored() async throws {
        let fixture = try makeFixture("""
        echo 'Some human sentence that is not a record'
        echo 'ITEM|homebrew|yes|/opt/homebrew'
        echo 'ITEM|prefs|yes|com.example.app'
        """)

        let items = await UninstallPlan.list(script: fixture, appBundle: appBundle)

        XCTAssertEqual(items.count, UninstallStep.allCases.count)
        XCTAssertEqual(items.filter(\.isPresent).map(\.step), [.prefs])
    }

    // MARK: - run

    func testRunReportsEachStepsOutcome() async throws {
        let fixture = try makeFixture("""
        echo 'RESULT|data|removed|/tmp/support'
        echo 'RESULT|mas|failed|brew uninstall mas failed'
        """)

        let outcome = await UninstallPlan.run(
            script: fixture, appBundle: appBundle, steps: [.data, .mas], dryRun: false
        )

        XCTAssertEqual(outcome.results.map(\.step), [.data, .mas])
        XCTAssertEqual(outcome.results[0].outcome, .removed)
        XCTAssertEqual(outcome.results[1].outcome, .failed)
        XCTAssertEqual(outcome.results[1].detail, "brew uninstall mas failed")
    }

    /// A step that died before it printed must not vanish: the page has a
    /// ticked box for it and owes the reader an answer about it.
    func testASelectedStepThatReportsNothingComesBackAsSkipped() async throws {
        let fixture = try makeFixture("echo 'RESULT|data|removed|/tmp/support'")

        let outcome = await UninstallPlan.run(
            script: fixture, appBundle: appBundle, steps: [.data, .prefs], dryRun: false
        )

        XCTAssertEqual(outcome.results.map(\.step), [.data, .prefs])
        XCTAssertEqual(outcome.results[1].outcome, .skipped)
    }

    func testRunWithNoStepsDoesNothingAtAll() async throws {
        // A fixture that would fail loudly if it were ever executed.
        let fixture = try makeFixture("echo 'RESULT|data|removed|should not happen'; exit 1")

        let outcome = await UninstallPlan.run(
            script: fixture, appBundle: appBundle, steps: [], dryRun: false
        )

        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertNil(outcome.failure)
    }

    func testFailureIsOnlySurfacedWhenTheScriptActuallySaidSomething() async throws {
        let quiet = try makeFixture("echo 'RESULT|data|failed|could not remove'; exit 1")
        let noisy = try makeFixture("echo 'boom' >&2; exit 1")

        let quietOutcome = await UninstallPlan.run(
            script: quiet, appBundle: appBundle, steps: [.data], dryRun: false
        )
        // The per-step row already says it failed; repeating "exit status 1"
        // in a banner would be noise, not information.
        XCTAssertNil(quietOutcome.failure)

        let noisyOutcome = await UninstallPlan.run(
            script: noisy, appBundle: appBundle, steps: [.data], dryRun: false
        )
        XCTAssertEqual(noisyOutcome.failure, "boom")
    }

    func testDryRunPassesTheFlagThrough() async throws {
        // Echoes its own arguments back as a result detail, so the test can
        // assert on what the script was actually invoked with.
        let fixture = try makeFixture("echo \"RESULT|data|dryrun|$*\"")

        let outcome = await UninstallPlan.run(
            script: fixture, appBundle: appBundle, steps: [.data], dryRun: true
        )

        let detail = try XCTUnwrap(outcome.results.first?.detail)
        XCTAssertTrue(detail.contains("--data"))
        XCTAssertTrue(detail.contains("--dry-run"))
        XCTAssertTrue(detail.contains("--app-path"))
        XCTAssertEqual(outcome.results.first?.outcome, .dryrun)
    }
}
