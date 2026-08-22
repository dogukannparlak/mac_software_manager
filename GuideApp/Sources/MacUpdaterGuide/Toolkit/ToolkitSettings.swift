import Foundation
import Observation

enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case terminal = "Terminal"
    case iTerm2 = "iTerm2"
    case warp = "Warp"
    case alacritty = "Alacritty"
    case ghostty = "Ghostty"

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// Bundle folder to look for, so the picker can grey out what is missing.
    var applicationName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iTerm2: return "iTerm"
        case .warp: return "Warp"
        case .alacritty: return "Alacritty"
        case .ghostty: return "Ghostty"
        }
    }

    var isInstalled: Bool {
        if self == .terminal { return true }
        return FileManager.default.fileExists(
            atPath: "/Applications/\(applicationName).app"
        )
    }
}

enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable = "main"
    case beta = "develop"

    var id: String { rawValue }

    var label: Localized {
        switch self {
        case .stable: return Localized("Stable", "Kararlı")
        case .beta: return Localized("Beta", "Beta")
        }
    }
}

/// Reads and writes the toolkit's `settings.conf`.
///
/// The shell side parses that file with a strict `KEY="value"` pattern and
/// warns about anything it does not recognise, so this writes exactly the keys
/// it knows about and nothing else. Settings that only concern this app (the
/// refresh interval, for instance) live in UserDefaults instead.
@Observable
final class ToolkitSettings {

    var preferredTerminal: TerminalApp = .terminal
    var masEnabled = true
    var channel: UpdateChannel = .stable
    var autostart = true
    var cleanupEnabled = true
    var autoInstallApps = false
    /// Empty means no Codeberg mirror is configured: downloads and self-update
    /// fall back to GitHub only, and the shell engine surfaces that in its
    /// own "Config Warnings" menu entry.
    var codebergUsername = ""

    /// Set when the file could not be written, so the UI can say so.
    private(set) var lastError: String?

    init() {
        load()
    }

    // MARK: - Loading

