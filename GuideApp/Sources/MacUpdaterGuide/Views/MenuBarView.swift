import SwiftUI
import AppKit

/// The menu bar panel.
///
/// Deliberately read-only: it answers "what is waiting for me?" and offers the
/// two actions that belong to a glance - update now, or refresh the list.
/// Everything configurable lives in Settings, because working through nested
/// menu bar submenus to change a preference is miserable.
struct MenuBarView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(NavigationStore.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // While a run is in flight, say which package it is on. This is the
            // one thing the terminal window cannot tell you at a glance.
            if let progress = toolkit.progress, progress.state != .done || toolkit.isUpdating {
                ProgressBanner(progress: progress, compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }

            Divider()

            if !toolkit.isToolkitInstalled {
                notInstalled
            } else if toolkit.snapshot.items.isEmpty {
                emptyState
            } else {
                updateList
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .frame(maxHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(symbol: headerSymbol, size: 30, tint: headerTint)

            VStack(alignment: .leading, spacing: 1) {
                Text(headerTitle)
                    .font(.headline)

                Text(lastCheckText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if toolkit.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var headerSymbol: String {
        toolkit.snapshot.count > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill"
    }

    private var headerTint: Color {
        toolkit.snapshot.count > 0 ? .orange : .green
    }

    private var headerTitle: String {
        let count = toolkit.snapshot.count
        if count == 0 {
            return UIStrings.everythingUpToDate[loc.language]
        }
        return String(
            format: UIStrings.updatesWaitingFormat[loc.language],
            count
        )
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

    // MARK: - States

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(UIStrings.toolkitNotFound[loc.language], systemImage: "questionmark.folder")
                .font(.callout.weight(.medium))

            Text(UIStrings.toolkitNotFoundDetail[loc.language])
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Text(UIStrings.nothingPending[loc.language])
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var updateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(toolkit.snapshot.groups, id: \.source.groupOrder) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.source.groupTitle[loc.language].uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)

                        ForEach(group.items) { item in
                            UpdateRow(item: item)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if toolkit.snapshot.count > 0 {
                MenuActionButton(
                    title: UIStrings.updateEverything[loc.language],
                    symbol: "arrow.triangle.2.circlepath",
                    isProminent: true
                ) {
                    toolkit.launchUpdate(scope: "all")
                }
            }

            MenuActionButton(
                title: UIStrings.refreshNow[loc.language],
                symbol: "arrow.clockwise"
            ) {
                toolkit.refresh(force: true)
            }

            MenuActionButton(
                title: UIStrings.openGuide[loc.language],
                symbol: "book"
            ) {
                // In menu-bar-only mode there is no Dock icon to click, so the
                // window has to be pulled forward explicitly.
                openWindow(id: "guide")
                NSApp.activate(ignoringOtherApps: true)
            }

            MenuActionButton(
                title: UIStrings.settings[loc.language],
                symbol: "gearshape"
            ) {
                navigation.show(.settings(.general))
                openWindow(id: "guide")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()
                .padding(.vertical, 4)

            MenuActionButton(
                title: UIStrings.quit[loc.language],
                symbol: "power"
            ) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

/// One pending update. Selecting it opens the publisher's page - the menu
/// itself never installs anything.
private struct UpdateRow: View {
    @Environment(\.openURL) private var openURL

    let item: UpdateItem

    @State private var isHovering = false

    var body: some View {
        Button {
            if let link = item.link { openURL(link) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.source.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("\(item.currentVersion)  →  \(item.newVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if item.link != nil, isHovering {
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
        .help(item.link?.absoluteString ?? item.name)
    }
}

/// Menu-style row button, matching the look of macOS menu items.
private struct MenuActionButton: View {
    let title: String
    let symbol: String
    var isProminent: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                Text(title)
                    .fontWeight(isProminent ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            }
            .foregroundStyle(isProminent && isHovering ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isHovering {
            return isProminent ? Color.accentColor : Color.primary.opacity(0.08)
        }
        return isProminent ? Color.accentColor.opacity(0.12) : .clear
    }
}
