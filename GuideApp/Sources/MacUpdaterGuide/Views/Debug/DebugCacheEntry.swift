import Foundation

/// One file the engine wrote, described the way CACHE_FORMAT.md describes it.
///
/// The freshness badge is not this app's opinion: the TTLs below are the ones
/// `lib/cache.sh` actually applies (`CACHE_TTL_*` and the `CACHE_KEYS_*`
/// tiers), so a row marked stale here is a row the engine's own
/// `cache_stale_tiers` would refresh on its next `refresh_cache auto`. That
/// is the only definition of stale worth showing - a second one maintained
/// here would drift from the engine within a release.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugCacheEntry: Identifiable, Sendable {

    enum Freshness: Sendable {
        case fresh
        case stale
        /// The entry deliberately carries no TTL: it is a record of the last
        /// run (`progress`, `engine`) or of a scan the user asked for
        /// (`migration_candidates`), not something a background refresh
        /// rebuilds on a clock.
        case untimed

        var label: String {
            switch self {
            case .fresh: return "fresh"
            case .stale: return "stale"
            case .untimed: return "no TTL"
            }
        }
    }

    var id: String { url.path(percentEncoded: false) }

    let url: URL
    let name: String
    let size: Int
    let modified: Date
    let lineCount: Int
    /// What `lib/cache.sh` would apply to this key, or nil for the untimed
    /// entries and for anything this build does not recognise.
    let ttl: TimeInterval?
    /// The `vN` marker in the first field of the first line, for the formats
    /// that carry one. Nil means the format is unversioned - which is the
    /// documented state of most of `cache/`, not a fault.
    let formatVersion: String?

    var age: TimeInterval { Date().timeIntervalSince(modified) }

    var freshness: Freshness {
        guard let ttl else { return .untimed }
        return age <= ttl ? .fresh : .stale
    }

    /// Whether asking the engine to rebuild this entry means anything.
    ///
    /// Only the tiered entries: `refresh_cache auto` walks the tiers and
    /// rebuilds whichever has gone stale. `progress` and the result records
    /// are written by runs, not by refreshes, so a "refresh" button on them
    /// would delete a file and rebuild nothing.
    var isRefreshable: Bool { ttl != nil }

    // MARK: - Reading a directory

    /// Every readable file in `directory`, newest first.
    ///
    /// `.tmp` files are listed rather than hidden: a record is written to
    /// `<name>.tmp` and renamed into place, so one still sitting there is
    /// either a write in flight or a run that died mid-write - and that is
    /// exactly the kind of thing this panel is for.
    static func load(from directory: URL) -> [DebugCacheEntry] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
            return []
        }

        return names
            .sorted()
            .compactMap { entry(at: directory.appending(path: $0), name: $0) }
            .sorted { $0.modified > $1.modified }
    }

    private static func entry(at url: URL, name: String) -> DebugCacheEntry? {
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        return DebugCacheEntry(
            url: url,
            name: name,
            size: (attributes[.size] as? Int) ?? 0,
            modified: (attributes[.modificationDate] as? Date) ?? .distantPast,
            lineCount: lines.count,
            ttl: ttl(forKey: name),
            formatVersion: versionMarker(in: lines.first.map(String.init))
        )
    }

    /// The first field of the first line, when it looks like a version
    /// marker. Deliberately shallow: this reports what is *written*, it does
    /// not validate it - a `v2` on a format this build reads as v1 is
    /// precisely the mismatch worth seeing in the table.
    private static func versionMarker(in line: String?) -> String? {
        guard let field = line?.components(separatedBy: "|").first, field.count >= 2 else { return nil }
        guard field.hasPrefix("v"), field.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return field
    }

    // MARK: - The engine's own TTLs

    /// `CACHE_TTL_UPDATES` - brew/mas outdated lists and the iTunes lookups.
    static let ttlUpdates: TimeInterval = 3600
    /// `CACHE_TTL_INSTALLED` - installed lists, descriptions, brew status.
    static let ttlInstalled: TimeInterval = 21600
    /// `CACHE_TTL_APPS` - one HTTP request per self-updating app, kept rare.
    static let ttlApps: TimeInterval = 21600
    /// `CACHE_TTL_WEBSITES` - a homepage practically never changes.
    static let ttlWebsites: TimeInterval = 86400

    private static let tiers: [(ttl: TimeInterval, keys: Set<String>)] = [
        (ttlUpdates, ["brew_outdated", "mas_outdated", "manual_updates"]),
        (ttlInstalled, [
            "brew_pinned", "brew_casks", "brew_formulae", "brew_leaves",
            "brew_formulae_desc", "brew_casks_desc", "mas_list", "brew_status"
        ]),
        (ttlApps, ["app_updates"]),
        (ttlWebsites, ["cask_homepages", "github_homepages"])
    ]

    static func ttl(forKey key: String) -> TimeInterval? {
        tiers.first { $0.keys.contains(key) }?.ttl
    }

    // MARK: - Formatting

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var modifiedText: String {
        Self.modifiedFormatter.string(from: modified)
    }

    /// "4m", "3h 20m", "2d 4h" - short enough for a table cell, and never
    /// relative wording ("about an hour ago"), because the question being
    /// asked of this column is how it compares with a TTL in seconds.
    var ageText: String {
        let seconds = Int(max(0, age))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(seconds / 86400)d \((seconds % 86400) / 3600)h"
    }

    var ttlText: String {
        guard let ttl else { return "—" }
        let hours = Int(ttl) / 3600
        return hours >= 1 ? "\(hours)h" : "\(Int(ttl) / 60)m"
    }

    private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
