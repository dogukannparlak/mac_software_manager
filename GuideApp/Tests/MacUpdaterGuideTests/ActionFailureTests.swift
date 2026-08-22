@testable import MacUpdaterGuide
import XCTest

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
        let reasons: [Failure.Reason] = [
            .toolkitMissing, .noOutput, .output("boom"),
            .reported(.stillOutdated, detail: "boom"),
            .reported(.unknown, detail: ""),
            .engineContract(found: nil), .engineContract(found: 0),
            .needsTerminal(detail: "boom"), .needsTerminal(detail: ""), .itemGone
        ]
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

    // MARK: - A reason the run filed itself

    func testAReportedReasonIsWordedAndKeepsWhatTheRunPrinted() {
        // The token is the category, which the app can translate; the output
        // is the specifics, which is brew's or mas's English either way -
        // the row needs both, so neither replaces the other.
        let reason = Failure.Reason.reported(.stillOutdated, detail: "Warning: awscli 2.36.24 already installed")
        for language in AppLanguage.allCases {
            let text = reason.text(for: language)
            XCTAssertTrue(text.hasPrefix(ItemRunResult.Reason.stillOutdated.label?[language] ?? "!"))
            XCTAssertTrue(text.hasSuffix("Warning: awscli 2.36.24 already installed"))
        }
    }

    func testAReportedReasonWithNoWordingOfItsOwnShowsTheOutput() {
        // "command-failed" carries no copy: what brew printed IS the reason,
        // and prefixing it with a generic sentence would only push the real
        // one down.
        let reason = Failure.Reason.reported(.commandFailed, detail: "Error: No such keg")
        XCTAssertEqual(reason.text(for: .english), "Error: No such keg")
    }

    func testAReportedReasonWithNothingAtAllStillSaysSomething() {
        // A token this build does not know, from a run that printed nothing:
        // silence is the one thing a failed row may not show.
        let reason = Failure.Reason.reported(.unknown, detail: "")
        for language in AppLanguage.allCases {
            XCTAssertEqual(reason.text(for: language), UIStrings.actionFailedNoReason[language])
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
            .hideItem, .unhideItem, .toolkitUpdateCheck, .engineOutdated
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

    // MARK: - What the banner shows first, and what it hides

    func testTheOutputIsNeverHiddenWhenItIsTheOnlyAccountThereIs() {
        // The banner collapses `evidence` behind a toggle only when there is
        // a headline to stand in for it. A bare `.output` has none, so
        // hiding it would leave a banner that says nothing at all.
        let reason = Failure.Reason.output("Error: No such keg")
        XCTAssertNil(reason.headline(for: .english))
        XCTAssertEqual(reason.evidence, "Error: No such keg")
    }

    func testAWordedReasonKeepsItsOutputSeparate() {
        let reason = Failure.Reason.reported(.stillOutdated, detail: "Warning: already installed")
        XCTAssertEqual(reason.headline(for: .english), ItemRunResult.Reason.stillOutdated.label?.en)
        XCTAssertEqual(reason.evidence, "Warning: already installed")
    }

    func testATokenWithNoCopyLeavesTheOutputToSpeak() {
        // "command-failed" carries no wording of its own: what brew printed
        // IS the reason, so it must not end up behind a toggle.
        let reason = Failure.Reason.reported(.commandFailed, detail: "Error: No such keg")
        XCTAssertNil(reason.headline(for: .english))
        XCTAssertEqual(reason.evidence, "Error: No such keg")
    }

    func testReasonsWithNothingToQuoteHaveNoEvidence() {
        for reason: Failure.Reason in [.toolkitMissing, .noOutput, .itemGone, .engineContract(found: nil)] {
            XCTAssertEqual(reason.evidence, "", "\(reason) has evidence to show")
            XCTAssertNotNil(reason.headline(for: .english), "\(reason) has nothing to say either")
        }
    }

    func testTheComposedTextStillCarriesBothForSurfacesWithNoToggle() {
        // A row's failure line has no room for a disclosure, so it keeps
        // showing headline and output together, exactly as before.
        let reason = Failure.Reason.reported(.stillOutdated, detail: "Warning: already installed")
        let text = reason.text(for: .english)
        XCTAssertTrue(text.hasPrefix(ItemRunResult.Reason.stillOutdated.label?.en ?? "!"))
        XCTAssertTrue(text.hasSuffix("Warning: already installed"))
    }

    func testADeadRecoveryTargetSaysSoInBothLanguages() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(Failure.Reason.itemGone.text(for: language),
                           UIStrings.actionFailedItemGone[language])
            XCTAssertFalse(Failure.Reason.itemGone.text(for: language).isEmpty)
        }
    }

    func testDetailPassesTheReasonThrough() {
        let failure = Failure(action: .refresh, subject: nil, reason: .output("brew: command not found"))
        XCTAssertEqual(failure.detail(for: .english), "brew: command not found")
        XCTAssertEqual(failure.detail(for: .turkish), "brew: command not found")
    }
}

