import SwiftUI

/// Every `ActionFailure` the app can raise, rendered through the real
/// `FailureBanner` with its real recovery wiring.
///
/// **What this does not do.** `ToolkitController.lastFailure` is
/// `private(set)`, so nothing outside the controller can push a failure into
/// the banner that ContentView draws above every page. Reaching it would mean
/// adding an injection point to `Toolkit/`, which is outside the four files
/// this page was allowed to touch - so the banner is rendered here instead,
/// from the same view type, with the same values, and `onRecover` wired to
/// the controller's real `recover(from:)`. Layout, wording, translation, the
/// disclosure, and what the recovery button actually calls are all exercised;
/// what is not is the placement of the banner inside ContentView.
///
/// The recovery button is worth pressing even so: `recover(from:)` looks the
/// row back up by id, and pressing it for an id that is not in the snapshot
/// makes the controller raise its own `.itemGone` failure - which *does* land
/// in the real banner at the top of the window. That is the one path from
/// here into the live one.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugStateFailurePanel: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugLog.self) private var log

    @State private var action = 0
    @State private var reason = 0
    @State private var withRecovery = true
    @State private var compact = false
    @State private var dismissed = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Failure banner")
                    .font(.headline)

                Text("""
                Every Reason the app can raise, in the real FailureBanner. Recovery is wired to \
                toolkit.recover(from:) - pressing it for a row that is not in the current snapshot \
                makes the controller raise its own itemGone failure in the live banner at the top \
                of the window.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                controls
                preview
                Divider()
                gallery
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Action", selection: $action) {
                    ForEach(Array(Self.actions.enumerated()), id: \.offset) { index, entry in
                        Text(entry.label).tag(index)
                    }
                }
                .frame(width: 280)

                Picker("Reason", selection: $reason) {
                    ForEach(Array(Self.reasons.enumerated()), id: \.offset) { index, entry in
                        Text(entry.label).tag(index)
                    }
                }
                .frame(width: 320)

                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                Toggle("Offer recovery", isOn: $withRecovery)
                Toggle("Compact (menu bar size)", isOn: $compact)
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dismissed {
                HStack(spacing: 8) {
                    Text("Dismissed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Show again") { dismissed = false }
                        .controlSize(.small)
                }
            } else {
                banner(for: current, compact: compact)
            }
        }
    }

    /// Every reason at once, so a wording or layout change can be checked
    /// against the whole set without clicking through a picker.
    private var gallery: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All reasons")
                .font(.subheadline.weight(.medium))

            ForEach(Array(Self.reasons.enumerated()), id: \.offset) { _, entry in
                banner(for: ToolkitController.ActionFailure(
                    action: Self.actions[action].value,
                    subject: Self.subject,
                    reason: entry.value,
                    recovery: withRecovery ? .runInTerminal(itemID: recoveryItemID) : nil
                ), compact: compact)
            }
        }
    }

    private func banner(for failure: ToolkitController.ActionFailure, compact: Bool) -> some View {
        FailureBanner(
            failure: failure,
            onDismiss: { dismissed = true },
            compact: compact,
            onRecover: { recovery in
                log.note("recover(from: \(recovery)) - item id \(recoveryItemID)")
                toolkit.recover(from: recovery)
            }
        )
    }

    private var current: ToolkitController.ActionFailure {
        ToolkitController.ActionFailure(
            action: Self.actions[action].value,
            subject: Self.subject,
            reason: Self.reasons[reason].value,
            recovery: withRecovery ? .runInTerminal(itemID: recoveryItemID) : nil
        )
    }

    /// A row that is really in the snapshot when there is one, so the
    /// recovery button does the real thing rather than always landing on
    /// itemGone.
    private var recoveryItemID: String {
        toolkit.snapshot.items.first?.id ?? "brew:not-in-this-snapshot"
    }

    // MARK: - The cases

    private static let subject = "AltTab"

    /// Enumerated by hand: `ActionFailure.Action` is not `CaseIterable`, and
    /// making it so would be a change to `Toolkit/` for a debug list.
    private static let actions: [(label: String, value: ToolkitController.ActionFailure.Action)] = [
        ("updateItem", .updateItem),
        ("refresh", .refresh),
        ("homebrewCheck", .homebrewCheck),
        ("startRun", .startRun),
        ("hideItem", .hideItem),
        ("unhideItem", .unhideItem),
        ("toolkitUpdateCheck", .toolkitUpdateCheck),
        ("migrateScan", .migrateScan),
        ("migrateItem", .migrateItem),
        ("engineOutdated", .engineOutdated)
    ]

    /// Every `Reason`, including one `reported` per token that has wording of
    /// its own plus the two that deliberately have none.
    private static let reasons: [(label: String, value: ToolkitController.ActionFailure.Reason)] = {
        var entries: [(String, ToolkitController.ActionFailure.Reason)] = [
            ("toolkitMissing", .toolkitMissing),
            ("output (raw shell)", .output("Error: alt-tab: undefined method\nzsh: exit 1")),
            ("noOutput", .noOutput),
            ("scanBusy", .scanBusy),
            ("itemGone", .itemGone),
            ("engineContract(nil) - declared nothing", .engineContract(found: nil)),
            ("engineContract(0) - too old", .engineContract(found: 0)),
            ("needsTerminal", .needsTerminal(detail: "sudo: a terminal is required to read the password"))
        ]

        for token in reportedTokens {
            let parsed = ItemRunResult.Reason(rawValue: token) ?? .unknown
            entries.append(("reported(.\(token))", .reported(parsed, detail: detail(for: token))))
        }

        // The two that carry no wording of their own: the printed detail has
        // to speak for both, and one of them has nothing to print either.
        entries.append(("reported(.commandFailed, empty detail)", .reported(.commandFailed, detail: "")))
        entries.append(("reported(unknown token)", .reported(.unknown, detail: "brew exited 1")))
        return entries
    }()

    /// The reason tokens from CACHE_FORMAT.md that have a sentence of their
    /// own in `ItemRunResult.Reason.label`.
    private static let reportedTokens = [
        "still-outdated", "timeout", "command-failed", "mas-disabled", "mas-missing",
        "not-pending", "not-installed", "setapp-managed", "no-direct-download",
        "download-failed", "extract-failed", "verify-failed", "replace-failed",
        "cask-not-found", "no-app-artifact", "needs-root", "target-mismatch",
        "adopt-version-mismatch", "install-failed", "restored-after-failure"
    ]

    private static func detail(for token: String) -> String {
        "Error: \(token) while running brew upgrade --cask alt-tab\nzsh: exit 1"
    }
}
