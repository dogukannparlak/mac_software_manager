import Foundation

/// What an update run is doing right now.
///
/// The run itself happens in a terminal window, so the app cannot watch its
/// output directly. Instead the script writes one line to `cache/progress` and
/// this reads it - the menu bar can then name the package being installed
/// without taking the run away from the terminal, where the user can still see
/// everything and stop it.
struct UpdateProgress: Equatable, Sendable {

    enum State: String, Sendable {
        case running
        case done
        case failed
    }

    enum Phase: String, Sendable {
        case starting
        case brewUpdate = "brew-update"
        case analyze
        case brewUpgrade = "brew-upgrade"
        case masUpgrade = "mas-upgrade"
        case cleanup
        case verify
        case installApp = "install-app"
        case single
        case complete
        /// The run reached the end, but the verify pass found items that
        /// were still outdated - written by `progress_write_completion()`
        /// with `index` = how many failed and `total` = how many were
        /// attempted. Separate from `.complete` because `state` alone
        /// ("failed") would otherwise be paired with the label "Finished".
        case completeWithFailures = "complete-with-failures"
        case unknown
        /// The toolkit process itself exited non-zero or was killed - caught on
        /// the Swift side (ToolkitController), not written by the shell script.
        /// Distinct from a stale "running" state: this means the process is
        /// definitely gone, not just quiet.
        case processError = "process-error"
        /// Set only by `ToolkitController.cancelUpdate()`, never written to
        /// the progress file - the user stopped this run on purpose, so it
        /// gets its own, non-alarming label instead of "Update failed".
        case cancelled
        /// Set only by `ToolkitController`'s progress watch, never written to
        /// the progress file: the run was asked for, but nothing of it ever
        /// reached `cache/progress` within `ProgressWatch.startupTimeout`.
        /// Distinct from `.processError` - there is no exit status here,
        /// nothing was ever seen to start.
        case notStarted = "not-started"

        var label: Localized {
            switch self {
            case .starting: return Localized("Starting…", "Başlıyor…")
            case .brewUpdate: return Localized("Refreshing Homebrew", "Homebrew yenileniyor")
            case .analyze: return Localized("Working out what to update", "Ne güncelleneceği belirleniyor")
            case .brewUpgrade: return Localized("Updating Homebrew packages", "Homebrew paketleri güncelleniyor")
            case .masUpgrade: return Localized("Updating App Store apps", "App Store uygulamaları güncelleniyor")
            case .cleanup: return Localized("Cleaning up", "Temizleniyor")
            case .verify: return Localized("Checking the results", "Sonuçlar kontrol ediliyor")
            case .installApp: return Localized("Installing", "Kuruluyor")
            case .single: return Localized("Updating", "Güncelleniyor")
            case .complete: return Localized("Finished", "Bitti")
            case .completeWithFailures:
                return Localized("Finished with errors", "Hatalarla bitti")
            case .unknown: return Localized("Working…", "Çalışıyor…")
            case .processError: return Localized("Update failed", "Güncelleme başarısız oldu")
            case .cancelled: return Localized("Cancelled", "İptal edildi")
            case .notStarted:
                return Localized("Update did not start", "Güncelleme başlamadı")
            }
        }

        /// Whether this phase can legitimately produce nothing for a long
        /// time: it is waiting on one download or one build, not stepping
        /// through a list of them. Picks which `staleAfter` window applies -
        /// see the two constants below.
        var canBeSilentForLong: Bool {
            switch self {
            case .brewUpgrade, .masUpgrade, .installApp, .single:
                return true
            // A phase this build does not know comes from a newer writer, so
            // there is nothing to base "should have written by now" on -
            // guessing "quick" here would risk calling a live run dead.
            case .unknown:
                return true
            case .starting, .brewUpdate, .analyze, .cleanup, .verify,
                 .complete, .completeWithFailures, .processError, .cancelled, .notStarted:
                return false
            }
        }
    }

    var state: State
    var phase: Phase
    var item: String
    var index: Int?
    var total: Int?
    /// When the line this was read from was last written, straight off the
    /// file's modification date. `ProgressWatch` needs it to tell an entry
    /// *this* run just wrote from one an earlier run left behind - reading a
    /// leftover "done|complete" as the current run's result is how a run that
    /// had not even started yet ended up reported as finished. Entries built
    /// in memory (cancelled, process-error) have no file behind them and keep
    /// the `.distantPast` default, which no freshness check can pass.
    var modified: Date = .distantPast

    /// The only format version this build understands. See CACHE_FORMAT.md -
    /// the shell writer (`PROGRESS_FORMAT_VERSION` in update_system.1h.sh)
    /// and this must agree, or `parse` fails closed instead of misreading.
    static let formatVersion = "v1"

