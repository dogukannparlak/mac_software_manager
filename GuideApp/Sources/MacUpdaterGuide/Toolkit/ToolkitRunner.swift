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

    /// The last thing the user asked for that failed with nothing else on
    /// screen to say so - rendered by `FailureBanner` until dismissed, and
    /// replaced by any later failure.
    ///
    /// This replaces a `lastMessage: String?` that six paths wrote to and no
    /// view ever read: a refresh that could not run, an ignore that did not
    /// take, a toolkit check that failed - all of them silent. One of the six
    /// wrote the raw token "toolkit-missing", which had no translation
    /// anywhere, which is proof enough that nothing was reading it.
    ///
    /// A bulk run does not report here: it has the progress banner, and
    /// `reportFailure` already writes its failure into that.
    private(set) var lastFailure: ActionFailure?

    /// A failed action in a shape the UI can render: what was being done,
    /// which is the app's own wording and therefore translated, and why it
    /// failed, which is whatever brew/mas/the script printed and therefore
    /// is not.
    struct ActionFailure: Identifiable, Equatable, Sendable {

        enum Action: Equatable, Sendable {
            case refresh
            case homebrewCheck
            /// A bulk run (or a terminal window) that could not be started.
            case startRun
            case updateItem
            case hideItem
            case unhideItem
            case toolkitUpdateCheck
        }

        /// `toolkitMissing` is the one reason the app works out for itself,
        /// so it is the one reason that can be worded in the user's language.
        enum Reason: Equatable, Sendable {
            case toolkitMissing
            case output(String)
            /// The run ended without a word and without a bad exit status,
            /// and the item is still outdated - `run single` reports success
            /// either way, so there is genuinely nothing to quote.
            case noOutput
            /// The reason the run itself filed, as one of the stable tokens
            /// of the single-item result contract (CACHE_FORMAT.md), plus
            /// whatever it printed on the way there.
            ///
            /// This is the one reason that is both specific *and*
            /// translatable: the token says which of a closed set of things
            /// went wrong, so the app can word it, while `detail` keeps the
            /// stderr that says which package, which URL, which error - and
            /// which is brew's or mas's English either way.
            case reported(ItemRunResult.Reason, detail: String)

            /// What a finished process leaves to show: what it printed, or
            /// its exit status when it printed nothing.
            static func from(_ outcome: ProcessOutcome) -> Reason {
                if outcome.succeeded, outcome.stderr.isEmpty { return .noOutput }
                return .output(outcome.summary)
            }

            func text(for language: AppLanguage) -> String {
                switch self {
                case .toolkitMissing: return UIStrings.toolkitNotFoundDetail[language]
                case .output(let text): return text
                case .noOutput: return UIStrings.actionFailedNoReason[language]
                case .reported(let reported, let detail):
                    // A token with no copy of its own (an unknown one from a
                    // newer toolkit, or one whose whole content is the
                    // output) leaves the printed detail to speak for itself.
                    guard let headline = reported.label?[language] else {
                        return detail.isEmpty ? UIStrings.actionFailedNoReason[language] : detail
                    }
                    return detail.isEmpty ? headline : headline + "\n" + detail
                }
            }
        }

        let id = UUID()
        let action: Action
        /// The package or app this was about, where it was about one.
        let subject: String?
        let reason: Reason

        /// "Could not refresh the update list" / "Rectangle güncellenemedi"
        func title(for language: AppLanguage) -> String {
            switch action {
            case .refresh: return UIStrings.actionFailedRefresh[language]
            case .homebrewCheck: return UIStrings.actionFailedHomebrewCheck[language]
            case .startRun: return UIStrings.actionFailedStartRun[language]
            case .updateItem: return named(UIStrings.actionFailedUpdateItemFormat, language)
            case .hideItem: return named(UIStrings.actionFailedHideItemFormat, language)
            case .unhideItem: return named(UIStrings.actionFailedUnhideItemFormat, language)
            case .toolkitUpdateCheck: return UIStrings.actionFailedToolkitUpdateCheck[language]
            }
        }

        func detail(for language: AppLanguage) -> String {
            reason.text(for: language)
        }

        /// The subject-carrying titles all read "<verb> %@" - with no subject
        /// to name (which no caller should produce, but a format string with
        /// nothing to fill it in is not worth crashing over) the generic
        /// "could not start" wording is the honest fallback.
        private func named(_ format: Localized, _ language: AppLanguage) -> String {
            guard let subject else { return UIStrings.actionFailedStartRun[language] }
            return String(format: format[language], subject)
        }
    }

    /// Outcome of a single-item "Update" button press, per `UpdateItem.id` -
    /// the App Store-style state shown on that item's own row (queued, then a
    /// spinner while running, then a transient "Updated"/"Update failed").
    /// Separate from `progress`, which is the one shared *bulk* run ("Update
    /// Everything", the Homebrew database check, the toolkit self-update) and
    /// says nothing about any one row.
    enum ItemUpdateStatus: Equatable, Sendable {
        case queued
        case updating
        case succeeded
        case failed
    }
    private(set) var itemStatuses: [String: ItemUpdateStatus] = [:]
    /// Why a row's own update failed, per `UpdateItem.id`, for as long as its
    /// failed badge is up.
    ///
    /// `run single` exits 0 whether or not the package actually updated -
    /// success is decided by re-reading the outdated list (`finishActiveItem`)
    /// - so the process outcome used to be dropped on the floor with `_ in`.
    /// That left the row saying "Güncelleme başarısız" with the stderr that
    /// explains it discarded, and no way for anyone to find out why.
    private(set) var itemFailureReasons: [String: ActionFailure.Reason] = [:]
    /// Kept alongside `itemStatuses`: a successful update removes the item
    /// from `snapshot.items` (it is no longer outdated), but its row still
    /// needs the item's data to render while its "Updated" badge is showing.
    private(set) var recentItemsByID: [String: UpdateItem] = [:]

    /// Simulated 0...1 completion for a row's own progress bar, per
    /// `UpdateItem.id`. Neither `brew` nor `mas` expose a real per-package
    /// percentage the way a single download does, so this eases toward ~92%
    /// over a plausible duration instead - a smooth, one-directional fill
    /// with a number on it, rather than the bouncing indeterminate
    /// animation `ProgressView()` draws with no `value` at all. It only
    /// ever reaches 100% when the row actually resolves.
    private(set) var itemFractions: [String: Double] = [:]
    private var fractionTasks: [String: Task<Void, Never>] = [:]

    /// One entry per currently-running headless single-item update, keyed by
    /// `UpdateItem.id` - up to `preferences.maxConcurrentUpdates` at once.
    /// Never used for terminal-mode runs (see `updateSingle`/`installApp`)
    /// or for the bulk run (`bulkProcess`, below).
    private var activeProcesses: [String: Process] = [:]
    /// Which run currently owns each row, so a per-item process that has been
    /// cancelled - or superseded by the user pressing Update again on the
    /// same row - can be told apart from the one that row is actually
    /// waiting on. A row's token is cleared the moment its run stops being
    /// the current one, and `finishActiveItem` refuses to touch a row whose
    /// token has moved on: that is what lets `cancelItemUpdate` tear a row
    /// down immediately instead of hoping a process that may be ignoring
    /// SIGTERM gets around to exiting.
    private var itemRunTokens: [String: Int] = [:]
    private var nextItemRunToken = 0
    /// FIFO of item ids waiting for a free concurrency slot, plus what to
    /// actually run for each once its turn comes - `drainQueue()` pops both
    /// together. A plain array is fine at this scale (a handful of rows).
    private var queuedItemIDs: [String] = []
    private var queuedLaunchers: [String: () -> Void] = [:]
    /// Runs for exactly as long as `queuedItemIDs` is not empty - see
    /// `syncQueueDrainWatch()`.
    private var queueDrainTask: Task<Void, Never>?

    /// The item a just-launched *terminal-mode* single-item run belongs to.
    /// Terminal mode stays single-flight (one visible window, watched
    /// directly) rather than joining the concurrency queue above, so it still
    /// needs the older "watch the shared progress file, resolve on quiet"
    /// approach `startProgressWatch()` uses.
    private var activeSingleItem: UpdateItem?
    /// When that run was launched - what tells a result record it wrote from
    /// one an earlier run of the same item left behind, exactly as
    /// `watchStartedAt` does for the shared progress file.
    private var activeSingleItemStartedAt: Date?
    /// The bulk run's own `Process`, kept only so `cancelUpdate()` has
    /// something to signal - never set for a terminal-mode run, where this
    /// object is just the short-lived launcher that opened the terminal
    /// window, not the actual work, and never set for a per-item run, which
    /// tracks itself in `activeProcesses` instead.
    private var bulkProcess: Process?
    /// Set right before `cancelUpdate()` signals `bulkProcess`, so its
    /// termination handler knows the exit was requested and skips reporting
    /// it as a crash - overwriting the "Cancelled" state already written.
    private var cancelledBulkRun = false

    private var refreshTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    /// When the current progress watch began, or `nil` when none is running.
    /// Anything written to the shared progress file before this belongs to an
    /// earlier run - see `ProgressWatch` and `UpdateProgress.modified`.
    private var watchStartedAt: Date?
    /// When this app last concluded on its own that the shared run was over:
    /// a bulk process of ours died, or the user cancelled one. Neither gets
    /// to write its ending, so the entry left in the file still says
    /// "running" - and every later read of that file (a reload, the queue's
    /// own poll) would otherwise put the run this app just reported as dead
    /// straight back on the banner, and park the queue behind it again until
    /// the entry aged out. Cleared when a new run starts watching.
    private var resolvedRunAt: Date?

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
        refreshProgressFromDisk()
    }

    /// Re-reads just the progress entry - what someone else's run (or a run
    /// that died) has left in the shared file since this app last looked.
    ///
    /// A run being watched owns `progress` (see `startProgressWatch`): an
    /// entry older than that watch is an earlier run's, and letting a read
    /// that happens to land mid-startup put it back on the banner would undo
    /// exactly what the watch is there to prevent.
    private func refreshProgressFromDisk() {
        let latest = UpdateProgress.load()
        if let started = watchStartedAt, (latest?.modified ?? .distantPast) < started { return }
        // Same rule for a run this app has already buried: only an entry
        // written *after* that verdict can be a run still worth showing.
        if let resolved = resolvedRunAt, (latest?.modified ?? .distantPast) <= resolved { return }
        progress = latest
    }

    /// True while the *bulk* run is working, whether it was started from here
    /// or straight from a terminal, or while any concurrent single-item run
    /// is active or queued. Gates the page-level actions (Update Everything,
    /// Refresh Now, Check Homebrew Now) - those touch the same shared state
    /// every in-flight run is using, bulk or not.
    var isUpdating: Bool { progress?.isRunning == true || !activeProcesses.isEmpty || !queuedItemIDs.isEmpty }

    /// True only for a headless bulk run - there is no process here to signal
    /// for a terminal-mode run (the launcher that opened the terminal window
    /// has already exited), and someone watching a terminal window can
    /// already stop it there directly.
    var canCancelCurrentRun: Bool { bulkProcess?.isRunning == true }

    /// True while this row's own run is something the app can actually stop:
    /// a headless per-item process of ours, or an item still waiting its turn
    /// in the concurrency queue. False for a terminal-mode single-item run,
    /// for the same reason `canCancelCurrentRun` is - the launcher has
    /// already exited and the window is the user's to close.
    func canCancelItem(_ id: String) -> Bool {
        activeProcesses[id]?.isRunning == true || queuedItemIDs.contains(id)
    }

    /// Stops one row's own update: a queued item never starts, a running one
    /// is signalled exactly the way `cancelUpdate` signals the bulk run.
    ///
    /// Cancelling used to reach `bulkProcess` and nothing else, so a
    /// single-item run that hung - `mas` has no timeout of its own, and one
    /// of its call sites was missing the wrapper the rest use - left a
    /// spinner nothing in the app could ever clear, with quitting the app as
    /// the only way out.
    ///
    /// The row goes straight back to its idle "Update" button rather than to
    /// a failed badge: the user asked for this, so there is no failure to
    /// report and no reason to keep on screen. All of that teardown happens
    /// here and now, not in the termination handler, because a process that
    /// ignores SIGTERM must not be able to hold the row a second time -
    /// `itemRunTokens` is what makes that handler, whenever it does arrive, a
    /// no-op rather than a second opinion on a row the user may since have
    /// restarted.
    func cancelItemUpdate(_ id: String) {
        let wasQueued = queuedItemIDs.contains(id)
        queuedItemIDs.removeAll { $0 == id }
        queuedLaunchers[id] = nil

        if let process = activeProcesses.removeValue(forKey: id) {
            itemRunTokens[id] = nil
            if process.isRunning { terminateWithChildren(process) }
        } else if !wasQueued {
            // Neither running here nor queued - a terminal-mode run, or one
            // that resolved between the button being drawn and pressed.
            return
        }

        itemStatuses[id] = nil
        itemFailureReasons[id] = nil
        recentItemsByID[id] = nil
        endFractionSimulation(for: id)
        // A slot just freed up (or the queue just got shorter): let whatever
        // is still waiting move, and stop the queue poll if nothing is.
        drainQueue()
    }

    /// SIGTERM to a script's direct children first (brew/mas/curl - whatever
    /// it is actually waiting on) and then to the script itself, since
    /// terminating just the zsh process does not by itself stop a foreground
    /// child it launched. Shared by the bulk cancel and the per-row one.
    private func terminateWithChildren(_ process: Process) {
        let pkill = Process()
        pkill.executableURL = URL(filePath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()

        process.terminate()
    }

    /// Stops the bulk run in progress - `terminateWithChildren` for how, and
    /// `cancelItemUpdate` for the single-row equivalent.
    func cancelUpdate() {
        guard let process = bulkProcess, process.isRunning else { return }
        cancelledBulkRun = true

        terminateWithChildren(process)

        // We just killed it ourselves - no need to keep polling a progress
        // file whose next write, if any, could only report the same thing.
        stopProgressWatch()

        resolvedRunAt = Date()
        progress = UpdateProgress(state: .failed, phase: .cancelled, item: "", index: nil, total: nil)
        if let active = activeSingleItem {
            itemStatuses[active.id] = .failed
            endFractionSimulation(for: active.id)
            activeSingleItem = nil
            activeSingleItemStartedAt = nil
            scheduleStatusClear(for: active.id)
        }
    }

    /// Watches the shared progress file for as long as a *bulk* (or
    /// terminal-mode single-item) run is in flight, so the menu bar can name
    /// the package currently being installed.
    ///
    /// Two-phased, per `ProgressWatch`: the run is given until
    /// `ProgressWatch.startupTimeout` to write its first line (a terminal
    /// window has to open, `acquire_lock` can block for 20 seconds), and only
    /// after it has been seen does silence mean the run is over.
    private func startProgressWatch() {
        guard progressTask == nil else { return }

        let startedAt = Date()
        watchStartedAt = startedAt
        // A new run owns the file from here on; whatever the last one died
        // leaving in it is no longer what anybody is reading.
        resolvedRunAt = nil

        progressTask = Task { [weak self] in
            var watch = ProgressWatch(startedAt: startedAt)
            while !Task.isCancelled {
                try? await Task.sleep(for: ProgressWatch.pollInterval)
                guard !Task.isCancelled, let self else { return }

                let latest = UpdateProgress.load()
                let step = watch.step(latest: latest, now: Date())

                await MainActor.run {
                    switch step {
                    case .awaitingStart:
                        // Nothing of this run's on disk yet: say "starting"
                        // rather than show whatever an earlier run left there.
                        self.progress = Self.startingUp
                    case .observed, .finished:
                        self.progress = latest
                    case .neverStarted:
                        self.progress = UpdateProgress(
                            state: .failed, phase: .notStarted, item: "", index: nil, total: nil
                        )
                    }
                }

                switch step {
                case .awaitingStart, .observed:
                    continue
                case .finished, .neverStarted:
                    await MainActor.run { self.finishProgressWatch() }
                    return
                }
            }
        }
    }

    /// What the banner shows between "the run was asked for" and "the run
    /// wrote its first line" - see `ProgressWatch`'s startup phase.
    private static let startingUp = UpdateProgress(
        state: .running, phase: .starting, item: "", index: nil, total: nil
    )

    /// The watch has seen this run through to its end (or to its failure to
    /// start): re-read what it produced and release everything waiting on it.
    /// By now the run has had `quietTicksToFinish` polls to finish writing, so
    /// the cache it leaves behind is the one to show.
    private func finishProgressWatch() {
        snapshot = UpdateSnapshot.load()
        resolveActiveSingleItem()
        // The bulk run holding up the concurrency queue (see `startOrQueue`)
        // just finished - anything queued behind it can start now.
        drainQueue()
        progressTask = nil
        watchStartedAt = nil
    }

    /// Drops the watch without resolving anything through it - for the paths
    /// that already know the run's outcome (a cancel, a dead process) and have
    /// written it themselves.
    private func stopProgressWatch() {
        progressTask?.cancel()
        progressTask = nil
        watchStartedAt = nil
    }

    func relocateScript() {
        scriptURL = ToolkitPaths.locateScript()
    }

    // MARK: - Refreshing

    /// Rebuilds the cache by running the script, then re-reads it.
    func refresh(force: Bool = true) {
        guard !isRefreshing else { return }
        guard let script = scriptURL else { return report(.refresh, .toolkitMissing) }

        isRefreshing = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let outcome = await Self.run(script: script, arguments: ["refresh_cache", force ? "force" : "auto"])
            await MainActor.run {
                guard let self else { return }
                if !outcome.succeeded { self.report(.refresh, .from(outcome)) }
                self.isRefreshing = false
                self.reload()
            }
        }
    }

    /// Runs the bulk update ("Update Everything" / a toolkit component).
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
        guard let script = scriptURL else { return report(.startRun, .toolkitMissing) }

        if preferences.runUpdatesInTerminal {
            let startedAt = Date()
            Task {
                let outcome = await Self.run(script: script, arguments: ["launch_update", scope])
                await MainActor.run {
                    // Only watch a run that was actually launched: a launcher
                    // that failed opened no terminal, so nothing is ever going
                    // to write to the progress file and the watch would only
                    // sit out its startup window overwriting the real error.
                    guard outcome.succeeded else {
                        return self.reportFailure(outcome, startedAt: startedAt)
                    }
                    self.startProgressWatch()
                }
            }
        } else {
            startBulkProcess(script: script, arguments: ["run", scope])
            startProgressWatch()
        }
    }

    /// `trackingItem` is set only for a live, single-item "Update" press (never
    /// for a dry run, never for the bulk toolkit-update path) - that is the
    /// one case where a row's spinner/outcome should follow this particular run.
    /// `forceTerminal` is for the menu bar's native "Bekleyen Güncellemeler"
    /// flyout - it has no row of its own to show a spinner or result on, so
    /// an update started from there always gets a terminal window instead of
    /// running invisibly, whatever the general Settings toggle says.
    func installApp(named name: String, dryRun: Bool, trackingItem: UpdateItem? = nil, forceTerminal: Bool = false) {
        guard let script = scriptURL else {
            return report(.updateItem, subject: name, .toolkitMissing)
        }
        let liveOrDry = dryRun ? "dry" : "live"

        if preferences.runUpdatesInTerminal || forceTerminal {
            if !dryRun, let trackingItem { beginTrackingSingleItem(trackingItem) }
            let startedAt = Date()
            Task {
                let outcome = await Self.run(script: script, arguments: ["install_app", name, liveOrDry])
                await MainActor.run {
                    // See `launchUpdate`: nothing to watch if the launcher
                    // itself failed.
                    guard outcome.succeeded else {
                        return self.reportFailure(outcome, startedAt: startedAt)
                    }
                    self.startProgressWatch()
                }
            }
        } else if dryRun {
            // Quick and read-only - always runs immediately, outside the
            // concurrency queue, with no row to attribute an outcome to.
            runFireAndForget(script: script, arguments: ["run", "install", name, liveOrDry])
        } else if let trackingItem {
            startOrQueue(trackingItem) { [weak self] in
                self?.startSingleItemProcess(trackingItem, script: script, arguments: ["run", "install", name, liveOrDry])
            }
        }
    }

    /// Update a single package or App Store app. `forceTerminal` - see
    /// `installApp` above - is set only by the menu bar's native flyout.
    func updateSingle(_ item: UpdateItem, forceTerminal: Bool = false) {
        guard let script = scriptURL else {
            return report(.updateItem, subject: item.name, .toolkitMissing)
        }

        let kind: String
        let identifier: String
        switch item.source {
        case .formula: kind = "brew"; identifier = item.name
        case .cask: kind = "cask"; identifier = item.name
        case .appStore, .manual: kind = "mas"; identifier = item.id.replacingOccurrences(of: "mas:", with: "").replacingOccurrences(of: "manual:", with: "")
        case .sparkle, .github: installApp(named: item.name, dryRun: false, trackingItem: item, forceTerminal: forceTerminal); return
        }

        let details = [kind, identifier, item.name, item.currentVersion, item.newVersion]

        if preferences.runUpdatesInTerminal || forceTerminal {
            // One visible terminal window, watched directly - stays
            // single-flight rather than joining the concurrency queue below.
            beginTrackingSingleItem(item)
            let startedAt = Date()
            Task {
                let outcome = await Self.run(script: script, arguments: ["update_app"] + details)
                await MainActor.run {
                    // See `launchUpdate`: nothing to watch if the launcher
                    // itself failed.
                    guard outcome.succeeded else {
                        return self.reportFailure(outcome, startedAt: startedAt)
                    }
                    self.startProgressWatch()
                }
            }
        } else {
            startOrQueue(item) { [weak self] in
                self?.startSingleItemProcess(item, script: script, arguments: ["run", "single"] + details)
            }
        }
    }

    /// Pulls the latest Homebrew + tap metadata, the equivalent of "check for
    /// updates" for Homebrew itself - there is no version to compare against
    /// the way an app has, so this is what "checking" means for it. Always
    /// headless: it is a quick, one-shot check, the same kind of action as
    /// "Refresh Now" on the Updates page, not a multi-package run someone
    /// would want to watch in a terminal.
    func checkHomebrewDatabase() {
        guard let script = scriptURL else { return report(.homebrewCheck, .toolkitMissing) }
        startBulkProcess(script: script, arguments: ["brew_update"])
        startProgressWatch()
    }

    /// Hide something from the update list.
    func ignore(type: String, id: String, name: String) {
        guard let script = scriptURL else {
            return report(.hideItem, subject: name, .toolkitMissing)
        }
        Task {
            let outcome = await Self.run(script: script, arguments: ["ignore_app", type, id, name])
            await MainActor.run {
                if !outcome.succeeded { self.report(.hideItem, subject: name, .from(outcome)) }
                self.reload()
            }
        }
    }

    func unignore(type: String, id: String, name: String) {
        guard let script = scriptURL else {
            return report(.unhideItem, subject: name, .toolkitMissing)
        }
        Task {
            let outcome = await Self.run(script: script, arguments: ["unignore_app", type, id, name])
            await MainActor.run {
                if !outcome.succeeded { self.report(.unhideItem, subject: name, .from(outcome)) }
                self.reload()
            }
        }
    }

    /// Ask the toolkit whether a newer version of itself is available.
    func checkToolkitUpdate() {
        guard let script = scriptURL else { return report(.toolkitUpdateCheck, .toolkitMissing) }
        Task {
            let outcome = await Self.run(script: script, arguments: ["check_updates"])
            if !outcome.succeeded {
                await MainActor.run { self.report(.toolkitUpdateCheck, .from(outcome)) }
            }
        }
    }

    /// Records a failure for the UI to show. One funnel, so no path can go
    /// back to failing silently - and so "the toolkit is missing" is a
    /// translated sentence rather than a raw token nothing renders.
    private func report(_ action: ActionFailure.Action,
                        subject: String? = nil,
                        _ reason: ActionFailure.Reason) {
        lastFailure = ActionFailure(action: action, subject: subject, reason: reason)
    }

    /// Drops the failure the banner is showing - the banner's own dismiss
    /// button, and nothing else: a failure stays up until it is read.
    func dismissFailure() {
        lastFailure = nil
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

    /// What a toolkit process invocation actually did, instead of assuming it
    /// worked because it ran. A crash, a timeout, or any non-zero exit all
    /// count as failure here, whatever the shell script's own progress file
    /// (which a killed or crashed process never gets to update) says.
    ///
    /// Internal (not private) so ProcessOutcomeTests/ToolkitRunnerRunTests can
    /// construct and exercise it directly via '@testable import'.
    struct ProcessOutcome: Sendable {
        let exitCode: Int32
        let reason: Process.TerminationReason
        let stderr: String

        var succeeded: Bool { reason == .exit && exitCode == 0 }

        var summary: String {
            if !stderr.isEmpty { return stderr }
            if reason == .uncaughtSignal { return "Process terminated by signal \(exitCode)." }
            return "Process exited with status \(exitCode)."
        }
    }

    /// Records a failed *bulk* process invocation using the same state
    /// ProgressBanner already renders for a failed update, so a crash is
    /// exactly as visible as a script-reported failure - never a silent no-op.
    ///
    /// `endedTheWatchedRun` marks the one caller whose process *is* the run
    /// the progress watch is following: the watch is now waiting on something
    /// that can never write again, so it gets stopped here and its
    /// end-of-run work done in its place. Every other caller (a dry run, a
    /// launcher that never opened its terminal) must leave a watch that
    /// belongs to some other run running - its next poll puts the real state
    /// back on the banner by itself.
    ///
    /// `startedAt` is when this process was launched, and is what makes an
    /// entry in the progress file attributable to it. The launcher paths pass
    /// it because they have no progress watch of their own to date an entry
    /// against; `endedTheWatchedRun` uses the watch's own start instead.
    private func reportFailure(_ outcome: ProcessOutcome,
                               startedAt: Date? = nil,
                               endedTheWatchedRun: Bool = false) {
        // Deliberately not routed through `report`/`lastFailure`: this writes
        // the failure into `progress` below, which ProgressBanner already
        // renders. Doing both would put the same error on screen twice.
        let processError = UpdateProgress(
            state: .failed, phase: .processError, item: outcome.summary, index: nil, total: nil
        )

        // The script may already have recorded a more precise ending than "the
        // process exited non-zero" - "3 of 8 failed", or a launcher naming the
        // Automation permission macOS refused. Prefer it, because the shell
        // writes a phase this app can word in the user's language while
        // `outcome.summary` is raw shell English. But only when *this* run
        // wrote it: an older entry describes some earlier run and must never
        // be shown as this one's outcome.
        let recordedSince = endedTheWatchedRun ? watchStartedAt : startedAt
        let ownEnding = recordedSince.flatMap { started -> UpdateProgress? in
            guard let latest = UpdateProgress.load(),
                  latest.state == .failed,
                  latest.modified >= started else { return nil }
            return latest
        }

        if endedTheWatchedRun {
            // Nothing more can reach the progress file now, so the watch must
            // not go on spending its startup window overwriting this failure -
            // and neither may a later re-read of the entry it left behind.
            stopProgressWatch()
            resolvedRunAt = Date()
            progress = ownEnding ?? processError
            // Whatever the run managed to do before dying still counts, and
            // the queue the watch would have drained on its way out is no
            // longer waiting on anything.
            snapshot = UpdateSnapshot.load()
            drainQueue()
        } else {
            progress = ownEnding ?? processError
        }

        // The process died outright - no need to wait for the progress watch
        // to go quiet, the row can flip to "failed" immediately. Only
        // relevant for a terminal-mode single-item run; the headless
        // concurrent path resolves through `finishActiveItem` instead.
        if let active = activeSingleItem {
            itemStatuses[active.id] = .failed
            endFractionSimulation(for: active.id)
            activeSingleItem = nil
            activeSingleItemStartedAt = nil
            scheduleStatusClear(for: active.id)
        }
    }

    // MARK: - Per-item status (headless concurrency queue)

    /// Starts a single item's update now if a concurrency slot is free and no
    /// bulk run is using the shared lock and cache, otherwise queues it -
    /// `drainQueue()` starts it automatically once room opens up.
    private func startOrQueue(_ item: UpdateItem, launch: @escaping () -> Void) {
        // Already running or already waiting its turn - a second press (the
        // row's own button is disabled once `rowStatus` is set, but the "..."
        // menu's duplicate entry isn't always) must not double-launch it.
        guard itemStatuses[item.id] != .updating, itemStatuses[item.id] != .queued else { return }

        recentItemsByID[item.id] = item

        guard progress?.isRunning != true, activeProcesses.count < preferences.maxConcurrentUpdates else {
            itemStatuses[item.id] = .queued
            queuedItemIDs.append(item.id)
            queuedLaunchers[item.id] = launch
            syncQueueDrainWatch()
            return
        }

        itemStatuses[item.id] = .updating
        beginFractionSimulation(for: item.id)
        launch()
    }

    /// Pops queued items into free concurrency slots, in the order they were
    /// requested. Safe to call any time - a no-op if the queue is empty, a
    /// bulk run is in progress, or every slot is already taken.
    private func drainQueue() {
        defer { syncQueueDrainWatch() }
        guard progress?.isRunning != true else { return }
        while activeProcesses.count < preferences.maxConcurrentUpdates, let nextID = queuedItemIDs.first {
            queuedItemIDs.removeFirst()
            guard let launch = queuedLaunchers.removeValue(forKey: nextID) else { continue }
            itemStatuses[nextID] = .updating
            beginFractionSimulation(for: nextID)
            launch()
        }
    }

    /// How often a queue held up by a bulk run re-checks whether that run is
    /// still there. Slower than the progress watch's own poll: nothing is
    /// being displayed off this, it only decides when to start work.
    private static let queuePollInterval: Duration = .seconds(2)

    /// Keeps a poll running for exactly as long as something is queued, and
    /// no longer.
    ///
    /// `startOrQueue` parks items while `progress` says a bulk run is going,
    /// but the two paths that call `drainQueue()` on their own -
    /// `finishActiveItem` (needs an active process of ours) and the progress
    /// watch finishing - only fire for runs this app is itself following.
    /// A run started from a terminal, or one that died and left `running`
    /// behind, is followed by neither - so every row sat at "Queued" with
    /// nothing in the app ever going to read that file again, and the queue
    /// moved only if the user happened to trigger something else. This poll
    /// is what reads it: a run that has ended - or gone stale, per
    /// `UpdateProgress.staleAfter(for:)` - releases the queue on its own.
    private func syncQueueDrainWatch() {
        guard !queuedItemIDs.isEmpty else {
            queueDrainTask?.cancel()
            queueDrainTask = nil
            return
        }
        guard queueDrainTask == nil else { return }

        queueDrainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.queuePollInterval)
                guard !Task.isCancelled, let self else { return }

                let stillWaiting = await MainActor.run { () -> Bool in
                    guard !self.queuedItemIDs.isEmpty else { return false }
                    // The run the queue is waiting on may have finished, or
                    // died, without this app hearing a thing about it.
                    self.refreshProgressFromDisk()
                    self.drainQueue()
                    return !self.queuedItemIDs.isEmpty
                }
                if !stillWaiting { return }
            }
        }
    }

    private func startSingleItemProcess(_ item: UpdateItem, script: URL, arguments: [String]) {
        nextItemRunToken += 1
        let token = nextItemRunToken
        itemRunTokens[item.id] = token
        let startedAt = Date()
        activeProcesses[item.id] = startProcess(
            script: script,
            arguments: arguments,
            // Several of these can run at once (see the concurrency queue
            // above) - none of them should touch the shared progress file
            // ProgressBanner reads for the bulk run. This run resolves its
            // own outcome via `finishActiveItem`, not that file.
            extraEnvironment: ["GUIDEAPP_NO_SHARED_PROGRESS": "1"]
        ) { [weak self] outcome in
            self?.finishActiveItem(item, token: token, startedAt: startedAt, outcome: outcome)
        }
    }

    /// Called once a concurrent single-item run's process has exited, one way
    /// or another.
    ///
    /// Whether it actually updated comes from the run's own result record -
    /// the single-item contract in CACHE_FORMAT.md, written by
    /// `result_write()` after the shell has verified the item really did
    /// leave the outdated list. The process exit code cannot answer it (`run
    /// single` exits 0 either way), and the snapshot check below is only the
    /// fallback: it is this app guessing from a list the run rewrote moments
    /// earlier, which reads a real success as a failure whenever that
    /// rewrite lands late, and has no way at all to tell "still outdated"
    /// from "the App Store refused it".
    ///
    /// The fallback stays because it must: GuideApp can be pointed at an
    /// engine older than this contract, which will never write a record.
    ///
    /// `outcome` is still needed for its stderr - the run's own detail of
    /// *why*, which no token can carry.
    private func finishActiveItem(_ item: UpdateItem, token: Int, startedAt: Date, outcome: ProcessOutcome) {
        // Cancelled, or already superseded by a later run on the same row:
        // this process is reporting on something nobody is waiting for any
        // more, and the row's state is not its to write. Without the check, a
        // cancelled run's eventual exit would put a "failed" badge (and a
        // banner) on a row the user had already sent back to idle, or worse,
        // clear the slot of the run that replaced it.
        guard itemRunTokens[item.id] == token else { return }
        itemRunTokens[item.id] = nil
        activeProcesses[item.id] = nil
        snapshot = UpdateSnapshot.load()

        let record = ItemRunResultStore.consume(itemID: item.id, since: startedAt)
        let failed = record.map { !$0.succeeded }
            ?? snapshot.items.contains { $0.id == item.id }
        itemStatuses[item.id] = failed ? .failed : .succeeded

        if failed {
            let reason = Self.failureReason(record: record, outcome: outcome)
            // Both surfaces, because they answer different questions: the row
            // says which package failed and is gone with the badge, the
            // banner keeps the reason on screen until it has been read.
            itemFailureReasons[item.id] = reason
            report(.updateItem, subject: item.name, reason)
        } else {
            itemFailureReasons[item.id] = nil
        }

        endFractionSimulation(for: item.id)
        scheduleStatusClear(for: item.id)
        drainQueue()
    }

    /// Why a row's own run failed: the reason the run filed, where it filed
    /// one worth wording, with whatever it printed kept underneath it -
    /// otherwise the process outcome on its own, which is all there was
    /// before the result contract existed and all there is against an engine
    /// that predates it.
    private static func failureReason(record: ItemRunResult?, outcome: ProcessOutcome) -> ActionFailure.Reason {
        // A token this build has no copy for says less than the output does.
        guard let record, record.reason.label != nil else { return .from(outcome) }
        return .reported(record.reason, detail: outcome.stderr)
    }

    private func beginTrackingSingleItem(_ item: UpdateItem) {
        activeSingleItem = item
        activeSingleItemStartedAt = Date()
        recentItemsByID[item.id] = item
        itemStatuses[item.id] = .updating
        beginFractionSimulation(for: item.id)
    }

    /// Called once a terminal-mode run's shared progress file has gone quiet.
    /// See `finishActiveItem` for the headless-concurrent equivalent; both
    /// read the same result record, and both fall back to the same "still on
    /// the outdated list" guess only when there is no record to read.
    ///
    /// There is no process here to take a reason from - the launcher that
    /// opened the terminal window exited long ago and the run's output went
    /// to that window - so the record's token is the only account of the
    /// failure this app can put on the row. The banner is left to the
    /// progress file, which the run wrote its own ending to; reporting it
    /// here as well would put the same failure on screen twice.
    private func resolveActiveSingleItem() {
        guard let active = activeSingleItem else { return }
        let record = ItemRunResultStore.consume(
            itemID: active.id,
            since: activeSingleItemStartedAt ?? .distantPast
        )
        let failed = record.map { !$0.succeeded }
            ?? snapshot.items.contains { $0.id == active.id }
        itemStatuses[active.id] = failed ? .failed : .succeeded
        if failed {
            if let reason = record?.reason, reason.label != nil {
                itemFailureReasons[active.id] = .reported(reason, detail: "")
            }
        } else {
            itemFailureReasons[active.id] = nil
        }
        endFractionSimulation(for: active.id)
        activeSingleItem = nil
        activeSingleItemStartedAt = nil
        scheduleStatusClear(for: active.id)
    }

    /// Starts (or restarts) the simulated fill for one row. `0` immediately,
    /// then eased upward on a timer - see `itemFractions` for why this is
    /// simulated rather than real.
    private func beginFractionSimulation(for id: String) {
        fractionTasks[id]?.cancel()
        itemFractions[id] = 0
        let start = Date()
        fractionTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(start)
                // Approaches 92%, slowing down as it gets there - never
                // claims "done" on its own; only `endFractionSimulation`
                // (called once the row's real outcome is known) does that.
                let fraction = 0.92 * (1 - exp(-elapsed / 6))
                await MainActor.run { self?.itemFractions[id] = fraction }
            }
        }
    }

    private func endFractionSimulation(for id: String) {
        fractionTasks[id]?.cancel()
        fractionTasks[id] = nil
        itemFractions[id] = nil
    }

    /// Clears a resolved row status a few seconds after it lands, the same
    /// "flash the result, then go back to normal" behaviour the App Store
    /// uses. Skipped if that id already moved on to a new run in the meantime.
    ///
    /// A failure gets longer than a success: "Updated" is a confirmation and
    /// is read at a glance, while a failed row is carrying the only per-row
    /// explanation there is (`itemFailureReasons`, rendered under the row)
    /// and needs long enough to actually be read. The banner keeps that
    /// reason afterwards either way.
    private func scheduleStatusClear(for id: String) {
        let seconds: Double = itemStatuses[id] == .failed ? 8 : 3
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run {
                guard let self, self.itemStatuses[id] != .updating, self.itemStatuses[id] != .queued else { return }
                self.itemStatuses[id] = nil
                self.itemFailureReasons[id] = nil
                self.recentItemsByID[id] = nil
            }
        }
    }

    /// Starts the one shared bulk-run process and tracks it in `bulkProcess`
    /// for `cancelUpdate()`, reporting a crash/non-zero exit through the same
    /// path a script-reported failure uses - unless we just cancelled it
    /// ourselves, in which case that state was already written.
    private func startBulkProcess(script: URL, arguments: [String]) {
        bulkProcess = startProcess(script: script, arguments: arguments) { [weak self] outcome in
            guard let self else { return }
            self.bulkProcess = nil
            guard !self.cancelledBulkRun else {
                self.cancelledBulkRun = false
                return
            }
            if !outcome.succeeded { self.reportFailure(outcome, endedTheWatchedRun: true) }
        }
    }

    /// For actions with no row or bulk state to update on completion (a dry
    /// run) - just report a crash if the process fails to launch or exits
    /// non-zero, the same as `startBulkProcess` without anywhere to stash
    /// the `Process` afterward.
    private func runFireAndForget(script: URL, arguments: [String]) {
        _ = startProcess(
            script: script,
            arguments: arguments,
            extraEnvironment: ["GUIDEAPP_NO_SHARED_PROGRESS": "1"]
        ) { [weak self] outcome in
            if !outcome.succeeded { self?.reportFailure(outcome) }
        }
    }

    /// Starts a process and returns immediately, without waiting for it to
    /// exit - the process's own lifetime, not this call returning, is what
    /// tells the caller when the run is done. `onExit` runs on the main actor
    /// once it has terminated one way or another (including a launch failure,
    /// reported through the same `ProcessOutcome` shape).
    ///
    /// The caller decides what "done" means for it - a shared bulk slot, a
    /// per-item slot in `activeProcesses`, or nothing at all - this only
    /// owns the `Process`/`Pipe` plumbing common to all three.
    private func startProcess(
        script: URL,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        onExit: @escaping (ProcessOutcome) -> Void
    ) -> Process? {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [script.path(percentEncoded: false)] + arguments
        process.standardOutput = FileHandle.nullDevice
        if !extraEnvironment.isEmpty {
            // Setting `environment` at all replaces the inherited one, not
            // merges with it - has to start from the real one (PATH, HOME,
            // ...) or the script cannot find `brew`/`mas`/etc.
            process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }
        }
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        // Started before the process is, so the pipe is never left full and
        // unattended - see StderrDrain for what happens when it is.
        let stderrDrain = StderrDrain(draining: stderrPipe)

        process.terminationHandler = { finished in
            let outcome = ProcessOutcome(
                exitCode: finished.terminationStatus,
                reason: finished.terminationReason,
                stderr: stderrDrain.text()
            )
            Task { @MainActor in onExit(outcome) }
        }

        do {
            try process.run()
            return process
        } catch {
            // Nothing was ever spawned, so nothing will ever write to that
            // pipe or close it: stop reading it rather than leave a reader
            // waiting on a process that does not exist.
            stderrDrain.stopDraining()
            onExit(ProcessOutcome(exitCode: -1, reason: .uncaughtSignal, stderr: error.localizedDescription))
            return nil
        }
    }

    /// Internal (not private) so ToolkitRunnerRunTests can call it directly
    /// with a small fixture script, exercising the real Process/Pipe plumbing
    /// rather than just the ProcessOutcome decision logic.
    static func run(script: URL, arguments: [String]) async -> ProcessOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutcome, Never>) in
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = [script.path(percentEncoded: false)] + arguments
            process.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            let stderrDrain = StderrDrain(draining: stderrPipe)

            process.terminationHandler = { finished in
                continuation.resume(returning: ProcessOutcome(
                    exitCode: finished.terminationStatus,
                    reason: finished.terminationReason,
                    stderr: stderrDrain.text()
                ))
            }

            do {
                try process.run()
            } catch {
                stderrDrain.stopDraining()
                continuation.resume(returning: ProcessOutcome(
                    exitCode: -1,
                    reason: .uncaughtSignal,
                    stderr: error.localizedDescription
                ))
            }
        }
    }
}

