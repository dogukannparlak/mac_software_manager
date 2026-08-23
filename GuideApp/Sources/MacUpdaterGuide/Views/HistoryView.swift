import SwiftUI

/// What has actually been updated, grouped by day.
///
/// Failed attempts stay in the list, marked, rather than disappearing - a log
/// that only records successes cannot be trusted to explain anything.
struct HistoryView: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(AppIconCache.self) private var icons

    @State private var history = UpdateHistory()
    @State private var windowDays = 7

    private var groups: [(day: Date, entries: [HistoryEntry])] {
        history.grouped(withinDays: windowDays)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                rangePicker

                if groups.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(UIStrings.historyEmpty[loc.language])
                                .font(.headline)
                            Text(UIStrings.historyEmptyDetail[loc.language])
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(groups, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(dayTitle(group.day))
                                .font(.title3.weight(.semibold))

                            Card {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                        if index > 0 { Divider().padding(.vertical, 2) }
                                        HistoryRow(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(UIStrings.navHistory[loc.language])
        .task(id: toolkit.snapshot.lastCheck) {
            history = UpdateHistory.load()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            IconTile(symbol: "clock.arrow.circlepath", size: 56, tint: .teal)

            VStack(alignment: .leading, spacing: 4) {
                Text(UIStrings.navHistory[loc.language])
                    .font(.system(.largeTitle).weight(.bold))

                HStack(spacing: 12) {
                    Label(
                        String(
                            format: UIStrings.historySucceededFormat[loc.language],
                            history.successCount(withinDays: windowDays)
                        ),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)

                    let failures = history.failureCount(withinDays: windowDays)
                    if failures > 0 {
                        Label(
                            String(format: UIStrings.historyFailedFormat[loc.language], failures),
                            systemImage: "xmark.circle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }

            Spacer(minLength: 0)
        }
    }

    private var rangePicker: some View {
        Picker("", selection: $windowDays) {
            Text(UIStrings.last7Days[loc.language]).tag(7)
            Text(UIStrings.last30Days[loc.language]).tag(30)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
    }

    private func dayTitle(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: loc.language.rawValue)
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

private struct HistoryRow: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(AppIconCache.self) private var icons
    @Environment(\.openURL) private var openURL

    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            iconView

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body.weight(.medium))

                    if !entry.succeeded {
                        Text(UIStrings.failedBadge[loc.language])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                    }

                    if entry.isMigration {
                        Text(UIStrings.migratedBadge[loc.language])
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue))
                    }
                }

                HStack(spacing: 6) {
                    Text(entry.oldVersion)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.newVersion)
                }
                .font(.callout.monospacedDigit())

                if !entry.succeeded, let reasonLabel = failureReasonText {
                    Text(reasonLabel[loc.language])
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let link = entry.link {
                Button {
                    openURL(link)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 5)
        .opacity(entry.succeeded ? 1 : 0.85)
    }

    /// `entry.reason.label` is `nil` for `.commandFailed` on purpose (see
    /// `ItemRunResult.Reason`) - the live banner fills that gap with stderr,
    /// which this row does not have. `.none` (no reason token was ever
    /// recorded, e.g. entries from before this field existed) and `.unknown`
    /// (a token this build does not recognize) stay silent instead of
    /// guessing.
    private var failureReasonText: Localized? {
        if let label = entry.reason.label { return label }
        return entry.reason == .commandFailed ? UIStrings.historyCommandFailed : nil
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: loc.language.rawValue)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: entry.date)
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = icons.icon(forAppNamed: entry.name) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 28, height: 28)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.14))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: entry.succeeded ? entry.source.symbol : "xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(entry.succeeded ? Color.secondary : Color.orange)
                }
        }
    }
}
