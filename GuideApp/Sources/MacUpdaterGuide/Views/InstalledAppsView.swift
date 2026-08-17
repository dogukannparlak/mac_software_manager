import SwiftUI

/// Every installed application with its icon, version and where it came from,
/// plus the Homebrew command line tools underneath.
struct InstalledAppsView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(AppIconCache.self) private var icons
    @Environment(InventoryStore.self) private var inventory

    @State private var searchText = ""
    @State private var sourceFilter: InstallSource?
    @State private var showsTools = false
    @State private var ignoredKeys: Set<String> = []

    private var apps: [InstalledApp] { inventory.apps }
    private var tools: [InstalledTool] { inventory.tools }
    private var isLoading: Bool { inventory.isLoading && inventory.apps.isEmpty }

    private var filteredApps: [InstalledApp] {
        apps.filter { app in
            if let sourceFilter, app.source != sourceFilter { return false }
            guard !searchText.isEmpty else { return true }
            return app.name.localizedCaseInsensitiveContains(searchText)
                || (app.token ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredTools: [InstalledTool] {
        guard !searchText.isEmpty else { return tools }
        return tools.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func ignoreKey(for app: InstalledApp) -> String {
        switch app.source {
        case .homebrew: return "cask|\(app.token ?? app.name)"
        case .manual: return "sparkle|\(app.name)"
        default: return "none|\(app.name)"
        }
    }

    private var counts: [InstallSource: Int] {
        Dictionary(grouping: apps, by: \.source).mapValues(\.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                filterBar

                if isLoading {
                    Card {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(UIStrings.scanning[loc.language])
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    appsCard

                    DisclosureGroup(isExpanded: $showsTools) {
                        toolsCard.padding(.top, 8)
                    } label: {
                        Label(
                            String(format: UIStrings.showToolsFormat[loc.language], tools.count),
                            systemImage: "terminal"
                        )
                        .font(.title3.weight(.semibold))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(UIStrings.navInstalled[loc.language])
        .searchable(text: $searchText, prompt: Text(UIStrings.searchApps[loc.language]))
        .task(id: toolkit.snapshot.lastCheck) { await reload() }
    }

    private func reload() async {
        await inventory.load()
        ignoredKeys = Set(IgnoreList.load().entries.map { "\($0.type)|\($0.id)" })
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(symbol: "square.grid.2x2.fill", size: 56, tint: .indigo)

            VStack(alignment: .leading, spacing: 4) {
                Text(UIStrings.navInstalled[loc.language])
                    .font(.system(.largeTitle).weight(.bold))

                Text(String(
                    format: UIStrings.installedSummaryFormat[loc.language],
                    apps.count,
                    tools.count
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { filterChips }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { filterChips }
            }
        }
    }

    @ViewBuilder
    private var filterChips: some View {
        FilterChip(
            title: UIStrings.filterAll[loc.language],
            count: apps.count,
            isSelected: sourceFilter == nil
        ) {
            sourceFilter = nil
        }

        ForEach(InstallSource.allCases.sorted { $0.sortRank < $1.sortRank }) { source in
            let count = counts[source] ?? 0
            if count > 0 {
                FilterChip(
                    title: source.label[loc.language],
                    count: count,
                    isSelected: sourceFilter == source,
                    tint: source.tint
                ) {
                    sourceFilter = (sourceFilter == source) ? nil : source
                }
            }
        }
    }

    // MARK: - Lists

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(UIStrings.applications[loc.language])
                .font(.title3.weight(.semibold))

            if filteredApps.isEmpty {
                Card {
                    Text(UIStrings.noMatches[loc.language])
                        .foregroundStyle(.secondary)
                }
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            InstalledAppRow(app: app, isIgnored: ignoredKeys.contains(ignoreKey(for: app)))
                        }
                    }
                }
            }
        }
    }

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(filteredTools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { Divider().padding(.vertical, 2) }
                        HStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                                .frame(width: 30)

                            Text(tool.name)
                                .font(.body.monospaced())

                            if tool.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .help(UIStrings.pinned[loc.language])
                            }

                            Spacer(minLength: 8)

                            Text(tool.version)
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.vertical, 5)
                        .contextMenu {
                            if tool.isPinned {
                                Button(UIStrings.unpinFormula[loc.language]) {
                                    toolkit.unignore(type: "brew", id: tool.name, name: tool.name)
                                }
                            } else {
                                Button(UIStrings.pinFormula[loc.language]) {
                                    toolkit.ignore(type: "brew", id: tool.name, name: tool.name)
                                }
                            }
                        }
                    }
                }
            }
        }
        .transition(.opacity)
    }
}

