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
            VStack(alignment: .leading, spacing: 16) {
                if !toolkit.snapshot.appGroups.isEmpty {
                    domainHeader(title: UIStrings.navInstalled[loc.language], symbol: "square.grid.2x2.fill")
                    ForEach(toolkit.snapshot.appGroups, id: \.source) { group in
                        subgroup(title: group.source.label[loc.language], symbol: group.source.symbol, items: group.items)
                    }
                }

                if !toolkit.snapshot.cliToolGroups.isEmpty {
                    domainHeader(title: UIStrings.navCLITools[loc.language], symbol: "terminal.fill")
                    ForEach(toolkit.snapshot.cliToolGroups, id: \.category) { group in
                        subgroup(title: group.category.label[loc.language], symbol: group.category.symbol, items: group.items)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        // Explicit bound so this ScrollView reliably gets real space: left
        // implicit, it was the most "flexible" view competing against the
        // fixed-height header/footer for room in a size-to-fit popover, and
        // SwiftUI squeezed it down to a sliver - one item, clipped mid-row -
        // instead of showing a proper scrollable list.
        .frame(maxHeight: 420)
    }

    /// Top tier: Installed Apps vs CLI Tools - the same two pages the sidebar
    /// links to, so a category/source subgroup below reads as "which section
    /// of the app would I find this in", not an unfamiliar new taxonomy.
    private func domainHeader(title: String, symbol: String) -> some View {
        Label(title.uppercased(), systemImage: symbol)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 14)
    }

    /// Second tier: install source for an app group, `CLIToolCategory` for a
    /// CLI tool group - whichever the caller passes in.
    private func subgroup(title: String, symbol: String, items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title.uppercased(), systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)

            ForEach(items) { item in
                UpdateRow(item: item)
            }
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

                // A real native NSMenu flyout, not more SwiftUI - system
                // chrome, hover highlighting and outside-click dismissal all
                // come for free that way, matching every other macOS menu.
                // It stays a quick glance/one-tap-update list; the full
                // per-row progress bars and queueing live in the Updates
                // page, one tap away via its own "Open Full App" row.
                MenuActionButton(
                    title: String(format: UIStrings.pendingUpdatesFormat[loc.language], toolkit.snapshot.count),
                    symbol: "list.bullet.rectangle",
                    showsDisclosure: true
                ) {
                    showPendingUpdatesMenu()
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

    // MARK: - Pending Updates flyout (native NSMenu)

    /// Pops a real `NSMenu` at the mouse location - system-drawn chrome,
    /// hover highlighting and outside-click dismissal, the same as any other
    /// macOS menu, rather than another SwiftUI popover pretending to be one.
    private func showPendingUpdatesMenu() {
        buildPendingUpdatesMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func buildPendingUpdatesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let appGroups = toolkit.snapshot.appGroups
        let cliGroups = toolkit.snapshot.cliToolGroups

        if !appGroups.isEmpty {
            addSectionHeader(UIStrings.navInstalled[loc.language], to: menu)
            for group in appGroups {
                for item in group.items {
                    menu.addItem(menuItem(for: item))
                }
            }
        }

        if !cliGroups.isEmpty {
            if !appGroups.isEmpty { menu.addItem(.separator()) }
            addSectionHeader(UIStrings.navCLITools[loc.language], to: menu)
            for group in cliGroups {
                for item in group.items {
                    menu.addItem(menuItem(for: item))
                }
            }
        }

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: UIStrings.openFullApp[loc.language], symbol: "macwindow") {
            navigation.show(.updates)
            openWindow(id: "guide")
            NSApp.activate(ignoringOtherApps: true)
        })

        return menu
    }

    private func addSectionHeader(_ title: String, to menu: NSMenu) {
        let header = NSMenuItem(title: title.uppercased(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
    }

    /// Tapping a row updates it directly where that is possible - the same
    /// action its own row's "Update" button performs on the Updates page,
    /// just one tap closer. Anything that cannot be installed from here
    /// (App Store ghosts, GitHub-only releases without a direct download)
    /// opens its page instead, or is shown disabled with nowhere to go.
    ///
    /// Always in a terminal window: this flyout has no row of its own to put
    /// a spinner or an Updated/Failed result on, so running it invisibly in
    /// the background would leave no way to tell it is even happening.
    private func menuItem(for item: UpdateItem) -> NSMenuItem {
        let title = "\(item.name)  \(item.currentVersion) → \(item.newVersion)"

        if canUpdateDirectly(item) {
            return ClosureMenuItem(title: title, symbol: item.source.symbol) {
                toolkit.updateSingle(item, forceTerminal: true)
            }
        }
        if let link = item.link {
            return ClosureMenuItem(title: title, symbol: item.source.symbol) {
                NSWorkspace.shared.open(link)
            }
        }

        let plain = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        plain.isEnabled = false
        plain.image = NSImage(systemSymbolName: item.source.symbol, accessibilityDescription: nil)
        return plain
    }

    private func canUpdateDirectly(_ item: UpdateItem) -> Bool {
        switch item.source {
        case .formula, .cask, .appStore: return true
        case .sparkle: return item.link?.pathExtension == "dmg" || item.link?.pathExtension == "zip"
        case .manual, .github: return false
        }
    }
}

/// `NSMenuItem` has no closure-based action, only target/action - this fills
/// that gap in a few lines instead of wiring up a separate target object.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() { handler() }
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
    /// Set for a row that opens another screen rather than acting directly -
    /// the ">" macOS uses for "there's more over here", e.g. System Settings.
    var showsDisclosure: Bool = false
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
                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
