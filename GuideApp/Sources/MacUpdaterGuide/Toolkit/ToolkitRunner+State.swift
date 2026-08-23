import Foundation

/// Reading the state the engine leaves on disk, and cancelling what is
/// running - see `ToolkitRunner.swift` for the type itself.
///
/// Everything here is about a run this app is watching rather than starting:
/// re-reading the cache, following the shared progress file, and taking a run
/// down on request.
extension ToolkitController {

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
    func refreshProgressFromDisk() {
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
    func startProgressWatch() {
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

                    // A terminal-mode single-item run's own row has no
                    // Process of ours to poll (see beginFractionSimulation) -
                    // this shared file, which the cask download watcher also
                    // writes real bytes into for exactly this run, is the
                    // only account of it this app has.
                    if let active = self.activeSingleItem,
                       latest?.phase == .single,
                       let fraction = latest?.downloadFraction {
                        self.itemFractions[active.id] = fraction
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
    func stopProgressWatch() {
        progressTask?.cancel()
        progressTask = nil
        watchStartedAt = nil
    }

    func relocateScript() {
        scriptURL = ToolkitPaths.locateScript()
    }
}
