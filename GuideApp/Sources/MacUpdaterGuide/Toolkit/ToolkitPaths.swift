import Foundation

/// Where the zsh toolkit keeps its state.
///
/// The shell scripts remain the engine - they know how to talk to Homebrew,
/// mas, Sparkle feeds and GitHub. This app is the interface on top of the files
/// they write, so every path here has to match what the scripts use.
enum ToolkitPaths {

    /// ~/Library/Application Support/MacSoftwareUpdater
    static var supportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/MacSoftwareUpdater", directoryHint: .isDirectory)
    }

    static var cacheDirectory: URL {
        supportDirectory.appending(path: "cache", directoryHint: .isDirectory)
    }

    static var settingsFile: URL { supportDirectory.appending(path: "settings.conf") }
    static var ignoredFile: URL { supportDirectory.appending(path: "ignored_apps.conf") }
    static var trackedAppsFile: URL { supportDirectory.appending(path: "tracked_apps.conf") }
    static var tokenMapFile: URL { supportDirectory.appending(path: "app_token_map.conf") }
    static var historyFile: URL { supportDirectory.appending(path: "update_history.log") }

    /// Per-app corrections for the website / GitHub links shown on the
    /// Installed Apps page. Read only by this app - the shell engine never
    /// touches it, so it stays purely local with no server, no review queue,
    /// nothing shared.
    static var appLinksFile: URL { supportDirectory.appending(path: "app_links.conf") }

    static func cacheFile(_ name: String) -> URL {
        cacheDirectory.appending(path: name)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: supportDirectory.path(percentEncoded: false))
    }

    // MARK: - Opening configuration files

    /// Opens a config file in the user's text editor.
    ///
    /// `NSWorkspace.open` fails on these: a `.conf` extension has no registered
    /// application, so macOS puts up "no application is set to open this
    /// document" instead of opening it. `open -t` asks for the default *text*
    /// editor, which is what the shell menu always did.
    ///
    /// The file is created from `template` when missing, so the button works on
    /// a fresh install where the engine has not written it yet.
    @discardableResult
    static func openInTextEditor(_ url: URL, template: String? = nil) -> Bool {
        let path = url.path(percentEncoded: false)

        if !FileManager.default.fileExists(atPath: path), let template {
            try? FileManager.default.createDirectory(
                at: supportDirectory,
                withIntermediateDirectories: true
            )
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }

        guard FileManager.default.fileExists(atPath: path) else { return false }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-t", path]

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    /// Matches the header the engine script writes, so a file created here and
    /// one created by the toolkit read the same.
    static let trackedAppsTemplate = """
    # How to check individual applications for updates.
    #
    # One entry per line:   App Name|method|identifier
    #   sparkle  | identifier = appcast URL
    #   github   | identifier = owner/repo
    #   homebrew | identifier = cask token
    #   skip     | identifier unused
    #
    # "App Name" is the bundle name without ".app", matched case insensitively.

    """

    static let tokenMapTemplate = """
    # Manual application -> Homebrew cask token mapping.
    #
    # One mapping per line:   App Name|cask-token
    # For example:
    #   lghub|logitech-g-hub
    #   Sublime Text|sublime-text

    """

    static let appLinksTemplate = """
    # Corrections for the website / GitHub links shown on the Installed Apps
    # page, for whenever the automatic detection gets one wrong or finds
    # nothing at all.
    #
    # One line per app:   App Name|website|owner/repo
    # Either link may be left blank to leave that one on the automatic result.
    # This file is local only - edit it from the app (right-click an app ->
    # Edit Links) instead of by hand where possible.

    """

    // MARK: - Locating the engine script

    private static let scriptOverrideKey = "com.macupdater.guide.scriptPath"

    /// A path the user picked by hand, when automatic discovery is not enough.
    static var scriptOverride: URL? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: scriptOverrideKey) else { return nil }
            return URL(filePath: stored)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.path(percentEncoded: false), forKey: scriptOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: scriptOverrideKey)
            }
        }
    }

    /// The `update_system.*.sh` script that does the actual work.
    ///
    /// Looked for in three places, in order: an explicit override, the SwiftBar
    /// plugin folder (where existing installations put it), and the toolkit's
    /// own support directory.
    static func locateScript() -> URL? {
        if let override = scriptOverride,
           FileManager.default.isExecutableFile(atPath: override.path(percentEncoded: false)) {
            return override
        }

        for directory in candidateDirectories() {
            if let found = firstScript(in: directory) {
                return found
            }
        }

        return nil
    }

    private static func candidateDirectories() -> [URL] {
        var directories: [URL] = []

        // SwiftBar remembers its plugin folder in its own preferences
        if let pluginPath = UserDefaults(suiteName: "com.ameba.SwiftBar")?
            .string(forKey: "PluginDirectory") {
            let expanded = NSString(string: pluginPath).expandingTildeInPath
            directories.append(URL(filePath: expanded))
        }

        directories.append(supportDirectory)
        directories.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/SwiftBar", directoryHint: .isDirectory)
        )

        return directories
    }

    /// The frequency suffix means the file can be named update_system.6h.sh,
    /// so match on the prefix rather than a fixed name.
    private static func firstScript(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
            return nil
        }

        let matches = entries
            .filter { $0.hasPrefix("update_system.") && $0.hasSuffix(".sh") }
            .sorted()

        for name in matches {
            let candidate = directory.appending(path: name)
            if fileManager.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }

        return nil
    }
}
