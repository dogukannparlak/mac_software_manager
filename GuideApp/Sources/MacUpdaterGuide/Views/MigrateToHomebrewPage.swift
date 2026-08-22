import SwiftUI

/// Applications installed by hand that Homebrew could keep up to date instead,
/// and a way to hand each one over.
///
/// The page is built around one idea: **scanning changes nothing**. The engine
/// reads cask metadata and each bundle's `Info.plist` and reports what *would*
/// happen (see CACHE_FORMAT.md, "`migration_candidates`"), so the whole list
/// can be shown up front and the user picks from it. Nothing here is
/// speculative about the outcome either - a row says which of the six states
/// the engine worked out, and the two that cannot be acted on are shown with
/// their reason rather than hidden.
///
/// Three sections, because the three groups want three different things from
/// the reader: pick, decide, or just know.
struct MigrateToHomebrewPage: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(InventoryStore.self) private var inventory

    /// Rows ticked for the bulk "Move Selected" button, by app name.
    @State private var selection: Set<String> = []
    /// The version-mismatch row waiting on its confirmation sheet. Replacing
    /// an app is the one destructive thing this page can do, so it never
    /// happens on a single click.
    @State private var confirming: MigrationCandidate?

    var body: some View {
        SettingsPage(
            symbol: "arrow.right.doc.on.clipboard",
            tint: .teal,
            title: UIStrings.tabMigrate[loc.language],
            subtitle: UIStrings.migrateIntro[loc.language]
        ) {
            if toolkit.engineSupportsMigration {
                scanCard
                results
            } else {
                engineTooOld
            }
        }
        .task { toolkit.loadMigrationCandidates() }
        // The migrated app is a cask now, so the installed-apps inventory is
        // stale. The controller does not own that store, so it bumps a counter
        // and this is what listens - see `ToolkitController.migrationsCompleted`.
        .onChange(of: toolkit.migrationsCompleted) {
            Task { await inventory.reload() }
        }
        .sheet(item: $confirming) { candidate in
            ReplaceConfirmationSheet(candidate: candidate) {
                toolkit.migrate(candidate: candidate, mode: .replace)
                selection.remove(candidate.appName)
            }
            .environment(loc)
        }
    }

    // MARK: - Engine gate

    /// An engine older than `EngineContract.migrationContract` has neither the
    /// scan nor the migrate action, so there is nothing to draw and no button
    /// worth offering - pressing one would just fail. Said plainly instead.
    private var engineTooOld: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(UIStrings.migrateEngineTooOld[loc.language], systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(UIStrings.migrateEngineTooOldDetail[loc.language])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Scanning

    private var scanCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(UIStrings.migrateExplain[loc.language])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button {
                        toolkit.scanMigration()
                    } label: {
                        Label(
                            toolkit.hasScannedMigration
                                ? UIStrings.migrateRescanButton[loc.language]
                                : UIStrings.migrateScanButton[loc.language],
                            systemImage: "magnifyingglass"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(toolkit.isScanningMigration)

                    if toolkit.isScanningMigration {
                        ProgressView()
                            .controlSize(.small)
                        Text(UIStrings.migrateScanning[loc.language])
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                Text(UIStrings.migrateScanCost[loc.language])
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Results

    private var adoptable: [MigrationCandidate] {
        toolkit.migrationCandidates.filter { $0.state.isAdoptable }.sorted(by: byName)
    }
    private var needsConfirmation: [MigrationCandidate] {
        toolkit.migrationCandidates.filter { $0.state.needsConfirmation }.sorted(by: byName)
    }
    private var blocked: [MigrationCandidate] {
        toolkit.migrationCandidates.filter { $0.state.isBlocked }.sorted(by: byName)
    }

    private func byName(_ a: MigrationCandidate, _ b: MigrationCandidate) -> Bool {
        a.appName.lowercased() < b.appName.lowercased()
    }

    @ViewBuilder
    private var results: some View {
        if toolkit.migrationCandidates.isEmpty {
            // "Never scanned" and "scanned, found nothing" are different
            // answers and get different wording: one is an invitation, the
            // other is a clean result.
            ContentUnavailableView(
                (toolkit.hasScannedMigration
                    ? UIStrings.migrateNothingFound
                    : UIStrings.migrateNeverScanned)[loc.language],
                systemImage: toolkit.hasScannedMigration ? "checkmark.circle" : "magnifyingglass",
                description: Text(
                    (toolkit.hasScannedMigration
                        ? UIStrings.migrateNothingFoundDetail
                        : UIStrings.migrateNeverScannedDetail)[loc.language]
                )
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            if !adoptable.isEmpty { adoptableSection }
            if !needsConfirmation.isEmpty { confirmSection }
            if !blocked.isEmpty { blockedSection }
        }
    }

    /// The only section with checkboxes: everything in it can be handed over
    /// with a plain adopt, which is non-destructive, so a bulk action over the
    /// lot of them is a reasonable thing to offer.
    private var adoptableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                title: UIStrings.migrateSectionReady[loc.language],
                detail: UIStrings.migrateSectionReadyDetail[loc.language],
                symbol: "checkmark.circle.fill",
                tint: .green
            )

            Card {
                VStack(spacing: 0) {
                    ForEach(Array(adoptable.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { Divider().padding(.vertical, 2) }
                        CandidateRow(
                            candidate: candidate,
                            isSelected: Binding(
                                get: { selection.contains(candidate.appName) },
                                set: { on in
                                    if on { selection.insert(candidate.appName) } else { selection.remove(candidate.appName) }
                                }
                            ),
                            action: {
                                toolkit.migrate(candidate: candidate, mode: .adopt)
                                selection.remove(candidate.appName)
                            }
                        )
                    }
                }
            }

            bulkBar
        }
    }

    private var selectedCandidates: [MigrationCandidate] {
        adoptable.filter { selection.contains($0.appName) }
    }

    private var bulkBar: some View {
        HStack(spacing: 12) {
            Button {
                // Every one of these goes through the same concurrency queue a
                // normal update uses, so "move eight" is eight queued runs at
                // the configured limit, not eight at once.
                for candidate in selectedCandidates {
                    toolkit.migrate(candidate: candidate, mode: .adopt)
                }
                selection.removeAll()
            } label: {
                Label(UIStrings.migrateSelected[loc.language], systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedCandidates.isEmpty)

            Button(
                selection.isEmpty
                    ? UIStrings.migrateSelectAll[loc.language]
                    : UIStrings.migrateSelectNone[loc.language]
            ) {
                if selection.isEmpty {
                    selection = Set(adoptable.map(\.appName))
                } else {
                    selection.removeAll()
                }
            }

            if !selection.isEmpty {
                Text(String(format: UIStrings.migrateSelectedCountFormat[loc.language], selection.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    /// No checkboxes and no bulk action here on purpose: each of these
    /// replaces an application, and that is a decision per app.
    private var confirmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                title: UIStrings.migrateSectionConfirm[loc.language],
                detail: UIStrings.migrateSectionConfirmDetail[loc.language],
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )

            Card {
                VStack(spacing: 0) {
                    ForEach(Array(needsConfirmation.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { Divider().padding(.vertical, 2) }
                        CandidateRow(
                            candidate: candidate,
                            isSelected: nil,
                            showsVersions: true,
                            action: { confirming = candidate }
                        )
                    }
                }
            }
        }
    }

    /// Information only. These are listed rather than filtered out because
    /// "why is my app not here" is the question a filtered list creates, and
    /// the engine already worked out the answer.
    private var blockedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(
                title: UIStrings.migrateSectionBlocked[loc.language],
                detail: UIStrings.migrateSectionBlockedDetail[loc.language],
                symbol: "nosign",
                tint: .secondary
            )

            Card {
                VStack(spacing: 0) {
                    ForEach(Array(blocked.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { Divider().padding(.vertical, 2) }
                        BlockedRow(candidate: candidate)
                    }
                }
            }
        }
    }
}

// MARK: - Rows

private struct SectionHeading: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

/// One actionable candidate: what it is, how sure the pairing is, and the
/// button that moves it.
private struct CandidateRow: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit

    let candidate: MigrationCandidate
    /// `nil` in the sections that have no bulk action - see `confirmSection`.
    var isSelected: Binding<Bool>?
    var showsVersions: Bool = false
    let action: () -> Void

    private var status: ToolkitController.ItemUpdateStatus? {
        toolkit.migrationStatus(for: candidate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let isSelected {
                    Toggle("", isOn: isSelected)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(status != nil)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(candidate.appName)
                            .font(.body.weight(.medium))

                        Text(candidate.token)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        if !candidate.match.isVerified { unverifiedBadge }
                    }

                    if showsVersions { versions }

                    Text(candidate.match.label[loc.language])
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                trailing
            }

            if let reason = toolkit.migrationFailureReason(for: candidate), status == .failed {
                Text(reason.text(for: loc.language))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 7)
    }

    /// The `token` match is the one the engine cannot vouch for - it resolved
    /// a name-derived guess to *a* cask and nothing confirmed it is this
    /// application. The link is the point of the badge: it is how the user
    /// checks before pressing a button that replaces an app.
    private var unverifiedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "questionmark.circle.fill")
            Text(UIStrings.migrateUnverified[loc.language])
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            Capsule().fill(Color.orange.opacity(0.14))
        }
        .help(UIStrings.migrateUnverifiedDetail[loc.language])
    }

    private var versions: some View {
        HStack(spacing: 6) {
            versionChip(UIStrings.migrateInstalledVersion[loc.language], candidate.installedVersion)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            versionChip(UIStrings.migrateCaskVersion[loc.language], candidate.caskVersion)
        }
    }

    private func versionChip(_ label: String, _ version: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(version.isEmpty ? "—" : version)
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospaced())
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 10) {
            if let url = candidate.caskPageURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help(UIStrings.migrateViewCask[loc.language])
            }

            switch status {
            case .queued:
                Text(UIStrings.queuedRowStatus[loc.language])
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .updating:
                ProgressView()
                    .controlSize(.small)
            case .succeeded:
                Label(UIStrings.migrateDone[loc.language], systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed:
                Label(UIStrings.migrateFailed[loc.language], systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case nil:
                Button(UIStrings.migrateOne[loc.language], action: action)
            }
        }
    }
}

