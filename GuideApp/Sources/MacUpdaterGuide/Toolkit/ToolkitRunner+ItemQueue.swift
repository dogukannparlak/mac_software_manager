import Foundation

/// The headless concurrency queue: which items are running, which are waiting
/// for a slot, and the per-row status each of them shows while it does.
extension ToolkitController {

    // MARK: - Per-item status (headless concurrency queue)

    /// Starts a single item's update now if a concurrency slot is free and no
    /// bulk run is using the shared lock and cache, otherwise queues it -
    /// `drainQueue()` starts it automatically once room opens up.
    func startOrQueue(_ item: UpdateItem, launch: @escaping () -> Void) {
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
    func drainQueue() {
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

    ///
    /// `resolve` overrides how the run is wrapped up. Migration uses it
    /// (`finishMigration`) because its rows are not snapshot items: the
    /// "is it still on the outdated list" fallback `finishActiveItem` ends on
    /// means nothing for an app that was never on that list. Everything above
    /// the resolution - the run token, the concurrency slot, and above all
    /// `GUIDEAPP_NO_SHARED_PROGRESS` - is shared, which is the point: every
    /// concurrent per-item run has to go through here or they trample each
    /// other's entry in the shared progress file.
    func startSingleItemProcess(
        _ item: UpdateItem,
        script: URL,
        arguments: [String],
        resolve: ((UpdateItem, Int, Date, ProcessOutcome) -> Void)? = nil
    ) {
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
            guard let self else { return }
            if let resolve {
                resolve(item, token, startedAt, outcome)
            } else {
                self.finishActiveItem(item, token: token, startedAt: startedAt, outcome: outcome)
            }
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

            // The one failure this app knows a way out of. There is only one
            // answer to "shall I open a terminal for the password prompt this
            // run had nowhere to show" - the update cannot happen anywhere
            // else - so by default it just does it, and the banner explains
            // the window that appeared rather than asking for a click first.
            // Turned off, the same failure waits behind the button instead.
            var needsTerminal = false
            if case .needsTerminal = reason { needsTerminal = true }
            let openNow = needsTerminal && preferences.autoOpenTerminalWhenRequired

            report(
                .updateItem,
                subject: item.name,
                reason,
                recovery: (needsTerminal && !openNow) ? .runInTerminal(itemID: item.id) : nil
            )

            if openNow {
                // After the report, so the explanation is already on screen
                // when the window opens - and after the queue below has been
                // told this run is over, which `drainQueue` at the end of
                // this function does.
                let id = item.id
                Task { @MainActor [weak self] in
                    guard let self, let again = self.recentItemsByID[id]
                        ?? self.snapshot.items.first(where: { $0.id == id }) else { return }
                    self.updateSingle(again, forceTerminal: true)
                }
            }
        } else {
            itemFailureReasons[item.id] = nil
        }

        // No record means the verdict above came from the outdated list. That
        // is legitimate against an engine that predates the contract - but the
        // user is entitled to know their row was decided by a guess, so this
        // goes last, where it takes the banner off the symptom and puts it on
        // the cause. A contract-capable engine that simply filed no record is
        // a different thing and says nothing here.
        if record == nil { reportEngineContract(forRunStartedAt: startedAt) }

        endFractionSimulation(for: item.id)
        scheduleStatusClear(for: item.id)
        drainQueue()
    }

    /// Why a row's own run failed: the reason the run filed, where it filed
    /// one worth wording, with whatever it printed kept underneath it -
    /// otherwise the process outcome on its own, which is all there was
    /// before the result contract existed and all there is against an engine
    /// that predates it.
    static func failureReason(record: ItemRunResult?, outcome: ProcessOutcome) -> ActionFailure.Reason {
        // Checked before the record's own token, because the token for this
        // is "command-failed" - true, and useless. The run reports that brew
        // exited non-zero; only what it printed says the upgrade was one
        // password away from working, and that difference is the one thing
        // the user can act on.
        if ActionFailure.Reason.needsTerminal(after: outcome) {
            return .needsTerminal(detail: outcome.stderr)
        }
        // A token this build has no copy for says less than the output does.
        guard let record, record.reason.label != nil else { return .from(outcome) }
        return .reported(record.reason, detail: outcome.stderr)
    }

    func beginTrackingSingleItem(_ item: UpdateItem) {
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
    func resolveActiveSingleItem() {
        guard let active = activeSingleItem else { return }
        let startedAt = activeSingleItemStartedAt ?? .distantPast
        let record = ItemRunResultStore.consume(itemID: active.id, since: startedAt)
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
        // The banner is otherwise left to the progress file for a
        // terminal-mode run (see this function's note), but an engine that
        // cannot report is not that run's failure - it is a standing one, and
        // nothing else on screen will say it.
        if record == nil { reportEngineContract(forRunStartedAt: startedAt) }

        endFractionSimulation(for: active.id)
        activeSingleItem = nil
        activeSingleItemStartedAt = nil
        scheduleStatusClear(for: active.id)
    }

    /// Starts (or restarts) the fill for one row. `0` immediately, then
    /// either the cask download watcher's real byte count
    /// (`cask_download_watch_start`, lib/cache.sh) once it has one, or - for
    /// everything else, and until then - eased upward on a timer. See
    /// `itemFractions` for why the fallback is simulated rather than real.
    private func beginFractionSimulation(for id: String) {
        fractionTasks[id]?.cancel()
        itemFractions[id] = 0
        let start = Date()
        fractionTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }

                let pid = await MainActor.run { self.activeProcesses[id]?.processIdentifier }
                let fraction: Double
                if let pid, let real = Self.realDownloadFraction(pid: pid) {
                    fraction = real
                } else {
                    // Approaches 92%, slowing down as it gets there - never
                    // claims "done" on its own; only `endFractionSimulation`
                    // (called once the row's real outcome is known) does that.
                    let elapsed = Date().timeIntervalSince(start)
                    fraction = 0.92 * (1 - exp(-elapsed / 6))
                }
                await MainActor.run { self.itemFractions[id] = fraction }
            }
        }
    }

    /// Real byte progress for a headless run's own cask download, read
    /// straight off the small per-PID file the shell watcher writes - `nil`
    /// whenever it has not written one (a formula, no Content-Length, the
    /// download has not started), which keeps the simulated ease-curve above
    /// as the fallback it always was.
    private static func realDownloadFraction(pid: Int32) -> Double? {
        guard let raw = try? String(contentsOf: ToolkitPaths.downloadProgressFile(pid: pid), encoding: .utf8) else {
            return nil
        }
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard let done = Double(fields.first ?? ""), done > 0,
              fields.count > 1, let total = Double(fields[1]), total > 0 else { return nil }
        return min(0.99, done / total)
    }

    func endFractionSimulation(for id: String) {
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
    func scheduleStatusClear(for id: String) {
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
}
