import AppKit
import Foundation
import Observation

/// Where an application came from.
enum InstallSource: String, CaseIterable, Identifiable, Sendable {
    case homebrew
    case appStore
    case setapp
    case manual
    case system

    var id: String { rawValue }

    var label: Localized {
        switch self {
        case .homebrew: return Localized("Homebrew", "Homebrew")
        case .appStore: return Localized("App Store", "App Store")
        case .setapp: return Localized("Setapp", "Setapp")
        case .manual: return Localized("Installed manually", "Elle kurulmuş")
        case .system: return Localized("Apple", "Apple")
        }
    }

    var symbol: String {
        switch self {
        case .homebrew: return "shippingbox.fill"
        case .appStore: return "bag.fill"
        case .setapp: return "s.square.fill"
        case .manual: return "hand.point.up.left.fill"
        case .system: return "apple.logo"
        }
    }

    var tint: Color {
        switch self {
        case .homebrew: return .orange
        case .appStore: return .blue
        case .setapp: return .purple
        case .manual: return .gray
        case .system: return .secondary
        }
    }

    /// Manually installed apps are the ones the toolkit can help with, so they
    /// sort first and everything Apple ships sorts last.
    var sortRank: Int {
        switch self {
        case .manual: return 0
        case .homebrew: return 1
        case .appStore: return 2
        case .setapp: return 3
        case .system: return 4
        }
    }
}

import SwiftUI

struct InstalledApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let source: InstallSource
    let url: URL
    let bundleIdentifier: String?
    /// Cask token, when Homebrew manages it.
    let token: String?
    /// "owner/repo" when the app can be traced back to GitHub.
    let githubRepo: String?
    /// True when `token` came from the user's Name Mapping list rather than
    /// from the automatic guess - worth calling out, since it means a person
    /// stepped in and corrected something.
    let isManuallyMapped: Bool

    var githubURL: URL? {
        guard let githubRepo else { return nil }
        return URL(string: "https://github.com/\(githubRepo)")
    }

    var githubReleasesURL: URL? {
        guard let githubRepo else { return nil }
        return URL(string: "https://github.com/\(githubRepo)/releases")
    }

    var homebrewURL: URL? {
        guard let token else { return nil }
        return URL(string: "https://formulae.brew.sh/cask/\(token)")
    }

    /// The developer's own site, when one is known - from the Homebrew cask
    /// definition (which requires a homepage) or, failing that, from the
    /// GitHub repository's own homepage field. Never guessed.
    var officialWebsiteURL: URL?

    /// True when either link above was corrected by hand in `app_links.conf`
    /// rather than detected automatically.
    var hasCustomLinks: Bool = false
}

/// A command line tool from Homebrew. No bundle, so no icon.
struct InstalledTool: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String
    let isPinned: Bool
}

/// Scans the Applications folders and works out where each app came from.
///
/// The shell toolkit already records which Homebrew casks are installed, so
/// this cross-references that list rather than shelling out to brew again.
enum InstalledInventory {

    static func load() -> (apps: [InstalledApp], tools: [InstalledTool]) {
        let caskTokens = caskVersionsByToken()
        let pinned = Set(cacheLines("brew_pinned"))
        let overrides = tokenOverrides()
        let caskMeta = caskMetadataByToken()
        let githubHomepages = websiteMap(fromCache: "github_homepages")
        let linkOverrides = linkOverridesByName()

        var apps: [InstalledApp] = []

        for directory in searchDirectories() {
            apps += scan(
                directory: directory,
                caskTokens: Set(caskTokens.keys),
                overrides: overrides,
                caskMeta: caskMeta,
                githubHomepages: githubHomepages,
                linkOverrides: linkOverrides
            )
        }

        let tools = cacheLines("brew_formulae").compactMap { line -> InstalledTool? in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let token = parts.first else { return nil }
            return InstalledTool(
                id: token,
                name: token,
                version: parts.count > 1 ? parts[1] : "",
                isPinned: pinned.contains(token)
            )
        }

        return (
            apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            tools.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        )
    }

    private static func searchDirectories() -> [URL] {
        var directories = [URL(filePath: "/Applications")]

        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: userApps.path(percentEncoded: false)) {
            directories.append(userApps)
        }

