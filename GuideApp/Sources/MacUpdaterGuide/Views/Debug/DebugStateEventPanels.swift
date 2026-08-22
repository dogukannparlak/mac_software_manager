import SwiftUI

/// Drops one-shot records into `results/` and `notifications/`.
///
/// Neither directory is ever overwritten - injection only adds a file, named
/// with the `.debug.` marker `DebugStateStore` uses for cleanup. CACHE_FORMAT.md
/// says outright that these names carry no meaning and that readers must
/// iterate rather than parse them, which is what makes a distinctive name
/// safe here.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugStateResultsPanel: View {
    @Environment(DebugStateStore.self) private var store
    @Environment(DebugLog.self) private var log

    @State private var kind = "cask"
    @State private var identifier = "alt-tab"
    @State private var displayName = "AltTab"

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Single-item run results")
                    .font(.headline)

                Text("""
                v1|epoch|kind|id|name|status|reason, one file per finished run. A row resolves off \
                the newest record matching its kind+id that is not older than the run asking, and \
                deletes only that one.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                target
                Divider()
                successButtons
                reasonGroup("run single", Self.singleReasons)
                reasonGroup("run install", Self.installReasons)
                reasonGroup("migrate_app", Self.migrateReasons)
                Divider()
                edgeCases
            }
        }
    }

    private var target: some View {
        HStack(spacing: 8) {
            Picker("Kind", selection: $kind) {
                ForEach(Self.kinds, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 160)

            TextField("id", text: $identifier)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .frame(width: 180)

            TextField("name", text: $displayName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Spacer(minLength: 0)
        }
    }

    private var successButtons: some View {
        HStack(spacing: 8) {
            Button("ok (updated)") {
                drop(status: "ok", reason: "")
            }
            Button("ok + reason (contradictory)") {
                // Not a record the engine writes. Worth injecting anyway:
                // the reader takes `status` as the verdict and the reason as
                // a label, so this must read as a success, not a failure.
                drop(status: "ok", reason: "still-outdated")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private func reasonGroup(_ title: String, _ reasons: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(reasons, id: \.self) { reason in
                    Button(reason) { drop(status: "fail", reason: reason) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var edgeCases: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], alignment: .leading, spacing: 6) {
                Button("Unknown reason token") { drop(status: "fail", reason: "invented-by-a-newer-engine") }
                Button("Malformed: too few fields") { raw("v1|\(epoch())|\(kind)|\(identifier)\n") }
                Button("Malformed: wrong version") { raw("v2|\(epoch())|\(kind)|\(identifier)|\(displayName)|fail|timeout\n") }
                Button("Malformed: unknown status") { raw("v1|\(epoch())|\(kind)|\(identifier)|\(displayName)|maybe|\n") }
                Button("Stale: written an hour ago") {
                    drop(status: "ok", reason: "", at: Date().addingTimeInterval(-3600))
                }
                Button(".tmp file (write in flight)") { rawNamed("result", suffix: ".tmp") }
            }
            .controlSize(.small)

            Text("""
            The malformed three must all read as "no usable data" and leave the row to its fallback, \
            never as an outcome. The stale record must not answer for a run that started after it. \
            The .tmp file must be skipped and left alone.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            noRecordCases
        }
    }

    /// The two states that are an *absence* of a record rather than a record.
    private var noRecordCases: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Cancelled: leave no record") {
                    log.note("""
                    A cancelled run files nothing - ToolkitController.cancelItemUpdate clears the row \
                    itself. Nothing was written; press Update on a row and cancel it to see that path.
                    """)
                }
                Button("Guessed outcome (engine contract 0)") {
                    store.write(
                        DebugFixtures.engineContract(contract: 0, release: "1.4.0-debug"),
                        to: ToolkitPaths.engineFile,
                        log: log
                    )
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            Text("""
            An engine declaring less than contract \(EngineContract.required) files no result at all, \
            so the app falls back to re-reading the outdated list - a guess made by a reader that \
            never saw the run. That is what raises the engine-out-of-date banner instead of letting \
            the guess speak for the run.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Writing

    private func drop(status: String, reason: String, at date: Date = Date()) {
        raw(DebugFixtures.result(
            kind: kind,
            id: identifier,
            name: displayName,
            status: status,
            reason: reason,
            at: date
        ))
    }

    private func raw(_ contents: String) {
        store.drop(contents, into: ToolkitPaths.resultsDirectory, prefix: "result", log: log)
    }

    private func rawNamed(_ prefix: String, suffix: String) {
        let contents = DebugFixtures.result(kind: kind, id: identifier, name: displayName, status: "ok", reason: "")
        guard let url = store.drop(contents, into: ToolkitPaths.resultsDirectory, prefix: prefix, log: log) else {
            return
        }
        let renamed = URL(filePath: url.path(percentEncoded: false) + suffix)
        try? FileManager.default.moveItem(at: url, to: renamed)
        store.rescan()
        log.note("Renamed to \(renamed.lastPathComponent) - readers must skip this.")
    }

    private func epoch() -> String { String(Int(Date().timeIntervalSince1970)) }

    // MARK: - Tokens

    /// Straight from the `kind` and `reason` tables in CACHE_FORMAT.md,
    /// grouped by which shell path writes each one. Held as strings rather
    /// than built from `ItemRunResult.Reason`: a fixture is the *other* side
    /// of the contract, and one generated from the reader could never catch
    /// the reader drifting from the document.
    private static let kinds = ["brew", "cask", "mas", "app", "migrate"]

    private static let singleReasons = [
        "still-outdated", "timeout", "command-failed", "mas-disabled", "mas-missing"
    ]

    private static let installReasons = [
        "not-pending", "not-installed", "setapp-managed", "no-direct-download",
        "download-failed", "extract-failed", "verify-failed", "replace-failed"
    ]

    private static let migrateReasons = [
        "cask-not-found", "no-app-artifact", "needs-root", "target-mismatch",
        "adopt-version-mismatch", "install-failed", "restored-after-failure"
    ]
}

/// Drops notification requests and lets `NotificationBridge` pick them up.
///
/// This is the one panel whose result is not on screen in this app at all:
/// the bridge turns each file into a native alert, so a successful test is a
/// banner from macOS. A file that stays in the directory is the failure -
/// the bridge deletes what it reads, parseable or not.
struct DebugStateNotificationsPanel: View {
    @Environment(DebugStateStore.self) private var store
    @Environment(DebugLog.self) private var log

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notifications")
                    .font(.headline)

                Text("""
                v1|title|subtitle|body - pipe-delimited, not JSON. NotificationBridge watches the \
                directory with a kevent source and consumes each file as it appears, so these should \
                raise a real alert within a moment of being dropped.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], alignment: .leading, spacing: 6) {
                    Button("Update complete") {
                        drop(subtitle: "Update Complete", body: "3 package(s) updated successfully.")
                    }
                    Button("Finished with failures") {
                        drop(subtitle: "Update Finished", body: "2 of 4 items failed. See History for details.")
                    }
                    Button("Update failed") {
                        drop(subtitle: "Update Failed", body: "Homebrew failed to refresh after several retries.")
                    }
                    Button("Single item") {
                        drop(subtitle: "AltTab", body: "Updated to 6.19.0.")
                    }
                    Button("Empty subtitle and body") {
                        drop(subtitle: "", body: "")
                    }
                    Button("Emoji + Turkish") {
                        drop(subtitle: "Güncelleme Tamamlandı 🎉", body: "Şifre Kasası 🔐 sürüm 2.4.1'e güncellendi.")
                    }
                }
                .controlSize(.small)

                Divider()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], alignment: .leading, spacing: 6) {
                    Button("Malformed: wrong version") { raw("v2|Mac Software Manager|Update Complete|Body\n") }
                    Button("Malformed: too few fields") { raw("v1|Mac Software Manager|Update Complete\n") }
                    Button("Malformed: too many fields") { raw("v1|Title|Subtitle|Body|extra\n") }
                    Button("Malformed: not the format at all") { raw("{\"title\": \"nope\"}\n") }
                }
                .controlSize(.small)

                Text("""
                All four must be discarded and the file deleted anyway - a request that cannot be \
                parsed must not be retried forever on every write event.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func drop(subtitle: String, body: String) {
        raw(DebugFixtures.notification(title: DebugFixtures.notificationTitle, subtitle: subtitle, body: body))
    }

    private func raw(_ contents: String) {
        store.drop(contents, into: ToolkitPaths.notificationsDirectory, prefix: "notify", log: log)
    }
}
