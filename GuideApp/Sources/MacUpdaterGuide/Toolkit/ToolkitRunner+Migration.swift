import Foundation

/// Moving an app off a manual download and onto Homebrew: finding candidates,
/// scanning them, running the migration and wording how it ended.
extension ToolkitController {

    // MARK: - Moving apps to Homebrew

    /// How `migrate_app` should move an application. The engine's own three
    /// modes, spelled exactly as it expects them.
    enum MigrationMode: String, Sendable {
        /// Homebrew takes over the bundle already on disk. Non-destructive:
        /// when it will not, it refuses and leaves the app untouched.
        case adopt
        /// Download the cask's copy over the installed one, with the original
        /// moved aside and put back if the install fails. Only ever reached
        /// because the user confirmed it.
        case replace
        /// Ask Homebrew what it would do and change nothing.
        case dry
    }

    /// Whether the installed engine has the migration actions at all. Read at
    /// the point of use rather than cached: the engine can be reinstalled
    /// underneath a running app, and this is a file read.
    var engineSupportsMigration: Bool { EngineContractStore.supportsMigration }

    /// Re-reads whatever the last scan left on disk. Cheap - one small file.
    func loadMigrationCandidates() {
        migrationCandidates = MigrationCandidateStore.load()
        hasScannedMigration = MigrationCandidateStore.hasScanned
    }

    /// Sweep the machine for applications Homebrew could manage.
    ///
    /// Detection only: the engine reads cask metadata and `Info.plist` files
    /// and writes a list. Nothing is installed, moved or downloaded, which is
    /// what makes it safe to offer as a plain button.
    ///
    /// A bulk run rather than a per-item one, and watched through the shared
    /// progress file: the engine writes `scan-migration` there, so
    /// `ProgressBanner` names the step with no extra wiring.
    func scanMigration() {
        guard let script = scriptURL else { return report(.migrateScan, .toolkitMissing) }
        guard !isScanningMigration else { return }

        isScanningMigration = true
        // stdout, because that is where the engine puts the one answer this
        // call has to tell apart from a real failure - see `scanBusy`.
        startBulkProcess(script: script, arguments: ["scan_migration"], captureStandardOutput: true) { [weak self] outcome in
            guard let self else { return }
            self.isScanningMigration = false

            if !outcome.succeeded {
                if Self.scanLockWasBusy(outcome) {
                    // Not a failure of the toolkit: a refresh already holds
                    // the cache lock. Stop the watch by hand, because the run
                    // that would have written an ending to the progress file
                    // never got past acquiring that lock.
                    self.stopProgressWatch()
                    self.progress = nil
                    self.report(.migrateScan, .scanBusy)
                } else {
                    self.reportFailure(outcome, endedTheWatchedRun: true)
                }
                return
            }

            self.loadMigrationCandidates()
        }
        startProgressWatch()
    }

    /// The engine's own words for "the cache lock is taken"
    /// (update_system.1h.sh, `scan_migration`), which it prints and exits 1
    /// on. Matched on the English sentence the engine writes, not on the exit
    /// code: exit 1 is also what a genuinely broken run gives.
    ///
    /// Both streams are checked so this keeps working if the message ever
    /// moves to stderr; if the wording changes, the banner quietly falls back
    /// to showing the raw output, which is what it would have shown anyway.
    private static let scanBusyMarker = "A cache refresh is already running"

    private static func scanLockWasBusy(_ outcome: ProcessOutcome) -> Bool {
        outcome.stdout.contains(scanBusyMarker) || outcome.stderr.contains(scanBusyMarker)
    }

    /// Hand one application over to Homebrew.
    ///
    /// `adopt` is the safe default: Homebrew takes over the bundle already on
    /// disk and, when it will not, refuses without touching it. `replace`
    /// downloads the cask's copy over the installed one and is only ever
    /// reached because the user confirmed it. `dry` asks Homebrew what it
    /// would do and changes nothing.
    ///
    /// Goes through `startOrQueue` + `startSingleItemProcess` like every other
    /// per-item run, which is what keeps `GUIDEAPP_NO_SHARED_PROGRESS` set:
    /// `migrate_app` writes to the shared progress file, so two concurrent
    /// migrations launched any other way would overwrite each other's entry
    /// there.
    func migrate(candidate: MigrationCandidate, mode: MigrationMode = .adopt) {
        guard let script = scriptURL else {
            return report(.migrateItem, subject: candidate.appName, .toolkitMissing)
        }

        let item = Self.migrationItem(for: candidate)
        startOrQueue(item) { [weak self] in
            self?.startSingleItemProcess(
                item,
                script: script,
                arguments: ["migrate_app", candidate.appName, candidate.token, mode.rawValue],
                resolve: { [weak self] item, token, startedAt, outcome in
                    self?.finishMigration(
                        item, candidate: candidate, mode: mode,
                        token: token, startedAt: startedAt, outcome: outcome
                    )
                }
            )
        }
    }