private struct InstalledAppRow: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(AppIconCache.self) private var icons

    let app: InstalledApp
    let isIgnored: Bool

    @State private var pendingLink: (title: Localized, url: URL)?
    @State private var isEditingLinks = false
    @State private var isEditingTracking = false
    @State private var isEditingMapping = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icons.icon(for: app.url))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.body.weight(.medium))

                if let token = app.token {
                    HStack(spacing: 4) {
                        Text(token)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        if app.isManuallyMapped {
                            Image(systemName: "pencil.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .help(UIStrings.manuallyMappedHelp[loc.language])
                        }
                    }
                } else if let identifier = app.bundleIdentifier {
                    Text(identifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Text(app.version)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            // Two clickable elements only: the Homebrew status, and everything
            // else - opening a link, correcting one, retagging how the app is
            // tracked - behind a single "more" menu. Three separate open-link
            // icons made the row noisy and none of the editing lived here at
            // all; this is the one place both now do.
            HStack(spacing: 6) {
                if app.hasCustomLinks {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .help(UIStrings.customLinksHelp[loc.language])
                }

                ExternalLinkButton(
                    symbol: "shippingbox.fill",
                    tint: .orange,
                    pageTitle: UIStrings.homebrewPageTitle,
                    url: app.homebrewURL
                )

                Menu {
                    rowActionsMenu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background {
                            Circle().fill(Color.secondary.opacity(0.14))
                        }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(UIStrings.moreOptions[loc.language])
            }
            .frame(width: 76, alignment: .trailing)

            SourceBadge(source: app.source)
                .frame(width: 132, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .opacity(isIgnored ? 0.55 : 1)
        .contextMenu {
            rowActionsMenu
        }
        .sheet(isPresented: $isEditingLinks) {
            AppLinkEditorSheet(app: app)
                .environment(loc)
        }
        .sheet(isPresented: $isEditingTracking) {
            AppTrackingEditorSheet(app: app)
                .environment(loc)
        }
        .sheet(isPresented: $isEditingMapping) {
            AppHomebrewMappingEditorSheet(app: app)
                .environment(loc)
        }
        .confirmationDialog(
            pendingLink?.title[loc.language] ?? "",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            titleVisibility: .visible,
            presenting: pendingLink
        ) { link in
            Button(UIStrings.openInBrowser[loc.language]) {
                NSWorkspace.shared.open(link.url)
            }
            Button(UIStrings.cancel[loc.language], role: .cancel) {}
        } message: { link in
            Text(link.url.absoluteString)
        }
    }

    /// Everything that used to be split across three menu-bar-era settings
    /// pages, scoped down to this one app. Shared between the "…" button and
    /// the right-click menu so both stay in sync automatically.
    @ViewBuilder
    private var rowActionsMenu: some View {
        if let website = app.officialWebsiteURL {
            Button(UIStrings.openOfficialWebsite[loc.language]) {
                pendingLink = (UIStrings.officialWebsiteTitle, website)
            }
        }
        if let repoPage = app.githubURL {
            Button(UIStrings.openGitHubRepository[loc.language]) {
                pendingLink = (UIStrings.githubRepositoryTitle, repoPage)
            }
        }
        if let releases = app.githubReleasesURL {
            Button(UIStrings.openGitHubReleases[loc.language]) {
                pendingLink = (UIStrings.githubReleasesTitle, releases)
            }
        }
        if app.officialWebsiteURL != nil || app.githubURL != nil {
            Divider()
        }

        // Everything below writes to a local file only - nothing here is
        // shared or uploaded anywhere.
        Button(UIStrings.editLinks[loc.language]) {
            isEditingLinks = true
        }
        Button(UIStrings.editTrackingMethod[loc.language]) {
            isEditingTracking = true
        }
        Button(UIStrings.editHomebrewMapping[loc.language]) {
            isEditingMapping = true
        }

        Divider()
        Button(UIStrings.revealInFinder[loc.language]) {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        }

        if let identifier = ignoreIdentifier {
            Divider()
            if isIgnored {
                Button(UIStrings.unignoreApp[loc.language]) {
                    toolkit.unignore(type: ignoreType, id: identifier, name: app.name)
                }
            } else {
                Button(UIStrings.ignoreApp[loc.language]) {
                    toolkit.ignore(type: ignoreType, id: identifier, name: app.name)
                }
            }
        }
    }

    private var ignoreType: String {
        switch app.source {
        case .homebrew: return "cask"
        case .appStore: return "mas"
        default: return "sparkle"
        }
    }

    /// App Store entries are keyed by their numeric id, which is not something
    /// the bundle exposes, so those cannot be toggled from here.
    private var ignoreIdentifier: String? {
        switch app.source {
        case .homebrew: return app.token
        case .appStore: return nil
        case .manual: return app.name
        default: return nil
        }
    }
}

private struct SourceBadge: View {
    @Environment(LocalizationStore.self) private var loc
    let source: InstallSource

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source.symbol)
                .font(.caption2)
            Text(source.label[loc.language])
                .font(.caption)
        }
        .foregroundStyle(source.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(source.tint.opacity(0.12))
        }
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .font(.callout)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(isSelected ? tint : Color.secondary.opacity(0.12))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}


/// One external-link slot in a row: a large, clearly tinted icon that always
/// occupies the same space whether or not a link is available, and that asks
/// before it sends the user to a browser.
private struct ExternalLinkButton: View {
    @Environment(LocalizationStore.self) private var loc

    let symbol: String
    let tint: Color
    let pageTitle: Localized
    let url: URL?

    @State private var isConfirming = false

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill((url == nil ? Color.secondary : tint).opacity(url == nil ? 0.08 : 0.16))
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(url == nil ? Color.secondary.opacity(0.35) : tint)
        .disabled(url == nil)
        .help(url?.absoluteString ?? "")
        .confirmationDialog(
            pageTitle[loc.language],
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(UIStrings.openInBrowser[loc.language]) {
                if let url { NSWorkspace.shared.open(url) }
            }
            Button(UIStrings.cancel[loc.language], role: .cancel) {}
        } message: {
            Text(url?.absoluteString ?? "")
        }
    }
}

