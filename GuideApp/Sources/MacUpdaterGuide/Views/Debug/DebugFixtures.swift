import Foundation

/// Fake payloads in the engine's own formats.
///
/// Pure functions, every one of them: input in, string out, no filesystem and
/// no clock except where a format carries a timestamp and the caller passes
/// it in. That is what makes them testable, and it is also what keeps the
/// formats honest - each generator is written straight from the table in
/// CACHE_FORMAT.md for that entry, and nothing here re-derives a field from
/// anything the app happens to expose.
///
/// Field order and separators are quoted in the doc comment of each
/// generator. If one of them stops matching CACHE_FORMAT.md, the fixture is
/// wrong, not the document.
///
/// English-only string literals - see the header of `DebugView.swift`.
enum DebugFixtures {

    /// How generated names should look. The point of the last two is that a
    /// name is the one field in every one of these formats that comes from
    /// the outside world, so it is where a layout breaks.
    enum NameStyle: String, CaseIterable, Identifiable, Hashable {
        /// Ordinary tokens and app names, the boring case.
        case plain
        /// A name long enough to push a row past any sensible width.
        case veryLong
        /// Turkish letters and emoji: the case where character count and
        /// rendered width stop agreeing, and where a lowercasing sort can go
        /// wrong (Turkish dotless i).
        case unicode

        var id: String { rawValue }

        var label: String {
            switch self {
            case .plain: return "Plain"
            case .veryLong: return "Very long name"
            case .unicode: return "Emoji + Turkish"
            }
        }
    }

    /// How many pending updates of each source to generate.
    ///
    /// One count per cache entry rather than one total, because each entry
    /// has its own format, its own parser and its own section in the UI -
    /// and the interesting states are the lopsided ones (nothing but App
    /// Store apps, 250 formulae and one cask).
    struct SnapshotCounts: Equatable, Sendable {
        var casks = 0
        var formulae = 0
        var appStore = 0
        var manual = 0
        /// Sparkle and GitHub self-updaters - the `app_updates` entry. Not a
        /// source the user picks between elsewhere in the app, but it is a
        /// fifth parser with a sixth field, and leaving it out would leave
        /// `UpdateSnapshot.selfUpdatingItems` untested.
        var selfUpdating = 0

        var total: Int { casks + formulae + appStore + manual + selfUpdating }

        static let empty = SnapshotCounts()
        static let one = SnapshotCounts(casks: 1)
        static let handful = SnapshotCounts(casks: 3, formulae: 2, appStore: 1, manual: 1)
        static let many = SnapshotCounts(casks: 60, formulae: 150, appStore: 25, manual: 5, selfUpdating: 10)
    }

    // MARK: - Names

    /// Deterministic, and never containing a `|`.
    ///
    /// The pipe is not a style choice: every format here is pipe-delimited
    /// and no field may contain one - the engine strips them at every writer
    /// for exactly this reason (`add_ignored`, `clean_mas_name`). A fixture
    /// that emitted one would be generating a record the real engine cannot
    /// produce, and the parser would be right to mangle it.
    static func name(_ index: Int, style: NameStyle) -> String {
        switch style {
        case .plain:
            return plainNames[index % plainNames.count] + (index < plainNames.count ? "" : "-\(index)")
        case .veryLong:
            return "Extremely Long Application Name That Nobody Would Ship But Somebody Always Does \(index) "
                + String(repeating: "Extended ", count: 4).trimmingCharacters(in: .whitespaces)
        case .unicode:
            return unicodeNames[index % unicodeNames.count] + (index < unicodeNames.count ? "" : " \(index)")
        }
    }

    /// A Homebrew-shaped token for the same index: lowercase, hyphenated, no
    /// spaces. Kept separate from `name` because `brew_outdated` holds a
    /// token, not a display name, and a fixture that put a display name
    /// there would be testing a line the engine never writes.
    static func token(_ index: Int, style: NameStyle) -> String {
        let base = name(index, style: style)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        // Long and unicode tokens are still worth generating - a cask token
        // really can be long - but they stay token-shaped.
        return String(base.prefix(120))
    }

    private static let plainNames = [
        "alt-tab", "rectangle", "iterm2", "keka", "raycast", "stats",
        "ripgrep", "fd", "jq", "fzf", "bat", "eza", "gh", "htop"
    ]

    private static let unicodeNames = [
        "Şifre Kasası 🔐", "Ağ Çözümleyici 📡", "Günlük İzleyici 📊",
        "Çöp Toplayıcı 🗑️", "Iğdır Not Defteri ✍️", "Örümcek Ağı 🕸️"
    ]

    /// "1.2.3" and "1.2.4" - deterministic, and different from each other,
    /// which is the only property any reader cares about.
    static func versions(_ index: Int) -> (current: String, next: String) {
        let major = 1 + index / 50
        let minor = index % 50
        return ("\(major).\(minor).3", "\(major).\(minor).4")
    }

