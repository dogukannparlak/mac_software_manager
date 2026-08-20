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
    /// FIFO of item ids waiting for a free concurrency slot, plus what to
    /// actually run for each once its turn comes - `drainQueue()` pops both
    /// together. A plain array is fine at this scale (a handful of rows).
    private var queuedItemIDs: [String] = []
    private var queuedLaunchers: [String: () -> Void] = [:]

    /// The item a just-launched *terminal-mode* single-item run belongs to.
    /// Terminal mode stays single-flight (one visible window, watched
    /// directly) rather than joining the concurrency queue above, so it still
    /// needs the older "watch the shared progress file, resolve on quiet"
    /// approach `startProgressWatch()` uses.
    private var activeSingleItem: UpdateItem?
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

        let latest = UpdateProgress.load()
        // A run being watched owns `progress` (see `startProgressWatch`): an
        // entry older than that watch is an earlier run's, and letting a
        // refresh that happens to land mid-startup put it back on the banner
        // would undo exactly what the watch is there to prevent.
        if let started = watchStartedAt, (latest?.modified ?? .distantPast) < started { return }
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

    /// Stops the bulk run in progress. Sends SIGTERM to the script's direct
    /// children first (brew/mas/curl - whatever it is actually waiting on)
    /// and then to the script itself, since terminating just the zsh process
    /// does not by itself stop a foreground child it launched.
    func cancelUpdate() {
        guard let process = bulkProcess, process.isRunning else { return }
        cancelledBulkRun = true

        let pkill = Process()
        pkill.executableURL = URL(filePath: "/usr/bin/pkill")
        pkill.arguments = ["-TERM", "-P", String(process.processIdentifier)]
        try? pkill.run()
        pkill.waitUntilExit()

        process.terminate()

        // We just killed it ourselves - no need to keep polling a progress
        // file whose next write, if any, could only report the same thing.
        stopProgressWatch()

        progress = UpdateProgress(state: .failed, phase: .cancelled, item: "", index: nil, total: nil)
        if let active = activeSingleItem {
            itemStatuses[active.id] = .failed
            endFractionSimulation(for: active.id)
            activeSingleItem = nil
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
        guard let script = scriptURL else {
            lastMessage = "toolkit-missing"
            return
        }

        isRefreshing = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let outcome = await Self.run(script: script, arguments: ["refresh_cache", force ? "force" : "auto"])
            await MainActor.run {
                guard let self else { return }
                if !outcome.succeeded { self.lastMessage = outcome.summary }
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
        guard let script = scriptURL else { return }

        if preferences.runUpdatesInTerminal {
            Task {
                let outcome = await Self.run(script: script, arguments: ["launch_update", scope])
                await MainActor.run {
                    // Only watch a run that was actually launched: a launcher
                    // that failed opened no terminal, so nothing is ever going
                    // to write to the progress file and the watch would only
                    // sit out its startup window overwriting the real error.
                    guard outcome.succeeded else { return self.reportFailure(outcome) }
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
        guard let script = scriptURL else { return }
        let liveOrDry = dryRun ? "dry" : "live"

        if preferences.runUpdatesInTerminal || forceTerminal {
            if !dryRun, let trackingItem { beginTrackingSingleItem(trackingItem) }
            Task {
                let outcome = await Self.run(script: script, arguments: ["install_app", name, liveOrDry])
                await MainActor.run {
                    // See `launchUpdate`: nothing to watch if the launcher
                    // itself failed.
                    guard outcome.succeeded else { return self.reportFailure(outcome) }
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
        guard let script = scriptURL else { return }

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
            Task {
                let outcome = await Self.run(script: script, arguments: ["update_app"] + details)
                await MainActor.run {
                    // See `launchUpdate`: nothing to watch if the launcher
                    // itself failed.
                    guard outcome.succeeded else { return self.reportFailure(outcome) }
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
        guard let script = scriptURL else { return }
        startBulkProcess(script: script, arguments: ["brew_update"])
        startProgressWatch()
    }

    /// Hide something from the update list.
    func ignore(type: String, id: String, name: String) {
        guard let script = scriptURL else { return }
        Task {
            let outcome = await Self.run(script: script, arguments: ["ignore_app", type, id, name])
            await MainActor.run {
                if !outcome.succeeded { self.lastMessage = outcome.summary }
                self.reload()
            }
        }
    }

    func unignore(type: String, id: String, name: String) {
        guard let script = scriptURL else { return }
        Task {
            let outcome = await Self.run(script: script, arguments: ["unignore_app", type, id, name])
            await MainActor.run {
                if !outcome.succeeded { self.lastMessage = outcome.summary }
                self.reload()
            }
        }
    }

    /// Ask the toolkit whether a newer version of itself is available.
    func checkToolkitUpdate() {
        guard let script = scriptURL else { return }
        Task {
            let outcome = await Self.run(script: script, arguments: ["check_updates"])
            if !outcome.succeeded {
                await MainActor.run { self.lastMessage = outcome.summary }
            }
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
    private func reportFailure(_ outcome: ProcessOutcome, endedTheWatchedRun: Bool = false) {
        lastMessage = outcome.summary
        let processError = UpdateProgress(
            state: .failed, phase: .processError, item: outcome.summary, index: nil, total: nil
        )

        if endedTheWatchedRun {
            // The script may already have recorded a more precise ending than
            // "the process exited non-zero" ("3 of 8 failed", say). Prefer it -
            // but only when this run wrote it: an older entry describes some
            // earlier run and must never be shown as this one's outcome.
            let ownEnding = watchStartedAt.flatMap { started -> UpdateProgress? in
                guard let latest = UpdateProgress.load(),
                      latest.state == .failed,
                      latest.modified >= started else { return nil }
                return latest
            }

            // Nothing more can reach the progress file now, so the watch must
            // not go on spending its startup window overwriting this failure.
            stopProgressWatch()
            progress = ownEnding ?? processError
            // Whatever the run managed to do before dying still counts, and
            // the queue the watch would have drained on its way out is no
            // longer waiting on anything.
            snapshot = UpdateSnapshot.load()
            drainQueue()
        } else {
            progress = processError
        }

        // The process died outright - no need to wait for the progress watch
        // to go quiet, the row can flip to "failed" immediately. Only
        // relevant for a terminal-mode single-item run; the headless
        // concurrent path resolves through `finishActiveItem` instead.
        if let active = activeSingleItem {
            itemStatuses[active.id] = .failed
            endFractionSimulation(for: active.id)
            activeSingleItem = nil
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
        guard progress?.isRunning != true else { return }
        while activeProcesses.count < preferences.maxConcurrentUpdates, let nextID = queuedItemIDs.first {
            queuedItemIDs.removeFirst()
            guard let launch = queuedLaunchers.removeValue(forKey: nextID) else { continue }
            itemStatuses[nextID] = .updating
            beginFractionSimulation(for: nextID)
            launch()
        }
    }

    private func startSingleItemProcess(_ item: UpdateItem, script: URL, arguments: [String]) {
        activeProcesses[item.id] = startProcess(
            script: script,
            arguments: arguments,
            // Several of these can run at once (see the concurrency queue
            // above) - none of them should touch the shared progress file
            // ProgressBanner reads for the bulk run. This run resolves its
            // own outcome via `finishActiveItem`, not that file.
            extraEnvironment: ["GUIDEAPP_NO_SHARED_PROGRESS": "1"]
        ) { [weak self] _ in
            self?.finishActiveItem(item)
        }
    }

    /// Called once a concurrent single-item run's process has exited, one way
    /// or another. Whether it actually updated is read straight from a fresh
    /// snapshot - the same "is it still on the outdated list" check the shell
    /// side already uses to decide success/failure, rather than trusting a
    /// process exit code that `run single` always reports as 0.
    private func finishActiveItem(_ item: UpdateItem) {
        activeProcesses[item.id] = nil
        snapshot = UpdateSnapshot.load()
        let stillPending = snapshot.items.contains { $0.id == item.id }
        itemStatuses[item.id] = stillPending ? .failed : .succeeded
        endFractionSimulation(for: item.id)
        scheduleStatusClear(for: item.id)
        drainQueue()
    }

    private func beginTrackingSingleItem(_ item: UpdateItem) {
        activeSingleItem = item
        recentItemsByID[item.id] = item
        itemStatuses[item.id] = .updating
        beginFractionSimulation(for: item.id)
    }

    /// Called once a terminal-mode run's shared progress file has gone quiet.
    /// See `finishActiveItem` for the headless-concurrent equivalent; both use
    /// the same "still on the outdated list" verification.
    private func resolveActiveSingleItem() {
        guard let active = activeSingleItem else { return }
        let stillPending = snapshot.items.contains { $0.id == active.id }
        itemStatuses[active.id] = stillPending ? .failed : .succeeded
        endFractionSimulation(for: active.id)
        activeSingleItem = nil
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
    private func scheduleStatusClear(for id: String, after seconds: Double = 3) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            await MainActor.run {
                guard let self, self.itemStatuses[id] != .updating, self.itemStatuses[id] != .queued else { return }
                self.itemStatuses[id] = nil
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

        process.terminationHandler = { finished in
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let outcome = ProcessOutcome(
                exitCode: finished.terminationStatus,
                reason: finished.terminationReason,
                stderr: stderrText
            )
            Task { @MainActor in onExit(outcome) }
        }

        do {
            try process.run()
            return process
        } catch {
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

            process.terminationHandler = { finished in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: ProcessOutcome(
                    exitCode: finished.terminationStatus,
                    reason: finished.terminationReason,
                    stderr: stderrText
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: ProcessOutcome(
                    exitCode: -1,
                    reason: .uncaughtSignal,
                    stderr: error.localizedDescription
                ))
            }
        }
    }
}
