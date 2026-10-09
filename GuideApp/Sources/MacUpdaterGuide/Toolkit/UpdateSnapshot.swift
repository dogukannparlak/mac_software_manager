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

    /// The same `InstallSource` vocabulary the Installed Apps page groups
    /// by, so a pending app update lands in the same bucket its inventory
    /// entry would. `nil` for `.formula` - a CLI tool isn't "an app with an
    /// install source", it gets its own section instead (see
    /// `UpdateSnapshot.cliToolGroups`).
    var installSource: InstallSource? {
        switch self {
        case .formula: return nil
        case .cask: return .homebrew
        // manual_updates is Apple's own titles the mas CLI misses - still
        // App Store purchases, just detected a different way.
        case .appStore, .manual: return .appStore
        // Sparkle/GitHub self-updaters are, by definition, apps that did not
        // come from Homebrew or the App Store - the same "manual" bucket
        // InstalledInventory falls back to for anything else.
        case .sparkle, .github: return .manual
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
    /// Same taxonomy the CLI Tools page uses - assigned in
    /// `UpdateSnapshot.load()`, once real description/leaf data is available.
    /// The parsing helpers below default it to `.other`.
    var category: CLIToolCategory = .other
}

/// Everything the menu bar shows, read from the cache the shell scripts write.
struct UpdateSnapshot: Sendable {
    var items: [UpdateItem] = []
    var lastCheck: Date?
    var installedCount: Int = 0
    var cacheExists: Bool = false

    var count: Int { items.count }

    /// Paired with `count` so the call sites can say which question they are
    /// asking. Everything that reads a snapshot wants one of the two.
    var isEmpty: Bool { items.isEmpty }

    /// Pending app updates (everything but a formula), grouped by
    /// `InstallSource` - the same split the Installed Apps page uses
    /// (Homebrew / App Store / Installed manually).
    var appGroups: [(source: InstallSource, items: [UpdateItem])] {
        let grouped = Dictionary(grouping: items.filter { $0.source != .formula }) {
            $0.source.installSource ?? .manual
        }
        return InstallSource.allCases
            .sorted { $0.sortRank < $1.sortRank }
            .compactMap { source -> (InstallSource, [UpdateItem])? in
                guard let value = grouped[source], !value.isEmpty else { return nil }
                return (source, value.sorted { $0.name.lowercased() < $1.name.lowercased() })
            }
    }

    /// Pending formula updates, grouped by `CLIToolCategory` - the same
    /// taxonomy the CLI Tools page uses.
    var cliToolGroups: [(category: CLIToolCategory, items: [UpdateItem])] {
        let grouped = Dictionary(grouping: items.filter { $0.source == .formula }, by: \.category)
        return CLIToolCategory.allCases
            .sorted { $0.sortRank < $1.sortRank }
            .compactMap { category -> (CLIToolCategory, [UpdateItem])? in
                guard let value = grouped[category], !value.isEmpty else { return nil }
                return (category, value.sorted { $0.name.lowercased() < $1.name.lowercased() })
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

        let leaves = Set(contents(of: "brew_leaves"))
        let hasLeavesData = !leaves.isEmpty
        let formulaDescriptions = CLIToolCategorizer.parseDescriptions(contents(of: "brew_formulae_desc"))
        let caskDescriptions = CLIToolCategorizer.parseDescriptions(contents(of: "brew_casks_desc"))

        snapshot.items = snapshot.items.map { item in
            categorized(item, leaves: leaves, hasLeavesData: hasLeavesData, formulaDescriptions: formulaDescriptions, caskDescriptions: caskDescriptions)
        }

        snapshot.installedCount =
            lineCount("brew_casks") + lineCount("brew_formulae") + lineCount("mas_list")

        snapshot.lastCheck = ["brew_outdated", "mas_outdated", "manual_updates", "app_updates", "other_outdated"]
            .compactMap { modificationDate(of: $0) }
            .max()

        return snapshot
    }

    /// Assigns each pending update the same category a CLI tool or app would
    /// get on its respective inventory page. Formula updates reuse the
    /// leaf/dependency split so a transitive library update still lands in
    /// `.libraries` rather than cluttering a real category; every other
    /// source (cask, App Store, manual, self-updating) is always
    /// user-facing, so it is treated as a leaf.
    private static func categorized(
        _ item: UpdateItem,
        leaves: Set<String>,
        hasLeavesData: Bool,
        formulaDescriptions: [String: String],
        caskDescriptions: [String: String]
    ) -> UpdateItem {
        var item = item
        switch item.source {
        case .formula:
            let isLeaf = !hasLeavesData || leaves.contains(item.name)
            let description = formulaDescriptions[item.name]
            item.category = CLIToolCategorizer.categorize(token: item.name, description: description, isLeaf: isLeaf)
        case .cask:
            let description = caskDescriptions[item.name]
            item.category = CLIToolCategorizer.categorize(token: item.name, description: description, isLeaf: true)
        case .appStore, .manual, .sparkle, .github:
            item.category = CLIToolCategorizer.categorize(token: item.name, description: nil, isLeaf: true)
        }
        return item
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
        homebrewItems(lines: contents(of: "brew_outdated"), ignoring: ignored)
    }

    /// Internal (not private) so UpdateSnapshotParsingTests can exercise the
    /// parsing logic directly against in-memory lines, without going through
    /// ToolkitPaths' real, non-injectable file locations - see the doc
    /// comment on ProcessOutcome (ToolkitRunner.swift) for the same pattern.
    static func homebrewItems(lines: [String], ignoring ignored: IgnoreList) -> [UpdateItem] {
        lines.compactMap { line in
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
        appStoreItems(lines: contents(of: "mas_outdated"), ignoring: ignored)
    }

    /// Internal (not private) - see homebrewItems(lines:ignoring:) above.
    static func appStoreItems(lines: [String], ignoring ignored: IgnoreList) -> [UpdateItem] {
        lines.compactMap { line in
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
        manualItems(lines: contents(of: "manual_updates"), ignoring: ignored)
    }

    /// Internal (not private) - see homebrewItems(lines:ignoring:) above.
    static func manualItems(lines: [String], ignoring ignored: IgnoreList) -> [UpdateItem] {
        lines.compactMap { line in
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
        selfUpdatingItems(lines: contents(of: "app_updates"), ignoring: ignored)
    }

    /// Internal (not private) - see homebrewItems(lines:ignoring:) above.
    static func selfUpdatingItems(lines: [String], ignoring ignored: IgnoreList) -> [UpdateItem] {
        lines.compactMap { line in
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
        guard let text = try? String(contentsOf: ToolkitPaths.ignoredFile, encoding: .utf8) else {
            return IgnoreList()
        }
        return parse(text: text)
    }

    /// Internal (not private) - see homebrewItems(lines:ignoring:) above.
    static func parse(text: String) -> IgnoreList {
        var list = IgnoreList()

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
