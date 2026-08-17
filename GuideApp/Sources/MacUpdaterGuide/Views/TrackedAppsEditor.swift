import SwiftUI

/// Editor for `tracked_apps.conf`.
///
/// Replaces "open this file in TextEdit and get the pipe syntax right", which
/// is not something an application should ask of anyone. The file format is
/// untouched - the shell engine still reads exactly the same thing.
struct TrackedAppsEditor: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(InventoryStore.self) private var inventory
    @Environment(ToolkitController.self) private var toolkit

    @State private var entries: [ConfigEntry] = []
    @State private var selection: ConfigEntry.ID?
    @State private var isAdding = false

    var body: some View {
        SettingsPage(
            symbol: "list.bullet.rectangle",
            tint: .blue,
            title: UIStrings.navTracked[loc.language],
            subtitle: UIStrings.trackedIntro[loc.language]
        ) {
            Card {
                VStack(spacing: 0) {
                    if entries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(UIStrings.trackedEmpty[loc.language])
                                .font(.headline)
                            Text(UIStrings.trackedEmptyDetail[loc.language])
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            row(for: entry)
                        }
                    }
                }
            }

            HStack {
                Button {
                    isAdding = true
                } label: {
                    Label(UIStrings.addRule[loc.language], systemImage: "plus")
                }

                Button(role: .destructive) {
                    removeSelected()
                } label: {
                    Label(UIStrings.removeRule[loc.language], systemImage: "minus")
                }
                .disabled(selection == nil)

                Spacer()

                Text(UIStrings.trackedAutoNote[loc.language])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { reload() }
        .sheet(isPresented: $isAdding) {
            TrackedRuleSheet(installedApps: inventory.ruleCandidates) { name, method, identifier in
                entries.append(ConfigEntry(fields: [name, method.rawValue, identifier]))
                persist()
            }
            .environment(loc)
            .environment(inventory)
        }
    }

    private func row(for entry: ConfigEntry) -> some View {
        let index = entries.firstIndex { $0.id == entry.id } ?? 0
        let method = TrackingMethod(rawValue: entry[1]) ?? .skip

        return HStack(spacing: 12) {
            Image(systemName: method.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(entry[0])
                .font(.body.weight(.medium))
                .frame(minWidth: 130, alignment: .leading)

            Picker("", selection: Binding(
                get: { method },
                set: { entries[index][1] = $0.rawValue; persist() }
            )) {
                ForEach(TrackingMethod.allCases) { option in
                    Text(option.label[loc.language]).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 165)

            if method != .skip {
                TextField(
                    method.identifierPrompt[loc.language],
                    text: Binding(
                        get: { entry[2] },
                        set: { entries[index][2] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit { persist() }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(selection == entry.id ? Color.accentColor.opacity(0.12) : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = entry.id }
    }

    private func reload() {
        entries = PipeConfig.load(ToolkitPaths.trackedAppsFile, fieldCount: 3)
    }

    private func removeSelected() {
        guard let selection else { return }
        entries.removeAll { $0.id == selection }
        self.selection = nil
        persist()
    }

    private func persist() {
        PipeConfig.save(
            entries,
            to: ToolkitPaths.trackedAppsFile,
            header: ToolkitPaths.trackedAppsTemplate
        )
        Task { await inventory.reload() }
    }
}

/// Add-rule sheet. The application is picked from what is actually installed,
/// so a typo cannot create a rule that silently never matches.
private struct TrackedRuleSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let installedApps: [InstalledApp]
    let onAdd: (String, TrackingMethod, String) -> Void

    @State private var appName = ""
    @State private var method: TrackingMethod = .sparkle
    @State private var identifier = ""

    private var candidates: [InstalledApp] { installedApps }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(UIStrings.addRule[loc.language])
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Form {
                Picker(UIStrings.application[loc.language], selection: $appName) {
                    Text(UIStrings.choosePlaceholder[loc.language]).tag("")
                    ForEach(candidates) { app in
                        Text(app.name).tag(app.name)
                    }
                }

                Picker(UIStrings.method[loc.language], selection: $method) {
                    ForEach(TrackingMethod.allCases) { option in
                        Text(option.label[loc.language]).tag(option)
                    }
                }

                if method != .skip {
                    TextField(
                        method.identifierLabel[loc.language],
                        text: $identifier,
                        prompt: Text(method.identifierPrompt[loc.language])
                    )
                    .font(.callout.monospaced())
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(UIStrings.cancel[loc.language]) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(UIStrings.add[loc.language]) {
                    onAdd(appName, method, identifier)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appName.isEmpty || (method != .skip && identifier.isEmpty))
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}