    /// Move an application to Homebrew in a real terminal window.
    ///
    /// The one thing the headless path cannot do: `migrate_to_cask` never runs
    /// sudo, because a background run has nowhere to show a password prompt.
    /// Here Homebrew has a tty and can ask.
    ///
    /// Single-flight and watched through the shared progress file, exactly
    /// like `updateSingle`'s terminal branch - the engine's `run migrate` mode
    /// writes `migrate` there, and `resolveActiveSingleItem` reads the run's
    /// result record when the file goes quiet.
    func migrateInTerminal(candidate: MigrationCandidate, mode: MigrationMode = .adopt) {
        guard let script = scriptURL else {
            return report(.migrateItem, subject: candidate.appName, .toolkitMissing)
        }

        let item = Self.migrationItem(for: candidate)
        beginTrackingSingleItem(item)
        let startedAt = Date()
        Task {
            let outcome = await Self.run(
                script: script,
                arguments: ["migrate_app_in_terminal", candidate.appName, candidate.token, mode.rawValue]
            )
            await MainActor.run {
                // See `launchUpdate`: nothing to watch if the launcher itself
                // failed - no terminal opened, so nothing will ever write.
                guard outcome.succeeded else {
                    return self.reportFailure(outcome, startedAt: startedAt)
                }
                self.startProgressWatch()
            }
        }
    }

    /// The row identity a migration run is tracked under.
    ///
    /// `migrate:<cask token>` because that is what the run files its result
    /// against (`ItemRunResult.candidateItemIDs`) - the engine is invoked with
    /// the app name but reports under the token it was moving to.
    ///
    /// A synthetic `UpdateItem` so the migration can use the same concurrency
    /// queue, spinner and fraction simulation every other per-item run uses,
    /// rather than growing a parallel set of all three. `.cask` is what it is
    /// becoming, and the versions are what the move would change.
    static func migrationItem(for candidate: MigrationCandidate) -> UpdateItem {
        UpdateItem(
            id: Self.migrationItemPrefix + candidate.token,
            source: .cask,
            name: candidate.appName,
            currentVersion: candidate.installedVersion,
            newVersion: candidate.caskVersion,
            link: candidate.caskPageURL
        )
    }

    /// A migration row's own end-of-run handling.
    ///
    /// Deliberately not `finishActiveItem`: that one ends on "is this item
    /// still in the outdated snapshot", which is meaningless here - a
    /// migration row was never in that list, so the fallback would read every
    /// run as a success. The result record is the only verdict, and unlike the
    /// update paths it is always there: this page does not draw at all unless
    /// the engine declared `migrationContract`, and an engine that declared it
    /// files records.
    private func finishMigration(_ item: UpdateItem,
                                 candidate: MigrationCandidate,
                                 mode: MigrationMode,
                                 token: Int,
                                 startedAt: Date,
                                 outcome: ProcessOutcome) {
        // Same guard, same reason, as finishActiveItem: a cancelled or
        // superseded run does not get to write this row's state.
        guard itemRunTokens[item.id] == token else { return }
        itemRunTokens[item.id] = nil
        activeProcesses[item.id] = nil

        let record = ItemRunResultStore.consume(itemID: item.id, since: startedAt)
        // No record and a clean exit is the only case left to guess at, and
        // the honest reading is the process's own status - `migrate_app`
        // returns non-zero for every failure it reports.
        let succeeded = record?.succeeded ?? outcome.succeeded
        itemStatuses[item.id] = succeeded ? .succeeded : .failed

        if succeeded {
            itemFailureReasons[item.id] = nil
        } else {
            let reason = Self.failureReason(record: record, outcome: outcome)
            itemFailureReasons[item.id] = reason

            // The same offer `finishActiveItem` makes, and it has to be made
            // here too: `migrate_to_cask` never runs sudo (nowhere to prompt
            // on a headless run), but Homebrew can still need a password to
            // write over a root-owned bundle or an /Applications this user
            // cannot write to. That is not the `needs-root` state - the engine
            // predicts that one from cask metadata and refuses up front - it
            // is the unforeseen case, recognised from what sudo printed.
            // Until this, `autoOpenTerminalWhenRequired` was simply ignored on
            // this page and the failure had no way out at all.
            var needsTerminal = false
            if case .needsTerminal = reason { needsTerminal = true }
            let openNow = needsTerminal && preferences.autoOpenTerminalWhenRequired

            report(
                .migrateItem,
                subject: candidate.appName,
                reason,
                recovery: (needsTerminal && !openNow) ? .runInTerminal(itemID: item.id) : nil
            )

            if openNow {
                // After the report, so the explanation is already on screen
                // when the window opens.
                Task { @MainActor [weak self] in
                    self?.migrateInTerminal(candidate: candidate, mode: mode)
                }
            }
        }

        endFractionSimulation(for: item.id)
        scheduleStatusClear(for: item.id)
        drainQueue()

        snapshot = UpdateSnapshot.load()

        if succeeded {
            // Drop the row from the list it was on: the app it described is no
            // longer unmanaged, and a stale row invites a second attempt at
            // something already done.
            migrationCandidates.removeAll { $0.appName == candidate.appName }
            // The app is a cask now, so the installed-apps inventory is stale.
            // The controller does not own that store - it is an `@Observable`
            // the views hold (see MacUpdaterGuideApp) - so this counter is what
            // it tells them with: the page watches it and reloads. A counter
            // rather than a flag so two migrations finishing in a row are two
            // separate changes, not one the second of which is missed.
            migrationsCompleted += 1
        }
    }

