import Foundation
import Observation

/// One line of a pipe-delimited config file.
struct ConfigEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    var fields: [String]

    init(id: UUID = UUID(), fields: [String]) {
        self.id = id
        self.fields = fields
    }

    subscript(index: Int) -> String {
        get { index < fields.count ? fields[index] : "" }
        set {
            while fields.count <= index { fields.append("") }
            fields[index] = newValue
        }
    }
}

/// Reads and writes the toolkit's `name|value|value` config files.
///
/// These were previously edited by hand in a text editor. Asking someone to
/// open TextEdit and get a pipe-delimited format right is a poor way to offer a
/// setting, so the app owns them now - but the on-disk format is unchanged,
/// because the shell side still parses it.
enum PipeConfig {

    /// Comment lines are dropped on read and the header is rewritten on save,
    /// so the file keeps its explanation without the app having to round-trip
    /// arbitrary user comments.
    static func load(_ url: URL, fieldCount: Int) -> [ConfigEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> ConfigEntry? in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

                var fields = line
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }

                guard let first = fields.first, !first.isEmpty else { return nil }
                while fields.count < fieldCount { fields.append("") }

                return ConfigEntry(fields: Array(fields.prefix(fieldCount)))
            }
    }

    @discardableResult
    static func save(_ entries: [ConfigEntry], to url: URL, header: String) -> Bool {
        var text = header
        if !text.hasSuffix("\n") { text += "\n" }

        for entry in entries {
            // A pipe inside a value would split the line when the shell reads it
            let cleaned = entry.fields.map {
                $0.replacingOccurrences(of: "|", with: " ")
                  .trimmingCharacters(in: .whitespaces)
            }
            guard let first = cleaned.first, !first.isEmpty else { continue }
            text += cleaned.joined(separator: "|") + "\n"
        }

        do {
            try FileManager.default.createDirectory(
                at: ToolkitPaths.supportDirectory,
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path(percentEncoded: false)
            )
            return true
        } catch {
            return false
        }
    }
}

/// How an application is checked for updates.
enum TrackingMethod: String, CaseIterable, Identifiable, Sendable {
    case sparkle
    case github
    case homebrew
    case skip

    var id: String { rawValue }

    var label: Localized {
        switch self {
        case .sparkle: return Localized("Sparkle feed", "Sparkle akışı")
        case .github: return Localized("GitHub releases", "GitHub sürümleri")
        case .homebrew: return Localized("Homebrew", "Homebrew")
        case .skip: return Localized("Never check", "Hiç kontrol etme")
        }
    }

    var identifierPrompt: Localized {
        switch self {
        case .sparkle: return Localized("https://example.com/appcast.xml", "https://ornek.com/appcast.xml")
        case .github: return Localized("owner/repository", "sahip/depo")
        case .homebrew: return Localized("cask-token", "cask-adi")
        case .skip: return Localized("not used", "kullanılmıyor")
        }
    }

    var identifierLabel: Localized {
        switch self {
        case .sparkle: return Localized("Feed URL", "Akış adresi")
        case .github: return Localized("Repository", "Depo")
        case .homebrew: return Localized("Cask token", "Cask adı")
        case .skip: return Localized("—", "—")
        }
    }

    var symbol: String {
        switch self {
        case .sparkle: return "sparkles"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .homebrew: return "shippingbox"
        case .skip: return "minus.circle"
        }
    }
}

/// Per-app read/write for `tracked_apps.conf`, used by the "Edit Tracking
/// Method…" sheet on an app row - the same file `TrackedAppsEditor` manages as
/// a full list, but scoped to one app so fixing a single wrong entry does not
/// require finding it in a long list first.
enum TrackedAppsStore {
    static func entry(forApp name: String) -> (method: TrackingMethod, identifier: String)? {
        for entry in PipeConfig.load(ToolkitPaths.trackedAppsFile, fieldCount: 3)
        where entry[0].caseInsensitiveCompare(name) == .orderedSame {
            guard let method = TrackingMethod(rawValue: entry[1]) else { return nil }
            return (method, entry[2])
        }
        return nil
    }

    static func setEntry(appName: String, method: TrackingMethod, identifier: String) {
        var entries = PipeConfig.load(ToolkitPaths.trackedAppsFile, fieldCount: 3)
        entries.removeAll { $0[0].caseInsensitiveCompare(appName) == .orderedSame }
        entries.append(ConfigEntry(fields: [appName, method.rawValue, identifier]))
        PipeConfig.save(entries, to: ToolkitPaths.trackedAppsFile, header: ToolkitPaths.trackedAppsTemplate)
    }

    static func removeEntry(appName: String) {
        var entries = PipeConfig.load(ToolkitPaths.trackedAppsFile, fieldCount: 3)
        entries.removeAll { $0[0].caseInsensitiveCompare(appName) == .orderedSame }
        PipeConfig.save(entries, to: ToolkitPaths.trackedAppsFile, header: ToolkitPaths.trackedAppsTemplate)
    }
}

/// Per-app read/write for `app_token_map.conf`, used by the "Edit Homebrew
/// Mapping…" sheet on an app row - same file `TokenMapEditor` manages as a
/// full list, scoped to the one app already on screen.
enum TokenMapStore {
    static func token(forApp name: String) -> String? {
        for entry in PipeConfig.load(ToolkitPaths.tokenMapFile, fieldCount: 2)
        where entry[0].caseInsensitiveCompare(name) == .orderedSame {
            return entry[1].isEmpty ? nil : entry[1]
        }
        return nil
    }

    static func setToken(appName: String, token: String) {
        var entries = PipeConfig.load(ToolkitPaths.tokenMapFile, fieldCount: 2)
        entries.removeAll { $0[0].caseInsensitiveCompare(appName) == .orderedSame }
        entries.append(ConfigEntry(fields: [appName, token]))
        PipeConfig.save(entries, to: ToolkitPaths.tokenMapFile, header: ToolkitPaths.tokenMapTemplate)
    }

    static func removeToken(appName: String) {
        var entries = PipeConfig.load(ToolkitPaths.tokenMapFile, fieldCount: 2)
        entries.removeAll { $0[0].caseInsensitiveCompare(appName) == .orderedSame }
        PipeConfig.save(entries, to: ToolkitPaths.tokenMapFile, header: ToolkitPaths.tokenMapTemplate)
    }
}

/// Where the sidebar is pointing. Shared so the menu bar, the keyboard shortcut
/// and the sidebar itself all drive the same selection.
@Observable
@MainActor
final class NavigationStore {
    var selection: SidebarItem? = .updates

    func show(_ item: SidebarItem) {
        selection = item
    }
}
