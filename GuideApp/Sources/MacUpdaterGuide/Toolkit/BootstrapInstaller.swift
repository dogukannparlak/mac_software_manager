import Foundation

/// Installing the things this project does *not* ship.
///
/// There are exactly two, and the engine is not one of them - it lives inside
/// the app and runs from there (see `BundledEngine`). What is left is Homebrew
/// and `mas`: third-party software, on the user's Mac, which the app can offer
/// to install but has no business installing unannounced.
///
/// The rule this file is built around: **the app never asks for a password and
/// never runs `sudo`.** A GUI application that puts up a password box is
/// indistinguishable from one phishing for it, and there is no way for the
/// user to tell which they are looking at. So Homebrew's installer - the only
/// thing here needing administrator rights - is handed to Terminal.app, where
/// the prompt comes from a program the user launched and can read. The app
/// watches for the result instead of asking for the means to produce it.

/// What an install reports while it works.
///
/// A plain `AsyncStream<String>` of log lines cannot say whether the thing
/// worked, and the sheet needs that for the green tick and for offering
/// "Try Again". The lines are still the bulk of it - `.log` is every line the
/// process printed, in order, as it printed it.
enum BootstrapEvent: Sendable {
    /// One line of output, for the log the "Details" disclosure shows.
    case log(String)
    /// How it ended. Always the last event.
    case finished(BootstrapOutcome)
}

enum BootstrapOutcome: Equatable, Sendable {
    case installed
    case cancelled
    case failed(BootstrapFailure)

    var didInstall: Bool { self == .installed }
}

/// Why an install did not happen, in the app's own words.
///
/// Each of these is something the app worked out for itself rather than read
/// off a process, which is what makes them translatable - the shell output
/// that goes with them is English and stays in the log where it belongs.
enum BootstrapFailure: Equatable, Sendable {
    /// `brew install` ended badly. The log has its account.
    case installFailed
    /// Something needs Homebrew and there is none.
    case homebrewMissing
    /// Terminal.app could not be opened, so there is nowhere to run
    /// Homebrew's installer.
    case terminalFailed
    /// The Terminal window opened and Homebrew never appeared - closed,
    /// cancelled, or failed in front of the user.
    case homebrewNotDetected

    var message: Localized {
        switch self {
        case .installFailed:
            return Localized(
                "The installation did not finish. Open Details below to see what it reported.",
                "Kurulum tamamlanamadı. Ne bildirdiğini görmek için aşağıdan Ayrıntılar'ı açın."
            )
        case .homebrewMissing:
            return Localized(
                "Homebrew has to be installed first - this is installed through it.",
                "Önce Homebrew kurulmalı; bu, onun üzerinden kuruluyor."
            )
        case .terminalFailed:
            return Localized(
                "Terminal could not be opened, so Homebrew's installer has nowhere to run.",
                "Terminal açılamadı; Homebrew'un kurulum betiğini çalıştıracak bir yer yok."
            )
        case .homebrewNotDetected:
            return Localized(
                "Homebrew still is not here. Finish its installation in Terminal, then press Try Again.",
                "Homebrew hâlâ yok. Kurulumunu Terminal'de tamamlayıp Yeniden Dene'ye basın."
            )
        }
    }
}

enum BootstrapInstaller {

    /// Homebrew's own published installer. Deliberately not pinned to a
    /// checksum: Homebrew publishes none for it, which is exactly why this is
    /// only ever *shown* to the user in a terminal rather than run by the app.
    static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    // MARK: - The install