        // Setapp keeps its catalogue in a subfolder
        let setapp = URL(filePath: "/Applications/Setapp")
        if FileManager.default.fileExists(atPath: setapp.path(percentEncoded: false)) {
            directories.append(setapp)
        }

        return directories
    }

    /// The user's `app_token_map.conf`, keyed by lowercased application name.
    ///
    /// A name can be impossible to derive - "lghub" is the cask
    /// "logitech-g-hub" - so a mapping stated by hand has to beat the guess,
    /// otherwise writing one would appear to do nothing.
    static func tokenOverrides() -> [String: String] {
        var result: [String: String] = [:]

        for entry in PipeConfig.load(ToolkitPaths.tokenMapFile, fieldCount: 2) {
            let name = entry[0].lowercased()
            let token = entry[1]
            guard !name.isEmpty, !token.isEmpty else { continue }
            result[name] = token
        }

        return result
    }

    /// Cask tokens Homebrew currently has installed, used to tell a working
    /// mapping from a typo.
    static func installedCaskTokens() -> Set<String> {
        Set(caskVersionsByToken().keys)
    }

    struct LinkOverride: Sendable {
        var website: URL?
        var githubRepo: String?
    }

    /// The user's local corrections from `app_links.conf`, keyed by lowercased
    /// application name. Purely local: nothing here is ever uploaded or shared,
    /// and the shell engine never reads this file - it exists only for this UI.
    static func linkOverridesByName() -> [String: LinkOverride] {
        var result: [String: LinkOverride] = [:]

        for entry in PipeConfig.load(ToolkitPaths.appLinksFile, fieldCount: 3) {
            let name = entry[0].lowercased()
            guard !name.isEmpty else { continue }

            let website = entry[1].isEmpty ? nil : URL(string: entry[1])
            let repo = entry[2].isEmpty ? nil : entry[2]
            guard website != nil || repo != nil else { continue }

            result[name] = LinkOverride(website: website, githubRepo: repo)
        }

        return result
    }

    /// Writes (or updates) one app's link correction, leaving every other
    /// entry untouched. Passing `nil` for both fields removes the override and
    /// reverts that app to the automatic result.
    static func setLinkOverride(appName: String, website: URL?, githubRepo: String?) {
        var entries = PipeConfig.load(ToolkitPaths.appLinksFile, fieldCount: 3)
        entries.removeAll { $0[0].caseInsensitiveCompare(appName) == .orderedSame }

        if website != nil || githubRepo != nil {
            entries.append(ConfigEntry(fields: [
                appName,
                website?.absoluteString ?? "",
                githubRepo ?? ""
            ]))
        }

        PipeConfig.save(entries, to: ToolkitPaths.appLinksFile, header: ToolkitPaths.appLinksTemplate)
    }

    /// `key|value` cache lines turned into a lookup, keyed lowercase so the
    /// match does not depend on getting a name's exact casing right.
    private static func websiteMap(fromCache name: String) -> [String: URL] {
        var result: [String: URL] = [:]
        for line in cacheLines(name) {
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 2, let url = URL(string: fields[1]) else { continue }
            result[fields[0].lowercased()] = url
        }
        return result
    }

    private struct CaskMeta {
        var homepage: URL?
        /// "owner/repo", when the cask's download URL is a GitHub release asset.
        var githubRepo: String?
    }

    /// `token|homepage|repo` cache lines - `repo` is blank for casks that do
    /// not download from GitHub releases.
    private static func caskMetadataByToken() -> [String: CaskMeta] {
        var result: [String: CaskMeta] = [:]
        for line in cacheLines("cask_homepages") {
            let fields = line.components(separatedBy: "|")
            guard let token = fields.first, !token.isEmpty else { continue }

            let homepage = fields.count > 1 ? URL(string: fields[1]) : nil
            let repo = (fields.count > 2 && !fields[2].isEmpty) ? fields[2] : nil
            guard homepage != nil || repo != nil else { continue }

            result[token.lowercased()] = CaskMeta(homepage: homepage, githubRepo: repo)
        }
        return result
    }

    private static func scan(
        directory: URL,
        caskTokens: Set<String>,
        overrides: [String: String],
        caskMeta: [String: CaskMeta],
        githubHomepages: [String: URL],
        linkOverrides: [String: LinkOverride]
    ) -> [InstalledApp] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        return entries.compactMap { url -> InstalledApp? in
            guard url.pathExtension == "app" else { return nil }

            let name = url.deletingPathExtension().lastPathComponent
            let bundle = Bundle(url: url)
            let info = bundle?.infoDictionary

            let version = (info?["CFBundleShortVersionString"] as? String)
                ?? (info?["CFBundleVersion"] as? String)
                ?? "—"
            let bundleIdentifier = info?["CFBundleIdentifier"] as? String

            // A hand-written mapping wins, but only when that cask is really
            // installed - otherwise the app would be labelled Homebrew-managed
            // on the strength of a typo.
            var matchedToken: String?
            var isManualMatch = false
            if let override = overrides[name.lowercased()], caskTokens.contains(override) {
                matchedToken = override
                isManualMatch = true
            } else if !caskTokens.isEmpty {
                matchedToken = caskCandidates(for: name).first { caskTokens.contains($0) }
            }

            let source = resolveSource(
                url: url,
                bundleIdentifier: bundleIdentifier,
                matchedToken: matchedToken
            )

            // A cask's own metadata is the most reliable source available (the
            // homepage it declares, the repo it actually downloads from);
            // Sparkle-feed / bundle-id derivation is the fallback for apps
            // Homebrew does not manage.
            let meta = matchedToken.flatMap { caskMeta[$0.lowercased()] }
            var website = meta?.homepage ?? githubHomepages[name.lowercased()]
            var repo = meta?.githubRepo
                ?? githubRepository(for: url, bundleIdentifier: bundleIdentifier)

            // A local correction always wins - that is the entire point of it -
            // but only replaces the field the user actually filled in, so
            // fixing just the website does not blank out a working repo link.
            var hasCustomLinks = false
            if let override = linkOverrides[name.lowercased()] {
                hasCustomLinks = true
                if let overrideWebsite = override.website { website = overrideWebsite }
                if let overrideRepo = override.githubRepo { repo = overrideRepo }
            }

            return InstalledApp(
                id: url.path(percentEncoded: false),
                name: name,
                version: version,
                source: source,
                url: url,
                bundleIdentifier: bundleIdentifier,
                token: matchedToken,
                githubRepo: repo,
                isManuallyMapped: isManualMatch,
                officialWebsiteURL: website,
                hasCustomLinks: hasCustomLinks
            )
        }
    }

    private static func resolveSource(
        url: URL,
        bundleIdentifier: String?,
        matchedToken: String?
    ) -> InstallSource {
        let path = url.path(percentEncoded: false)

        if path.contains("/Applications/Setapp/") {
            return .setapp
        }

        let receipt = url.appending(path: "Contents/_MASReceipt", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: receipt.path(percentEncoded: false)) {
            return .appStore
        }

        if matchedToken != nil {
            return .homebrew
        }

        if let bundleIdentifier, bundleIdentifier.hasPrefix("com.apple.") {
            return .system
        }

        return .manual
    }

    /// Works out the GitHub repository behind an app, in the same order the
    /// shell engine does: a GitHub host in the Sparkle feed URL is proof, a
    /// com.github.owner.repo bundle identifier is a good guess, anything less
    /// certain is not worth showing a link for.
    static func githubRepository(for appURL: URL, bundleIdentifier: String?) -> String? {
        let plist = appURL.appending(path: "Contents/Info.plist")

        if let info = NSDictionary(contentsOf: plist),
           let feed = info["SUFeedURL"] as? String,
           let repo = repository(fromFeed: feed) {
            return repo
        }

        if let bundleIdentifier, bundleIdentifier.hasPrefix("com.github.") {
            let parts = bundleIdentifier
                .replacingOccurrences(of: "com.github.", with: "")
                .split(separator: ".")
            if parts.count >= 2 {
                return "\(parts[0])/\(parts[1])"
            }
        }

        return nil
    }

    private static func repository(fromFeed feed: String) -> String? {
        guard let components = URLComponents(string: feed), let host = components.host else {
            return nil
        }

        let segments = components.path.split(separator: "/").map(String.init)

        // https://owner.github.io/Repo/appcast.xml
        if host.hasSuffix(".github.io") {
            let owner = String(host.dropLast(".github.io".count))
            guard let repo = segments.first, !owner.isEmpty else { return nil }
            return "\(owner)/\(repo)"
        }

        // https://github.com/owner/repo/... and raw.githubusercontent.com/owner/repo/...
        guard host == "github.com" || host == "raw.githubusercontent.com" else { return nil }
        guard segments.count >= 2 else { return nil }
        return "\(segments[0])/\(segments[1])"
    }

    // MARK: - Cache helpers

    private static func cacheLines(_ name: String) -> [String] {
        guard let text = try? String(contentsOf: ToolkitPaths.cacheFile(name), encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `token version...` from `brew list --cask --versions`
    private static func caskVersionsByToken() -> [String: String] {
        var result: [String: String] = [:]
        for line in cacheLines("brew_casks") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let token = parts.first else { continue }
            result[token] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    /// Same shape as the shell side: an app name rarely equals its cask token
    /// ("AltTab" is "alt-tab"), so try the obvious transformations.
    /// Deliberately excludes progressive truncation - a wrong match here would
    /// mislabel where an app came from.
    static func caskCandidates(for appName: String) -> [String] {
        let base = appName.lowercased().replacingOccurrences(of: " ", with: "-")
        let camel = splitCamelCase(appName)

        var candidates = [base]
        if camel != base { candidates.append(camel) }
        candidates.append(base.replacingOccurrences(of: ".", with: ""))
        candidates.append(camel.replacingOccurrences(of: ".", with: ""))

        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func splitCamelCase(_ value: String) -> String {
        var output = ""
        let characters = Array(value)

        for (index, character) in characters.enumerated() {
            if index > 0, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase

                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    output.append("-")
                }
            }
            output.append(character)
        }

        return output
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "--", with: "-")
    }
}