/// The one failure the app offers a way out of: an upgrade that could not ask
/// for a password because it was running headless.
///
/// Homebrew uninstalls the old version before installing the new one, and a
/// cask whose uninstall stanza touches a system-owned path does that through
/// `sudo`. With no tty there is nobody to type the password, so the upgrade
/// dies *after* the download - every time, for the same packages, while the
/// rest update fine. Reported as a plain "command-failed" it reads as a
/// broken package; it is one password away from working.
final class NeedsTerminalFailureTests: XCTestCase {

    private typealias Failure = ToolkitController.ActionFailure

    private func outcome(stderr: String) -> ToolkitController.ProcessOutcome {
        ToolkitController.ProcessOutcome(exitCode: 1, reason: .exit, stderr: stderr)
    }

    /// What a real failing run left on stderr, verbatim.
    private static let realOutput = """
    ==> Downloading Cask files
    ✔ Cask obs (32.2.2)
    sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
    sudo: a password is required
    Error: obs: Failure while executing; `/usr/bin/sudo -E -- /usr/bin/xargs -0 -- /bin/rm -r -f --` exited with 1.
    """

    // MARK: - Recognising it

    func testTheRealFailureIsRecognised() {
        XCTAssertTrue(Failure.Reason.needsTerminal(after: outcome(stderr: Self.realOutput)))
    }

    func testEveryWaySudoSaysItIsRecognised() {
        // sudo's own wording, not brew's, so this holds whatever command
        // underneath asked for the escalation.
        let phrasings = [
            "sudo: a terminal is required to read the password",
            "sudo: a password is required",
            "sudo: no tty present and no askpass program specified"
        ]
        for phrasing in phrasings {
            XCTAssertTrue(Failure.Reason.needsTerminal(after: outcome(stderr: phrasing)), phrasing)
        }
    }

    func testAnOrdinaryBrewFailureIsNotMistakenForIt() {
        // The button offers to open a terminal window. Offering it for a
        // failure a terminal cannot fix wastes the user's time and their
        // trust in the next offer.
        let unrelated = [
            "Error: No such keg: /opt/homebrew/Cellar/awscli",
            "Error: Download failed on Cask 'obs' with message: Connection reset",
            "curl: (22) The requested URL returned error: 404"
        ]
        for stderr in unrelated {
            XCTAssertFalse(Failure.Reason.needsTerminal(after: outcome(stderr: stderr)), stderr)
        }
    }

    func testASilentFailureIsNotMistakenForIt() {
        XCTAssertFalse(Failure.Reason.needsTerminal(after: outcome(stderr: "")))
    }

    // MARK: - Which reason wins

    @MainActor
    func testItBeatsTheTokenTheRunFiled() {
        // The run files "command-failed", which is true and useless: brew did
        // exit non-zero. Only what it printed says the upgrade was one
        // password away from working.
        let record = ItemRunResult.parse(raw: "v1|1755400000|cask|obs|obs|fail|command-failed")
        let reason = ToolkitController.failureReason(record: record, outcome: outcome(stderr: Self.realOutput))
        guard case .needsTerminal = reason else {
            return XCTFail("classified as \(reason) instead of needsTerminal")
        }
    }