    /// Installs one dependency, reporting as it goes.
    ///
    /// Cancellable: dropping the stream, or cancelling the task iterating it,
    /// terminates whatever process is running and ends with `.cancelled`.
    static func install(_ dependency: Dependency) -> AsyncStream<BootstrapEvent> {
        AsyncStream { continuation in
            let emit: @Sendable (BootstrapEvent) -> Void = { continuation.yield($0) }

            // Detached rather than a plain `Task`: this closure runs in the
            // caller's context, which is `OnboardingStore` on the main actor,
            // and an inherited main-actor task would run every one of these
            // steps there. Nothing in them needs it - they wait on processes
            // and a clock - and the state they feed is updated on the main
            // actor anyway, by the sheet consuming this stream.
            let task = Task.detached(priority: .userInitiated) {
                let outcome: BootstrapOutcome
                switch dependency {
                case .homebrew: outcome = await installHomebrew(emit: emit)
                case .mas:      outcome = await installMas(emit: emit)
                }
                continuation.yield(.finished(Task.isCancelled ? .cancelled : outcome))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Homebrew

    /// Opens Homebrew's own installer in Terminal.app and waits for it to
    /// appear.
    ///
    /// This is the one dependency the app cannot install itself, and the
    /// reason is worth being explicit about: Homebrew's installer runs `sudo`.
    /// Collecting that password in a SwiftUI sheet would teach the user that
    /// applications asking for their administrator password is normal, which
    /// is the exact habit every credential-phishing Mac malware campaign
    /// relies on. In Terminal the prompt comes from `sudo` itself, in a window
    /// the user opened, and they can read the command that is about to run.
    ///
    /// So the app does the only honest thing available to it: it types the
    /// command out in a terminal and then watches the filesystem.
    private static func installHomebrew(emit: @Sendable @escaping (BootstrapEvent) -> Void) async -> BootstrapOutcome {
        emit(.log("Opening Terminal to run Homebrew's official installer:"))
        emit(.log(homebrewInstallCommand))

        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(homebrewInstallCommand))"
        end tell
        """

        let status = await run(executable: "/usr/bin/osascript", arguments: ["-e", script], emit: emit)
        guard status == 0 else { return .failed(.terminalFailed) }

        emit(.log("Waiting for Homebrew to appear. Enter your password in the Terminal window."))
        return await waitForHomebrew(emit: emit)
    }

    /// Polls for the `brew` binary until it shows up.
    ///
    /// Polling rather than watching the Terminal window: the installer is a
    /// process this app did not start and has no handle on, and what actually
    /// matters is not whether that window closed but whether `brew` is now on
    /// disk - a user who installs it some other way while this waits is
    /// noticed just the same.
    ///
    /// The cap exists so a window someone abandoned does not leave a spinner
    /// turning for the rest of the session. It is generous because a first
    /// Homebrew install downloads the Command Line Tools, which on a slow
    /// connection is genuinely a quarter of an hour.
    private static func waitForHomebrew(
        emit: @Sendable @escaping (BootstrapEvent) -> Void,
        pollInterval: Duration = .seconds(3),
        limit: Duration = .seconds(30 * 60)
    ) async -> BootstrapOutcome {
        let deadline = ContinuousClock.now.advanced(by: limit)
        var polls = 0

        while ContinuousClock.now < deadline {
            if DependencyCheck.executablePath(named: "brew") != nil {
                emit(.log("Homebrew is here."))
                return .installed
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return .cancelled
            }
            polls += 1
            // Every tenth poll, so a wait that is working looks different
            // from one that has died - without a line every three seconds
            // burying the instruction above it.
            if polls.isMultiple(of: 10) {
                emit(.log("Still waiting for Homebrew..."))
            }
        }

        return .failed(.homebrewNotDetected)
    }

    /// AppleScript string literals take the same two escapes as C. Anything
    /// else in the command is left alone - it is a shell command, and mangling
    /// it here would be a bug rather than a safety measure.
    static func appleScriptEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - mas

    /// `brew install mas` - a formula, so it lands in a prefix the user
    /// already owns and there is nothing to ask a password for. Headless,
    /// with its output on screen.
    private static func installMas(emit: @Sendable @escaping (BootstrapEvent) -> Void) async -> BootstrapOutcome {
        guard let brew = DependencyCheck.executablePath(named: "brew") else {
            return .failed(.homebrewMissing)
        }

        emit(.log("\(brew) install mas"))
        let status = await run(
            executable: brew,
            arguments: ["install", "mas"],
            // The same three the engine sets: no implicit `brew update` on a
            // query, no shell hints aimed at a terminal, and no ANSI colour
            // codes in a log that is rendered as plain text.
            environment: [
                "HOMEBREW_NO_AUTO_UPDATE": "1",
                "HOMEBREW_NO_ENV_HINTS": "1",
                "HOMEBREW_NO_COLOR": "1"
            ],
            emit: emit
        )

        if Task.isCancelled { return .cancelled }
        return status == 0 ? .installed : .failed(.installFailed)
    }
}
