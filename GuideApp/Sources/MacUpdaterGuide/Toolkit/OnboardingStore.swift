import Foundation
import Observation

/// What the setup sheet is showing, and the work it starts.
///
/// Kept apart from the view because more than one place opens the same sheet -
/// the window at launch and Settings › Advanced - and a sheet whose state
/// lives in one of them cannot be opened from the other.
@Observable
@MainActor
final class OnboardingStore {

    /// The app version whose setup sheet the user dismissed with "Later".
    ///
    /// A version rather than a flag: "not now" is an answer about this
    /// build's requirements, and a later build that needs something new has a
    /// different question to ask. A boolean here would mean one dismissal
    /// silences the sheet permanently, including the release that starts
    /// depending on a dependency the user does not have.
    private static let skippedVersionKey = "com.macupdater.guide.onboardingSkippedVersion"

    /// How much of the installer's output is kept.
    ///
    /// `brew install` on a machine with work to do prints thousands of lines,
    /// and all of them in a `Text` in a `ScrollView` is a window that stops
    /// redrawing. The tail is the part anybody reads: a failure explains
    /// itself at the end.
    private static let logLimit = 400

    var isPresented = false

    private(set) var states: [Dependency: DependencyState] = Dictionary(
        uniqueKeysWithValues: Dependency.allCases.map { ($0, .checking) }
    )

    /// Every line the running install has printed, oldest first.
    private(set) var log: [String] = []

    /// What is being installed right now, if anything. One at a time: these
    /// all end up talking to the same Homebrew, and two `brew` processes
    /// racing each other is how a lock file gets left behind.
    private(set) var installing: Dependency?

    /// Why the last install did not work, in the app's own words. Cleared
    /// when the next one starts.
    private(set) var failure: Localized?

    private var installTask: Task<Void, Never>?

    // MARK: - Opening and closing

    /// Whether anything required is unaccounted for.
    var hasBlockingGap: Bool { DependencyCheck.hasBlockingGap(states) }

    var isInstalling: Bool { installing != nil }

    /// Probes, and puts the sheet up only if this build cannot work as things
    /// stand and the user has not already said "later" to this same version.
    ///
    /// Called from the window's `.task`, so it runs once per launch and never
    /// blocks the first draw.
    func presentIfNeeded() async {
        await probe()
        guard hasBlockingGap else { return }
        guard UserDefaults.standard.string(forKey: Self.skippedVersionKey) != ToolkitVersion.appVersion else { return }
        isPresented = true
    }

    /// Opens the sheet on demand - Settings › Advanced, and the Uninstall
    /// page. Deliberately ignores the skipped version: this one was asked
    /// for.
    func present() {
        isPresented = true
        Task { await probe() }
    }

    /// "Later". Remembers the answer for this version and closes; nothing is
    /// cancelled, because the button is only ever offered when nothing is
    /// running.
    func skip() {
        UserDefaults.standard.set(ToolkitVersion.appVersion, forKey: Self.skippedVersionKey)
        isPresented = false
    }

    /// Closing with everything satisfied. No version is recorded - there was
    /// nothing to defer.
    func close() {
        isPresented = false
    }

    // MARK: - Probing

    func probe() async {
        states = await DependencyCheck.probe()
    }

    // MARK: - Installing

    /// Installs one dependency and re-probes when it is done.
    func install(_ dependency: Dependency, toolkit: ToolkitController) {
        start([dependency], toolkit: toolkit)
    }

    /// Installs everything with something wrong with it, in row order.
    func installMissing(toolkit: ToolkitController) {
        start(DependencyCheck.installable(from: states), toolkit: toolkit)
    }

    /// Stops the running install. The process is terminated through the
    /// stream's cancellation handler; the row goes back to whatever the
    /// re-probe finds, which is the truth about a half-finished install
    /// rather than a guess at it.
    func cancel() {
        installTask?.cancel()
    }

    private func start(_ dependencies: [Dependency], toolkit: ToolkitController) {
        guard !dependencies.isEmpty, installTask == nil else { return }

        failure = nil
        log = []

        installTask = Task { [weak self] in
            guard let self else { return }

            for dependency in dependencies {
                if Task.isCancelled { break }
                let outcome = await self.run(dependency)
                if case .failed(let reason) = outcome {
                    self.failure = reason.message
                    // Stop at the first failure rather than carrying on: the
                    // rest of the list is usually downstream of it (there is
                    // no `brew install mas` without Homebrew), and a queue
                    // that keeps going produces a log of failures whose real
                    // cause is the first.
                    break
                }
                if outcome == .cancelled { break }
            }

            self.installing = nil
            self.installTask = nil

            // Homebrew appearing changes what the engine can do, and the app
            // caches where it resolved the script to - so both are refreshed
            // here rather than at the next launch.
            toolkit.relocateScript()
            toolkit.reload()
            await self.probe()
        }
    }

    /// Drives one install's event stream onto the screen.
    private func run(_ dependency: Dependency) async -> BootstrapOutcome {
        installing = dependency
        // The row's state is deliberately left alone while this runs. Setting
        // it to `.checking` here put a spinner on the row - which `installing`
        // already does - at the cost of making `hasBlockingGap` false for the
        // duration, so the sheet spent every install claiming everything was
        // installed and offering "Done" as the way out. What is true until the
        // re-probe says otherwise is the state it had before.

        var outcome: BootstrapOutcome = .cancelled

        for await event in BootstrapInstaller.install(dependency) {
            switch event {
            case .log(let line):
                append(line)
            case .finished(let result):
                outcome = result
            }
        }

        return outcome
    }

    private func append(_ line: String) {
        guard !line.isEmpty else { return }
        log.append(line)
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }
}
