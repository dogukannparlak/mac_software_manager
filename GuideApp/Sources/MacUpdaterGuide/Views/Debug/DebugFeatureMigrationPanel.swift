import SwiftUI

/// The Move to Homebrew feature: scan, read the candidates, and try one.
///
/// The table shows `match` next to `state` because those two answer different
/// questions and the page is only safe when both are read: `state` says what
/// migrating would do, `match` says whether this is even the right cask. A
/// `token` match is the one that pairs an app with an unrelated cask - the
/// engine's own comment cites "ClearDisk" resolving to "clearvpn" - so it is
/// called out here rather than averaged into a single number.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugFeatureMigrationPanel: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugLog.self) private var log

    @State private var selected: String?
    @State private var pendingRealMigration: MigrationCandidate?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Migration")
                    .font(.headline)

                contractLine
                actions
                candidateTable
                selectedActions
            }
        }
        .confirmationDialog(
            "Really move this application to Homebrew?",
            isPresented: Binding(
                get: { pendingRealMigration != nil },
                set: { if !$0 { pendingRealMigration = nil } }
            ),
            presenting: pendingRealMigration
        ) { candidate in
            Button("Move \(candidate.appName)", role: .destructive) { migrate(candidate, mode: .adopt) }
            Button("Cancel", role: .cancel) { pendingRealMigration = nil }
        } message: { candidate in
            Text("""
            brew install --cask --adopt \(candidate.token) runs for real. Homebrew takes over the copy \
            already at \(candidate.appPath). It refuses rather than damages anything when it will not \
            adopt, but this is a real change to a real application.
            """)
        }
    }

    private var contractLine: some View {
        HStack(spacing: 8) {
            Image(systemName: toolkit.engineSupportsMigration ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(toolkit.engineSupportsMigration ? .green : .orange)
            Text(toolkit.engineSupportsMigration
                 ? "Engine declares contract \(EngineContract.migrationContract) or newer."
                 : "Engine does not declare contract \(EngineContract.migrationContract) - the page will refuse to act.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("scanMigration()") {
                log.note("scanMigration() - one brew info per candidate token, no downloads")
                toolkit.scanMigration()
            }
            .disabled(toolkit.isScanningMigration || toolkit.isUpdating)

            Button("loadMigrationCandidates()") {
                toolkit.loadMigrationCandidates()
                report()
            }

            if toolkit.isScanningMigration {
                ProgressView().controlSize(.small)
            }

            Text(toolkit.hasScannedMigration
                 ? "\(toolkit.migrationCandidates.count) candidate(s)"
                 : "never scanned")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var candidateTable: some View {
        VStack(alignment: .leading, spacing: 2) {
            if toolkit.migrationCandidates.isEmpty {
                Text("No candidates loaded. Scan, or press loadMigrationCandidates() to read the last scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                headings
                ForEach(toolkit.migrationCandidates) { candidate in
                    row(candidate)
                }
            }
        }
    }

    private var headings: some View {
        HStack(spacing: 8) {
            Text("App").frame(width: 150, alignment: .leading)
            Text("Cask").frame(width: 120, alignment: .leading)
            Text("Confidence").frame(width: 110, alignment: .leading)
            Text("State").frame(width: 120, alignment: .leading)
            Text("Evidence").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func row(_ candidate: MigrationCandidate) -> some View {
        Button {
            selected = selected == candidate.id ? nil : candidate.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(candidate.appName)
                    .frame(width: 150, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(candidate.token)
                    .frame(width: 120, alignment: .leading)
                    .lineLimit(1)

                confidence(candidate.match)
                    .frame(width: 110, alignment: .leading)

                Text(candidate.state.rawValue)
                    .frame(width: 120, alignment: .leading)
                    .foregroundStyle(candidate.state.isAdoptable ? Color.green : Color.orange)

                Text(candidate.match.label.en)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption.monospaced())
            .padding(.vertical, 2)
            .background(selected == candidate.id ? Color.accentColor.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
    }

    /// `match` is a four-value ladder, not a percentage - showing it as one
    /// would invent precision the engine never claimed.
    private func confidence(_ match: MigrationCandidate.Match) -> some View {
        HStack(spacing: 4) {
            Image(systemName: match.isVerified ? "checkmark.seal.fill" : "questionmark.diamond.fill")
                .foregroundStyle(match.isVerified ? .green : .orange)
            Text(match.rawValue)
        }
    }

    private var selectedActions: some View {
        HStack(spacing: 8) {
            if let candidate = current {
                Button("migrate(.dry)") { migrate(candidate, mode: .dry) }
                Button("migrate(.adopt) — real", role: .destructive) { pendingRealMigration = candidate }
                    .tint(.red)
                if let url = candidate.caskPageURL {
                    Link("Cask page", destination: url)
                }
                Text(candidate.state.detail.en)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Select a row to act on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var current: MigrationCandidate? {
        toolkit.migrationCandidates.first { $0.id == selected }
    }

    private func migrate(_ candidate: MigrationCandidate, mode: ToolkitController.MigrationMode) {
        pendingRealMigration = nil
        log.note("migrate(candidate: \"\(candidate.appName)\", mode: .\(mode.rawValue)) → cask \(candidate.token)")
        toolkit.migrate(candidate: candidate, mode: mode)
    }

    private func report() {
        let candidates = toolkit.migrationCandidates
        let verified = candidates.filter(\.self.match.isVerified).count
        let adoptable = candidates.filter(\.self.state.isAdoptable).count
        log.note("""
        \(candidates.count) candidate(s): \(verified) verified match, \
        \(candidates.count - verified) name-guess only, \(adoptable) ready to move.
        """)
    }
}
