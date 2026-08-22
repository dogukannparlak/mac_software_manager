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

    var snapshot = UpdateSnapshot()
    var progress: UpdateProgress?
    var isRefreshing = false
    var scriptURL: URL?

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
    var lastFailure: ActionFailure?

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
            /// The sweep for applications Homebrew could manage
            /// (`scan_migration`).
            case migrateScan
            /// One application being handed over to a cask (`migrate_app`).
            case migrateItem
            /// Not a failed action at all but a failed *assumption*: the
            /// installed engine cannot do what this build reads from it.
            /// It rides the same banner because it is the same kind of
            /// message - something did not work and nothing else on screen
            /// would have said so.
            case engineOutdated
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
            /// The engine that ran declared a contract this build cannot
            /// work with, or - the case that matters, and the one every
            /// engine older than the contract produces - declared nothing
            /// at all. `found` is what it declared, `nil` when it said
            /// nothing. See `EngineContract`.
            case engineContract(found: Int?)
            /// The package could not be updated without a password, and the
            /// run had no terminal to ask for one in.
            ///
            /// Homebrew uninstalls the old version before it installs the
            /// new one, and a cask whose uninstall stanza touches a
            /// system-owned path (`delete:` under /Library, `pkgutil:`,
            /// `launchctl:`) does that through `sudo`. A headless run has no
            /// tty, so sudo cannot prompt and the whole upgrade fails after
            /// the download - which is why the same packages fail every time
            /// while the rest update fine.
            ///
            /// Recognised from what the run printed rather than filed as a
            /// token by the shell: the failure can only happen on a headless
            /// run, which is exactly the case where the app has the run's
            /// stderr in hand. A terminal run has the tty sudo wanted, so it
            /// never gets here.
            case needsTerminal(detail: String)
            /// The scan could not start because a cache refresh already holds
            /// the lock it needs.
            ///
            /// Its own case rather than `.output`, because it is the one
            /// "failure" here that is not one: nothing is wrong, the engine
            /// printed "A cache refresh is already running." and exited 1
            /// (update_system.1h.sh, `scan_migration`), and the answer is to
            /// press the button again in a moment. Folded into the generic
            /// output banner it would read as a broken toolkit.
            case scanBusy
            /// The row a recovery button pointed at is no longer anywhere to
            /// be found. Should not happen - the snapshot keeps a failed
            /// item, because a failed upgrade is still outdated - but a
            /// button that does nothing at all is the one outcome this whole
            /// type exists to prevent.
            case itemGone

            /// What a finished process leaves to show: what it printed, or
            /// its exit status when it printed nothing.
            static func from(_ outcome: ProcessOutcome) -> Reason {
                if outcome.succeeded, outcome.stderr.isEmpty { return .noOutput }
                return .output(outcome.summary)
            }

            /// The three ways sudo says "there is nobody here to type a
            /// password". Matching sudo's own wording rather than brew's
            /// keeps this working whichever command underneath asked for the
            /// escalation; if sudo ever rewords them, the banner quietly goes
            /// back to showing the raw output, which is what it showed
            /// before this existed.
            private static let noTerminalForSudo = [
                "sudo: a terminal is required",
                "sudo: a password is required",
                "sudo: no tty present"
            ]

            static func needsTerminal(after outcome: ProcessOutcome) -> Bool {
                noTerminalForSudo.contains { outcome.stderr.contains($0) }
            }

            /// The part the app words itself: what went wrong, in the
            /// user's language. `nil` where the run's own output is the only
            /// account there is - see `evidence`.
            func headline(for language: AppLanguage) -> String? {
                switch self {
                case .toolkitMissing: return UIStrings.toolkitNotFoundDetail[language]
                case .output: return nil
                case .noOutput: return UIStrings.actionFailedNoReason[language]
                case .itemGone: return UIStrings.actionFailedItemGone[language]
                case .scanBusy: return UIStrings.migrateScanBusyDetail[language]
                case .reported(let reported, let detail):
                    // A token with no copy of its own (an unknown one from a
                    // newer toolkit, or one whose whole content is the
                    // output) leaves the printed detail to speak for itself.
                    guard let headline = reported.label?[language] else {
                        return detail.isEmpty ? UIStrings.actionFailedNoReason[language] : nil
                    }
                    return headline
                case .needsTerminal:
                    return UIStrings.updateNeedsTerminalDetail[language]
                case .engineContract(let found):
                    guard let found else { return UIStrings.engineContractMissingDetail[language] }
                    return String(
                        format: UIStrings.engineContractTooOldFormat[language],
                        found,
                        EngineContract.required
                    )
                }
            }

            /// What brew/mas/the script printed: raw, English, and long. Kept
            /// apart from the headline so a surface can put it behind a
            /// disclosure instead of making the user read a stack of shell
            /// output to find the one sentence that tells them what to do.
            var evidence: String {
                switch self {
                case .output(let text): return text
                case .reported(_, let detail): return detail
                case .needsTerminal(let detail): return detail
                case .toolkitMissing, .noOutput, .itemGone, .scanBusy, .engineContract: return ""
                }
            }

            /// Headline and evidence as one block - what a surface with no
            /// room for a disclosure (a row's own failure line) still shows.
            func text(for language: AppLanguage) -> String {
                guard let headline = headline(for: language) else {
                    return evidence.isEmpty ? UIStrings.actionFailedNoReason[language] : evidence
                }
                return evidence.isEmpty ? headline : headline + "\n" + evidence
            }
        }

        /// Something the user can press to get out of this failure, where
        /// the app knows of one. The banner renders it as a button; pressing
        /// it *is* the permission, so nothing happens until they do.
        enum Recovery: Equatable, Sendable {
            /// Re-run this row's update in a real terminal window, where the
            /// password prompt this failure was about has somewhere to
            /// appear. Carries the row id rather than the item so the
            /// failure stays a plain value - the controller looks the item
            /// back up when the button is pressed.
            case runInTerminal(itemID: String)

            func label(for language: AppLanguage) -> String {
                switch self {
                case .runInTerminal: return UIStrings.updateInTerminal[language]
                }
            }
        }

        let id = UUID()
        let action: Action
        /// The package or app this was about, where it was about one.
        let subject: String?
        let reason: Reason
        /// `nil` for every failure the app has no fix to offer for, which is
        /// most of them.
        var recovery: Recovery?

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
            case .migrateScan: return UIStrings.actionFailedMigrateScan[language]
            case .migrateItem: return named(UIStrings.actionFailedMigrateItemFormat, language)
            case .engineOutdated: return UIStrings.actionFailedEngineOutdated[language]
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
    var itemStatuses: [String: ItemUpdateStatus] = [:]
    /// Why a row's own update failed, per `UpdateItem.id`, for as long as its
    /// failed badge is up.
    ///
    /// `run single` exits 0 whether or not the package actually updated -
    /// success is decided by re-reading the outdated list (`finishActiveItem`)
    /// - so the process outcome used to be dropped on the floor with `_ in`.
    /// That left the row saying "Güncelleme başarısız" with the stderr that
    /// explains it discarded, and no way for anyone to find out why.
    var itemFailureReasons: [String: ActionFailure.Reason] = [:]
    /// Kept alongside `itemStatuses`: a successful update removes the item
    /// from `snapshot.items` (it is no longer outdated), but its row still
    /// needs the item's data to render while its "Updated" badge is showing.
    var recentItemsByID: [String: UpdateItem] = [:]

    /// Simulated 0...1 completion for a row's own progress bar, per
    /// `UpdateItem.id`. Neither `brew` nor `mas` expose a real per-package
    /// percentage the way a single download does, so this eases toward ~92%
    /// over a plausible duration instead - a smooth, one-directional fill
    /// with a number on it, rather than the bouncing indeterminate
    /// animation `ProgressView()` draws with no `value` at all. It only
    /// ever reaches 100% when the row actually resolves.
    var itemFractions: [String: Double] = [:]
    var fractionTasks: [String: Task<Void, Never>] = [:]

    /// One entry per currently-running headless single-item update, keyed by
    /// `UpdateItem.id` - up to `preferences.maxConcurrentUpdates` at once.
    /// Never used for terminal-mode runs (see `updateSingle`/`installApp`)
    /// or for the bulk run (`bulkProcess`, below).
    var activeProcesses: [String: Process] = [:]
    /// Which run currently owns each row, so a per-item process that has been
    /// cancelled - or superseded by the user pressing Update again on the
    /// same row - can be told apart from the one that row is actually
    /// waiting on. A row's token is cleared the moment its run stops being
    /// the current one, and `finishActiveItem` refuses to touch a row whose
    /// token has moved on: that is what lets `cancelItemUpdate` tear a row
    /// down immediately instead of hoping a process that may be ignoring
    /// SIGTERM gets around to exiting.
    var itemRunTokens: [String: Int] = [:]
    var nextItemRunToken = 0
    /// FIFO of item ids waiting for a free concurrency slot, plus what to
    /// actually run for each once its turn comes - `drainQueue()` pops both
    /// together. A plain array is fine at this scale (a handful of rows).
    var queuedItemIDs: [String] = []
    var queuedLaunchers: [String: () -> Void] = [:]
    /// Runs for exactly as long as `queuedItemIDs` is not empty - see
    /// `syncQueueDrainWatch()`.
    var queueDrainTask: Task<Void, Never>?

    /// The item a just-launched *terminal-mode* single-item run belongs to.
    /// Terminal mode stays single-flight (one visible window, watched
    /// directly) rather than joining the concurrency queue above, so it still
    /// needs the older "watch the shared progress file, resolve on quiet"
    /// approach `startProgressWatch()` uses.
    var activeSingleItem: UpdateItem?
    /// When that run was launched - what tells a result record it wrote from
    /// one an earlier run of the same item left behind, exactly as
    /// `watchStartedAt` does for the shared progress file.
    var activeSingleItemStartedAt: Date?
    /// The bulk run's own `Process`, kept only so `cancelUpdate()` has
    /// something to signal - never set for a terminal-mode run, where this
    /// object is just the short-lived launcher that opened the terminal
    /// window, not the actual work, and never set for a per-item run, which
    /// tracks itself in `activeProcesses` instead.
    var bulkProcess: Process?
    /// Set right before `cancelUpdate()` signals `bulkProcess`, so its
    /// termination handler knows the exit was requested and skips reporting
    /// it as a crash - overwriting the "Cancelled" state already written.
    var cancelledBulkRun = false

    var refreshTask: Task<Void, Never>?
    var timerTask: Task<Void, Never>?
    var progressTask: Task<Void, Never>?
    /// When the current progress watch began, or `nil` when none is running.
    /// Anything written to the shared progress file before this belongs to an
    /// earlier run - see `ProgressWatch` and `UpdateProgress.modified`.
    var watchStartedAt: Date?
    /// When this app last concluded on its own that the shared run was over:
    /// a bulk process of ours died, or the user cancelled one. Neither gets
    /// to write its ending, so the entry left in the file still says
    /// "running" - and every later read of that file (a reload, the queue's
    /// own poll) would otherwise put the run this app just reported as dead
    /// straight back on the banner, and park the queue behind it again until
    /// the entry aged out. Cleared when a new run starts watching.
    var resolvedRunAt: Date?

    // MARK: - Migration state
    //
    // Used from ToolkitRunner+Migration.swift, but declared here because an
    // extension cannot hold stored properties.

    /// What the last scan found. Empty until a scan has run - nothing writes
    /// `migration_candidates` in the background, by design (it costs a
    /// `brew info` round trip per candidate token).
    var migrationCandidates: [MigrationCandidate] = []
    /// Whether a scan has ever been run on this machine, which is a different
    /// question from whether it found anything: an empty list after a scan
    /// means "nothing to move", an empty list before one means "nobody has
    /// looked yet", and the page says a different thing for each.
    var hasScannedMigration = false
    /// True from the moment the scan is asked for until its process exits.
    /// The progress banner covers the run itself; this is what disables the
    /// button so it cannot be pressed twice into the same cache lock.
    var isScanningMigration = false

    /// Bumped once per successful migration, purely as a change for views to
    /// observe - see `finishMigration`. Never reset.
    var migrationsCompleted = 0

    /// Whether the engine-too-old banner has already been raised in this
    /// session. The mismatch is one standing condition, not one failure per
    /// row: reinstalling the engine is the only thing that changes it, and
    /// that means a restart, so saying it once is saying it.
    var reportedEngineContract = false

    let preferences: AppPreferences

    init(preferences: AppPreferences) {
        self.preferences = preferences
        scriptURL = ToolkitPaths.locateScript()
        reload()
    }

    var isToolkitInstalled: Bool { ToolkitPaths.isInstalled && scriptURL != nil }
}
