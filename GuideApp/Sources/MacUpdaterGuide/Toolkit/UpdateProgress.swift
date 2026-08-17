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
        case unknown

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
            case .unknown: return Localized("Working…", "Çalışıyor…")
            }
        }
    }

    var state: State
    var phase: Phase
    var item: String
    var index: Int?
    var total: Int?

    /// A run that died without writing a final state would otherwise leave the
    /// menu claiming to be busy forever.
    static let staleAfter: TimeInterval = 15 * 60

    var isRunning: Bool { state == .running }

    /// "Updating Homebrew packages" / "Installing BetterDisplay"
    func title(for language: AppLanguage) -> String {
        phase.label[language]
    }

    /// "awscli (3 of 8)"
    func detail(for language: AppLanguage) -> String? {
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

        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard fields.count >= 2 else { return nil }

        var progress = UpdateProgress(
            state: State(rawValue: fields[0]) ?? .done,
            phase: Phase(rawValue: fields[1]) ?? .unknown,
            item: fields.count > 2 ? fields[2] : "",
            index: fields.count > 3 ? Int(fields[3]) : nil,
            total: fields.count > 4 ? Int(fields[4]) : nil
        )

        if progress.state == .running, Date().timeIntervalSince(modified) > staleAfter {
            progress.state = .failed
        }

        return progress
    }
}