    /// The row state a migration candidate is showing, if any - the same
    /// queued/updating/succeeded/failed states every other per-item run uses.
    func migrationStatus(for candidate: MigrationCandidate) -> ItemUpdateStatus? {
        itemStatuses[Self.migrationItemPrefix + candidate.token]
    }

    func migrationFailureReason(for candidate: MigrationCandidate) -> ActionFailure.Reason? {
        itemFailureReasons[Self.migrationItemPrefix + candidate.token]
    }

    func migrationFraction(for candidate: MigrationCandidate) -> Double? {
        itemFractions[Self.migrationItemPrefix + candidate.token]
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
    func report(_ action: ActionFailure.Action,
                subject: String? = nil,
                _ reason: ActionFailure.Reason,
                recovery: ActionFailure.Recovery? = nil) {
        lastFailure = ActionFailure(action: action, subject: subject, reason: reason, recovery: recovery)
    }

    /// Does the thing the banner's button offered, then clears the banner -
    /// the failure has been answered, and leaving it up next to a run that is
    /// now starting would say the opposite.
    ///
    /// Only ever reached from a button the user pressed: the app never opens
    /// a terminal window on its own.
    func recover(from recovery: ActionFailure.Recovery) {
        switch recovery {
        case .runInTerminal(let itemID):
            // A migration row is not an update row: its id is
            // `migrate:<token>`, it is never in `snapshot.items` (the app was
            // never outdated - it was unmanaged), and re-running it as an
            // update would run `run single cask migrate:<token>`, which is
            // nonsense. Checked first, so the lookup below never sees one.
            if let candidate = migrationCandidate(forItemID: itemID) {
                dismissFailure()
                return migrateInTerminal(candidate: candidate)
            }

            // The banner outlives the row: `scheduleStatusClear` drops the
            // item from `recentItemsByID` eight seconds after the failure,
            // while the failure itself stays up until it is read. The
            // snapshot is the fallback that keeps the button working after
            // that - and it always has the item, because an upgrade that
            // failed is by definition still outdated.
            guard let item = recentItemsByID[itemID] ?? snapshot.items.first(where: { $0.id == itemID }) else {
                // Pressing a button and getting nothing back is the failure
                // mode this app keeps having to fix; it does not get to
                // happen here too.
                return report(.startRun, .itemGone)
            }
            dismissFailure()
            updateSingle(item, forceTerminal: true)
        }
    }

    /// The candidate a `migrate:<token>` row id refers to, or `nil` when the
    /// id is not a migration row at all.
    ///
    /// Read back from `migrationCandidates` rather than from
    /// `recentItemsByID`: the synthetic `UpdateItem` kept there carries only
    /// the token and versions, and re-running the move needs the app name the
    /// engine is invoked with. A failed candidate is still on the list -
    /// `finishMigration` only removes the ones that succeeded - which is
    /// exactly the case this button exists for.
    func migrationCandidate(forItemID itemID: String) -> MigrationCandidate? {
        guard itemID.hasPrefix(Self.migrationItemPrefix) else { return nil }
        let token = String(itemID.dropFirst(Self.migrationItemPrefix.count))
        return migrationCandidates.first { $0.token == token }
    }

    /// The one place the `migrate:` row-id prefix is spelled. It has to agree
    /// with `ItemRunResult.candidateItemIDs`, which is how a run's result
    /// record finds the row waiting on it.
    static let migrationItemPrefix = "migrate:"

    /// Drops the failure the banner is showing - the banner's own dismiss
    /// button, and nothing else: a failure stays up until it is read.
    func dismissFailure() {
        lastFailure = nil
    }

    /// Says out loud that the engine cannot answer what this build asks it,
    /// after a run that has just finished and therefore would have left a
    /// current record if it could.
    ///
    /// This is the whole point of the contract record. The fallback it
    /// replaces stays where it is - a row still needs a status, and the
    /// documented rule is that no record means "check the outdated list",
    /// never "failed" - but it is no longer silent, so a user watching a
    /// successful upgrade get marked failed is told why the app disagrees
    /// with what they saw.
    func reportEngineContract(forRunStartedAt startedAt: Date) {
        guard !reportedEngineContract else { return }
        let declared = EngineContractStore.declared(forRunStartedAt: startedAt)
        guard declared?.meetsRequirement != true else { return }
        reportedEngineContract = true
        report(.engineOutdated, .engineContract(found: declared?.contract))
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
}
