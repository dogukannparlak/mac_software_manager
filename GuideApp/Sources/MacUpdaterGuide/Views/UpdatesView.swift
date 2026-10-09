import AppKit
import SwiftUI

/// The two tabs the Updates page switches between - same split as the
/// sidebar's Installed Apps / CLI Tools pages.
private enum UpdateDomain: Hashable {
    case apps
    case cliTools
}

/// Everything waiting to be updated, in one place - the same data the menu bar
/// shows, with room to actually read it.
struct UpdatesView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(AppIconCache.self) private var icons
    @Environment(\.openURL) private var openURL
    @Environment(InventoryStore.self) private var inventory

    @State private var warnings: [ConfigWarning] = []
    @State private var domain: UpdateDomain = .apps
    @State private var appSourceFilter: InstallSource?
    @State private var cliCategoryFilter: CLIToolCategory?
    @State private var showCancelConfirmation = false

    /// `snapshot.items` plus anything still showing a transient per-row
    /// result. A successful single-item update drops the item from the real
    /// outdated list right away - this keeps its row rendering (with its
    /// "Updated" badge) for the few seconds that badge is still up, the same
    /// way the App Store lets a just-updated app linger before it moves on.
    /// The header's own count/title deliberately read `toolkit.snapshot`
    /// directly instead, so "N pending" drops the moment it's actually true.
    private var displaySnapshot: UpdateSnapshot {
        var display = toolkit.snapshot
        for (id, item) in toolkit.recentItemsByID where !display.items.contains(where: { $0.id == id }) {
            display.items.append(item)
        }
        return display
    }

    /// Pending updates from outside Homebrew and the App Store (npm, pipx,
    /// uv, Cargo, self-updating tools). Not part of `UpdateSnapshot`: they
    /// update one at a time, in a terminal, through their own managers - so
    /// they get their own section below, with the same rows the CLI Tools
    /// page shows.
    private var otherUpdates: [OtherPackage] { inventory.otherPackages.filter(\.isOutdated) }

    /// Everything waiting, both kinds - what the title and the icon count.
    private var totalPending: Int { toolkit.snapshot.count + otherUpdates.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let progress = toolkit.progress, progress.state != .done || toolkit.isUpdating {
                    ProgressBanner(
                        progress: progress,
                        onCancel: toolkit.canCancelCurrentRun ? { showCancelConfirmation = true } : nil
                    )
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

                if displaySnapshot.items.isEmpty && otherUpdates.isEmpty {
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
                } else if !displaySnapshot.items.isEmpty {
                    // Installed Apps vs CLI Tools as two switchable tabs -
                    // the same two pages the sidebar links to - each with its
                    // own filter-chip bar (install source for apps,
                    // CLIToolCategory for CLI tools), matching the filter
                    // bar those two pages already use.
                    domainSwitcher

                    switch domain {
                    case .apps:
                        appFilterBar
                        if filteredAppGroups.isEmpty {
                            Card {
                                Text(UIStrings.noMatches[loc.language])
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(filteredAppGroups, id: \.source) { group in
                                sourceGroup(title: group.source.label[loc.language], symbol: group.source.symbol, items: group.items)
                            }
                        }
                    case .cliTools:
                        cliFilterBar
                        if filteredCLIGroups.isEmpty {
                            Card {
                                Text(UIStrings.noMatches[loc.language])
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(filteredCLIGroups, id: \.category) { group in
                                sourceGroup(title: group.category.label[loc.language], symbol: group.category.symbol, items: group.items)
                            }
                        }
                    }
                }

                if !otherUpdates.isEmpty {
                    OtherPackagesSection(packages: otherUpdates)
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
        .confirmationDialog(
            UIStrings.cancelUpdateConfirmTitle[loc.language],
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button(UIStrings.cancelUpdateConfirmAction[loc.language], role: .destructive) {
                toolkit.cancelUpdate()
            }
            Button(UIStrings.cancelUpdateKeepGoing[loc.language], role: .cancel) { }
        } message: {
            Text(UIStrings.cancelUpdateConfirmMessage[loc.language])
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(
                symbol: totalPending > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill",
                size: 56,
                tint: totalPending > 0 ? .orange : .green
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

            if !toolkit.snapshot.isEmpty {
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
        totalPending == 0
            ? UIStrings.everythingUpToDate[loc.language]
            : String(format: UIStrings.updatesWaitingFormat[loc.language], totalPending)
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

    // MARK: - Domain tabs

    private var appItems: [UpdateItem] { displaySnapshot.items.filter { $0.source != .formula } }
    private var cliItems: [UpdateItem] { displaySnapshot.items.filter { $0.source == .formula } }

    private var appSourceCounts: [InstallSource: Int] {
        Dictionary(grouping: appItems, by: { $0.source.installSource ?? .manual }).mapValues(\.count)
    }

    private var cliCategoryCounts: [CLIToolCategory: Int] {
        Dictionary(grouping: cliItems, by: \.category).mapValues(\.count)
    }

    private var filteredAppGroups: [(source: InstallSource, items: [UpdateItem])] {
        guard let appSourceFilter else { return displaySnapshot.appGroups }
        return displaySnapshot.appGroups.filter { $0.source == appSourceFilter }
    }

    private var filteredCLIGroups: [(category: CLIToolCategory, items: [UpdateItem])] {
        guard let cliCategoryFilter else { return displaySnapshot.cliToolGroups }
        return displaySnapshot.cliToolGroups.filter { $0.category == cliCategoryFilter }
    }

    private var domainSwitcher: some View {
        Picker("", selection: $domain) {
            Text("\(UIStrings.navInstalled[loc.language]) (\(appItems.count))").tag(UpdateDomain.apps)
            Text("\(UIStrings.navCLITools[loc.language]) (\(cliItems.count))").tag(UpdateDomain.cliTools)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    private var appFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: UIStrings.filterAll[loc.language],
                    count: appItems.count,
                    isSelected: appSourceFilter == nil
                ) {
                    appSourceFilter = nil
                }

                ForEach(InstallSource.allCases.sorted { $0.sortRank < $1.sortRank }) { source in
                    let count = appSourceCounts[source] ?? 0
                    if count > 0 {
                        FilterChip(
                            title: source.label[loc.language],
                            count: count,
                            isSelected: appSourceFilter == source,
                            tint: source.tint
                        ) {
                            appSourceFilter = (appSourceFilter == source) ? nil : source
                        }
                    }
                }
            }
        }
    }

    private var cliFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: UIStrings.filterAll[loc.language],
                    count: cliItems.count,
                    isSelected: cliCategoryFilter == nil
                ) {
                    cliCategoryFilter = nil
                }

                ForEach(CLIToolCategory.allCases.sorted { $0.sortRank < $1.sortRank }) { category in
                    let count = cliCategoryCounts[category] ?? 0
                    if count > 0 {
                        FilterChip(
                            title: category.label[loc.language],
                            count: count,
                            isSelected: cliCategoryFilter == category
                        ) {
                            cliCategoryFilter = (cliCategoryFilter == category) ? nil : category
                        }
                    }
                }
            }
        }
    }

    /// Install source for an app group, `CLIToolCategory` for a CLI tool group.
    private func sourceGroup(title: String, symbol: String, items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))

            Card {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.vertical, 2) }
                        UpdateDetailRow(item: item)
                    }
                }
            }
        }
    }
}