/// Reads a child process's stderr *while it is still running*, and keeps the
/// tail of what it read.
///
/// A pipe is a fixed-size buffer - 64 KB here. A process that writes past
/// that into a pipe nobody is reading blocks inside `write()` and stays
/// blocked: it never exits, so `terminationHandler` never runs, so a reader
/// that only starts there never starts at all. Each side ends up waiting for
/// the other, permanently, and the run hangs with no error and no exit.
/// `brew cleanup --prune=all` and `mas upgrade` (lib/run_modes.sh) are the
/// two calls whose stderr is not already redirected into `progress_tap`, and
/// on a machine with a lot to clean up or update either can print well past
/// 64 KB.
///
/// Only the last `limit` bytes survive. This text is shown in a failure
/// banner, where what matters is how the run ended - not every line it
/// printed on the way there - and an unbounded buffer would be one more way
/// for a chatty script to take the app down.
private final class StderrDrain: @unchecked Sendable {

    /// Far more than a failure needs to explain itself, and small enough to
    /// hand to a text view without a second thought.
    private static let limit = 16 * 1024

    /// Says so when the head was dropped, so a truncated tail is never read
    /// as the whole story.
    private static let truncationNotice = "[... earlier output dropped ...]\n"

    private let pipe: Pipe
    private let lock = NSLock()
    private var buffer = Data()
    private var droppedHead = false
    private var isDone = false
    private let done = DispatchSemaphore(value: 0)

