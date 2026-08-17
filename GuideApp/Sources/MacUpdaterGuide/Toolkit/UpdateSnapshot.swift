import Foundation

enum UpdateSource: String, Sendable {
    case formula
    case cask
    case appStore
    case manual
    case sparkle
    case github

    var symbol: String {
        switch self {
        case .formula: return "terminal"
        case .cask: return "shippingbox"
        case .appStore: return "bag"
        case .manual: return "exclamationmark.triangle"
        case .sparkle: return "sparkles"
        case .github: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var groupTitle: Localized {
        switch self {
        case .formula, .cask: return Localized("Homebrew", "Homebrew")
        case .appStore: return Localized("App Store", "App Store")
        case .manual, .sparkle, .github:
            return Localized("Manual update required", "Elle güncelleme gerekiyor")
        }
    }

    /// Groups that are shown together in the menu.
    var groupOrder: Int {
        switch self {
        case .formula, .cask: return 0
        case .appStore: return 1
        case .manual, .sparkle, .github: return 2
        }
    }
}

struct UpdateItem: Identifiable, Hashable, Sendable {
    let id: String
    let source: UpdateSource
    let name: String
    let currentVersion: String
    let newVersion: String
    /// Download or release page, when the update cannot be installed from here.
    let link: URL?
}

/// Everything the menu bar shows, read from the cache the shell scripts write.
struct UpdateSnapshot: Sendable {
    var items: [UpdateItem] = []
    var lastCheck: Date?
    var installedCount: Int = 0
    var cacheExists: Bool = false

    var count: Int { items.count }

    var groups: [(source: UpdateSource, items: [UpdateItem])] {
        let grouped = Dictionary(grouping: items, by: \.source.groupOrder)
        return grouped
            .sorted { $0.key < $1.key }
            .compactMap { _, value in
                guard let first = value.first else { return nil }
                return (first.source, value.sorted { $0.name.lowercased() < $1.name.lowercased() })
            }
    }

    // MARK: - Reading the cache

    static func load() -> UpdateSnapshot {
        var snapshot = UpdateSnapshot()
        snapshot.cacheExists = FileManager.default.fileExists(
            atPath: ToolkitPaths.cacheDirectory.path(percentEncoded: false)
        )

        let ignored = IgnoreList.load()

        snapshot.items += homebrewItems(ignoring: ignored)
        snapshot.items += appStoreItems(ignoring: ignored)
        snapshot.items += manualItems(ignoring: ignored)
        snapshot.items += selfUpdatingItems(ignoring: ignored)

        snapshot.installedCount =
            lineCount("brew_casks") + lineCount("brew_formulae") + lineCount("mas_list")

        snapshot.lastCheck = ["brew_outdated", "mas_outdated", "manual_updates", "app_updates"]
            .compactMap { modificationDate(of: $0) }
            .max()

        return snapshot
    }

    private static func contents(of name: String) -> [String] {
        guard let text = try? String(contentsOf: ToolkitPaths.cacheFile(name), encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func lineCount(_ name: String) -> Int {
        contents(of: name).count
    }

    private static func modificationDate(of name: String) -> Date? {
        let path = ToolkitPaths.cacheFile(name).path(percentEncoded: false)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date
    }

    /// `src|token|installed|current|pinned`
    private static func homebrewItems(ignoring ignored: IgnoreList) -> [UpdateItem] {
        contents(of: "brew_outdated").compactMap { line in
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 5 else { return nil }

            let isCask = fields[0] == "cask"
            let token = fields[1]

            guard fields[4] != "1" else { return nil }
            if isCask, ignored.contains(type: "cask", id: token) { return nil }

            return UpdateItem(
                id: "brew:\(token)",
                source: isCask ? .cask : .formula,
                name: token,
                currentVersion: fields[2],
                newVersion: fields[3],
                link: URL(string: isCask
                          ? "https://formulae.brew.sh/cask/\(token)"
                          : "https://formulae.brew.sh/formula/\(token)")
            )
        }
    }

    /// Raw `mas outdated` output: `123456 App Name (1.0 -> 1.1)`
    private static func appStoreItems(ignoring ignored: IgnoreList) -> [UpdateItem] {
        contents(of: "mas_outdated").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let idEnd = trimmed.firstIndex(of: " ") else { return nil }

            let identifier = String(trimmed[trimmed.startIndex..<idEnd])
            guard Int(identifier) != nil else { return nil }
            guard !ignored.contains(type: "mas", id: identifier) else { return nil }

            var remainder = String(trimmed[trimmed.index(after: idEnd)...])
                .trimmingCharacters(in: .whitespaces)

            var current = "?"
            var next = "?"

            if let open = remainder.lastIndex(of: "("), let close = remainder.lastIndex(of: ")"), open < close {
                let versions = String(remainder[remainder.index(after: open)..<close])
                remainder = String(remainder[remainder.startIndex..<open])
                    .trimmingCharacters(in: .whitespaces)

                let parts = versions.components(separatedBy: "->")
                if parts.count == 2 {
                    current = parts[0].trimmingCharacters(in: .whitespaces)
                    next = parts[1].trimmingCharacters(in: .whitespaces)
                } else {
                    next = versions.trimmingCharacters(in: .whitespaces)
                }
            }

            return UpdateItem(
                id: "mas:\(identifier)",
                source: .appStore,
                name: remainder,
                currentVersion: current,
                newVersion: next,
                link: URL(string: "https://apps.apple.com/app/id\(identifier)")
            )
        }
    }

    /// `name|local|remote|appID` - Apple apps the mas CLI misses
    private static func manualItems(ignoring ignored: IgnoreList) -> [UpdateItem] {
        contents(of: "manual_updates").compactMap { line in
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 4 else { return nil }
            guard !ignored.contains(type: "mas", id: fields[3]) else { return nil }

            return UpdateItem(
                id: "manual:\(fields[3])",
                source: .manual,
                name: fields[0],
                currentVersion: fields[1],
                newVersion: fields[2],
                link: URL(string: "https://apps.apple.com/app/id\(fields[3])")
            )
        }
    }

    /// `method|name|local|remote|url|signature`
    private static func selfUpdatingItems(ignoring ignored: IgnoreList) -> [UpdateItem] {
        contents(of: "app_updates").compactMap { line in
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 4 else { return nil }

            let name = fields[1]
            guard !ignored.contains(type: "sparkle", id: name) else { return nil }

            return UpdateItem(
                id: "app:\(name)",
                source: fields[0] == "github" ? .github : .sparkle,
                name: name,
                currentVersion: fields[2],
                newVersion: fields[3],
                link: fields.count >= 5 ? URL(string: fields[4]) : nil
            )
        }
    }
}

/// The `type|id|name` ignore list, so hidden entries stay hidden here too.
struct IgnoreList: Sendable {
    private var keys: Set<String> = []
    private(set) var entries: [(type: String, id: String, name: String)] = []

    static func load() -> IgnoreList {
        var list = IgnoreList()

        guard let text = try? String(contentsOf: ToolkitPaths.ignoredFile, encoding: .utf8) else {
            return list
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = rawLine.components(separatedBy: "|")
            guard fields.count >= 2 else { continue }

            let type = fields[0].trimmingCharacters(in: .whitespaces)
            let identifier = fields[1].trimmingCharacters(in: .whitespaces)
            guard !type.isEmpty, !identifier.isEmpty else { continue }

            let name = fields.count >= 3
                ? fields[2].trimmingCharacters(in: .whitespaces)
                : identifier

            list.keys.insert("\(type)|\(identifier)")
            list.entries.append((type, identifier, name.isEmpty ? identifier : name))
        }

        return list
    }

    func contains(type: String, id: String) -> Bool {
        keys.contains("\(type)|\(id)")
    }

    /// Rewrites the file without the given entry.
    static func remove(type: String, id: String) {
        guard let text = try? String(contentsOf: ToolkitPaths.ignoredFile, encoding: .utf8) else { return }

        let kept = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { line in
                let fields = line.components(separatedBy: "|")
                guard fields.count >= 2 else { return true }
                return !(fields[0] == type && fields[1] == id)
            }
            .joined(separator: "\n")

        let output = kept.isEmpty ? "" : kept + "\n"
        try? output.write(to: ToolkitPaths.ignoredFile, atomically: true, encoding: .utf8)
    }
}
