import AppKit
import SwiftUI

/// Every translated string in the app, with the three things that go wrong.
///
/// The specifier filter is the one that matters: a Turkish string carrying a
/// different set of `%d`/`%@` from its English twin is not a cosmetic problem,
/// it is `String(format:)` reading an argument that was never passed. The
/// other two filters are a missing translation and a suspiciously identical
/// one, in that order of certainty.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugSectionLocalization: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(DebugLog.self) private var log

    @State private var audit = DebugLocalizationAudit()
    @State private var filter: DebugLocalizationAudit.Issue?
    @State private var copied = false

    var body: some View {
        header
        table
            .task { audit.load() }
    }

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                @Bindable var localization = loc

                HStack(spacing: 10) {
                    Picker("Language", selection: $localization.language) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.endonym).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)

                    Text("switches the whole app immediately")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button {
                        audit.load()
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }

                filterRow

                Text(audit.sourceStatus)
                    .font(.caption)
                    .foregroundStyle(audit.didFindSources ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        copyReport()
                    } label: {
                        Label("Copy report as markdown", systemImage: "doc.on.clipboard")
                    }
                    .controlSize(.small)
                    .disabled(audit.pairs.isEmpty)

                    if copied {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            FilterChip(
                title: "All",
                count: audit.pairs.count,
                isSelected: filter == nil
            ) { filter = nil }

            ForEach(DebugLocalizationAudit.Issue.allCases) { issue in
                FilterChip(
                    title: issue.label,
                    count: audit.count(of: issue),
                    isSelected: filter == issue,
                    tint: issue == .specifierMismatch ? .red : (issue.isFault ? .orange : .gray)
                ) { filter = filter == issue ? nil : issue }
            }

            Spacer(minLength: 0)
        }
    }

    private var table: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                let rows = audit.filtered(by: filter)

                HStack(spacing: 10) {
                    Text("Key").frame(width: 190, alignment: .leading)
                    Text("EN").frame(maxWidth: .infinity, alignment: .leading)
                    Text("TR").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                if rows.isEmpty {
                    Text(audit.pairs.isEmpty ? "Nothing parsed." : "Nothing matches this filter.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(rows) { pair in
                        Divider().padding(.vertical, 1)
                        row(pair)
                    }
                }
            }
        }
    }

    private func row(_ pair: DebugLocalizationAudit.Pair) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pair.key)
                        .font(.caption.monospaced().weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(pair.file):\(pair.line)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 190, alignment: .leading)

                Text(pair.en)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Text(pair.tr.isEmpty ? "—" : pair.tr)
                    .font(.caption)
                    .foregroundStyle(pair.issues.contains(.missingTranslation) ? Color.orange : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !pair.issues.isEmpty {
                issueRow(pair)
            }
        }
    }

    private func issueRow(_ pair: DebugLocalizationAudit.Pair) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 200)

            ForEach(Array(pair.issues).sorted(by: { $0.rawValue < $1.rawValue })) { issue in
                Text(issue.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(issue == .specifierMismatch ? Color.red : Color.orange))
            }

            if pair.issues.contains(.specifierMismatch) {
                Text("EN \(pair.enSpecifiers.joined(separator: " ")) vs TR \(pair.trSpecifiers.joined(separator: " "))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)
        }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(audit.markdown(filter: filter), forType: .string)
        copied = true
        log.note("Copied localization report: \(audit.filtered(by: filter).count) row(s), \(audit.faults) fault(s).")
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