/// Local, per-app correction for the website / GitHub links.
///
/// Nothing here leaves the machine: it writes straight to `app_links.conf` and
/// nothing else reads that file. This is the "fix it yourself, right now"
/// option rather than the shared, moderated version, which needs someone to
/// review submissions before they reach anyone else and is not built yet.
private struct AppLinkEditorSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(InventoryStore.self) private var inventory
    @Environment(\.dismiss) private var dismiss

    let app: InstalledApp

    @State private var website: String
    @State private var repo: String

    init(app: InstalledApp) {
        self.app = app
        _website = State(initialValue: app.officialWebsiteURL?.absoluteString ?? "")
        _repo = State(initialValue: app.githubRepo ?? "")
    }

    private var trimmedWebsite: String { website.trimmingCharacters(in: .whitespaces) }
    private var trimmedRepo: String { repo.trimmingCharacters(in: .whitespaces) }

    private var websiteIsValid: Bool {
        trimmedWebsite.isEmpty || URL(string: trimmedWebsite)?.scheme == "https"
    }

    private var repoIsValid: Bool {
        trimmedRepo.isEmpty || trimmedRepo.split(separator: "/").count == 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(String(format: UIStrings.editLinksTitleFormat[loc.language], app.name))
                    .font(.headline)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section {
                    TextField(
                        UIStrings.officialWebsiteField[loc.language],
                        text: $website,
                        prompt: Text("https://example.com")
                    )
                    .font(.callout.monospaced())

                    if !websiteIsValid {
                        Label(UIStrings.invalidWebsiteURL[loc.language], systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    TextField(
                        UIStrings.githubRepoField[loc.language],
                        text: $repo,
                        prompt: Text("owner/repository")
                    )
                    .font(.callout.monospaced())

                    if !repoIsValid {
                        Label(UIStrings.invalidGithubRepo[loc.language], systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text(UIStrings.editLinksHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if app.hasCustomLinks {
                    Button(UIStrings.resetToAutomatic[loc.language]) {
                        InstalledInventory.setLinkOverride(appName: app.name, website: nil, githubRepo: nil)
                        Task { await inventory.reload() }
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }

                Spacer()
                Button(UIStrings.cancel[loc.language]) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(UIStrings.save[loc.language]) {
                    InstalledInventory.setLinkOverride(
                        appName: app.name,
                        website: trimmedWebsite.isEmpty ? nil : URL(string: trimmedWebsite),
                        githubRepo: trimmedRepo.isEmpty ? nil : trimmedRepo
                    )
                    Task { await inventory.reload() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!websiteIsValid || !repoIsValid)
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}

/// Sets how one specific app is checked for updates - the same rule
/// `TrackedAppsEditor` manages as a list, minus the step of finding this app
/// in that list first, since it is already on screen.
private struct AppTrackingEditorSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let app: InstalledApp

    @State private var method: TrackingMethod
    @State private var identifier: String
    @State private var hadExistingRule: Bool

    init(app: InstalledApp) {
        self.app = app

        if let existing = TrackedAppsStore.entry(forApp: app.name) {
            _method = State(initialValue: existing.method)
            _identifier = State(initialValue: existing.identifier)
            _hadExistingRule = State(initialValue: true)
        } else {
            // A reasonable starting point, not a rule until Save is pressed
            _method = State(initialValue: app.githubRepo != nil ? .github : .sparkle)
            _identifier = State(initialValue: app.githubRepo ?? "")
            _hadExistingRule = State(initialValue: false)
        }
    }

    private var identifierIsValid: Bool {
        switch method {
        case .skip: return true
        case .github: return identifier.split(separator: "/").count == 2
        case .sparkle: return URL(string: identifier)?.scheme == "https"
        case .homebrew: return !identifier.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(String(format: UIStrings.editTrackingTitleFormat[loc.language], app.name))
                    .font(.headline)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section {
                    Picker(UIStrings.method[loc.language], selection: $method) {
                        ForEach(TrackingMethod.allCases) { option in
                            Text(option.label[loc.language]).tag(option)
                        }
                    }

                    if method != .skip {
                        TextField(
                            method.identifierLabel[loc.language],
                            text: $identifier,
                            prompt: Text(method.identifierPrompt[loc.language])
                        )
                        .font(.callout.monospaced())

                        if !identifierIsValid {
                            Label(UIStrings.invalidIdentifier[loc.language], systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text(UIStrings.editTrackingHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if hadExistingRule {
                    Button(UIStrings.removeRule[loc.language], role: .destructive) {
                        TrackedAppsStore.removeEntry(appName: app.name)
                        dismiss()
                    }
                }

                Spacer()
                Button(UIStrings.cancel[loc.language]) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(UIStrings.save[loc.language]) {
                    TrackedAppsStore.setEntry(appName: app.name, method: method, identifier: identifier)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!identifierIsValid)
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}

/// Sets which Homebrew cask one specific app maps to - the same mapping
/// `TokenMapEditor` manages as a list, scoped to the app already on screen.
private struct AppHomebrewMappingEditorSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(InventoryStore.self) private var inventory
    @Environment(\.dismiss) private var dismiss

    let app: InstalledApp

    @State private var token: String
    @State private var hadExistingMapping: Bool

    init(app: InstalledApp) {
        self.app = app
        let existing = TokenMapStore.token(forApp: app.name)
        _token = State(initialValue: existing ?? app.token ?? "")
        _hadExistingMapping = State(initialValue: existing != nil)
    }

    private var trimmedToken: String { token.trimmingCharacters(in: .whitespaces) }
    private var isKnownCask: Bool { inventory.isKnownCask(trimmedToken) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 28, height: 28)
                Text(String(format: UIStrings.editMappingTitleFormat[loc.language], app.name))
                    .font(.headline)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section {
                    TextField(
                        UIStrings.caskToken[loc.language],
                        text: $token,
                        prompt: Text("logitech-g-hub")
                    )
                    .font(.callout.monospaced())

                    if !trimmedToken.isEmpty {
                        if isKnownCask {
                            Label(UIStrings.mappingValid[loc.language], systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label(UIStrings.mappingUnknownCask[loc.language], systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text(UIStrings.editMappingHelp[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if hadExistingMapping {
                    Button(UIStrings.removeRule[loc.language], role: .destructive) {
                        TokenMapStore.removeToken(appName: app.name)
                        Task { await inventory.reload() }
                        dismiss()
                    }
                }

                Spacer()
                Button(UIStrings.cancel[loc.language]) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(UIStrings.save[loc.language]) {
                    TokenMapStore.setToken(appName: app.name, token: trimmedToken)
                    Task { await inventory.reload() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedToken.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}
