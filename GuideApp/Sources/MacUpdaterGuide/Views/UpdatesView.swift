import SwiftUI

/// Everything waiting to be updated, in one place - the same data the menu bar
/// shows, with room to actually read it.
struct UpdatesView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(AppIconCache.self) private var icons
    @Environment(\.openURL) private var openURL

    @State private var warnings: [ConfigWarning] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let progress = toolkit.progress, progress.state != .done || toolkit.isUpdating {
                    ProgressBanner(progress: progress)
                }

                // The toolkit updates itself; say so here rather than burying it
                if toolkit.toolkitUpdatePending {
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(UIStrings.toolkitUpdateAvailable[loc.language])
                                    .font(.headline)
                                Text(UIStrings.toolkitUpdateHelp[loc.language])
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button(UIStrings.installToolkitUpdate[loc.language]) {
                                toolkit.installToolkitUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                // A typo in settings.conf changes behaviour silently otherwise
                if !warnings.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(UIStrings.configWarnings[loc.language], systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            ForEach(warnings) { warning in
                                Text(warning.message[loc.language])
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if toolkit.snapshot.items.isEmpty {
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(UIStrings.everythingUpToDate[loc.language])
                                    .font(.headline)
                                Text(UIStrings.nothingPending[loc.language])
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    ForEach(toolkit.snapshot.groups, id: \.source.groupOrder) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.source.groupTitle[loc.language])
                                .font(.title3.weight(.semibold))

                            Card {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                        if index > 0 { Divider().padding(.vertical, 2) }
                                        UpdateDetailRow(item: item)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(UIStrings.navUpdates[loc.language])
        .task(id: toolkit.snapshot.lastCheck) { warnings = ConfigWarning.check() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toolkit.checkHomebrewDatabase()
                } label: {
                    Label(UIStrings.checkHomebrewNow[loc.language], systemImage: "shippingbox")
                }
                .disabled(toolkit.isUpdating)
                .help(UIStrings.checkHomebrewNowHelp[loc.language])
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    toolkit.refresh(force: true)
                } label: {
                    Label(UIStrings.refreshNow[loc.language], systemImage: "arrow.clockwise")
                }
                .disabled(toolkit.isRefreshing)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(
                symbol: toolkit.snapshot.count > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill",
                size: 56,
                tint: toolkit.snapshot.count > 0 ? .orange : .green
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(.largeTitle).weight(.bold))

                HStack(spacing: 8) {
                    Text(lastCheckText)
                    if toolkit.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if toolkit.snapshot.count > 0 {
                Button {
                    toolkit.launchUpdate(scope: "all")
                } label: {
                    Label(UIStrings.updateEverything[loc.language], systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var headerTitle: String {
        toolkit.snapshot.count == 0
            ? UIStrings.everythingUpToDate[loc.language]
            : String(format: UIStrings.updatesWaitingFormat[loc.language], toolkit.snapshot.count)
    }

    private var lastCheckText: String {
        guard let date = toolkit.snapshot.lastCheck else {
            return UIStrings.neverChecked[loc.language]
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: loc.language.rawValue)
        formatter.unitsStyle = .full
        return String(
            format: UIStrings.lastCheckedFormat[loc.language],
            formatter.localizedString(for: date, relativeTo: Date())
        )
    }
}

private struct UpdateDetailRow: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(AppIconCache.self) private var icons
    @Environment(\.openURL) private var openURL

    let item: UpdateItem

    var body: some View {
        HStack(spacing: 12) {
            iconView

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))

                HStack(spacing: 6) {
                    Text(item.currentVersion)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.newVersion)
                        .foregroundStyle(.primary)
                }
                .font(.callout.monospacedDigit())
            }

            Spacer(minLength: 8)

            if let link = item.link {
                Button {
                    openURL(link)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help(link.absoluteString)
            }

            // Per-item actions, back from the old menu but somewhere they fit
            if canUpdateHere {
                Button(UIStrings.updateThis[loc.language]) {
                    toolkit.updateSingle(item)
                }
                .buttonStyle(.bordered)
                .disabled(toolkit.isUpdating)
            }

            Menu {
                if canUpdateHere {
                    Button(UIStrings.updateThis[loc.language]) {
                        toolkit.updateSingle(item)
                    }
                }
                if item.source == .sparkle {
                    Button(UIStrings.dryRun[loc.language]) {
                        toolkit.installApp(named: item.name, dryRun: true)
                    }
                }
                if let ignoreType {
                    Divider()
                    Button(UIStrings.ignoreThis[loc.language]) {
                        toolkit.ignore(type: ignoreType, id: ignoreIdentifier, name: item.name)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    /// App Store ghosts and GitHub-only releases cannot be installed from here.
    private var canUpdateHere: Bool {
        switch item.source {
        case .formula, .cask, .appStore:
            return true
        case .sparkle:
            return item.link?.pathExtension == "dmg" || item.link?.pathExtension == "zip"
        case .manual, .github:
            return false
        }
    }

    private var ignoreType: String? {
        switch item.source {
        case .formula: return "brew"
        case .cask: return "cask"
        case .appStore, .manual: return "mas"
        case .sparkle, .github: return "sparkle"
        }
    }

    private var ignoreIdentifier: String {
        switch item.source {
        case .appStore: return item.id.replacingOccurrences(of: "mas:", with: "")
        case .manual: return item.id.replacingOccurrences(of: "manual:", with: "")
        default: return item.name
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = icons.icon(forAppNamed: item.name) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 30, height: 30)
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: item.source.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
        }
    }
}
