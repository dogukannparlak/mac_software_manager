import SwiftUI

/// Hide and unhide an entry by hand, and watch the file underneath change.
///
/// The two calls and the file are shown together on purpose: `ignore` and
/// `unignore` go through the engine (`ignore_app` / `unignore_app`), which
/// means the round trip can fail silently in a way neither the call nor the
/// snapshot alone would reveal. Reading `ignored_apps.conf` straight after is
/// the check.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugFeatureIgnorePanel: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugLog.self) private var log

    @State private var type = "cask"
    @State private var identifier = "debug-sample-app"
    @State private var displayName = "Debug Sample App"
    @State private var raw = ""

    /// The four the engine's own `ignore_app` switch accepts.
    private static let types = ["cask", "brew", "mas", "sparkle"]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ignore flow")
                    .font(.headline)

                HStack(spacing: 8) {
                    Picker("Type", selection: $type) {
                        ForEach(Self.types, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 150)

                    TextField("id", text: $identifier)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .frame(width: 200)

                    TextField("name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button("ignore()") {
                        log.note("toolkit.ignore(type: \"\(type)\", id: \"\(identifier)\", name: \"\(displayName)\")")
                        toolkit.ignore(type: type, id: identifier, name: displayName)
                        scheduleRefresh()
                    }
                    Button("unignore()") {
                        log.note("toolkit.unignore(type: \"\(type)\", id: \"\(identifier)\", name: \"\(displayName)\")")
                        toolkit.unignore(type: type, id: identifier, name: displayName)
                        scheduleRefresh()
                    }
                    Button("IgnoreList.remove() — app side only") {
                        IgnoreList.remove(type: type, id: identifier)
                        log.note("IgnoreList.remove() rewrote the file directly, without the engine")
                        refresh()
                    }
                    Button("Re-read file") { refresh() }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)

                fileView
            }
        }
        .task { refresh() }
    }

    private var fileView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ignored_apps.conf — \(IgnoreList.load().entries.count) entry/entries, \(toolkit.snapshot.count) pending after filtering")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(raw.isEmpty ? "(empty or missing)" : raw)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 110)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    /// The engine writes the file, so there is nothing to read the instant
    /// the call returns - the process has to run first. A short wait is
    /// honest here in a way polling would not be: this panel is for watching
    /// the round trip, and hiding its latency would hide the thing being
    /// tested.
    private func scheduleRefresh() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            refresh()
        }
    }

    private func refresh() {
        raw = (try? String(contentsOf: ToolkitPaths.ignoredFile, encoding: .utf8)) ?? ""
        toolkit.reload()
    }
}
