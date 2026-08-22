import SwiftUI

/// The five hand-editable config files, parsed the way the app parses them.
///
/// Reset goes through `DebugStateStore`, so a template written over a file
/// somebody spent an evening filling in is still recoverable from the sidecar
/// next to it. These are the files with no engine to regenerate them, which
/// makes them the ones where losing a backup would actually cost something.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugFeatureConfigPanel: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugStateStore.self) private var store
    @Environment(DebugLog.self) private var log

    @State private var settings = ToolkitSettings()
    @State private var pendingReset: DebugConfigFile?
    @State private var reloadTick = 0

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Config files")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button("Reload all") { reload() }
                        .controlSize(.small)
                }

                ForEach(DebugConfigFile.allCases) { file in
                    Divider()
                    fileRow(file)
                }
            }
        }
        .task { reload() }
        .confirmationDialog(
            pendingReset.map { "Reset \($0.fileName) to its template?" } ?? "",
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            presenting: pendingReset
        ) { file in
            Button("Reset \(file.fileName)", role: .destructive) { reset(file) }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: { file in
            Text("""
            Everything in \(file.fileName) is replaced by defaults. The current file is copied to \
            \(file.fileName)\(DebugStateStore.backupSuffix) first, and "Restore all real state" puts \
            it back.
            """)
        }
    }

    private func fileRow(_ file: DebugConfigFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(file.fileName)
                    .font(.callout.monospaced().weight(.medium))
                    .frame(width: 190, alignment: .leading)

                Text(exists(file) ? "present" : "missing")
                    .font(.caption)
                    .foregroundStyle(exists(file) ? Color.secondary : Color.orange)

                Spacer(minLength: 8)

                Button("Open in editor") {
                    let opened = ToolkitPaths.openInTextEditor(file.url, template: file.template)
                    log.note("openInTextEditor(\(file.fileName)) → \(opened ? "opened" : "failed")")
                }
                Button("Add sample line") { addSample(file) }
                    .disabled(file.sampleLine == nil)
                Button("Reset to template", role: .destructive) { pendingReset = file }
            }
            .controlSize(.small)

            parsed(file)
        }
    }

    /// What the app's own parser makes of the file - not a re-read of the raw
    /// text. A row that looks right on disk and wrong here is the bug worth
    /// finding.
    @ViewBuilder
    private func parsed(_ file: DebugConfigFile) -> some View {
        let lines = parsedLines(file)
        if lines.isEmpty {
            Text("no entries")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.prefix(12).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if lines.count > 12 {
                    Text("… \(lines.count - 12) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func parsedLines(_ file: DebugConfigFile) -> [String] {
        _ = reloadTick
        switch file {
        case .settings:
            return [
                "PREFERRED_TERMINAL = \(settings.preferredTerminal.rawValue)",
                "MAS_ENABLED = \(settings.masEnabled)",
                "UPDATE_BRANCH = \(settings.channel.rawValue)",
                "AUTOSTART = \(settings.autostart)",
                "CLEANUP_ENABLED = \(settings.cleanupEnabled)",
                "AUTO_INSTALL_APPS = \(settings.autoInstallApps)",
                "CODEBERG_USERNAME = \(settings.codebergUsername.isEmpty ? "(unset)" : settings.codebergUsername)"
            ]
        case .ignored:
            return IgnoreList.load().entries.map { "\($0.type) | \($0.id) | \($0.name)" }
        case .tracked, .tokenMap, .appLinks:
            return PipeConfig.load(file.url, fieldCount: file.fieldCount)
                .map { $0.fields.joined(separator: " | ") }
        }
    }

    private func exists(_ file: DebugConfigFile) -> Bool {
        _ = reloadTick
        return FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false))
    }

    // MARK: - Actions

    private func reload() {
        settings.load()
        reloadTick += 1
        log.note("Re-read all five config files.")
    }

    private func addSample(_ file: DebugConfigFile) {
        guard let sample = file.sampleLine else { return }
        let existing = (try? String(contentsOf: file.url, encoding: .utf8)) ?? file.template ?? ""
        let separator = existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n"
        store.write(existing + separator + sample + "\n", to: file.url, log: log)
        reload()
        toolkit.reload()
    }

    private func reset(_ file: DebugConfigFile) {
        pendingReset = nil
        if let template = file.template {
            store.write(template, to: file.url, log: log)
        } else {
            // settings.conf: back up first, *then* let ToolkitSettings write
            // its own defaults out. The backup has to happen before the save,
            // not after, or the real file is gone before anything copied it.
            store.prepare(file.url, log: log)
            ToolkitSettings().save()
            log.note("Rewrote settings.conf from ToolkitSettings defaults")
        }
        reload()
        toolkit.reload()
    }
}

/// The five files, their templates and a plausible line for each.
///
/// The templates are the app's own (`ToolkitPaths.*Template`) wherever it has
/// one, so a reset produces exactly the file a fresh install would - not a
/// second, drifting idea of what the header should say.
enum DebugConfigFile: String, CaseIterable, Identifiable, Hashable {
    case settings
    case ignored
    case tracked
    case tokenMap
    case appLinks

    var id: String { rawValue }

    var url: URL {
        switch self {
        case .settings: return ToolkitPaths.settingsFile
        case .ignored: return ToolkitPaths.ignoredFile
        case .tracked: return ToolkitPaths.trackedAppsFile
        case .tokenMap: return ToolkitPaths.tokenMapFile
        case .appLinks: return ToolkitPaths.appLinksFile
        }
    }

    var fileName: String { url.lastPathComponent }

    var fieldCount: Int {
        switch self {
        case .settings: return 0
        case .ignored: return 3
        case .tracked: return 3
        case .tokenMap: return 2
        case .appLinks: return 3
        }
    }

    /// `nil` for `settings.conf`, which has no template constant: the file is
    /// regenerated wholesale by `ToolkitSettings.save()` from the type's own
    /// property defaults. Duplicating that format here would be a second,
    /// drifting idea of what the file should look like - so its reset takes a
    /// different path (see `reset(_:)`), and this property stays free of side
    /// effects. It has to be: it is read to build the "Open in editor"
    /// argument, and a template that wrote a file just by being read would
    /// destroy the real one before anything had backed it up.
    var template: String? {
        switch self {
        case .settings: return nil
        case .ignored: return "# type|id|name - one hidden entry per line.\n"
        case .tracked: return ToolkitPaths.trackedAppsTemplate
        case .tokenMap: return ToolkitPaths.tokenMapTemplate
        case .appLinks: return ToolkitPaths.appLinksTemplate
        }
    }

    /// A line that parses, so "add one and watch it appear" is a real test of
    /// the reader rather than of the writer.
    var sampleLine: String? {
        switch self {
        case .settings: return nil
        case .ignored: return "cask|debug-sample-app|Debug Sample App"
        case .tracked: return "Debug Sample App|github|dogukannparlak/mac_software_manager"
        case .tokenMap: return "Debug Sample App|debug-sample-app"
        case .appLinks: return "Debug Sample App|https://example.invalid|dogukannparlak/mac_software_manager"
        }
    }
}
