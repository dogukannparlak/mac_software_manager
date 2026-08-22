import SwiftUI

/// Produces UI states by writing the files the app reads, so every screen can
/// be seen without brew, mas or the network doing anything.
///
/// The whole panel rests on one rule, enforced by `DebugStateStore`: a real
/// file is backed up beside itself before anything is written over it, and
/// "Restore all real state" puts every one of them back. The warning strip at
/// the top of the page stays up for as long as anything is injected, because
/// the failure mode this page has to avoid is somebody debugging the fake
/// state for an hour without knowing it is fake.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugSectionState: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugStateStore.self) private var store
    @Environment(DebugLog.self) private var log

    @State private var counts = DebugFixtures.SnapshotCounts.handful
    @State private var style = DebugFixtures.NameStyle.plain

    var body: some View {
        restorePanel
        snapshotPanel
        DebugStateProgressPanel()
        DebugStateResultsPanel()
        DebugStateNotificationsPanel()
        DebugStateFailurePanel()

        Card {
            DebugConsoleView(height: 200)
        }
    }

    // MARK: - Restore

    /// Always here, injected or not.
    ///
    /// A restore button that only appears once something has gone wrong is a
    /// button nobody can find in the moment they need it, and pressing this
    /// one with nothing injected is a no-op by construction - it works off
    /// what is on disk, so there is no reason to hide it.
    private var restorePanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        store.restoreAll(log: log)
                        toolkit.reload()
                    } label: {
                        Label("Restore all real state", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        store.rescan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)

                    Text(store.isInjecting
                         ? "\(store.injectedPaths.count) file(s) injected"
                         : "nothing injected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(store.isInjecting ? Color.orange : Color.secondary)

                    Spacer(minLength: 0)
                }

                Text("""
                Every injection copies the real file to <name>.debugbackup first, or drops a \
                <name>.debugbackup.none marker where there was no file. Restore works off those \
                sidecars alone, so it still works after a relaunch or a crash.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !store.injectedPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(store.injectedPaths, id: \.self) { path in
                            Text(path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Updates snapshot

    private var snapshotPanel: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Updates snapshot")
                    .font(.headline)

                Text("""
                Writes brew_outdated, mas_outdated, manual_updates and app_updates, then calls \
                toolkit.reload(). Drives the Updates page, the sidebar badge, the menu bar icon \
                and its count - all four read the same snapshot.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                countFields
                stylePicker
                presets

                HStack(spacing: 10) {
                    Button {
                        injectSnapshot()
                    } label: {
                        Label("Inject snapshot", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("\(counts.total) item(s) → currently showing \(toolkit.snapshot.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var countFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            countField("Casks (brew_outdated, src=cask)", value: $counts.casks)
            countField("Formulae (brew_outdated, src=brew)", value: $counts.formulae)
            countField("App Store (mas_outdated)", value: $counts.appStore)
            countField("Apple apps mas misses (manual_updates)", value: $counts.manual)
            countField("Sparkle / GitHub (app_updates)", value: $counts.selfUpdating)
        }
    }

    private func countField(_ title: String, value: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .frame(width: 300, alignment: .leading)

            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)

            Stepper("", value: value, in: 0...500)
                .labelsHidden()

            Spacer(minLength: 0)
        }
    }

    private var stylePicker: some View {
        Picker("Names", selection: $style) {
            ForEach(DebugFixtures.NameStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        }
        .pickerStyle(.segmented)
    }

    private var presets: some View {
        HStack(spacing: 8) {
            Button("0 updates") {
                counts = .empty
                style = .plain
            }
            Button("A handful") {
                counts = .handful
                style = .plain
            }
            Button("250 mixed") {
                counts = .many
                style = .plain
            }
            Button("Very long name") {
                counts = DebugFixtures.SnapshotCounts(casks: 2, formulae: 1, appStore: 1, manual: 0, selfUpdating: 1)
                style = .veryLong
            }
            Button("Emoji + Turkish") {
                counts = DebugFixtures.SnapshotCounts(casks: 2, formulae: 1, appStore: 2, manual: 1, selfUpdating: 0)
                style = .unicode
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    /// One write per cache entry, including the ones the counts leave at
    /// zero: an entry left holding real data would put real pending updates
    /// on screen alongside the fake ones, and the number in the menu bar
    /// would then be neither.
    private func injectSnapshot() {
        store.write(
            DebugFixtures.brewOutdated(casks: counts.casks, formulae: counts.formulae, style: style),
            to: ToolkitPaths.cacheFile("brew_outdated"),
            log: log
        )
        store.write(
            DebugFixtures.masOutdated(count: counts.appStore, style: style),
            to: ToolkitPaths.cacheFile("mas_outdated"),
            log: log
        )
        store.write(
            DebugFixtures.manualUpdates(count: counts.manual, style: style),
            to: ToolkitPaths.cacheFile("manual_updates"),
            log: log
        )
        store.write(
            DebugFixtures.appUpdates(count: counts.selfUpdating, style: style),
            to: ToolkitPaths.cacheFile("app_updates"),
            log: log
        )
        toolkit.reload()
        log.note("Snapshot now reports \(toolkit.snapshot.count) pending item(s).")
    }
}

/// The strip that says the app is not showing the truth right now.
///
/// Drawn from the top of the Debug page rather than from inside the State
/// panel, so it is still there after switching to another section - the
/// state stays injected either way, and the warning has to outlive the panel
/// that caused it.
struct DebugInjectionBanner: View {
    @Environment(DebugStateStore.self) private var store
    @Environment(DebugLog.self) private var log

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text("Fake state is injected")
                    .font(.body.weight(.medium))

                Text("""
                \(store.injectedPaths.count) file(s) are holding debug fixtures. Everything this app \
                shows right now - counts, banners, notifications - is made up. The real files are \
                backed up beside them.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = store.lastError {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 0)

            Button {
                store.restoreAll(log: log)
            } label: {
                Label("Restore all real state", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.yellow.opacity(0.16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.45), lineWidth: 1)
        }
    }
}
