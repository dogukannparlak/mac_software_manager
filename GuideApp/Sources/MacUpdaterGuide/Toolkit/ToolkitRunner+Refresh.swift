import Foundation

/// Starting runs: the cache refresh, the bulk update, a single item, and the
/// timer that fires the first of those on its own.
extension ToolkitController {

    // MARK: - Refreshing

    /// Rebuilds the cache by running the script, then re-reads it.
    func refresh(force: Bool = true) {
        guard !isRefreshing else { return }
        guard let script = scriptURL else { return report(.refresh, .toolkitMissing) }

        isRefreshing = true
        refreshTask?.cancel()
        let startedAt = Date()
        refreshTask = Task { [weak self] in
            let outcome = await Self.run(script: script, arguments: ["refresh_cache", force ? "force" : "auto"])
            await MainActor.run {
                guard let self else { return }
                if !outcome.succeeded { self.report(.refresh, .from(outcome)) }
                self.isRefreshing = false
                self.reload()
                // A run this app started has just ended, so an engine new
                // enough to declare itself has necessarily done so. This is
                // where the mismatch is caught before it costs anyone an
                // update, rather than on the first row that fails.
                if outcome.succeeded { self.reportEngineContract(forRunStartedAt: startedAt) }
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

    // MARK: - Periodic refresh

    /// Replaces the plugin-filename trick the menu bar plugin used for its
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
}