    func load() {
        lastError = nil

        guard let contents = try? String(contentsOf: ToolkitPaths.settingsFile, encoding: .utf8) else {
            return
        }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            var value = String(line[line.index(after: separator)...])
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            apply(key: key, value: value)
        }
    }

    /// Internal (not private) so ToolkitSettingsParsingTests can exercise key
    /// recognition/error handling directly, without going through `load()`'s
    /// real, non-injectable file location - see the doc comment on
    /// ProcessOutcome (ToolkitRunner.swift) for the same pattern.
    func apply(key: String, value: String) {
        switch key {
        case "PREFERRED_TERMINAL":
            if let terminal = TerminalApp(rawValue: value) { preferredTerminal = terminal }
        case "MAS_ENABLED":
            masEnabled = (value == "1")
        case "UPDATE_BRANCH":
            if let parsed = UpdateChannel(rawValue: value) { channel = parsed }
        case "AUTOSTART":
            autostart = (value == "1")
        case "CLEANUP_ENABLED":
            cleanupEnabled = (value == "1")
        case "AUTO_INSTALL_APPS":
            autoInstallApps = (value == "1")
        case "CODEBERG_USERNAME":
            codebergUsername = (value == "YOUR_CODEBERG_USERNAME") ? "" : value
        default:
            break
        }
    }

    // MARK: - Saving

    /// Rewrites the whole file. Comments are regenerated rather than preserved,
    /// which keeps the result identical to what the setup script produces.
    func save() {
        let contents = """
        # Mac Software Manager Configuration
        # Written by MacUpdaterGuide on \(Self.timestamp())

        # Terminal app to use for running updates
        # Valid values: Terminal, iTerm2, Warp, Alacritty, Ghostty
        PREFERRED_TERMINAL="\(preferredTerminal.rawValue)"

        # App Store Updates (1=Enabled, 0=Disabled)
        MAS_ENABLED="\(masEnabled ? "1" : "0")"

        # Update Channel (main=Stable, develop=Beta)
        UPDATE_BRANCH="\(channel.rawValue)"

        # SwiftBar Autostart State (Syncs with System Events)
        AUTOSTART="\(autostart ? "1" : "0")"

        # Run 'brew cleanup --prune=all' after each update (1=Enabled, 0=Disabled)
        CLEANUP_ENABLED="\(cleanupEnabled ? "1" : "0")"

        # Replace self-updating apps (Sparkle/GitHub) directly (1=Enabled, 0=Disabled)
        AUTO_INSTALL_APPS="\(autoInstallApps ? "1" : "0")"

        # Codeberg username for the backup mirror (blank = GitHub only, no dual-source verification)
        CODEBERG_USERNAME="\(codebergUsername)"

        """

        do {
            try FileManager.default.createDirectory(
                at: ToolkitPaths.supportDirectory,
                withIntermediateDirectories: true
            )
            try contents.write(to: ToolkitPaths.settingsFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: ToolkitPaths.settingsFile.path(percentEncoded: false)
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

/// Settings that belong to this app rather than to the shell toolkit.
@Observable
final class AppPreferences {
    private static let intervalKey = "com.macupdater.guide.refreshMinutes"
    private static let hideDockIconKey = "com.macupdater.guide.hideDockIcon"
    private static let runInTerminalKey = "com.macupdater.guide.runUpdatesInTerminal"
    private static let maxConcurrentUpdatesKey = "com.macupdater.guide.maxConcurrentUpdates"
    private static let autoTerminalKey = "com.macupdater.guide.autoOpenTerminalWhenRequired"
    private static let debugModeKey = "com.macupdater.guide.debugMode"

    /// How often the menu bar data is rebuilt, in minutes.
    var refreshMinutes: Int {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: Self.intervalKey) }
    }

    /// Off by default: updates run in the background and are reported through
    /// the in-app progress bar instead of a terminal window popping up. Turn
    /// this on to get the old behaviour back - a visible, watchable,
    /// stoppable terminal session - for whenever that is what you want.
    var runUpdatesInTerminal: Bool {
        didSet { UserDefaults.standard.set(runUpdatesInTerminal, forKey: Self.runInTerminalKey) }
    }

    /// How many single-item updates ("Update" pressed on one row) can run at
    /// once in the background. Only applies to headless runs - a terminal
    /// window is already one run someone is watching directly, so that path
    /// stays single-flight the way it always has. Anything started past this
    /// limit is queued and starts automatically as the next slot frees up.
    var maxConcurrentUpdates: Int {
        didSet { UserDefaults.standard.set(maxConcurrentUpdates, forKey: Self.maxConcurrentUpdatesKey) }
    }

    /// On by default: an update that cannot finish without a password is
    /// reopened in a terminal window straight away, instead of stopping to
    /// offer a button first.
    ///
    /// Some casks uninstall the old version through `sudo` (an `uninstall
    /// delete:` under /Library, `pkgutil:`, `launchctl:`), and a background
    /// run has no terminal for the password prompt to appear in - so it fails
    /// every time, after the download, for the same handful of packages. The
    /// window is the only place that update can happen, and asking first only
    /// adds a click to a decision with one answer.
    ///
    /// Turn it off to be asked instead: the same failure then waits behind
    /// an "Update in Terminal" button in the banner and nothing opens on its
    /// own.
    var autoOpenTerminalWhenRequired: Bool {
        didSet { UserDefaults.standard.set(autoOpenTerminalWhenRequired, forKey: Self.autoTerminalKey) }
    }

    /// Reveals the Debug page in Release builds. Off by default, and
    /// deliberately not discoverable from anywhere but Settings › Advanced:
    /// the page can start real updates.
    var debugMode: Bool {
        didSet { UserDefaults.standard.set(debugMode, forKey: Self.debugModeKey) }
    }

    /// Whether the sidebar shows the Debug page at all.
    ///
    /// Always on in DEBUG, because a page for testing the app by hand that
    /// has to be switched on before it can be used is one more step between
    /// a change and seeing it. In Release it is the toggle and nothing else -
    /// the point of shipping it is that a user can be walked through
    /// collecting diagnostics, not that anybody stumbles into it.
    var showsDebugPage: Bool {
        #if DEBUG
        return true
        #else
        return debugMode
        #endif
    }

    static let maxConcurrentUpdatesChoices = [1, 2, 3, 4]

    /// Live in the menu bar only: no Dock icon, no app menu.
    /// The menu bar panel keeps its own Quit and Settings entries, so nothing
    /// becomes unreachable when this is on.
    var hideDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(hideDockIcon, forKey: Self.hideDockIconKey)
            // Changing the activation policy has to happen on the main actor,
            // and it takes effect immediately - no relaunch needed.
            let hidden = hideDockIcon
            Task { @MainActor in DockVisibility.apply(hidden: hidden) }
        }
    }

    static let intervalChoices = [30, 60, 120, 360, 720, 1440]

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.intervalKey)
        refreshMinutes = Self.intervalChoices.contains(stored) ? stored : 60

        hideDockIcon = UserDefaults.standard.bool(forKey: Self.hideDockIconKey)
        runUpdatesInTerminal = UserDefaults.standard.bool(forKey: Self.runInTerminalKey)
        // Defaults to true, which `bool(forKey:)` cannot express - it returns
        // false for a key that was never written. `object(forKey:)` tells the
        // two apart.
        autoOpenTerminalWhenRequired =
            (UserDefaults.standard.object(forKey: Self.autoTerminalKey) as? Bool) ?? true

        debugMode = UserDefaults.standard.bool(forKey: Self.debugModeKey)

        let storedConcurrency = UserDefaults.standard.integer(forKey: Self.maxConcurrentUpdatesKey)
        maxConcurrentUpdates = Self.maxConcurrentUpdatesChoices.contains(storedConcurrency) ? storedConcurrency : 2
    }

    static func intervalLabel(_ minutes: Int) -> Localized {
        switch minutes {
        case 30: return Localized("Every 30 minutes", "30 dakikada bir")
        case 60: return Localized("Every hour", "Saatte bir")
        case 120: return Localized("Every 2 hours", "2 saatte bir")
        case 360: return Localized("Every 6 hours", "6 saatte bir")
        case 720: return Localized("Every 12 hours", "12 saatte bir")
        default: return Localized("Once a day", "Günde bir")
        }
    }
}
