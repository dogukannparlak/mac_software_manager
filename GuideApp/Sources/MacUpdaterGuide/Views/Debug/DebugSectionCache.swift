import AppKit
import SwiftUI

/// Every file the engine writes, how old it is, and what is actually in it.
///
/// Three directories rather than one, because the app treats them as three
/// different things and so should this: `cache/` is TTL-refreshed state,
/// `notifications/` and `results/` are one-shot events consumed and deleted
/// as they are read (ToolkitPaths, and CACHE_FORMAT.md). A record still
/// sitting in either of the latter two is either in flight or was never
/// consumed, which is worth being able to see.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugSectionCache: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugLog.self) private var log

    @State private var runner = DebugProcessRunner()
    @State private var listings: [DebugCacheStore: [DebugCacheEntry]] = [:]
    @State private var expanded: Set<String> = []
    @State private var previews: [String: String] = [:]
    @State private var pendingWipe: DebugCacheStore?

    var body: some View {
        intro

        ForEach(DebugCacheStore.allCases) { store in
            storeCard(store)
        }

        Card {
            DebugConsoleView(height: 200)
        }
        .task { reloadAll() }
        .onChange(of: runner.isRunning) {
            // A refresh rewrites the very files this table is describing, so
            // the listing is only correct once the engine has exited.
            if !runner.isRunning { reloadAll() }
        }
        .confirmationDialog(
            pendingWipe?.wipeTitle ?? "",
            isPresented: Binding(get: { pendingWipe != nil }, set: { if !$0 { pendingWipe = nil } }),
            presenting: pendingWipe
        ) { store in
            Button(store.wipeConfirmLabel, role: .destructive) { wipe(store) }
            Button("Cancel", role: .cancel) { pendingWipe = nil }
        } message: { store in
            Text(store.wipeMessage)
        }
    }

    private var intro: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Files on disk")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button {
                        reloadAll()
                    } label: {
                        Label("Reload listing", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }

                Text("""
                Fresh/stale is the engine's own answer: the TTLs come from CACHE_TTL_* in \
                lib/cache.sh, so a stale row here is one refresh_cache auto would rebuild. \
                Click a row to see its raw contents.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - One directory

    private func storeCard(_ store: DebugCacheStore) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                storeHeader(store)

                let entries = listings[store] ?? []
                if entries.isEmpty {
                    Text("Empty.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    columnHeadings
                    ForEach(entries) { entry in
                        Divider().padding(.vertical, 1)
                        row(entry, in: store)
                    }
                }
            }
        }
    }

    private func storeHeader(_ store: DebugCacheStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(store.title)
                    .font(.headline)

                Text("\((listings[store] ?? []).count) files")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: store.directory.path(percentEncoded: false)
                    )
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .controlSize(.small)

                Button(role: .destructive) {
                    pendingWipe = store
                } label: {
                    Label(store.wipeButtonLabel, systemImage: "trash")
                }
                .controlSize(.small)
                .disabled((listings[store] ?? []).isEmpty)
            }

            Text(store.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: 10) {
            Text("Name").frame(width: 170, alignment: .leading)
            Text("Size").frame(width: 66, alignment: .trailing)
            Text("Modified").frame(width: 150, alignment: .leading)
            Text("Age").frame(width: 62, alignment: .trailing)
            Text("TTL").frame(width: 42, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func row(_ entry: DebugCacheEntry, in store: DebugCacheStore) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    toggle(entry)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded.contains(entry.id) ? 90 : 0))
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(width: 170, alignment: .leading)
                }
                .buttonStyle(.plain)

                Text(entry.sizeText).frame(width: 66, alignment: .trailing)
                Text(entry.modifiedText).frame(width: 150, alignment: .leading)
                Text(entry.ageText).frame(width: 62, alignment: .trailing)
                Text(entry.ttlText).frame(width: 42, alignment: .trailing)

                badges(entry)

                Spacer(minLength: 4)
                rowActions(entry, in: store)
            }
            .font(.caption.monospaced())

            if expanded.contains(entry.id) {
                preview(entry)
            }
        }
    }

    private func badges(_ entry: DebugCacheEntry) -> some View {
        HStack(spacing: 5) {
            Text(entry.freshness.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(tint(for: entry.freshness)))

            // Only for the formats that carry a marker. An absent badge is
            // not a fault: most of cache/ is documented as unversioned.
            if let version = entry.formatVersion {
                Text(version)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
    }

    private func tint(for freshness: DebugCacheEntry.Freshness) -> Color {
        switch freshness {
        case .fresh: return .green
        case .stale: return .orange
        case .untimed: return .gray
        }
    }

    private func rowActions(_ entry: DebugCacheEntry, in store: DebugCacheStore) -> some View {
        HStack(spacing: 6) {
            Button {
                refresh(entry)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!entry.isRefreshable || runner.isRunning || toolkit.scriptURL == nil)
            .help(entry.isRefreshable
                  ? "Delete this entry and run refresh_cache auto, which rebuilds whichever tier it belongs to."
                  : "Not a tiered cache entry - nothing rebuilds it on a refresh.")

            Button {
                delete(entry, in: store)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete this file")
        }
    }

    private func preview(_ entry: DebugCacheEntry) -> some View {
        ScrollView {
            Text(previews[entry.id] ?? "")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 220)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
        .padding(.leading, 20)
        .padding(.bottom, 4)
    }

    // MARK: - Actions

    private func reloadAll() {
        for store in DebugCacheStore.allCases {
            listings[store] = DebugCacheEntry.load(from: store.directory)
        }
        // Anything still open keeps showing what is on disk now, not what
        // was there when it was opened.
        for id in expanded {
            if let entry = listings.values.flatMap({ $0 }).first(where: { $0.id == id }) {
                previews[id] = Self.readPreview(entry)
            }
        }
    }

    private func toggle(_ entry: DebugCacheEntry) {
        if expanded.contains(entry.id) {
            expanded.remove(entry.id)
            previews[entry.id] = nil
        } else {
            expanded.insert(entry.id)
            previews[entry.id] = Self.readPreview(entry)
        }
    }

    /// The engine has no "refresh one entry" verb - `refresh_cache` takes
    /// only `force` or `auto`. Deleting the file first is what turns `auto`
    /// into exactly that: `cache_stale_tiers` sees a missing entry as stale
    /// and rebuilds its tier, leaving every other tier alone. `force` would
    /// rebuild all four.
    private func refresh(_ entry: DebugCacheEntry) {
        guard let script = toolkit.scriptURL else {
            log.note("No engine script found - see the Environment panel.")
            return
        }
        remove(entry)
        log.note("Deleted \(entry.name); running refresh_cache auto to rebuild its tier.")
        runner.run(
            executable: URL(filePath: "/bin/zsh"),
            arguments: [script.path(percentEncoded: false), "refresh_cache", "auto"],
            log: log
        )
    }

    private func delete(_ entry: DebugCacheEntry, in store: DebugCacheStore) {
        remove(entry)
        log.note("Deleted \(store.rawValue)/\(entry.name)")
        reloadAll()
    }

    private func remove(_ entry: DebugCacheEntry) {
        try? FileManager.default.removeItem(at: entry.url)
        expanded.remove(entry.id)
        previews[entry.id] = nil
    }

    /// Empties the directory but keeps it.
    ///
    /// Same rule `AdvancedSettingsPage.clearCache` follows: removing the
    /// directory itself leaves the app with nothing to read and the engine
    /// with nowhere to write until something recreates it.
    private func wipe(_ store: DebugCacheStore) {
        pendingWipe = nil
        let manager = FileManager.default
        let path = store.directory.path(percentEncoded: false)

        if let names = try? manager.contentsOfDirectory(atPath: path) {
            for name in names {
                try? manager.removeItem(at: store.directory.appending(path: name))
            }
        } else {
            try? manager.createDirectory(at: store.directory, withIntermediateDirectories: true)
        }

        log.note("Emptied \(path)")
        expanded.removeAll()
        previews.removeAll()
        reloadAll()
        toolkit.reload()
    }

    /// Capped, because a cache entry is not always small - `brew_formulae_desc`
    /// runs to hundreds of kilobytes, and putting all of it into one `Text`
    /// hangs the window for as long as it takes to lay out.
    private static let previewLimit = 64 * 1024

    private static func readPreview(_ entry: DebugCacheEntry) -> String {
        guard let text = try? String(contentsOf: entry.url, encoding: .utf8) else {
            return "(not readable as UTF-8)"
        }
        guard text.count > previewLimit else { return text.isEmpty ? "(empty file)" : text }
        return String(text.prefix(previewLimit)) + "\n[... truncated at \(previewLimit) characters ...]"
    }
}

/// The three directories the engine writes into, and what emptying one means.
enum DebugCacheStore: String, CaseIterable, Identifiable, Hashable {
    case cache
    case notifications
    case results

    var id: String { rawValue }

    var directory: URL {
        switch self {
        case .cache: return ToolkitPaths.cacheDirectory
        case .notifications: return ToolkitPaths.notificationsDirectory
        case .results: return ToolkitPaths.resultsDirectory
        }
    }

    var title: String {
        switch self {
        case .cache: return "cache/"
        case .notifications: return "notifications/"
        case .results: return "results/"
        }
    }

    var subtitle: String {
        switch self {
        case .cache:
            return "TTL-refreshed state. The app reads these; the engine rebuilds a whole tier at a time."
        case .notifications:
            return """
            One file per notification the engine wants shown. NotificationBridge consumes and \
            deletes them as it reads them, so anything here has not been delivered yet.
            """
        case .results:
            return """
            One file per finished single-item run. A run consumes only its own record; \
            the rest are pruned by age in the shell.
            """
        }
    }

    var wipeButtonLabel: String {
        switch self {
        case .cache: return "Delete whole cache"
        case .notifications, .results: return "Delete all"
        }
    }

    var wipeTitle: String {
        switch self {
        case .cache: return "Delete the whole cache?"
        case .notifications: return "Delete every pending notification?"
        case .results: return "Delete every run result?"
        }
    }

    var wipeMessage: String {
        switch self {
        case .cache:
            return """
            Every file in cache/ is removed and the directory kept. The app will show nothing \
            pending until a refresh rebuilds it, which takes a brew and mas round trip. \
            Nothing is uninstalled.
            """
        case .notifications:
            return """
            Every queued notification is dropped without being shown. These are one-shot \
            events - nothing regenerates them.
            """
        case .results:
            return """
            Every run result is dropped. A row still waiting on one falls back to re-reading \
            the outdated list to guess its outcome, which is exactly what the result records \
            exist to avoid.
            """
        }
    }

    var wipeConfirmLabel: String {
        switch self {
        case .cache: return "Delete cache"
        case .notifications: return "Delete notifications"
        case .results: return "Delete results"
        }
    }
}
