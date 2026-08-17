import Foundation
import Observation

/// Drives the zsh toolkit and keeps the current snapshot in memory.
///
/// The app never reimplements what the scripts already do - it calls them and
/// reads the files they produce. That keeps a single source of truth for what
/// "outdated" means, whether you are looking at the menu bar or a terminal.
@Observable
@MainActor
final class ToolkitController {

    private(set) var snapshot = UpdateSnapshot()
    private(set) var progress: UpdateProgress?
    private(set) var isRefreshing = false
    private(set) var scriptURL: URL?
    private(set) var lastMessage: String?

    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    let preferences: AppPreferences

    init(preferences: AppPreferences) {
        self.preferences = preferences
        scriptURL = ToolkitPaths.locateScript()
        reload()
    }

    var isToolkitInstalled: Bool { ToolkitPaths.isInstalled && scriptURL != nil }

    // MARK: - Reading

    /// Re-reads the cache. Cheap: no processes, no network.
    func reload() {
        snapshot = UpdateSnapshot.load()
        progress = UpdateProgress.load()
    }

    /// True while an update run is working, whether it was started from here
    /// or straight from a terminal.
    var isUpdating: Bool { progress?.isRunning == true }

    /// Watches the progress file for as long as a run is in flight, so the menu
    /// bar can name the package currently being installed.
    private func startProgressWatch() {
        guard progressTask == nil else { return }

        progressTask = Task { [weak self] in
            var quietTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self else { return }

                let latest = await MainActor.run { () -> UpdateProgress? in
                    self.progress = UpdateProgress.load()
                    return self.progress
                }

                if latest?.isRunning == true {
                    quietTicks = 0
                } else {
                    quietTicks += 1
                    // Give the run a moment to finish writing, then reload the
                    // cache once so the new versions show up.
                    if quietTicks >= 4 {
                        await MainActor.run {
                            self.snapshot = UpdateSnapshot.load()
                            self.progressTask = nil
                        }
                        return
                    }
                }
            }
        }
    }

    func relocateScript() {
        scriptURL = ToolkitPaths.locateScript()
    }

    // MARK: - Refreshing

    /// Rebuilds the cache by running the script, then re-reads it.
    func refresh(force: Bool = true) {
        guard !isRefreshing else { return }
        guard let script = scriptURL else {
            lastMessage = "toolkit-missing"
            return
        }

        isRefreshing = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await Self.run(script: script, arguments: ["refresh_cache", force ? "force" : "auto"])
            await MainActor.run {
                guard let self else { return }
                self.isRefreshing = false
                self.reload()
            }
        }
    }

    /// Runs an update.
    ///
    /// Background by default: the same `run <scope>` the terminal path would
    /// execute, just without a terminal window - the in-app progress bar is
    /// the feedback instead. Turning on Settings → General → "Run updates in
    /// Terminal" switches to the old behaviour (`launch_update`, opens the
    /// configured terminal) for anyone who wants to watch or stop it there.
    ///
    /// The two paths cannot share one code path: the terminal one launches a
    /// short-lived command that just opens a window, so it is fine to await
    /// its exit before watching for progress. The headless one *is* the
    /// multi-minute update - awaiting its exit before starting the progress
    /// watch would mean the watch starts after the run has already finished.
    func launchUpdate(scope: String = "all") {
        guard let script = scriptURL else { return }

        if preferences.runUpdatesInTerminal {
            Task {
                await Self.run(script: script, arguments: ["launch_update", scope])
                await MainActor.run { self.startProgressWatch() }
            }
        } else {
            Self.runDetached(script: script, arguments: ["run", scope])
            startProgressWatch()
        }
    }

    func installApp(named name: String, dryRun: Bool) {
        guard let script = scriptURL else { return }
        let liveOrDry = dryRun ? "dry" : "live"

        if preferences.runUpdatesInTerminal {
            Task {
                await Self.run(script: script, arguments: ["install_app", name, liveOrDry])
                await MainActor.run { self.startProgressWatch() }
            }
        } else {
            Self.runDetached(script: script, arguments: ["run", "install", name, liveOrDry])
            startProgressWatch()
        }
    }

    /// Update a single package or App Store app.
    func updateSingle(_ item: UpdateItem) {
        guard let script = scriptURL else { return }

        let kind: String
        let identifier: String
        switch item.source {
        case .formula: kind = "brew"; identifier = item.name
        case .cask: kind = "cask"; identifier = item.name
        case .appStore, .manual: kind = "mas"; identifier = item.id.replacingOccurrences(of: "mas:", with: "").replacingOccurrences(of: "manual:", with: "")
        case .sparkle, .github: installApp(named: item.name, dryRun: false); return
        }

        let details = [kind, identifier, item.name, item.currentVersion, item.newVersion]

        if preferences.runUpdatesInTerminal {
            Task {
                await Self.run(script: script, arguments: ["update_app"] + details)
                await MainActor.run { self.startProgressWatch() }
            }
        } else {
            Self.runDetached(script: script, arguments: ["run", "single"] + details)
            startProgressWatch()
        }
    }

    /// Pulls the latest Homebrew + tap metadata, the equivalent of "check for
    /// updates" for Homebrew itself - there is no version to compare against
    /// the way an app has, so this is what "checking" means for it. Always
    /// headless: it is a quick, one-shot check, the same kind of action as
    /// "Refresh Now" on the Updates page, not a multi-package run someone
    /// would want to watch in a terminal.
    func checkHomebrewDatabase() {
        guard let script = scriptURL else { return }
        Self.runDetached(script: script, arguments: ["brew_update"])
        startProgressWatch()
    }

    /// Hide something from the update list.
    func ignore(type: String, id: String, name: String) {
        guard let script = scriptURL else { return }
        Task {
            await Self.run(script: script, arguments: ["ignore_app", type, id, name])
            await MainActor.run { self.reload() }
        }
    }

    func unignore(type: String, id: String, name: String) {
        guard let script = scriptURL else { return }
        Task {
            await Self.run(script: script, arguments: ["unignore_app", type, id, name])
            await MainActor.run { self.reload() }
        }
    }

    /// Ask the toolkit whether a newer version of itself is available.
    func checkToolkitUpdate() {
        guard let script = scriptURL else { return }
        Task {
            await Self.run(script: script, arguments: ["check_updates"])
        }
    }

    var toolkitUpdatePending: Bool {
        FileManager.default.fileExists(
            atPath: ToolkitPaths.supportDirectory
                .appending(path: ".plugin_update_pending")
                .path(percentEncoded: false)
        )
    }

    func installToolkitUpdate() {
        launchUpdate(scope: "plugin")
    }

    // MARK: - Periodic refresh

    /// Replaces the plugin-filename trick the SwiftBar version used for its
    /// interval: the schedule is now just a timer inside this app.
    func startScheduler() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let minutes = await MainActor.run { self.preferences.refreshMinutes }
                try? await Task.sleep(for: .seconds(minutes * 60))
                guard !Task.isCancelled else { return }
                await MainActor.run { self.refresh(force: false) }
            }
        }
    }

    func stopScheduler() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Process helper

    /// Starts a process and returns immediately, without waiting for it to
    /// exit. For the headless update path, where the process itself runs for
    /// as long as the update takes - the progress file, not this call's
    /// return, is what tells the caller when it is done.
    private static func runDetached(script: URL, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [script.path(percentEncoded: false)] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func run(script: URL, arguments: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = [script.path(percentEncoded: false)] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            process.terminationHandler = { _ in
                continuation.resume()
            }

            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }
    }
}
