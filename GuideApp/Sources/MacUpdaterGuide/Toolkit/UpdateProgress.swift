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

    /// A run that died without writing a final state would otherwise leave the
    /// menu claiming to be busy forever.
    static let staleAfter: TimeInterval = 15 * 60

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

        if progress.state == .running, now.timeIntervalSince(modified) > staleAfter {
            progress.state = .failed
        }

        return progress
    }
}