private struct UpdateDetailRow: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(AppIconCache.self) private var icons
    @Environment(\.openURL) private var openURL

    let item: UpdateItem

    /// Up while this row's own cancel button is waiting on its confirmation -
    /// separate from the page-level one, which cancels the bulk run.
    @State private var showCancelConfirmation = false

    /// This row's own outcome, independent of whatever else the toolkit is
    /// doing - set only by pressing this row's own Update button, never by a
    /// bulk "Update Everything" run passing through this package.
    private var rowStatus: ToolkitController.ItemUpdateStatus? {
        toolkit.itemStatuses[item.id]
    }

    /// Why this row's own update failed - stderr from that run, kept for as
    /// long as the failed badge is up (`ToolkitController.itemFailureReasons`).
    private var failureReason: String? {
        toolkit.itemFailureReasons[item.id]?.text(for: loc.language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                    updateControl
                }

                Menu {
                    if canUpdateHere {
                        Button(UIStrings.updateThis[loc.language]) {
                            toolkit.updateSingle(item)
                        }
                        .disabled(blocksNewLaunch || rowStatus != nil)
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

            // Directly under this row, not the whole page - the App Store way
            // of showing "this one is the one currently installing". A
            // determinate fill with a percentage, not the bouncing
            // indeterminate animation - real for a cask's own download when
            // the shell watcher has one to report, simulated otherwise; see
            // `itemFractions`.
            if rowStatus == .updating, let fraction = toolkit.itemFractions[item.id] {
                HStack(spacing: 8) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.leading, 42)
            }

            // What went wrong, under the row it went wrong on. The badge
            // above only says "failed"; this is the sentence brew or mas
            // actually printed, which used to be thrown away with the
            // process outcome it arrived in.
            if rowStatus == .failed, let failureReason {
                Text(failureReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)
            }
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            UIStrings.cancelUpdateConfirmTitle[loc.language],
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button(UIStrings.cancelUpdateConfirmAction[loc.language], role: .destructive) {
                toolkit.cancelItemUpdate(item.id)
            }
            Button(UIStrings.cancelUpdateKeepGoing[loc.language], role: .cancel) { }
        } message: {
            Text(UIStrings.cancelUpdateConfirmMessage[loc.language])
        }
    }

    /// Update button while idle; a spinner while this row's own run is in
    /// flight; a transient "Updated" / "Update failed" once it lands.
    @ViewBuilder
    private var updateControl: some View {
        switch rowStatus {
        case .queued:
            HStack(spacing: 6) {
                Label(UIStrings.queuedRowStatus[loc.language], systemImage: "clock")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                cancelRowButton
            }
        case .updating:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 60)
                cancelRowButton
            }
        case .succeeded:
            Label(UIStrings.updatedRowStatus[loc.language], systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        case .failed:
            Label(UIStrings.updateFailedRowStatus[loc.language], systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .help(failureReason ?? UIStrings.updateFailedRowStatus[loc.language])
        case nil:
            Button(UIStrings.updateThis[loc.language]) {
                toolkit.updateSingle(item)
            }
            .buttonStyle(.bordered)
            .disabled(blocksNewLaunch)
        }
    }

    /// Stops this row's own run, so a single-item update that hangs is not a
    /// spinner the user can only get rid of by quitting the app. Only shown
    /// where there is genuinely something to stop (`canCancelItem`): a
    /// terminal-mode run is stopped in its own window, not from here.
    @ViewBuilder
    private var cancelRowButton: some View {
        if toolkit.canCancelItem(item.id) {
            Button {
                // Nothing has been started for a queued row yet, so there is
                // nothing to warn about - only a run already in flight can
                // leave a package half-installed.
                if rowStatus == .queued {
                    toolkit.cancelItemUpdate(item.id)
                } else {
                    showCancelConfirmation = true
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(UIStrings.cancelUpdate[loc.language])
        }
    }

    /// Headless updates run concurrently (Settings → General → "Aynı Anda
    /// Yapılabilecek Güncelleme Sayısı") - another row updating is never a
    /// reason to grey this one out, pressing it just queues it. Terminal
    /// mode stays single-flight (one visible window at a time), so it keeps
    /// the old behaviour of disabling every other row while it runs. Either
    /// way, a bulk "Update Everything" run still blocks new single-item
    /// launches - `updateSingle`/`installApp` queue them until it finishes.
    private var blocksNewLaunch: Bool {
        toolkit.preferences.runUpdatesInTerminal && toolkit.isUpdating
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
