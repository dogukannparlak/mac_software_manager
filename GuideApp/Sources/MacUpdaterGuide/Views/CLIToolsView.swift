import SwiftUI

/// Every Homebrew formula on the Mac, grouped into categories - its own page
/// rather than a disclosure group buried under Installed Apps, since the
/// list (leaves plus every transitive dependency) is often bigger than the
/// application list itself. Below it, everything from outside Homebrew
/// (`OtherPackagesSection`), when Settings › Updates allows it.
struct CLIToolsView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(InventoryStore.self) private var inventory

    @State private var searchText = ""
    @State private var categoryFilter: CLIToolCategory?
    /// Only meaningful while `categoryFilter == .libraries` - selecting a
    /// different top-level category resets it, same as switching away from
    /// Libraries at all would make it meaningless.
    @State private var librarySubcategoryFilter: LibrarySubcategory?
    /// The "Beyond Homebrew" chip: hides the Homebrew categories.
    @State private var showOtherOnly = false
    @State private var otherSourcesEnabled = true

    private var tools: [InstalledTool] { inventory.tools }
    private var otherPackages: [OtherPackage] { inventory.otherPackages }

    /// The other sources have no categories, so a category filter hides them.
    private var filteredOthers: [OtherPackage] {
        guard categoryFilter == nil else { return [] }
        guard !searchText.isEmpty else { return otherPackages }
        return otherPackages.filter { package in
            package.name.localizedCaseInsensitiveContains(searchText)
                || package.source.label[loc.language].localizedCaseInsensitiveContains(searchText)
        }
    }
    private var isLoading: Bool { inventory.isLoading && inventory.tools.isEmpty }

    private var filteredTools: [InstalledTool] {
        guard !showOtherOnly else { return [] }
        return tools.filter { tool in
            if let categoryFilter, tool.category != categoryFilter { return false }
            if categoryFilter == .libraries, let librarySubcategoryFilter,
               tool.librarySubcategory != librarySubcategoryFilter { return false }
            guard !searchText.isEmpty else { return true }
            return tool.name.localizedCaseInsensitiveContains(searchText)
                || (tool.description ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var categoryCounts: [CLIToolCategory: Int] {
        Dictionary(grouping: tools, by: \.category).mapValues(\.count)
    }

    private var librarySubcategoryCounts: [LibrarySubcategory: Int] {
        Dictionary(grouping: tools.filter { $0.category == .libraries }, by: { $0.librarySubcategory ?? .core })
            .mapValues(\.count)
    }

    private func selectCategory(_ category: CLIToolCategory?) {
        categoryFilter = (categoryFilter == category) ? nil : category
        librarySubcategoryFilter = nil
        showOtherOnly = false
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
                    toolsList
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(UIStrings.navCLITools[loc.language])
        .searchable(text: $searchText, prompt: Text(UIStrings.searchCLITools[loc.language]))
        .task(id: toolkit.snapshot.lastCheck) {
            otherSourcesEnabled = ToolkitSettings().otherSourcesEnabled
            await inventory.load()
        }
        .toolbar {
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(symbol: "terminal.fill", size: 56, tint: .indigo)

            VStack(alignment: .leading, spacing: 4) {
                Text(UIStrings.navCLITools[loc.language])
                    .font(.system(.largeTitle).weight(.bold))

                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        guard !otherPackages.isEmpty else {
            return String(format: UIStrings.cliToolsSummaryFormat[loc.language], tools.count)
        }
        return String(format: UIStrings.otherSourcesSummaryFormat[loc.language], tools.count, otherPackages.count)
    }

    /// Nine categories with long Turkish labels routinely overflow the page
    /// width - squeezing them into a fixed-width row wraps each pill's text
    /// internally instead (a label breaking mid-word). A horizontal scroller
    /// lets every pill keep its natural, unbroken width; the row just scrolls
    /// past the visible edge instead of being crushed.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { filterChips }
            }

            if categoryFilter == .libraries {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { librarySubcategoryChips }
                }
            }
        }
    }

    @ViewBuilder
    private var filterChips: some View {
        FilterChip(
            title: UIStrings.filterAll[loc.language],
            count: tools.count,
            isSelected: categoryFilter == nil
        ) {
            categoryFilter = nil
            librarySubcategoryFilter = nil
            showOtherOnly = false
        }

        if !otherPackages.isEmpty {
            FilterChip(
                title: UIStrings.otherSourcesFilter[loc.language],
                count: otherPackages.count,
                isSelected: showOtherOnly,
                tint: .teal
            ) {
                showOtherOnly.toggle()
                categoryFilter = nil
                librarySubcategoryFilter = nil
            }
        }

        ForEach(CLIToolCategory.allCases.sorted { $0.sortRank < $1.sortRank }) { category in
            let count = categoryCounts[category] ?? 0
            if count > 0 {
                FilterChip(
                    title: category.label[loc.language],
                    count: count,
                    isSelected: categoryFilter == category
                ) {
                    selectCategory(category)
                }
            }
        }
    }

    /// Same chip pattern, one level down - only shown once "Libraries &
    /// Dependencies" is the active filter, since a subcategory only means
    /// anything relative to that bucket.
    @ViewBuilder
    private var librarySubcategoryChips: some View {
        FilterChip(
            title: UIStrings.filterAll[loc.language],
            count: categoryCounts[.libraries] ?? 0,
            isSelected: librarySubcategoryFilter == nil,
            tint: .secondary
        ) {
            librarySubcategoryFilter = nil
        }

        ForEach(LibrarySubcategory.allCases.sorted { $0.sortRank < $1.sortRank }) { subcategory in
            let count = librarySubcategoryCounts[subcategory] ?? 0
            if count > 0 {
                FilterChip(
                    title: subcategory.label[loc.language],
                    count: count,
                    isSelected: librarySubcategoryFilter == subcategory,
                    tint: .secondary
                ) {
                    librarySubcategoryFilter = (librarySubcategoryFilter == subcategory) ? nil : subcategory
                }
            }
        }
    }

    // MARK: - Lists

    /// The matching entry from the Homebrew outdated list, when this tool
    /// actually has an update pending - the same data the Updates page uses,
    /// so a pending CLI tool update shows the real old→new version instead
    /// of a guess.
    private func outdatedItem(for tool: InstalledTool) -> UpdateItem? {
        toolkit.snapshot.items.first { $0.source == .formula && $0.name == tool.name }
    }

    /// The `updateSingle` flow needs an `UpdateItem` regardless of whether
    /// this tool is actually outdated - "Update" in a tool's menu should
    /// work (as a safe, idempotent `brew upgrade`) even when nothing is
    /// pending. Falls back to same-version-to-same-version when there is no
    /// real pending update to report.
    private func updateItem(for tool: InstalledTool) -> UpdateItem {
        outdatedItem(for: tool) ?? UpdateItem(
            id: "brew:\(tool.name)",
            source: .formula,
            name: tool.name,
            currentVersion: tool.version,
            newVersion: tool.version,
            link: URL(string: "https://formulae.brew.sh/formula/\(tool.name)")
        )
    }

    private var groupedTools: [(category: CLIToolCategory, tools: [InstalledTool])] {
        let grouped = Dictionary(grouping: filteredTools, by: \.category)
        return CLIToolCategory.allCases
            .compactMap { category -> (CLIToolCategory, [InstalledTool])? in
                guard let items = grouped[category], !items.isEmpty else { return nil }
                return (category, items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
            .sorted { $0.category.sortRank < $1.category.sortRank }
    }

    /// `.libraries` is by far the biggest bucket on most machines (a build
    /// toolchain drags in dozens of small C libraries), so unlike every
    /// other category it gets a second level of grouping instead of one long
    /// flat card.
    private func librarySubgroups(_ tools: [InstalledTool]) -> [(subcategory: LibrarySubcategory, tools: [InstalledTool])] {
        let grouped = Dictionary(grouping: tools, by: { $0.librarySubcategory ?? .core })
        return LibrarySubcategory.allCases
            .compactMap { subcategory -> (LibrarySubcategory, [InstalledTool])? in
                guard let items = grouped[subcategory], !items.isEmpty else { return nil }
                return (subcategory, items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
            .sorted { $0.subcategory.sortRank < $1.subcategory.sortRank }
    }

    private var toolsList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if filteredTools.isEmpty && filteredOthers.isEmpty {
                Card {
                    Text(UIStrings.noMatches[loc.language])
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(groupedTools, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: group.category.symbol)
                                .foregroundStyle(.secondary)
                            Text(group.category.label[loc.language])
                                .font(.subheadline.weight(.semibold))
                            Text("\(group.tools.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if group.category == .libraries {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(librarySubgroups(group.tools), id: \.subcategory) { sub in
                                    librarySubgroupCard(sub)
                                }
                            }
                        } else {
                            toolsCard(group.tools)
                        }
                    }
                }

                if !filteredOthers.isEmpty {
                    OtherPackagesSection(packages: filteredOthers)
                }
            }

            if !otherSourcesEnabled && categoryFilter == nil {
                Card {
                    Label(UIStrings.otherSourcesOff[loc.language], systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .transition(.opacity)
    }

    private func librarySubgroupCard(_ sub: (subcategory: LibrarySubcategory, tools: [InstalledTool])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(sub.subcategory.label[loc.language])
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(sub.tools.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 4)

            toolsCard(sub.tools)
        }
    }

    private func toolsCard(_ tools: [InstalledTool]) -> some View {
        Card {
            VStack(spacing: 0) {
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    if index > 0 { Divider().padding(.vertical, 2) }
                    CLIToolRow(
                        tool: tool,
                        updateItem: updateItem(for: tool),
                        isOutdated: outdatedItem(for: tool) != nil
                    )
                }
            }
        }
    }
}

/// One CLI tool row: name, optional description, version (or the pending
/// update when one exists), and the same Update / Pin actions the rest of
/// the app uses - a click runs `toolkit.updateSingle`, the exact path the
/// Updates page uses for a Homebrew formula, with no extra confirmation and
/// no auto-answered prompts. Any interactive step Homebrew itself needs
/// (a sudo password, a cask license prompt) is only ever handled inside the
/// real terminal window that flow already opens when "Run updates in
/// Terminal" is on.
private struct CLIToolRow: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit

    let tool: InstalledTool
    let updateItem: UpdateItem
    let isOutdated: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.body.monospaced())

                    if tool.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(UIStrings.pinned[loc.language])
                    }
                }

                if let description = tool.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if isOutdated {
                HStack(spacing: 6) {
                    Text(updateItem.currentVersion)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(updateItem.newVersion)
                        .foregroundStyle(.primary)
                }
                .font(.callout.monospacedDigit())
                .lineLimit(1)

                Button(UIStrings.updateThis[loc.language]) {
                    toolkit.updateSingle(updateItem)
                }
                .buttonStyle(.bordered)
                .disabled(toolkit.isUpdating)
            } else {
                Text(tool.version)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button(UIStrings.updateThis[loc.language]) {
                toolkit.updateSingle(updateItem)
            }
            .disabled(toolkit.isUpdating)

            Divider()

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
