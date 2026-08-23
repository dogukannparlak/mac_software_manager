import SwiftUI

/// What the sidebar can point at.
enum SidebarItem: Hashable {
    case updates
    case installed
    case cliTools
    case history
    case topic(GuideTopic.ID)
    case settings(SettingsSection)
    /// The manual test surface. Only reachable when
    /// `AppPreferences.showsDebugPage` says so - see `DebugView`.
    case debug
}

/// Single window: navigation on the left, content on the right - the split
/// layout System Settings and Mail use, so it needs no learning.
struct ContentView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(NavigationStore.self) private var navigation
    @Environment(InventoryStore.self) private var inventory

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 236, ideal: 252, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // Above whichever page is showing, because the actions that
                // produce one of these - a refresh, an ignore, a toolkit
                // check - are started from several of them and from the menu
                // bar, and none of them has anywhere else to report.
                if let failure = toolkit.lastFailure {
                    FailureBanner(
                        failure: failure,
                        onDismiss: { toolkit.dismissFailure() },
                        onRecover: { toolkit.recover(from: $0) }
                    )
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                languagePicker
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .updates:
            UpdatesView()
        case .installed:
            InstalledAppsView()
        case .cliTools:
            CLIToolsView()
        case .history:
            HistoryView()
        case .topic(let id):
            if let topic = GuideContent.topics.first(where: { $0.id == id }) {
                TopicDetailView(topic: topic)
            } else {
                placeholder
            }
        case .settings(let section):
            settingsPage(section)
        case .debug:
            // Checked here as well as in the sidebar: the selection survives
            // in the navigation store, so turning the toggle off with the
            // page open must take the page away too, not just its row.
            if toolkit.preferences.showsDebugPage {
                DebugView()
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    @ViewBuilder
    private func settingsPage(_ section: SettingsSection) -> some View {
        switch section {
        case .general:  GeneralSettingsPage()
        case .updates:  UpdateSettingsPage()
        case .tracked:  TrackedAppsEditor()
        case .tokenMap: TokenMapEditor()
        case .migrate:  MigrateToHomebrewPage()
        case .ignored:  IgnoredAppsPage()
        case .advanced: AdvancedSettingsPage()
        case .uninstall: UninstallPage()
        case .about:    AboutPage()
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            GuideContent.sidebarHeading[loc.language],
            systemImage: "sidebar.left"
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        @Bindable var navigation = navigation

        return List(selection: $navigation.selection) {
            Section {
                appHeader
                    .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 14, trailing: 8))
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }

            Section(UIStrings.sidebarStatus[loc.language]) {
                Label {
                    HStack {
                        Text(UIStrings.navUpdates[loc.language])
                        Spacer(minLength: 4)
                        if !toolkit.snapshot.isEmpty {
                            Text("\(toolkit.snapshot.count)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                } icon: {
                    Image(systemName: "arrow.down.circle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                }
                .tag(SidebarItem.updates)

                Label {
                    Text(UIStrings.navInstalled[loc.language])
                } icon: {
                    Image(systemName: "square.grid.2x2")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                }
                .tag(SidebarItem.installed)

                Label {
                    HStack {
                        Text(UIStrings.navCLITools[loc.language])
                        Spacer(minLength: 4)
                        if !inventory.tools.isEmpty {
                            Text("\(inventory.tools.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "terminal")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                }
                .tag(SidebarItem.cliTools)

                Label {
                    Text(UIStrings.navHistory[loc.language])
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                }
                .tag(SidebarItem.history)
            }

            // Settings are part of this window rather than a separate
            // preferences panel: one place to look, and the rules editors need
            // the room anyway.
            Section(UIStrings.sidebarSettingsSection[loc.language]) {
                ForEach(SettingsSection.allCases) { section in
                    Label {
                        Text(section.title[loc.language])
                    } icon: {
                        Image(systemName: section.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    .tag(SidebarItem.settings(section))
                }
            }

            Section(GuideContent.sidebarHeading[loc.language]) {
                ForEach(GuideContent.topics) { topic in
                    Label {
                        Text(topic.title[loc.language])
                    } icon: {
                        Image(systemName: topic.symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    .tag(SidebarItem.topic(topic.id))
                }
            }

            // Last, and only when asked for: everything above is the app,
            // this is the workbench for it.
            if toolkit.preferences.showsDebugPage {
                Section(UIStrings.sidebarDeveloperSection[loc.language]) {
                    Label {
                        Text(UIStrings.navDebug[loc.language])
                    } icon: {
                        Image(systemName: "ladybug")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    .tag(SidebarItem.debug)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var appHeader: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "shippingbox.fill", size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(GuideContent.appName[loc.language])
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(GuideContent.appTagline[loc.language])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var languagePicker: some View {
        @Bindable var store = loc

        Picker(selection: $store.language) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.endonym).tag(language)
            }
        } label: {
            Label(
                GuideContent.languagePickerLabel[loc.language],
                systemImage: "globe"
            )
        }
        .pickerStyle(.menu)
        .help(GuideContent.languagePickerLabel[loc.language])
    }
}
