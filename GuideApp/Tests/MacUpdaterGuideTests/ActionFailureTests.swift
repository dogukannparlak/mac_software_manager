import XCTest
@testable import MacUpdaterGuide

/// Wording and classification for `ToolkitController.ActionFailure` - what
/// the UI puts on screen when an action fails.
///
/// The bug behind this type: six paths (refresh, ignore, unignore, the
/// toolkit check, and two missing-script guards) reported their failures by
/// writing to a `lastMessage: String?` that no view ever read, so all of them
/// failed in total silence. One of the six wrote the raw token
/// "toolkit-missing", which had no translation anywhere - so these tests
/// check both halves of the replacement: that every action has real copy in
/// both languages, and that a finished process is turned into the right
/// reason.
final class ActionFailureTests: XCTestCase {

    private typealias Failure = ToolkitController.ActionFailure

    private func outcome(_ code: Int32,
                         _ reason: Process.TerminationReason = .exit,
                         stderr: String = "") -> ToolkitController.ProcessOutcome {
        ToolkitController.ProcessOutcome(exitCode: code, reason: reason, stderr: stderr)
    }

    // MARK: - Reason

    func testStderrIsTheReasonWhenThereIsAny() {
        let reason = Failure.Reason.from(outcome(1, stderr: "Error: No such keg: /usr/local/Cellar/awscli"))
        XCTAssertEqual(reason, .output("Error: No such keg: /usr/local/Cellar/awscli"))
    }

    func testASilentFailureFallsBackToTheExitStatus() {
        // Nothing printed, but the process still died badly: the status is
        // all there is to report, and reporting nothing is what this whole
        // type exists to stop.
        let reason = Failure.Reason.from(outcome(3))
        XCTAssertEqual(reason, .output("Process exited with status 3."))
    }

    func testASilentCleanExitHasNoReasonToQuote() {
        // `run single` exits 0 whether or not the package actually updated -
        // finishActiveItem decides that by re-reading the outdated list - so
        // a clean, silent exit really does leave nothing to show.
        XCTAssertEqual(Failure.Reason.from(outcome(0)), .noOutput)
    }

    func testEveryReasonRendersSomethingInBothLanguages() {
        let reasons: [Failure.Reason] = [.toolkitMissing, .noOutput, .output("boom")]
        for reason in reasons {
            for language in AppLanguage.allCases {
                XCTAssertFalse(reason.text(for: language).isEmpty,
                               "\(reason) renders nothing in \(language)")
            }
        }
    }

    func testToolkitMissingIsWordedNotTokenised() {
        // The exact regression: "toolkit-missing" used to be written straight
        // into the message property as a token no view could translate.
        for language in AppLanguage.allCases {
            let text = Failure.Reason.toolkitMissing.text(for: language)
            XCTAssertFalse(text.contains("toolkit-missing"), "\(language) still shows the raw token")
            XCTAssertEqual(text, UIStrings.toolkitNotFoundDetail[language])
        }
    }

    // MARK: - Titles

    func testASubjectIsNamedInTheTitle() {
        let failure = Failure(action: .updateItem, subject: "Rectangle", reason: .noOutput)
        XCTAssertEqual(failure.title(for: .english), "Could not update Rectangle")
        XCTAssertEqual(failure.title(for: .turkish), "Rectangle güncellenemedi")
    }

    func testHideAndUnhideAreDistinctTitles() {
        let hide = Failure(action: .hideItem, subject: "awscli", reason: .noOutput)
        let unhide = Failure(action: .unhideItem, subject: "awscli", reason: .noOutput)
        for language in AppLanguage.allCases {
            XCTAssertNotEqual(hide.title(for: language), unhide.title(for: language))
        }
    }

    func testEveryActionHasCopyInBothLanguages() {
        let actions: [Failure.Action] = [
            .refresh, .homebrewCheck, .startRun, .updateItem,
            .hideItem, .unhideItem, .toolkitUpdateCheck
        ]
        for action in actions {
            for language in AppLanguage.allCases {
                let title = Failure(action: action, subject: "Rectangle", reason: .noOutput)
                    .title(for: language)
                XCTAssertFalse(title.isEmpty, "\(action) has no title in \(language)")
                // A format string that never got its subject substituted is
                // the failure mode worth catching here.
                XCTAssertFalse(title.contains("%@"), "\(action) leaked its format placeholder in \(language)")
            }
        }
    }

    func testASubjectlessItemFailureStillReadsAsASentence() {
        // No caller should produce this, but a title is not worth crashing
        // over: it falls back to the generic wording rather than "%@".
        let failure = Failure(action: .updateItem, subject: nil, reason: .noOutput)
        XCTAssertEqual(failure.title(for: .english), UIStrings.actionFailedStartRun.en)
    }

    func testDetailPassesTheReasonThrough() {
        let failure = Failure(action: .refresh, subject: nil, reason: .output("brew: command not found"))
        XCTAssertEqual(failure.detail(for: .english), "brew: command not found")
        XCTAssertEqual(failure.detail(for: .turkish), "brew: command not found")
    }
}
