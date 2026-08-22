import AppKit
import SwiftUI

/// Which settings page the sidebar is showing.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case updates
    case tracked
    case tokenMap
    case migrate
    case ignored
    case advanced
    case about

    var id: String { rawValue }

    var title: Localized {
        switch self {
        case .general: return UIStrings.tabGeneral
        case .updates: return UIStrings.tabUpdates
        case .tracked: return UIStrings.navTracked
        case .tokenMap: return UIStrings.navTokenMap
        case .migrate: return UIStrings.tabMigrate
        case .ignored: return UIStrings.tabIgnored
        case .advanced: return UIStrings.tabAdvanced
        case .about: return UIStrings.tabAbout
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .updates: return "arrow.triangle.2.circlepath"
        case .tracked: return "list.bullet.rectangle"
        case .tokenMap: return "arrow.left.arrow.right"
        case .migrate: return "arrow.right.doc.on.clipboard"
        case .ignored: return "eye.slash"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

// MARK: - General

struct GeneralSettingsPage: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit

    @State private var settings = ToolkitSettings()
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var localization = loc
        @Bindable var preferences = toolkit.preferences

        SettingsPage(
            symbol: "gearshape",
            title: UIStrings.tabGeneral[loc.language],
            subtitle: UIStrings.generalIntro[loc.language]
        ) {
            Card {
                Form {
                    Picker(UIStrings.language[loc.language], selection: $localization.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.endonym).tag(language)
                        }
                    }

                    Picker(UIStrings.checkInterval[loc.language], selection: $preferences.refreshMinutes) {
                        ForEach(AppPreferences.intervalChoices, id: \.self) { minutes in
                            Text(AppPreferences.intervalLabel(minutes)[loc.language]).tag(minutes)
                        }
                    }
                }
                .formStyle(.columns)
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(UIStrings.sectionRunning[loc.language])
                        .font(.headline)

                    Toggle(isOn: $preferences.runUpdatesInTerminal) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(UIStrings.runInTerminal[loc.language])
                            Text(UIStrings.runInTerminalHelp[loc.language])
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Toggle(isOn: $preferences.autoOpenTerminalWhenRequired) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(UIStrings.autoOpenTerminal[loc.language])
                            Text(UIStrings.autoOpenTerminalHelp[loc.language])
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if preferences.runUpdatesInTerminal {
                        Divider()

                        Picker(UIStrings.terminal[loc.language], selection: Binding(
                            get: { settings.preferredTerminal },
                            set: { settings.preferredTerminal = $0; settings.save() }
                        )) {
                            ForEach(TerminalApp.allCases) { terminal in
                                Text(terminal.isInstalled
                                     ? terminal.displayName
                                     : "\(terminal.displayName) — \(UIStrings.notInstalled[loc.language])")
                                    .tag(terminal)
                            }
                        }

                        Text(UIStrings.terminalHelp[loc.language])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    Picker(UIStrings.maxConcurrentUpdates[loc.language], selection: $preferences.maxConcurrentUpdates) {
                        ForEach(AppPreferences.maxConcurrentUpdatesChoices, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    Text(UIStrings.maxConcurrentUpdatesHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $preferences.hideDockIcon) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(UIStrings.hideDockIcon[loc.language])
                            Text(UIStrings.hideDockIconHelp[loc.language])
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { launchAtLogin },
                        set: {
                            loginItemError = LaunchAtLogin.set($0)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(UIStrings.launchAtLogin[loc.language])
                            Text(UIStrings.launchAtLoginHelp[loc.language])
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if LaunchAtLogin.requiresApproval || loginItemError != nil {
                        HStack(spacing: 8) {
                            Label(UIStrings.launchAtLoginBlocked[loc.language],
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button(UIStrings.openLoginItems[loc.language]) {
                                LaunchAtLogin.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .task {
            settings.load()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

// MARK: - Updates

struct UpdateSettingsPage: View {
    @Environment(LocalizationStore.self) private var loc

    @State private var settings = ToolkitSettings()

    var body: some View {
        SettingsPage(
            symbol: "arrow.triangle.2.circlepath",
            tint: .green,
            title: UIStrings.tabUpdates[loc.language],
            subtitle: UIStrings.updatesIntro[loc.language]
        ) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    settingToggle(
                        \.masEnabled,
                        title: UIStrings.appStoreUpdates,
                        help: UIStrings.appStoreHelp
                    )
                    Divider()
                    settingToggle(
                        \.cleanupEnabled,
                        title: UIStrings.cleanup,
                        help: UIStrings.cleanupHelp
                    )
                    Divider()
                    settingToggle(
                        \.autoInstallApps,
                        title: UIStrings.autoInstall,
                        help: UIStrings.autoInstallHelp
                    )

                    if settings.autoInstallApps {
                        Label(UIStrings.autoInstallWarning[loc.language], systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(UIStrings.sectionToolkit[loc.language])
                        .font(.headline)

                    Picker("", selection: Binding(
                        get: { settings.channel },
                        set: { settings.channel = $0; settings.save() }
                    )) {
                        ForEach(UpdateChannel.allCases) { channel in
                            Text(channel.label[loc.language]).tag(channel)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(UIStrings.channelHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { settings.load() }
    }

    private func settingToggle(
        _ keyPath: ReferenceWritableKeyPath<ToolkitSettings, Bool>,
        title: Localized,
        help: Localized
    ) -> some View {
        Toggle(isOn: Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0; settings.save() }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title[loc.language])
                Text(help[loc.language])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Ignored

struct IgnoredAppsPage: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit

    @State private var entries: [(type: String, id: String, name: String)] = []

    var body: some View {
        SettingsPage(
            symbol: "eye.slash",
            tint: .gray,
            title: UIStrings.tabIgnored[loc.language],
            subtitle: UIStrings.ignoredIntro[loc.language]
        ) {
            Card {
                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(UIStrings.noIgnoredApps[loc.language])
                            .font(.headline)
                        Text(UIStrings.noIgnoredAppsDetail[loc.language])
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            HStack(spacing: 12) {
                                Image(systemName: symbol(for: entry.type))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                Text(entry.name)
                                    .font(.body.weight(.medium))

                                Text(sourceLabel(for: entry.type)[loc.language])
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer(minLength: 8)

                                Button(UIStrings.restore[loc.language]) {
                                    IgnoreList.remove(type: entry.type, id: entry.id)
                                    reload()
                                    toolkit.reload()
                                }
                                .controlSize(.small)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
            }
        }
        .task { reload() }
    }

    private func reload() {
        entries = IgnoreList.load().entries
    }

    private func symbol(for type: String) -> String {
        switch type {
        case "cask": return "shippingbox"
        case "mas": return "bag"
        case "brew": return "terminal"
        default: return "app"
        }
    }

    private func sourceLabel(for type: String) -> Localized {
        switch type {
        case "cask": return Localized("Homebrew cask", "Homebrew cask")
        case "brew": return Localized("Homebrew formula (pinned)", "Homebrew formülü (sabit)")
        case "mas": return Localized("App Store", "App Store")
        default: return Localized("Application", "Uygulama")
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsPage: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit

    @State private var cacheSize = ""
    @State private var didResetCache = false

    var body: some View {
        @Bindable var preferences = toolkit.preferences

        return SettingsPage(
            symbol: "wrench.and.screwdriver",
            tint: .purple,
            title: UIStrings.tabAdvanced[loc.language],
            subtitle: UIStrings.advancedIntro[loc.language]
        ) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(UIStrings.sectionEngine[loc.language])
                        .font(.headline)

                    if let url = toolkit.scriptURL {
                        Text(url.path(percentEncoded: false))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(UIStrings.notFound[loc.language], systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Button(UIStrings.locateAgain[loc.language]) { toolkit.relocateScript() }
                        Button(UIStrings.chooseManually[loc.language]) { chooseScript() }
                    }

                    Text(UIStrings.engineHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(UIStrings.sectionCache[loc.language])
                        .font(.headline)

                    LabeledContent(UIStrings.cacheSize[loc.language]) {
                        Text(cacheSize.isEmpty ? "—" : cacheSize)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button {
                            toolkit.refresh(force: true)
                        } label: {
                            Label(UIStrings.refreshNow[loc.language], systemImage: "arrow.clockwise")
                        }
                        .disabled(toolkit.isRefreshing)

                        Button(role: .destructive) {
                            clearCache()
                        } label: {
                            Label(UIStrings.clearCache[loc.language], systemImage: "trash")
                        }

                        if didResetCache {
                            Label(UIStrings.cacheCleared[loc.language], systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }

                    Text(UIStrings.cacheHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(UIStrings.sectionFiles[loc.language])
                        .font(.headline)

                    Button {
                        NSWorkspace.shared.selectFile(
                            nil,
                            inFileViewerRootedAtPath: ToolkitPaths.supportDirectory.path(percentEncoded: false)
                        )
                    } label: {
                        Label(UIStrings.revealSupportFolder[loc.language], systemImage: "folder")
                    }

                    Text(UIStrings.filesHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Bottom of the last settings page on purpose: this reveals a
            // page that can start real updates, so it is somewhere you end
            // up looking for rather than somewhere you pass through.
            Card {
                Toggle(isOn: $preferences.debugMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UIStrings.debugMode[loc.language])
                        Text(UIStrings.debugModeHelp[loc.language])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task { measureCache() }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = UIStrings.chooseScriptPrompt[loc.language]

        if panel.runModal() == .OK, let url = panel.url {
            ToolkitPaths.scriptOverride = url
            toolkit.relocateScript()
        }
    }

    private func measureCache() {
        let path = ToolkitPaths.cacheDirectory.path(percentEncoded: false)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            cacheSize = "—"
            return
        }
        var total = 0
        for file in files {
            let attributes = try? FileManager.default.attributesOfItem(atPath: "\(path)/\(file)")
            total += (attributes?[.size] as? Int) ?? 0
        }
        cacheSize = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    /// Empties the cache but keeps the directory.
    ///
    /// Removing the directory itself left the app with nothing to read until
    /// something recreated it, and a refresh interrupted at the wrong moment
    /// meant the menu stayed empty with no clue why.
    private func clearCache() {
        let directory = ToolkitPaths.cacheDirectory
        let fileManager = FileManager.default

        if let files = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) {
            for file in files {
                try? fileManager.removeItem(at: directory.appending(path: file))
            }
        } else {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        didResetCache = true
        measureCache()
        toolkit.refresh(force: true)
    }
}

// MARK: - About

struct AboutPage: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(\.openURL) private var openURL

    @State private var updatePending = false
    @State private var settings = ToolkitSettings()

    var body: some View {
        SettingsPage(
            symbol: "info.circle",
            tint: .teal,
            title: UIStrings.tabAbout[loc.language],
            subtitle: GuideContent.appTagline[loc.language]
        ) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(UIStrings.appVersionLabel[loc.language]) {
                        Text(ToolkitVersion.appVersion).foregroundStyle(.secondary)
                    }
                    Divider()
                    LabeledContent(UIStrings.toolkitVersionLabel[loc.language]) {
                        Text(ToolkitVersion.read(from: toolkit.scriptURL) ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HomebrewStatusCard()

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    if updatePending {
                        Label(UIStrings.toolkitUpdateAvailable[loc.language],
                              systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.orange)

                        Button {
                            toolkit.installToolkitUpdate()
                        } label: {
                            Label(UIStrings.installToolkitUpdate[loc.language],
                                  systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button {
                        toolkit.checkToolkitUpdate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            updatePending = toolkit.toolkitUpdatePending
                        }
                    } label: {
                        Label(UIStrings.checkForToolkitUpdate[loc.language], systemImage: "sparkles")
                    }

                    Text(UIStrings.toolkitUpdateHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            openURL(ToolkitVersion.projectURL)
                        } label: {
                            Label(UIStrings.visitProject[loc.language], systemImage: "link")
                        }
                        if let mirrorURL = ToolkitVersion.mirrorURL(username: settings.codebergUsername) {
                            Button {
                                openURL(mirrorURL)
                            } label: {
                                Label(UIStrings.visitMirror[loc.language], systemImage: "arrow.triangle.branch")
                            }
                        }
                        Spacer()
                    }

                    if ToolkitVersion.mirrorURL(username: settings.codebergUsername) == nil {
                        Text(UIStrings.mirrorNotConfigured[loc.language])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            updatePending = toolkit.toolkitUpdatePending
            settings.load()
        }
    }
}

/// Homebrew's own version, and how stale its local database is.
///
/// Homebrew has no versioned releases to check for the way an app does -
/// `brew update` just pulls the latest commits - so what is worth showing is
/// *when that last happened*: every "outdated" list in this app is only as
/// accurate as this timestamp.
private struct HomebrewStatusCard: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit

    @State private var status: HomebrewStatus?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(UIStrings.homebrewVersionLabel[loc.language]) {
                    Text(status?.version ?? "—").foregroundStyle(.secondary)
                }

                Divider()

                LabeledContent(UIStrings.homebrewDatabaseLabel[loc.language]) {
                    HStack(spacing: 6) {
                        if let status, let lastUpdated = status.lastUpdated {
                            if status.isStale {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Text(relativeTime(lastUpdated))
                                .foregroundStyle(status.isStale ? .orange : .secondary)
                        } else {
                            Text(UIStrings.neverChecked[loc.language])
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    Button {
                        toolkit.checkHomebrewDatabase()
                    } label: {
                        Label(UIStrings.checkHomebrewNow[loc.language], systemImage: "shippingbox")
                    }
                    .disabled(toolkit.isUpdating)

                    if toolkit.isUpdating, toolkit.progress?.phase == .brewUpdate {
                        ProgressView().controlSize(.small)
                    }
                }

                if status?.isStale != false {
                    Text(UIStrings.homebrewStaleHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: toolkit.snapshot.lastCheck) {
            status = HomebrewStatus.load()
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: loc.language.rawValue)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
