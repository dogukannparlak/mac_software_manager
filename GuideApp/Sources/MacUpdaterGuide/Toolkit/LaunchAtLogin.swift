import Foundation
import ServiceManagement

/// Registers the app itself as a login item.
///
/// The SwiftBar version added *SwiftBar* to the login items, because that was
/// what drew the menu bar. The menu bar item now belongs to this app, so this
/// is what has to start at login for it to be there.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS can refuse the request (for example when the app runs from a build
    /// folder rather than /Applications), so the caller gets the reason.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return nil }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// True when the login item was blocked and needs the user's approval in
    /// System Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Reads the version out of the engine script's own header, which is the same
/// value the toolkit reports about itself.
enum ToolkitVersion {
    static func read(from script: URL?) -> String? {
        guard let script,
              let text = try? String(contentsOf: script, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(8) {
            guard let open = line.range(of: "<bitbar.version>"),
                  let close = line.range(of: "</bitbar.version>") else { continue }
            return String(line[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "v "))
        }
        return nil
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // TODO: no Codeberg mirror set up yet - fill in YOUR_CODEBERG_USERNAME below.
    static let projectURL = URL(string: "https://github.com/dogukannparlak/mac_software_manager")!
    static let mirrorURL = URL(string: "https://codeberg.org/YOUR_CODEBERG_USERNAME/mac_software_manager")!
}

/// Homebrew's own version and how stale its local database is.
///
/// Homebrew has no versioned releases the way an app does - `brew update` just
/// pulls the latest commits - so there is no "a new version is out" to detect.
/// What matters instead is *when that pull last happened*: every "outdated"
/// list on the Updates page is only as accurate as this timestamp.
struct HomebrewStatus: Sendable {
    let version: String
    let lastUpdated: Date?

    /// Past this age, the outdated list is worth treating with some suspicion.
    static let staleAfter: TimeInterval = 24 * 3600

    var isStale: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > Self.staleAfter
    }

    static func load() -> HomebrewStatus? {
        guard let text = try? String(contentsOf: ToolkitPaths.cacheFile("brew_status"), encoding: .utf8) else {
            return nil
        }

        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard let version = fields.first, !version.isEmpty else { return nil }

        var lastUpdated: Date?
        if fields.count > 1, let epoch = TimeInterval(fields[1]), epoch > 0 {
            lastUpdated = Date(timeIntervalSince1970: epoch)
        }

        return HomebrewStatus(version: version, lastUpdated: lastUpdated)
    }
}