    /// Begins draining `pipe` on the reader queue Foundation manages for it.
    /// Call this *before* launching the process: the point is that no write
    /// ever finds the pipe full with nobody reading.
    init(draining pipe: Pipe) {
        self.pipe = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            // Empty means end of file: every write end is closed, so the
            // process and anything it spawned are done printing.
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self.markDone()
                return
            }
            self.append(chunk)
        }
    }

    /// The stderr of a process that has exited, as far as it could be read.
    ///
    /// Waits for end of file first, because the last writes can still be in
    /// flight when the process dies. The wait is bounded: end of file may
    /// genuinely never come - a grandchild that inherited the descriptor
    /// keeps the write end open after its parent exits - and a missing last
    /// line of a log costs far less than another permanent hang.
    func text(waitingUpTo timeout: TimeInterval = 2) -> String {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard droppedHead, !text.isEmpty else { return text }
        return Self.truncationNotice + text
    }

    /// Gives up on the pipe - for the caller whose process never launched, so
    /// nothing will ever write to it or close it.
    func stopDraining() {
        pipe.fileHandleForReading.readabilityHandler = nil
        markDone()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        if buffer.count > Self.limit {
            buffer.removeFirst(buffer.count - Self.limit)
            droppedHead = true
        }
    }

    private func markDone() {
        lock.lock()
        let wasDone = isDone
        isDone = true
        lock.unlock()
        // `signal()` once only: `text()` waits once, and a stray extra count
        // would let a later wait through before its own read had finished.
        if !wasDone { done.signal() }
    }
}
