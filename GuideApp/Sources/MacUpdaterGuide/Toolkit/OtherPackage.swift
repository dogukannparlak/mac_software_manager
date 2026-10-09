import Foundation

/// Where a package outside Homebrew and the App Store came from.
///
/// Homebrew stays the primary source - its formulae keep their own, richer
/// section on the CLI Tools page. Everything here is what the engine finds
/// past it (lib/updaters.sh, section 3c2), and the raw values are the
/// `source` field of the `other_packages` cache entry (CACHE_FORMAT.md).
enum PackageSource: String, CaseIterable, Identifiable, Sendable {
    case npm
    case pipx
    case uv
    case cargo
    case go
    /// A command line shim that lives inside an application bundle - it is
    /// updated with that app.
    case app
    /// A standalone executable in ~/.local/bin and the like, installed by its
    /// own script (Claude Code is one).
    case local
    /// An installer package receipt (`pkgutil --pkgs`).
    case pkg

    var id: String { rawValue }

    var label: Localized {
        switch self {
        case .npm: return Localized("npm", "npm")
        case .pipx: return Localized("pipx", "pipx")
        case .uv: return Localized("uv", "uv")
        case .cargo: return Localized("Cargo", "Cargo")
        case .go: return Localized("Go", "Go")
        case .app: return Localized("Part of an app", "Uygulamanın parçası")
        case .local: return Localized("Standalone install", "Bağımsız kurulum")
        case .pkg: return Localized("Installer packages (.pkg)", "Kurulum paketleri (.pkg)")
        }
    }

    var symbol: String {
        switch self {
        case .npm, .pipx, .uv, .cargo, .go: return "shippingbox"
        case .app: return "app.badge"
        case .local: return "terminal"
        case .pkg: return "archivebox"
        }
    }

    /// Sources the engine has an update command for (`run tool`).
    var isUpdatable: Bool {
        switch self {
        case .npm, .pipx, .uv, .cargo, .go: return true
        case .app, .local, .pkg: return false
        }
    }

    /// Package managers first, then the tools that came on their own, then
    /// the installer receipts - the noisiest list, and the least actionable.
    var sortRank: Int {
        switch self {
        case .npm: return 0
        case .pipx: return 1
        case .uv: return 2
        case .cargo: return 3
        case .go: return 4
        case .local: return 5
        case .app: return 6
        case .pkg: return 7
        }
    }
}

/// One package from `other_packages`, joined with `other_outdated` when that
/// knows of a newer version.
struct OtherPackage: Identifiable, Hashable, Sendable {
    let source: PackageSource
    let name: String
    let version: String
    /// What the source needs to act on the package: the module path for go,
    /// the bundle for an app's shim, the resolved file for a standalone tool,
    /// the install location for a .pkg. Nil when the engine wrote none.
    let location: String?
    /// Set only when the source reported a newer version.
    let latestVersion: String?

    var id: String { "\(source.rawValue):\(name)" }

    var isOutdated: Bool { latestVersion != nil }

    /// Standalone tools that update themselves (`claude update`, `uv self
    /// update`, …). Kept in step with `local_tool_is_updatable` in
    /// lib/updaters.sh, which is what actually decides.
    static let selfUpdatingTools: Set<String> = ["claude", "uv", "bun", "deno", "rustup"]

    /// Whether the engine has an update command for this package: every
    /// package-manager install, plus the self-updating standalone tools.
    var isUpdatable: Bool {
        source.isUpdatable || (source == .local && Self.selfUpdatingTools.contains(name))
    }

    /// Parses the two cache entries. Lines from a source this build does not
    /// know, and lines with fewer than three fields, are skipped rather than
    /// guessed at: a newer engine may add sources before this app knows how
    /// to show them.
    static func parse(packages: [String], outdated: [String]) -> [OtherPackage] {
        var latest: [String: String] = [:]
        for line in outdated {
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 4, !fields[3].isEmpty, fields[2] != fields[3] else { continue }
            latest["\(fields[0]):\(fields[1])"] = fields[3]
        }

        var seen = Set<String>()
        return packages.compactMap { line in
            let fields = line.components(separatedBy: "|")
            guard fields.count >= 3,
                  let source = PackageSource(rawValue: fields[0]),
                  !fields[1].isEmpty
            else { return nil }

            let key = "\(source.rawValue):\(fields[1])"
            guard seen.insert(key).inserted else { return nil }

            let location = fields.count >= 4 && !fields[3].isEmpty
                ? fields[3...].joined(separator: "|")
                : nil
            return OtherPackage(
                source: source,
                name: fields[1],
                version: fields[2],
                location: location,
                latestVersion: latest[key]
            )
        }
    }
}
