import Foundation

/// One recorded update attempt.
///
/// The log is written by the shell toolkit as
/// `timestamp|source|name|old|new|id|status|reason`. Records written before
/// status tracking existed have six fields or fewer and are treated as
/// successes, which is what they were assumed to be at the time; records
/// written before the reason field existed have exactly seven and are read
/// with `reason == .none`.
struct HistoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let source: UpdateSource
    let name: String
    let oldVersion: String
    let newVersion: String
    let identifier: String
    let succeeded: Bool
    /// Whether this row is a "Move to Homebrew" run rather than a regular
    /// update - `lib/migrate.sh` logs those as source `migrate`, which reads
    /// back as `.cask` (the closest fit: it is a cask afterwards) but is
    /// tagged here so the row can say so and so `link` can use `identifier`
    /// (the cask token) instead of `name` (the app's display name).
    let isMigration: Bool
    /// Reuses `ItemRunResult.Reason` - the shell writes the exact same
    /// tokens into both the per-run result file and this log line.
    let reason: ItemRunResult.Reason
    /// Set when the line came from a package beyond Homebrew (`run tool`
    /// logs the manager's own name - npm, pipx, uv, …). `source` reads those
    /// back as `.formula`, the closest fit: a command line tool.
    var otherSource: PackageSource?

    var link: URL? {
        if let otherSource {
            switch otherSource {
            case .npm: return URL(string: "https://www.npmjs.com/package/\(name)")
            case .pipx, .uv: return URL(string: "https://pypi.org/project/\(name)/")
            case .cargo: return URL(string: "https://crates.io/crates/\(name)")
            case .go: return identifier.isEmpty ? nil : URL(string: "https://pkg.go.dev/\(identifier)")
            case .app, .local, .pkg: return nil
            }
        }
        switch source {
        case .formula: return URL(string: "https://formulae.brew.sh/formula/\(name)")
        case .cask:
            let token = isMigration ? identifier : name
            guard !token.isEmpty else { return nil }
            return URL(string: "https://formulae.brew.sh/cask/\(token)")
        case .appStore, .manual:
            guard !identifier.isEmpty else { return nil }
            return URL(string: "https://apps.apple.com/app/id\(identifier)")
        case .sparkle, .github: return nil
        }
    }
}

struct UpdateHistory: Sendable {
    var entries: [HistoryEntry] = []

    /// Newest first.
    static func load() -> UpdateHistory {
        guard let text = try? String(contentsOf: ToolkitPaths.historyFile, encoding: .utf8) else {
            return UpdateHistory()
        }

        var result: [HistoryEntry] = []

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let fields = rawLine.components(separatedBy: "|")
            guard fields.count >= 5,
                  let seconds = TimeInterval(fields[0]) else { continue }

            let name = fields[2]
            guard !name.isEmpty else { continue }

            let status = fields.count >= 7 ? fields[6] : "ok"
            let reasonToken = fields.count >= 8 ? fields[7] : ""

            result.append(
                HistoryEntry(
                    id: "\(fields[0])-\(offset)",
                    date: Date(timeIntervalSince1970: seconds),
                    source: source(from: fields[1]),
                    name: name,
                    oldVersion: fields[3],
                    newVersion: fields[4],
                    identifier: fields.count >= 6 ? fields[5] : "",
                    succeeded: status != "fail",
                    isMigration: fields[1] == "migrate",
                    reason: ItemRunResult.Reason(rawValue: reasonToken) ?? .none,
                    otherSource: PackageSource(rawValue: fields[1])
                )
            )
        }

        return UpdateHistory(entries: result.sorted { $0.date > $1.date })
    }

    private static func source(from raw: String) -> UpdateSource {
        switch raw {
        case "cask", "migrate": return .cask
        case "mas": return .appStore
        case "sparkle": return .sparkle
        case "github": return .github
        default: return .formula
        }
    }

    func entries(withinDays days: Int) -> [HistoryEntry] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.date >= cutoff }
    }

    /// Entries bucketed by calendar day, newest day first.
    func grouped(withinDays days: Int) -> [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let filtered = entries(withinDays: days)

        let buckets = Dictionary(grouping: filtered) { entry in
            calendar.startOfDay(for: entry.date)
        }

        return buckets
            .sorted { $0.key > $1.key }
            .map { (day: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
    }

    func successCount(withinDays days: Int) -> Int {
        entries(withinDays: days).count { $0.succeeded }
    }

    func failureCount(withinDays days: Int) -> Int {
        entries(withinDays: days).count { !$0.succeeded }
    }
}

/// Problems found in `settings.conf`.
///
/// The shell side refuses values it does not recognise and carries on with the
/// default; surfacing that here means a typo is visible instead of silently
/// changing behaviour.
struct ConfigWarning: Identifiable, Hashable, Sendable {
    let id: String
    let line: Int
    let message: Localized

    static func check() -> [ConfigWarning] {
        guard let text = try? String(contentsOf: ToolkitPaths.settingsFile, encoding: .utf8) else {
            return []
        }

        let knownKeys: Set<String> = [
            "PREFERRED_TERMINAL", "MAS_ENABLED", "UPDATE_BRANCH",
            "AUTOSTART", "CLEANUP_ENABLED", "AUTO_INSTALL_APPS",
            "CODEBERG_USERNAME"
        ]

        var warnings: [ConfigWarning] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let number = index + 1

            guard line.range(of: #"^[A-Z_]+="[^"]*"$"#, options: .regularExpression) != nil else {
                warnings.append(
                    ConfigWarning(
                        id: "syntax-\(number)",
                        line: number,
                        message: Localized(
                            "Line \(number) is not in KEY=\"value\" form and is ignored.",
                            "\(number). satır KEY=\"değer\" biçiminde değil, yok sayılıyor."
                        )
                    )
                )
                continue
            }

            let key = String(line.prefix(while: { $0 != "=" }))
            if !knownKeys.contains(key) {
                warnings.append(
                    ConfigWarning(
                        id: "unknown-\(number)",
                        line: number,
                        message: Localized(
                            "Unknown setting \"\(key)\" on line \(number) is ignored.",
                            "\(number). satırdaki bilinmeyen ayar \"\(key)\" yok sayılıyor."
                        )
                    )
                )
            }
        }

        return warnings
    }
}
