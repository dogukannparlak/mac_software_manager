import Foundation

/// Driving `uninstall.sh` from the app instead of from a terminal.
///
/// The script stays the thing that removes files - it is the only place that
/// knows what the support folder is called and which defaults domain the app
/// writes. What changes here is who answers
/// its questions: the `[y/N]` walkthrough assumes someone is reading a
/// terminal, and nobody who installed the app from a disk image expects to
/// open one. So the app asks with checkboxes and runs the script with the step
/// flags that match, which turns its prompts off entirely.

/// One removable thing, matching a step flag in `uninstall.sh`.
///
/// The raw values *are* the flag names, so the two cannot drift apart by a
/// typo in a string literal somewhere. The script rejects an unknown option
/// with exit 2, which makes a real mismatch loud rather than a silent no-op.
enum UninstallStep: String, CaseIterable, Identifiable, Sendable {
    case app
    case loginItem = "login-item"
    case data
    case prefs
    case mas

    var id: String { rawValue }

    var flag: String { "--\(rawValue)" }

    var symbol: String {
        switch self {
        case .app:       return "app.badge"
        case .loginItem: return "power"
        case .data:      return "folder"
        case .prefs:     return "slider.horizontal.3"
        case .mas:       return "bag"
        }
    }

    var title: Localized {
        switch self {
        case .app:
            return Localized("This application", "Bu uygulama")
        case .loginItem:
            return Localized("Leftover launch agent", "Artık kalmış launch agent")
        case .data:
            return Localized("Settings, history and cache", "Ayarlar, geçmiş ve önbellek")
        case .prefs:
            return Localized("Application preferences", "Uygulama tercihleri")
        case .mas:
            return Localized("mas (App Store command line tool)", "mas (App Store komut satırı aracı)")
        }
    }

    var explanation: Localized {
        switch self {
        case .app:
            return Localized(
                "The app bundle itself. Ticking this closes the app once everything else is done.",
                "Uygulama paketinin kendisi. Bunu işaretlerseniz geri kalan biter bitmez uygulama kapanır."
            )
        case .loginItem:
            return Localized(
                "A launch agent from an older install. The app's own login item is switched off separately.",
                "Eski bir kurulumdan kalan launch agent. Uygulamanın kendi giriş ögesi ayrıca kapatılır."
            )
        case .data:
            return Localized(
                "Everything the toolkit stores about your Mac: settings, the ignore list, update history and the cached scan.",
                "Aracın Mac'iniz hakkında sakladığı her şey: ayarlar, yoksayma listesi, güncelleme geçmişi ve önbellekteki tarama."
            )
        case .prefs:
            return Localized(
                "Chosen language, window state and the other preferences this app keeps for itself.",
                "Seçilen dil, pencere durumu ve bu uygulamanın kendisi için sakladığı diğer tercihler."
            )
        case .mas:
            return Localized(
                "Installed by setup_mac.sh to check App Store apps. Other tools on your Mac may use it too.",
                "App Store uygulamalarını kontrol etmek için setup_mac.sh tarafından kuruldu. Mac'inizdeki başka araçlar da kullanıyor olabilir."
            )
        }
    }

    /// Which boxes start ticked. The four things this toolkit put there and
    /// nothing else uses; `mas` is a general-purpose tool someone may well want
    /// to keep, so it starts off and has to be chosen.
    var isCheckedByDefault: Bool {
        switch self {
        case .app, .loginItem, .data, .prefs: return true
        case .mas: return false
        }
    }
}

/// What the script's `--list` says about one step.
struct UninstallItem: Identifiable, Sendable {
    let step: UninstallStep
    /// Whether the thing is actually on disk. Absent steps are still listed,
    /// disabled: "nothing to remove" is information, and a row that quietly
    /// vanishes reads as a bug.
    let isPresent: Bool
    /// The path, bundle identifier or package name this step would remove.
    let detail: String

    var id: String { step.rawValue }
}

/// How one step ended, exactly as the script reported it.
enum UninstallOutcome: String, Sendable {
    case removed
    case skipped
    case failed
    case dryrun
}

struct UninstallResult: Identifiable, Sendable {
    let step: UninstallStep
    let outcome: UninstallOutcome
    let detail: String

    var id: String { step.rawValue }
}

enum UninstallPlan {