/// A candidate nothing can be done about: name, why, and where to read more.
/// No button, because there is no action that would work.
private struct BlockedRow: View {
    @Environment(LocalizationStore.self) private var loc

    let candidate: MigrationCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(candidate.appName)
                        .font(.body.weight(.medium))
                    Text(candidate.token)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(candidate.state.label[loc.language])
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background { Capsule().fill(Color.secondary.opacity(0.14)) }
                }

                Text(candidate.state.detail[loc.language])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The one blocked state with something the user can still do
                // themselves. The engine will not run sudo from a headless
                // run, so the command has to be here to be copied.
                if candidate.state == .needsRoot {
                    Text(String(format: UIStrings.migrateRunYourselfFormat[loc.language], candidate.token))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let url = candidate.caskPageURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help(UIStrings.migrateViewCask[loc.language])
            }
        }
        .padding(.vertical, 7)
    }
}

// MARK: - Confirmation

/// The gate in front of the one destructive path on this page.
///
/// A `version-mismatch` move is not an adoption: Homebrew downloads its own
/// copy and puts it where the user's application was. That is worth a sentence
/// and a second click - and, when the installed copy is the *newer* one, an
/// explicit warning, because the move is then a downgrade the user almost
/// certainly did not intend.
private struct ReplaceConfirmationSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let candidate: MigrationCandidate
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(format: UIStrings.migrateConfirmTitleFormat[loc.language], candidate.appName))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 14) {
                Text(UIStrings.migrateConfirmBody[loc.language])
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    versionBox(UIStrings.migrateInstalledVersion[loc.language], candidate.installedVersion)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    versionBox(UIStrings.migrateCaskVersion[loc.language], candidate.caskVersion)
                }

                if isDowngrade {
                    Callout(role: .caution, text: UIStrings.migrateConfirmDowngrade[loc.language])
                }

                if !candidate.match.isVerified {
                    Callout(role: .caution, text: UIStrings.migrateUnverifiedDetail[loc.language])
                }
            }
            .padding(20)

            Divider()

            HStack {
                if let url = candidate.caskPageURL {
                    Link(UIStrings.migrateViewCask[loc.language], destination: url)
                }
                Spacer()
                Button(UIStrings.cancel[loc.language]) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(UIStrings.migrateConfirmAction[loc.language]) {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    /// Whether moving would take the user *back* a version.
    ///
    /// Both strings come straight off disk unnormalized (`Info.plist` and the
    /// cask's `version`), so this uses macOS' own version comparison rather
    /// than parsing them - and answers "no" whenever either side is missing or
    /// not a version at all, because a warning nobody can act on is worse than
    /// no warning.
    private var isDowngrade: Bool {
        guard !candidate.installedVersion.isEmpty, !candidate.caskVersion.isEmpty else { return false }
        return candidate.installedVersion.compare(
            candidate.caskVersion,
            options: .numeric
        ) == .orderedDescending
    }

    private func versionBox(_ label: String, _ version: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(version.isEmpty ? "—" : version)
                .font(.callout.monospaced())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }
}
