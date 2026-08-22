import CoreServices
import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// Everything the Environment panel shows, gathered in one place.
///
/// Split out from the view because collecting it is the interesting part -
/// two subprocesses, three permission APIs and a handful of file probes -
/// and because the same values have to come out identically in the markdown
/// the Copy button produces. One model, two renderings.
///
/// English-only string literals - see the header of `DebugView.swift`.
@MainActor
@Observable
final class DebugEnvironmentReport {

    private(set) var groups: [DebugFactGroup] = []
    private(set) var isLoading = false

    /// Rebuilds every group. Cheap enough to run on every appearance: the
    /// two version probes are the only processes, and they are the reason
    /// this is async rather than a computed property.
    func load() async {
        isLoading = true
        var built: [DebugFactGroup] = []
        built.append(Self.systemGroup())
        built.append(Self.applicationGroup())
        built.append(Self.engineGroup())
        built.append(await Self.toolchainGroup())
        built.append(await Self.permissionsGroup())
        groups = built
        isLoading = false
    }

    /// The whole table as a markdown document, for pasting into an issue.
    ///
    /// Generated from the same `DebugFact` values the table draws, never
    /// re-derived, so what gets pasted is what was on screen.
    var markdown: String {
        var lines = ["# MacUpdaterGuide environment", "", "_Collected \(Self.timestamp())_"]
        for group in groups {
            lines.append("")
            lines.append("### \(group.id)")
            lines.append("")
            lines.append("| Setting | Value |")
            lines.append("| --- | --- |")
            lines.append(contentsOf: group.facts.map(\.markdownRow))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - System

    private static func systemGroup() -> DebugFactGroup {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        let architecture = sysctlString("hw.machine")

        var facts: [DebugFact] = [
            DebugFact(
                id: "macOS",
                value: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                detail: process.operatingSystemVersionString
            ),
            DebugFact(id: "Architecture", value: architecture)
        ]

        // Worth its own row rather than a footnote on the architecture: an
        // arm64 Mac running this app under Rosetta reports x86_64 above and
        // then finds Homebrew at /usr/local instead of /opt/homebrew, which
        // looks like a broken install and is not one.
        if isTranslated {
            facts.append(DebugFact(
                id: "Rosetta",
                value: "Running translated",
                isProblem: true,
                detail: "sysctl.proc_translated = 1 - this process is x86_64 on Apple silicon."
            ))
        }

        facts.append(DebugFact(id: "Kernel", value: sysctlString("kern.osrelease")))
        return DebugFactGroup(id: "System", facts: facts)
    }

    // MARK: - Application

    private static func applicationGroup() -> DebugFactGroup {
        let bundle = Bundle.main
        return DebugFactGroup(id: "Application", facts: [
            DebugFact(id: "App version", value: ToolkitVersion.appVersion),
            DebugFact(
                id: "Bundle identifier",
                // A bundle-less run (swift run, straight from .build) has no
                // identifier at all, which is worth seeing: several APIs
                // below - login items, notifications - behave differently
                // for one.
                value: bundle.bundleIdentifier ?? "none (unbundled run)",
                isProblem: bundle.bundleIdentifier == nil
            ),
            DebugFact(id: "Bundle path", value: bundle.bundlePath),
            DebugFact(id: "Build configuration", value: buildConfiguration)
        ])
    }

    private static var buildConfiguration: String {
        #if DEBUG
        return "DEBUG"
        #else
        return "RELEASE"
        #endif
    }

    // MARK: - Engine

    private static func engineGroup() -> DebugFactGroup {
        let script = ToolkitPaths.locateScript()
        var facts: [DebugFact] = [
            DebugFact(
                id: "Support directory",
                value: ToolkitPaths.isInstalled ? "present" : "missing",
                isProblem: !ToolkitPaths.isInstalled,
                detail: ToolkitPaths.supportDirectory.path(percentEncoded: false)
            ),
            DebugFact(
                id: "locateScript()",
                value: script?.path(percentEncoded: false) ?? "not found",
                isProblem: script == nil
            ),
            DebugFact(
                id: "Script override",
                value: ToolkitPaths.scriptOverride?.path(percentEncoded: false) ?? "not set",
                detail: "UserDefaults com.macupdater.guide.scriptPath"
            ),
            DebugFact(id: "Toolkit version", value: ToolkitVersion.read(from: script) ?? "—")
        ]
        facts.append(contentsOf: engineContractFacts())
        return DebugFactGroup(id: "Engine", facts: facts)
    }

    /// The `cache/engine` record, field by field.
    ///
    /// Absence is the case that matters and is reported as such: an engine
    /// older than the contract writes no record at all, which is exactly
    /// what `EngineContract` is there to make visible instead of letting the
    /// app guess - see its doc comment.
    private static func engineContractFacts() -> [DebugFact] {
        guard let contract = EngineContractStore.load() else {
            return [DebugFact(
                id: "Engine contract",
                value: "no record",
                isProblem: true,
                detail: "cache/engine is missing or unreadable: an engine older than contract 1, or one that has never run."
            )]
        }

        return [
            DebugFact(
                id: "Engine contract",
                value: "\(contract.contract) (this build requires \(EngineContract.required))",
                isProblem: !contract.meetsRequirement
            ),
            DebugFact(id: "Engine release", value: contract.release.isEmpty ? "—" : contract.release),
            DebugFact(id: "Contract written", value: stamp(contract.recordedAt)),
            DebugFact(
                id: "supportsMigration",
                value: contract.supportsMigration ? "yes" : "no",
                detail: "needs contract \(EngineContract.migrationContract)"
            )
        ]
    }

    // MARK: - Toolchain

    private static func toolchainGroup() async -> DebugFactGroup {
        var facts: [DebugFact] = []
        facts.append(await tool(named: "brew", candidates: brewPaths))
        facts.append(await tool(named: "mas", candidates: masPaths))
        return DebugFactGroup(id: "Toolchain", facts: facts)
    }

    /// Homebrew's two documented prefixes, Apple silicon first. See
    /// `DebugCommand.locate` for why `PATH` is no use here.
    private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private static let masPaths = ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]

    private static func tool(named name: String, candidates: [String]) async -> DebugFact {
        guard let url = DebugCommand.locate(candidates) else {
            return DebugFact(
                id: name,
                value: "not found",
                isProblem: true,
                detail: "looked in: " + candidates.joined(separator: ", ")
            )
        }

        let result = await DebugCommand.capture(executable: url, arguments: ["--version"])
        // First line only: `brew --version` prints its own version and then
        // the tap's git revision, and the second line is noise in a table.
        let firstLine = result.output.split(separator: "\n").first.map(String.init) ?? "no output"
        return DebugFact(
            id: name,
            value: result.succeeded ? firstLine : "exit \(result.exitCode)",
            isProblem: !result.succeeded,
            detail: url.path(percentEncoded: false)
        )
    }

    // MARK: - Permissions

    private static func permissionsGroup() async -> DebugFactGroup {
        var facts = [await notificationFact()]
        facts.append(loginItemFact())
        facts.append(contentsOf: automationFacts())
        return DebugFactGroup(id: "Permissions", facts: facts)
    }

    private static func notificationFact() async -> DebugFact {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let status = settings.authorizationStatus
        return DebugFact(
            id: "Notifications",
            value: label(for: status),
            // Not-determined is not a problem: nothing has asked yet, which
            // is the normal state until NotificationBridge.start() runs.
            isProblem: status == .denied,
            detail: "alerts: \(label(for: settings.alertSetting)), sound: \(label(for: settings.soundSetting))"
        )
    }

    private static func loginItemFact() -> DebugFact {
        let status = SMAppService.mainApp.status
        let value: String
        switch status {
        case .enabled: value = "enabled"
        case .requiresApproval: value = "requires approval"
        case .notFound: value = "not found"
        case .notRegistered: value = "not registered"
        @unknown default: value = "unknown (\(status.rawValue))"
        }
        return DebugFact(
            id: "Launch at login",
            value: value,
            isProblem: status == .requiresApproval,
            detail: "SMAppService.mainApp.status"
        )
    }

    /// One row per terminal that is actually installed.
    ///
    /// Asking about a terminal that is not there tells nobody anything -
    /// macOS answers "process not found" whether or not permission would be
    /// granted - and five rows of that would bury the one terminal the
    /// answer matters for.
    private static func automationFacts() -> [DebugFact] {
        TerminalApp.allCases.filter(\.isInstalled).map { terminal in
            let bundleID = terminalBundleIDs[terminal] ?? ""
            let permission = AutomationPermission.check(bundleID: bundleID)
            return DebugFact(
                id: "Automation: \(terminal.displayName)",
                value: permission.label,
                isProblem: permission == .denied,
                detail: bundleID.isEmpty ? "no bundle identifier on record" : bundleID
            )
        }
    }

    /// Bundle identifiers for the terminals `TerminalApp` knows about.
    ///
    /// Kept here rather than added to `TerminalApp`: the app drives
    /// terminals through `osascript` by name and never needs an identifier,
    /// so this is the only code that has to ask macOS a question keyed on
    /// one. Growing a Toolkit type for a debug table would be backwards.
    private static let terminalBundleIDs: [TerminalApp: String] = [
        .terminal: "com.apple.Terminal",
        .iTerm2: "com.googlecode.iterm2",
        .warp: "dev.warp.Warp-Stable",
        .alacritty: "org.alacritty",
        .ghostty: "com.mitchellh.ghostty"
    ]

    // MARK: - Formatting

    private static func label(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    private static func label(for setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "not supported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown (\(setting.rawValue))"
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func timestamp() -> String { stamp(Date()) }

    // MARK: - sysctl

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "—" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "—" }
        // sysctl includes the terminating NUL in the length it reports.
        if buffer.last == 0 { buffer.removeLast() }
        return String(bytes: buffer, encoding: .utf8) ?? "—"
    }

    private static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // ENOENT on an Intel Mac, where the key does not exist at all -
        // which is the same answer as "not translated".
        guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }
}

