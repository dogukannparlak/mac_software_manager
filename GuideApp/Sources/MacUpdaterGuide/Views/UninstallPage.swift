import AppKit
import SwiftUI

/// Removing the toolkit without opening a terminal.
///
/// `uninstall.sh` has always been able to do this, but only by asking `[y/N]`
/// seven times in a shell - which is fine for whoever installed it from a
/// terminal and no use at all to someone who dragged the app out of a disk
/// image. The choosing happens here instead: tick the rows, press the button
/// once, and the script runs with those steps as flags and its questions off.
///
/// Two things the script deliberately cannot do are done here in Swift, and
/// both for the same reason - only the running app can make them stick:
///
/// * the login item, which is an `SMAppService` registration macOS ties to
///   this bundle, not a file on disk a script could delete;
/// * dropping the in-memory copy of the preferences, because a `defaults
///   delete` against a running app is undone the moment that app writes its
///   defaults back out on quit.
struct UninstallPage: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(OnboardingStore.self) private var onboarding
    @Environment(ToolkitController.self) private var toolkit

    /// What `--list` found. Empty until the first load finishes.
    @State private var items: [UninstallItem] = []
    @State private var selection: Set<UninstallStep> = []
    @State private var isLoading = true
    @State private var isRunning = false
    @State private var dryRun = false
    @State private var turnOffLoginItem = LaunchAtLogin.isEnabled
    @State private var results: [UninstallResult] = []
    @State private var failure: String?
    @State private var confirming = false
    /// Set once the app bundle is gone: everything on screen is still true,
    /// but nothing new can be started and the window is about to close.
    @State private var isQuitting = false

    private var script: URL? { UninstallPlan.scriptURL }
    private var appBundle: URL { Bundle.main.bundleURL }

    var body: some View {
        SettingsPage(
            symbol: "trash",
            tint: .red,
            title: UIStrings.tabUninstall[loc.language],
            subtitle: UIStrings.uninstallIntro[loc.language]
        ) {
            if script == nil {
                missingScriptCard
            } else {
                explanationCard
                itemsCard
                loginItemCard
                actionCard
                if !results.isEmpty { resultsCard }
            }
        }
        .task { await load() }
        .alert(
            UIStrings.uninstallConfirmTitle[loc.language],
            isPresented: $confirming
        ) {
            Button(UIStrings.cancel[loc.language], role: .cancel) {}
            Button(UIStrings.uninstallConfirmAction[loc.language], role: .destructive) {
                Task { await runUninstall() }
            }
        } message: {
            Text(String(format: UIStrings.uninstallConfirmBodyFormat[loc.language], selection.count))
        }
    }

    // MARK: - Cards

    private var explanationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(UIStrings.uninstallExplain[loc.language])
                    .fixedSize(horizontal: false, vertical: true)

                Label(UIStrings.uninstallHomebrewNote[loc.language], systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var itemsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(UIStrings.uninstallIntro[loc.language])
                        .font(.headline)
                    Spacer()
                    Button(UIStrings.uninstallSelectAll[loc.language]) {
                        selection = Set(items.filter(\.isPresent).map(\.step))
                    }
                    .buttonStyle(.link)
                    Button(UIStrings.uninstallSelectNone[loc.language]) { selection = [] }
                        .buttonStyle(.link)
                }

                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    ForEach(items) { item in
                        row(for: item)
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
            .disabled(isRunning || isQuitting)
        }
    }

    private func row(for item: UninstallItem) -> some View {
        Toggle(isOn: Binding(
            get: { selection.contains(item.step) },
            set: { isOn in
                if isOn { selection.insert(item.step) } else { selection.remove(item.step) }
            }
        )) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.step.symbol)
                    .frame(width: 18)
                    .foregroundStyle(item.isPresent ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.step.title[loc.language])

                    Text(item.isPresent && !item.detail.isEmpty
                         ? item.detail
                         : UIStrings.uninstallNothingToRemove[loc.language])
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text(item.step.explanation[loc.language])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // A row for something that is not there stays visible but cannot be
        // ticked: "nothing to remove" is worth reading, and a list whose
        // length changes between visits is harder to trust than one that
        // does not.
        .disabled(!item.isPresent)
        .opacity(item.isPresent ? 1 : 0.5)
    }

    /// Separate from the list above because it is not one of the script's
    /// steps - see the note at the top of this file.
    @ViewBuilder
    private var loginItemCard: some View {
        if LaunchAtLogin.isEnabled || turnOffLoginItem {
            Card {
                Toggle(isOn: $turnOffLoginItem) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UIStrings.uninstallLoginItemToggle[loc.language])
                        Text(UIStrings.uninstallLoginItemHelp[loc.language])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(isRunning || isQuitting)
            }
        }
    }

    private var actionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $dryRun) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UIStrings.uninstallDryRun[loc.language])
                        Text(UIStrings.uninstallDryRunHelp[loc.language])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(isRunning || isQuitting)

                HStack(spacing: 12) {
                    Button(role: dryRun ? nil : .destructive) {
                        // A dry run changes nothing, so making someone confirm
                        // it would only teach them to click through the dialog
                        // that matters.
                        if dryRun {
                            Task { await runUninstall() }
                        } else {
                            confirming = true
                        }
                    } label: {
                        Label(
                            isRunning
                                ? UIStrings.uninstallRunning[loc.language]
                                : UIStrings.uninstallRemoveSelected[loc.language],
                            systemImage: dryRun ? "eye" : "trash"
                        )
                    }
                    .disabled(selection.isEmpty && !turnOffLoginItem || isRunning || isQuitting)

                    if isRunning { ProgressView().controlSize(.small) }
                }

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var resultsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(UIStrings.uninstallResults[loc.language])
                    .font(.headline)

                ForEach(results) { result in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: symbol(for: result.outcome))
                            .foregroundStyle(tint(for: result.outcome))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.step.title[loc.language])
                            Text(label(for: result.outcome)[loc.language]
                                 + (result.detail.isEmpty ? "" : " — \(result.detail)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if isQuitting {
                    Divider()
                    HStack {
                        Text(UIStrings.uninstallQuitting[loc.language])
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(UIStrings.uninstallQuitNow[loc.language]) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// Nothing to drive: the app is here but the engine never was.
    private var missingScriptCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label(UIStrings.uninstallNoScript[loc.language], systemImage: "questionmark.folder")
                    .font(.headline)

                Text(UIStrings.uninstallNoScriptDetail[loc.language])
                    .fixedSize(horizontal: false, vertical: true)

                // This card is where someone lands after the engine turns out
                // not to be installed, and until now it offered exactly one
                // way forward: remove the app. Installing the thing that is
                // missing is the more likely intent, and it goes first.
                Button {
                    onboarding.present()
                } label: {
                    Label(UIStrings.onboardingOpenWizard[loc.language], systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isQuitting)

                Button(role: .destructive) { removeAppOnly() } label: {
                    Label(UIStrings.uninstallRemoveApp[loc.language], systemImage: "trash")
                }
                .disabled(isQuitting)

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Work

    private func load() async {
        guard let script else {
            isLoading = false
            return
        }
        let found = await UninstallPlan.list(script: script, appBundle: appBundle)
        items = found
        // Only ever preselect what is actually there. A default that ticks an
        // absent row would put a count in the confirmation dialog that does
        // not match what happens.
        selection = Set(found.filter { $0.isPresent && $0.step.isCheckedByDefault }.map(\.step))
        isLoading = false
    }

    private func runUninstall() async {
        guard let script else { return }
        isRunning = true
        failure = nil

        if turnOffLoginItem, !dryRun {
            // Reported through the same banner a script failure uses: macOS
            // can refuse this (an app running from a build folder, say), and
            // a login item that silently stayed on is exactly the kind of
            // leftover this page exists to prevent.
            if let error = LaunchAtLogin.set(false) {
                failure = error
            } else {
                turnOffLoginItem = false
            }
        }

        let steps = UninstallStep.allCases.filter { selection.contains($0) }
        let outcome = await UninstallPlan.run(
            script: script,
            appBundle: appBundle,
            steps: steps,
            dryRun: dryRun
        )

        results = outcome.results
        if let scriptFailure = outcome.failure {
            failure = [failure, scriptFailure].compactMap { $0 }.joined(separator: "\n")
        }
        isRunning = false

        guard !dryRun else {
            await load()
            return
        }

        // `defaults delete` reaches the file on disk; this process still holds
        // its own copy and would write it straight back out on quit. Dropping
        // the domain here is what makes the removal survive.
        if outcome.results.contains(where: { $0.step == .prefs && $0.outcome == .removed }),
           let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        if outcome.results.contains(where: { $0.step == .app && $0.outcome == .removed }) {
            // The bundle is unlinked but this process keeps running off the
            // inode it already opened. Long enough to read the results, then
            // out - staying open on a deleted bundle only invites a confusing
            // relaunch failure later.
            isQuitting = true
            try? await Task.sleep(for: .seconds(6))
            NSApplication.shared.terminate(nil)
        } else {
            await load()
        }
    }

    /// The disk-image case: no script to run, so the app removes the only two
    /// things it knows it owns - its bundle and its preferences.
    private func removeAppOnly() {
        failure = nil
        LaunchAtLogin.set(false)

        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        // recycle, not delete: the Trash is undoable and this is the one
        // removal here that nobody can walk back through the app itself.
        NSWorkspace.shared.recycle([appBundle]) { _, error in
            Task { @MainActor in
                if let error {
                    failure = String(
                        format: UIStrings.uninstallTrashFailedFormat[loc.language],
                        error.localizedDescription
                    )
                    return
                }
                isQuitting = true
                try? await Task.sleep(for: .seconds(2))
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Outcome presentation

    private func symbol(for outcome: UninstallOutcome) -> String {
        switch outcome {
        case .removed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed:  return "xmark.octagon.fill"
        case .dryrun:  return "eye.circle"
        }
    }

    private func tint(for outcome: UninstallOutcome) -> Color {
        switch outcome {
        case .removed: return .green
        case .skipped: return .secondary
        case .failed:  return .red
        case .dryrun:  return .accentColor
        }
    }

    private func label(for outcome: UninstallOutcome) -> Localized {
        switch outcome {
        case .removed: return UIStrings.uninstallOutcomeRemoved
        case .skipped: return UIStrings.uninstallOutcomeSkipped
        case .failed:  return UIStrings.uninstallOutcomeFailed
        case .dryrun:  return UIStrings.uninstallOutcomeDryRun
        }
    }
}