    /// A stable App Store-shaped numeric id.
    static func appStoreID(_ index: Int) -> String { "\(400_000_000 + index * 7919)" }

    // MARK: - cache/brew_outdated

    /// `src|token|installed_versions|current_version|pinned`
    ///
    /// `src` is `brew` or `cask`; `pinned` is `0`/`1`. A pinned row is
    /// included on purpose when there is room for one: `UpdateSnapshot`
    /// drops those, so it is the cheapest check that the filter still works.
    static func brewOutdated(casks: Int, formulae: Int, style: NameStyle, includePinned: Bool = true) -> String {
        var lines: [String] = []

        for index in 0..<casks {
            let (current, next) = versions(index)
            lines.append("cask|\(token(index, style: style))|\(current)|\(next)|0")
        }

        for index in 0..<formulae {
            let (current, next) = versions(index + 100)
            // One pinned formula, and only when there are others to see it
            // sitting next to.
            let pinned = includePinned && formulae > 1 && index == formulae - 1 ? "1" : "0"
            lines.append("brew|\(token(index + 100, style: style))|\(current)|\(next)|\(pinned)")
        }

        return joined(lines)
    }

    // MARK: - cache/mas_outdated

    /// Raw `mas outdated` output, which is what this entry holds - not a
    /// format this project defines (CACHE_FORMAT.md, "Explicitly out of
    /// scope"). The shape the Swift reader parses is
    /// `<id> <name> (<current> -> <next>)`.
    static func masOutdated(count: Int, style: NameStyle) -> String {
        joined((0..<count).map { index in
            let (current, next) = versions(index + 200)
            return "\(appStoreID(index)) \(name(index, style: style)) (\(current) -> \(next))"
        })
    }

    // MARK: - cache/manual_updates

    /// `name|local_version|remote_version|app_id` - Apple first-party apps
    /// `mas` fails to report.
    static func manualUpdates(count: Int, style: NameStyle) -> String {
        joined((0..<count).map { index in
            let (current, next) = versions(index + 300)
            return "\(name(index + 3, style: style))|\(current)|\(next)|\(appStoreID(index + 500))"
        })
    }

    // MARK: - cache/app_updates

    /// `method|name|local_version|remote_version|url|signature`
    ///
    /// `method` is `sparkle` or `github`; `signature` is empty unless the
    /// feed provided one, which is the common case and therefore the one
    /// worth generating - a trailing empty field is exactly where a
    /// components(separatedBy:) reader goes wrong.
    static func appUpdates(count: Int, style: NameStyle) -> String {
        joined((0..<count).map { index in
            let (current, next) = versions(index + 400)
            let method = index.isMultiple(of: 2) ? "sparkle" : "github"
            let appName = name(index + 6, style: style)
            let url = "https://example.invalid/\(index)/releases/tag/v\(next)"
            return "\(method)|\(appName)|\(current)|\(next)|\(url)|"
        })
    }

    // MARK: - cache/progress

    /// `v1|state|phase|item|index|total`
    ///
    /// `index`/`total` are written empty when absent, which is what the
    /// shell does and what the reader's `Int(fields[4])` expects.
    static func progress(
        state: String,
        phase: String,
        item: String = "",
        index: Int? = nil,
        total: Int? = nil
    ) -> String {
        let fields = [
            UpdateProgress.formatVersion,
            state,
            phase,
            item,
            index.map(String.init) ?? "",
            total.map(String.init) ?? ""
        ]
        return fields.joined(separator: "|") + "\n"
    }

    // MARK: - results/

    /// `v1|epoch|kind|id|name|status|reason`
    ///
    /// `reason` is empty on `ok`; the caller is trusted with that because
    /// writing a reason next to an `ok` is itself a state worth being able
    /// to inject.
    static func result(
        kind: String,
        id: String,
        name: String,
        status: String,
        reason: String,
        at date: Date = Date()
    ) -> String {
        let epoch = String(Int(date.timeIntervalSince1970))
        return [ItemRunResult.formatVersion, epoch, kind, id, name, status, reason].joined(separator: "|") + "\n"
    }

    // MARK: - notifications/

    /// `v1|title|subtitle|body`
    static func notification(title: String, subtitle: String, body: String) -> String {
        [NotificationRequest.formatVersion, title, subtitle, body].joined(separator: "|") + "\n"
    }

    /// The title the engine always writes today.
    static let notificationTitle = "Mac Software Manager"

    // MARK: - cache/engine

    /// `v1|epoch|contract|release`
    static func engineContract(contract: Int, release: String, at date: Date = Date()) -> String {
        let epoch = String(Int(date.timeIntervalSince1970))
        return [EngineContract.formatVersion, epoch, String(contract), release].joined(separator: "|") + "\n"
    }

    // MARK: - Helpers

    /// Trailing newline on a non-empty payload, none on an empty one.
    ///
    /// An empty cache entry is a real state - "checked, nothing pending" -
    /// and it is written as a genuinely empty file, not as a file holding
    /// one blank line.
    private static func joined(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