/// Whether macOS will let this app drive another one through Apple events.
///
/// The one permission the app cannot recover from on its own: a terminal-mode
/// update that is refused here fails with osascript error -1743, which is
/// what `UpdateProgress.Phase.terminalPermission` exists to word. Being able
/// to read the answer *before* starting a run is the whole reason this row is
/// in the table.
enum AutomationPermission: Equatable, Sendable {
    case granted
    case denied
    /// Nobody has been asked yet. Not a failure - the first terminal-mode
    /// run is what raises the prompt.
    case undetermined
    /// The target is not running, so macOS has nothing to answer about.
    case targetNotRunning
    case unknown(OSStatus)

    var label: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "not determined"
        case .targetNotRunning: return "target not running"
        case .unknown(let status): return "unknown (OSStatus \(status))"
        }
    }

    /// Asks macOS, without prompting.
    ///
    /// `askUserIfNeeded: false` is not optional here: a diagnostics table
    /// that made the system throw up a consent alert just for being looked
    /// at would be answering a question nobody asked, and the answer would
    /// then be recorded for the rest of the app.
    static func check(bundleID: String) -> AutomationPermission {
        guard !bundleID.isEmpty else { return .unknown(0) }

        var target = AEAddressDesc()
        let identifier = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, identifier, identifier.count, &target) == noErr else {
            return .unknown(0)
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        case OSStatus(procNotFound): return .targetNotRunning
        default: return .unknown(status)
        }
    }
}