    @MainActor
    func testAnUnrelatedFailureStillReportsWhatTheRunFiled() {
        let record = ItemRunResult.parse(raw: "v1|1755400000|cask|obs|obs|fail|still-outdated")
        let reason = ToolkitController.failureReason(record: record, outcome: outcome(stderr: "Error: nope"))
        XCTAssertEqual(reason, .reported(.stillOutdated, detail: "Error: nope"))
    }

    // MARK: - What the user is told

    func testTheExplanationComesFirstAndKeepsWhatBrewPrinted() {
        // The cause in the app's own words, then the evidence: a user who
        // reads only the first sentence still knows what to do, and one who
        // reads all of it can still paste brew's line somewhere.
        let reason = Failure.Reason.needsTerminal(detail: Self.realOutput)
        for language in AppLanguage.allCases {
            let text = reason.text(for: language)
            XCTAssertTrue(text.hasPrefix(UIStrings.updateNeedsTerminalDetail[language]),
                          "\(language) does not explain itself first")
            XCTAssertTrue(text.hasSuffix(Self.realOutput), "\(language) dropped what brew printed")
        }
    }

    func testTheExplanationStandsOnItsOwnWithNoOutput() {
        let reason = Failure.Reason.needsTerminal(detail: "")
        for language in AppLanguage.allCases {
            XCTAssertEqual(reason.text(for: language), UIStrings.updateNeedsTerminalDetail[language])
        }
    }

    func testTheExplanationSaysTerminalInBothLanguages() {
        // The whole point of the sentence is telling the user where this has
        // to happen; a translation that loses the word loses the instruction.
        for language in AppLanguage.allCases {
            XCTAssertTrue(UIStrings.updateNeedsTerminalDetail[language].contains("Terminal"),
                          "\(language) never says where to run it")
        }
    }

    // MARK: - The offer

    func testTheFailureCarriesAButtonBackToTheRightRow() {
        let failure = Failure(
            action: .updateItem,
            subject: "obs",
            reason: .needsTerminal(detail: Self.realOutput),
            recovery: .runInTerminal(itemID: "brew:obs")
        )
        XCTAssertEqual(failure.recovery, .runInTerminal(itemID: "brew:obs"))
        for language in AppLanguage.allCases {
            let label = failure.recovery?.label(for: language) ?? ""
            XCTAssertFalse(label.isEmpty, "\(language) has no button label")
            XCTAssertTrue(label.contains("Terminal"), "\(language) button does not say Terminal")
        }
    }

    func testFailuresWithNoWayOutOfferNoButton() {
        // Most failures have nothing to offer, and a banner that always shows
        // a button teaches the user to ignore it.
        let failure = Failure(action: .refresh, subject: nil, reason: .output("boom"))
        XCTAssertNil(failure.recovery)
    }
}

/// The setting that decides whether a password-needing update opens a terminal
/// on its own or waits behind a button.
final class AutoOpenTerminalPreferenceTests: XCTestCase {

    private static let key = "com.macupdater.guide.autoOpenTerminalWhenRequired"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        super.tearDown()
    }

    @MainActor
    func testItIsOnForSomeoneWhoHasNeverTouchedIt() {
        // There is one answer to "shall I open a terminal for the password
        // prompt this run had nowhere to show" - the update cannot happen
        // anywhere else - so the default does it rather than asking.
        UserDefaults.standard.removeObject(forKey: Self.key)
        XCTAssertTrue(AppPreferences().autoOpenTerminalWhenRequired)
    }

    @MainActor
    func testTurningItOffSticks() {
        // The bug this guards: `bool(forKey:)` returns false for a key that
        // was never written, so a default of true read back through it would
        // ignore the user turning it off and quietly turn itself on again.
        UserDefaults.standard.set(false, forKey: Self.key)
        XCTAssertFalse(AppPreferences().autoOpenTerminalWhenRequired)
    }

    @MainActor
    func testTurningItBackOnSticks() {
        UserDefaults.standard.set(true, forKey: Self.key)
        XCTAssertTrue(AppPreferences().autoOpenTerminalWhenRequired)
    }
}