    /// The uninstaller to drive.
    ///
    /// An installed copy wins when there is one: it is the script that matches
    /// whatever that installation put on disk, including layouts predating
    /// this app. Otherwise the app's own copy is used, which is what makes the
    /// Uninstall page work on a Mac where `setup_mac.sh` never ran - the
    /// common case now that the engine ships inside the app.
    static var scriptURL: URL? {
        let installed = ToolkitPaths.supportDirectory.appending(path: "uninstall.sh")
        if FileManager.default.isReadableFile(atPath: installed.path(percentEncoded: false)) {
            return installed
        }
        return BundledEngine.uninstallScriptURL
    }

    /// Asks the script what is present.
    ///
    /// Every step comes back in declaration order whether the script mentioned
    /// it or not, so the page's rows never reshuffle between refreshes and a
    /// step the script has dropped shows up as "nothing to remove" rather than
    /// disappearing.
    static func list(script: URL, appBundle: URL) async -> [UninstallItem] {
        let output = await run(
            script: script,
            arguments: ["--list", "--app-path", appBundle.path(percentEncoded: false)]
        )

        var found: [UninstallStep: UninstallItem] = [:]
        for line in output.stdout.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, fields[0] == "ITEM",
                  let step = UninstallStep(rawValue: fields[1]) else { continue }
            found[step] = UninstallItem(
                step: step,
                isPresent: fields[2] == "yes",
                detail: fields[3].trimmingCharacters(in: .whitespaces)
            )
        }

        return UninstallStep.allCases.map { step in
            found[step] ?? UninstallItem(step: step, isPresent: false, detail: "")
        }
    }

    /// Runs the chosen steps with no questions asked, and reads back one
    /// result line per step.
    ///
    /// A step the script never reported on comes back as `.skipped` rather
    /// than being dropped: the page has to be able to say something about
    /// every box that was ticked, including one whose step died before it
    /// printed anything.
    static func run(
        script: URL,
        appBundle: URL,
        steps: [UninstallStep],
        dryRun: Bool
    ) async -> (results: [UninstallResult], failure: String?) {
        guard !steps.isEmpty else { return ([], nil) }

        var arguments = steps.map(\.flag)
        arguments += ["--app-path", appBundle.path(percentEncoded: false), "--quiet"]
        if dryRun { arguments.append("--dry-run") }

        let output = await run(script: script, arguments: arguments)

        var reported: [UninstallStep: UninstallResult] = [:]
        for line in output.stdout.split(separator: "\n") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4, fields[0] == "RESULT",
                  let step = UninstallStep(rawValue: fields[1]),
                  let outcome = UninstallOutcome(rawValue: fields[2]) else { continue }
            reported[step] = UninstallResult(step: step, outcome: outcome, detail: fields[3])
        }

        let results = steps.map { step in
            reported[step] ?? UninstallResult(step: step, outcome: .skipped, detail: "")
        }

        // A non-zero exit with nothing on stderr is not worth showing: the
        // per-step rows already say what happened, in the reader's own
        // language rather than in shell English.
        let failure = output.succeeded || output.stderr.isEmpty ? nil : output.stderr
        return (results, failure)
    }

    // MARK: - Process

    private struct Output {
        let stdout: String
        let stderr: String
        let succeeded: Bool
    }

    /// A plain run-to-completion process, unlike `ToolkitController`'s: none of
    /// this belongs on the progress banner, and the whole answer is what the
    /// script printed.
    private static func run(script: URL, arguments: [String]) async -> Output {
        await withCheckedContinuation { (continuation: CheckedContinuation<Output, Never>) in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = [script.path(percentEncoded: false)] + arguments
            let environment = BundledEngine.environment
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(environment) { _, new in new }
            }
            // The script asks nothing in this mode, but a read on an inherited
            // descriptor would hang forever if one ever slipped through.
            // /dev/null turns that into an instant end of file instead.
            process.standardInput = FileHandle.nullDevice

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            // Drained while the process runs, not after: a 64 KB pipe nobody
            // is reading blocks the writer, and `brew uninstall` prints more
            // than that. See StderrDrain.
            let outDrain = StderrDrain(draining: stdoutPipe)
            let errDrain = StderrDrain(draining: stderrPipe)

            process.terminationHandler = { finished in
                continuation.resume(returning: Output(
                    stdout: outDrain.text(),
                    stderr: errDrain.text(),
                    succeeded: finished.terminationReason == .exit && finished.terminationStatus == 0
                ))
            }

            do {
                try process.run()
            } catch {
                outDrain.stopDraining()
                errDrain.stopDraining()
                continuation.resume(returning: Output(
                    stdout: "",
                    stderr: error.localizedDescription,
                    succeeded: false
                ))
            }
        }
    }
}