/// Icons are read from disk, so they are fetched once and kept.
@Observable
@MainActor
final class AppIconCache {
    private var icons: [String: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        let key = url.path(percentEncoded: false)
        if let cached = icons[key] { return cached }

        let image = NSWorkspace.shared.icon(forFile: key)
        image.size = NSSize(width: 32, height: 32)
        icons[key] = image
        return image
    }

    /// Best-effort icon for an update entry, matched by application name.
    func icon(forAppNamed name: String) -> NSImage? {
        for directory in ["/Applications", "/Applications/Setapp"] {
            let candidate = "\(directory)/\(name).app"
            if FileManager.default.fileExists(atPath: candidate) {
                return icon(for: URL(filePath: candidate))
            }
        }
        return nil
    }
}


/// Holds the scan result for the whole app.
///
/// Each view used to scan `/Applications` itself, which meant a picker could
/// render before its own scan finished and appear empty. One store, loaded when
/// the app starts and refreshed with the update cache, removes that class of
/// bug and the repeated work along with it.
@Observable
@MainActor
final class InventoryStore {
    private(set) var apps: [InstalledApp] = []
    private(set) var tools: [InstalledTool] = []
    private(set) var installedCaskTokens: Set<String> = []
    private(set) var isLoading = false

    /// Applications a tracking rule or a name mapping can sensibly apply to.
    var ruleCandidates: [InstalledApp] {
        apps.filter { $0.source == .manual || $0.source == .homebrew }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true

        let result = await Task.detached(priority: .userInitiated) {
            (
                inventory: InstalledInventory.load(),
                tokens: InstalledInventory.installedCaskTokens()
            )
        }.value

        apps = result.inventory.apps
        tools = result.inventory.tools
        installedCaskTokens = result.tokens
        isLoading = false
    }

    /// Rescans after a mapping changed, so the Installed Apps page reflects it
    /// straight away rather than at the next launch.
    func reload() async {
        isLoading = false
        await load()
    }

    /// Is this cask token actually installed?
    func isKnownCask(_ token: String) -> Bool {
        !token.isEmpty && installedCaskTokens.contains(token)
    }
}
