import AppKit
import SwiftUI

/// Read-only diagnostics: what this machine has, what the app found, and what
/// macOS is letting it do.
///
/// Nothing here changes anything - every row is a probe. That is deliberate:
/// this is the panel to look at first when something is wrong, and a panel
/// that could itself alter the state being investigated is worth less than
/// one that cannot.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugSectionEnvironment: View {
    @State private var report = DebugEnvironmentReport()
    @State private var copied: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Diagnostics")
                        .font(.headline)

                    if report.isLoading {
                        ProgressView().controlSize(.small)
                    }

                    Spacer(minLength: 8)

                    Button {
                        copy(report.markdown, label: "markdown")
                    } label: {
                        Label("Copy all as markdown", systemImage: "doc.on.clipboard")
                    }
                    .controlSize(.small)
                    .disabled(report.groups.isEmpty)

                    Button {
                        Task { await report.load() }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(report.isLoading)
                }

                Text("Paste the markdown straight into an issue - it is generated from the rows below, not collected again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let copied {
                    Label("Copied \(copied)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }

        ForEach(report.groups) { group in
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.id)
                        .font(.headline)

                    ForEach(Array(group.facts.enumerated()), id: \.element.id) { index, fact in
                        if index > 0 { Divider().padding(.vertical, 1) }
                        DebugFactRow(fact: fact) { copy($0, label: fact.id) }
                    }
                }
            }
        }
        .task { await report.load() }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = label
        // Cleared on its own rather than left on screen: the confirmation is
        // about the press, and a stale "Copied macOS" next to a table full
        // of other rows reads as though it applies to all of them.
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == label { copied = nil }
        }
    }
}

/// One label/value row with its own Copy button.
private struct DebugFactRow: View {
    let fact: DebugFact
    let onCopy: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(fact.id)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(fact.value)
                    .font(.callout.monospaced())
                    .foregroundStyle(fact.isProblem ? Color.orange : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = fact.detail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            Button {
                onCopy(copyText)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy this value")
        }
        .padding(.vertical, 2)
    }

    /// The value and its detail together: the detail is usually the path or
    /// the error that makes the value mean something, and copying one
    /// without the other produces a line nobody can act on.
    private var copyText: String {
        guard let detail = fact.detail else { return fact.value }
        return "\(fact.value) — \(detail)"
    }
}
