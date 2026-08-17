import SwiftUI

/// Editor for `app_token_map.conf` - the app name to Homebrew cask mapping.
///
/// Needed when a name cannot be derived: "lghub" is the cask "logitech-g-hub".
/// The migration wizard also appends here when you type a cask name by hand.
struct TokenMapEditor: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(InventoryStore.self) private var inventory

    @State private var entries: [ConfigEntry] = []
    @State private var selection: ConfigEntry.ID?
    @State private var isAdding = false

    var body: some View {
        SettingsPage(
            symbol: "arrow.left.arrow.right",
            tint: .orange,
            title: UIStrings.navTokenMap[loc.language],
            subtitle: UIStrings.tokenMapIntro[loc.language]
        ) {
            Card {
                VStack(spacing: 0) {
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(UIStrings.tokenMapEmpty[loc.language])
                                .font(.headline)
                            Text(UIStrings.tokenMapEmptyDetail[loc.language])
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.vertical, 2) }

                            HStack(spacing: 12) {
                                Text(entry[0])
                                    .font(.body.weight(.medium))
                                    .frame(minWidth: 160, alignment: .leading)

                                Image(systemName: "arrow.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)

                                TextField(
                                    "cask-token",
                                    text: Binding(
                                        get: { entry[1] },
                                        set: { entries[index][1] = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.callout.monospaced())
                                .onSubmit { persist() }

                                MappingStatus(
                                    token: entry[1],
                                    isKnown: inventory.isKnownCask(entry[1]),
                                    appliedTo: appliedApp(for: entry[0])
                                )
                            }
                            .padding(.vertical, 5)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selection == entry.id ? Color.accentColor.opacity(0.12) : .clear)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selection = entry.id }
                        }
                    }
                }
            }

            HStack {
                Button {
                    isAdding = true
                } label: {
                    Label(UIStrings.addMapping[loc.language], systemImage: "plus")
                }

                Button(role: .destructive) {
                    if let selection {
                        entries.removeAll { $0.id == selection }
                        self.selection = nil
                        persist()
                    }
                } label: {
                    Label(UIStrings.removeRule[loc.language], systemImage: "minus")
                }
                .disabled(selection == nil)

                Spacer()
            }
        }
        .task {
            entries = PipeConfig.load(ToolkitPaths.tokenMapFile, fieldCount: 2)
            }
        .sheet(isPresented: $isAdding) {
            MappingSheet(installedApps: inventory.apps) { name, token in
                entries.append(ConfigEntry(fields: [name, token]))
                persist()
            }
            .environment(loc)
            .environment(inventory)
        }
    }

    private func persist() {
        PipeConfig.save(
            entries,
            to: ToolkitPaths.tokenMapFile,
            header: ToolkitPaths.tokenMapTemplate
        )

        // Re-scan so Installed Apps reclassifies the app straight away instead
        // of showing the old source until the next launch.
        Task { await inventory.reload() }
    }

    /// The installed app this mapping ended up applying to, if any.
    private func appliedApp(for name: String) -> InstalledApp? {
        inventory.apps.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}

/// Says whether a mapping actually did anything: a token that is not installed
/// silently does nothing, which is exactly the kind of thing a text file could
/// never tell you.
private struct MappingStatus: View {
    @Environment(LocalizationStore.self) private var loc

    let token: String
    let isKnown: Bool
    let appliedTo: InstalledApp?

    var body: some View {
        Group {
            if token.isEmpty {
                EmptyView()
            } else if isKnown, appliedTo?.source == .homebrew {
                label("checkmark.circle.fill", .green, UIStrings.mappingApplied)
            } else if isKnown {
                label("checkmark.circle", .secondary, UIStrings.mappingValid)
            } else {
                label("exclamationmark.triangle.fill", .orange, UIStrings.mappingUnknownCask)
            }
        }
        .frame(width: 22)
    }

    private func label(_ symbol: String, _ tint: Color, _ help: Localized) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .help(help[loc.language])
    }
}

private struct MappingSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(InventoryStore.self) private var inventory
    @Environment(\.dismiss) private var dismiss

    let installedApps: [InstalledApp]
    let onAdd: (String, String) -> Void

    @State private var appName = ""
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(UIStrings.addMapping[loc.language])
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Form {
                Picker(UIStrings.application[loc.language], selection: $appName) {
                    Text(UIStrings.choosePlaceholder[loc.language]).tag("")
                    ForEach(installedApps) { app in
                        Text(app.name).tag(app.name)
                    }
                }

                TextField(
                    UIStrings.caskToken[loc.language],
                    text: $token,
                    prompt: Text("logitech-g-hub")
                )
                .font(.callout.monospaced())

                if !token.isEmpty {
                    if inventory.isKnownCask(token) {
                        Label(UIStrings.mappingValid[loc.language], systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label(UIStrings.mappingUnknownCask[loc.language], systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(UIStrings.cancel[loc.language]) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(UIStrings.add[loc.language]) {
                    onAdd(appName, token)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appName.isEmpty || token.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}

/// Shared chrome for the settings pages, so they match the Updates, Installed
/// and History pages instead of looking like a bolted-on preferences window.
struct SettingsPage<Content: View>: View {
    let symbol: String
    var tint: Color = .accentColor
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    IconTile(symbol: symbol, size: 52, tint: tint)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(.largeTitle).weight(.bold))

                        if let subtitle {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)

                content
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(title)
    }
}