    /// How long a `running` entry may go without being touched before it is
    /// read as a run that died. A run killed mid-flight (a closed terminal
    /// window, a panic, `kill -9`) never gets to write a final state, and
    /// without this the menu would claim to be busy forever - and
    /// `ToolkitController`'s per-item queue would wait forever behind a run
    /// that no longer exists.
    ///
    /// Two windows, because "has not been touched" means different things in
    /// different phases. The bookkeeping phases (`starting`, `analyze`,
    /// `verify`, ...) step through work and write as they go, so silence
    /// there is already suspicious. The phases below wait on one download or
    /// one build: `mas-upgrade` may legitimately be quiet for as long as
    /// `MAS_UPGRADE_TIMEOUT` (7200s, lib/utils.sh) and a single large
    /// `brew upgrade` package is no different. The one 15-minute window
    /// these replace declared exactly those runs failed *while they were
    /// still downloading*, and released the queue on top of them.
    ///
    /// A current toolkit re-stamps the file every
    /// `PROGRESS_HEARTBEAT_INTERVAL` seconds for as long as the run is alive
    /// (`progress_heartbeat_start`, lib/cache.sh), so neither window is
    /// reachable by a living run and a dead one is caught within
    /// `staleAfterQuick` at worst. `staleAfterLong` is what remains for a
    /// toolkit installed before that heartbeat existed, where a long quiet
    /// phase really is normal.
    static let staleAfterQuick: TimeInterval = 15 * 60
    static let staleAfterLong: TimeInterval = 2 * 60 * 60 + 15 * 60

    static func staleAfter(for phase: Phase) -> TimeInterval {
        phase.canBeSilentForLong ? staleAfterLong : staleAfterQuick
    }

    var isRunning: Bool { state == .running }

    /// "Updating Homebrew packages" / "Installing BetterDisplay"
    func title(for language: AppLanguage) -> String {
        phase.label[language]
    }

    /// "awscli (3 of 8)", or "3 of 8 failed" once a run has finished badly.
    func detail(for language: AppLanguage) -> String? {
        // A finished-with-failures entry carries counts, not a package name:
        // index is the failure count, total the number of items attempted.
        // Running them through the generic "(3 of 8)" wording below would
        // read as progress through a batch, so this phase words its own.
        if phase == .completeWithFailures, let failed = index, failed > 0 {
            if let total, total > 0 {
                let format = Localized("%d of %d failed", "%d / %d başarısız")[language]
                return String(format: format, failed, total)
            }
            return String(format: UIStrings.historyFailedFormat[language], failed)
        }

        var parts: [String] = []
        if !item.isEmpty { parts.append(item) }

        if let index, let total, total > 0 {
            let format = Localized("%d of %d", "%d / %d")[language]
            parts.append("(" + String(format: format, index, total) + ")")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var fractionCompleted: Double? {
        guard let index, let total, total > 0 else { return nil }
        return min(1.0, Double(index) / Double(total))
    }

    // MARK: - Reading

    static func load() -> UpdateProgress? {
        let url = ToolkitPaths.cacheFile("progress")
        let path = url.path(percentEncoded: false)

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        return parse(raw: raw, modified: modified)
    }

    /// The parsing logic in isolation, taking the file's raw content and
    /// modification date directly rather than reading them from disk - kept
    /// separate from `load()` (which is tied to the real, non-injectable
    /// `ToolkitPaths.cacheFile` location) so it can be unit-tested against
    /// arbitrary payloads without touching the filesystem.
    ///
    /// A missing or unrecognized version field (fields[0]) returns `nil` -
    /// the same "nothing to show" outcome every other malformed line already
    /// gets. Before the version field existed, an incompatible format would
    /// fall through to `State(rawValue: fields[0]) ?? .done`, silently
    /// reporting an unreadable line as a *successful* update; failing closed
    /// here is the whole point of the marker.
    static func parse(raw: String, modified: Date, now: Date = Date()) -> UpdateProgress? {
        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard fields.count >= 3, fields[0] == formatVersion else { return nil }

        var progress = UpdateProgress(
            state: State(rawValue: fields[1]) ?? .done,
            phase: Phase(rawValue: fields[2]) ?? .unknown,
            item: fields.count > 3 ? fields[3] : "",
            index: fields.count > 4 ? Int(fields[4]) : nil,
            total: fields.count > 5 ? Int(fields[5]) : nil,
            modified: modified
        )

        if progress.state == .running,
           now.timeIntervalSince(modified) > staleAfter(for: progress.phase) {
            progress.state = .failed
        }

        return progress
    }
}
