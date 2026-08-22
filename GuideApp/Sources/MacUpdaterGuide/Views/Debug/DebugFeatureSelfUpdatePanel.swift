import CryptoKit
import Foundation
import SwiftUI

/// Local toolkit version against what the publisher is serving, and whether
/// the served copy matches its own SHA256SUMS.
///
/// Nothing is written to disk. The check fetches the remote
/// `update_system.1h.sh` into memory to read its `<bitbar.version>` header
/// and hash it - which is exactly what `check_for_updates_manual`
/// (lib/selfupdate.sh) does before it decides anything - and fetches
/// `SHA256SUMS` from the same base to compare against. Installing is a
/// separate button behind a confirmation, because that one really does
/// replace the engine this app is talking to.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugFeatureSelfUpdatePanel: View {
    @Environment(ToolkitController.self) private var toolkit
    @Environment(DebugLog.self) private var log

    @State private var settings = ToolkitSettings()
    @State private var results: [DebugFact] = []
    @State private var isChecking = false
    @State private var confirmingInstall = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Self-update")
                    .font(.headline)

                Text("""
                Fetches the remote script and SHA256SUMS into memory only - nothing is written and \
                nothing is installed. The same comparison lib/selfupdate.sh makes: version header \
                first, then hash.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                actions

                ForEach(results) { fact in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(fact.id)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 210, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.value)
                                .font(.callout.monospaced())
                                .foregroundStyle(fact.isProblem ? Color.orange : Color.primary)
                                .textSelection(.enabled)
                            if let detail = fact.detail {
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { settings.load() }
        .confirmationDialog(
            "Install the toolkit update?",
            isPresented: $confirmingInstall
        ) {
            Button("Install", role: .destructive) {
                log.note("toolkit.installToolkitUpdate()")
                toolkit.installToolkitUpdate()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("""
            Runs the engine's plugin mode, which downloads and replaces setup_mac.sh, uninstall.sh, \
            update_system.1h.sh and every lib/*.sh - the copy of the toolkit this app is talking to \
            changes underneath it. Only does anything when an update is already pending.
            """)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Check remote (no download)") {
                Task { await check() }
            }
            .disabled(isChecking)

            Button("checkToolkitUpdate() — engine's own check") {
                log.note("toolkit.checkToolkitUpdate() - the engine writes .plugin_update_pending itself")
                toolkit.checkToolkitUpdate()
            }

            Button("Install toolkit update", role: .destructive) {
                confirmingInstall = true
            }
            .tint(.red)

            if isChecking { ProgressView().controlSize(.small) }

            Text(toolkit.toolkitUpdatePending ? "pending flag set" : "no pending flag")
                .font(.caption)
                .foregroundStyle(toolkit.toolkitUpdatePending ? Color.orange : Color.secondary)

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    // MARK: - Checking

    private func check() async {
        isChecking = true
        defer { isChecking = false }

        let branch = settings.channel.rawValue
        var facts: [DebugFact] = [
            DebugFact(id: "Local version", value: ToolkitVersion.read(from: toolkit.scriptURL) ?? "unknown"),
            DebugFact(id: "Channel", value: branch, detail: "settings.conf UPDATE_BRANCH")
        ]

        let localHash = toolkit.scriptURL.flatMap { url in
            (try? Data(contentsOf: url)).map(Self.sha256)
        }
        facts.append(DebugFact(id: "Local SHA256", value: localHash ?? "unreadable", isProblem: localHash == nil))

        facts.append(contentsOf: await source(
            "GitHub",
            base: "https://raw.githubusercontent.com/dogukannparlak/mac_software_manager/\(branch)",
            localHash: localHash
        ))

        if let username = codebergUsername {
            facts.append(contentsOf: await source(
                "Codeberg",
                base: "https://codeberg.org/\(username)/mac_software_manager/raw/branch/\(branch)",
                localHash: localHash
            ))
        } else {
            facts.append(DebugFact(
                id: "Codeberg",
                value: "not configured",
                detail: "settings.conf CODEBERG_USERNAME is blank - no dual-source verification"
            ))
        }

        results = facts
        log.note("Self-update check finished against branch \(branch).")
    }

    private var codebergUsername: String? {
        let name = settings.codebergUsername
        return name.isEmpty || name == "YOUR_CODEBERG_USERNAME" ? nil : name
    }

    /// One publisher: its script's version, its hash, and whether its own
    /// SHA256SUMS agrees with the file it is serving.
    private func source(_ label: String, base: String, localHash: String?) async -> [DebugFact] {
        guard let scriptURL = URL(string: "\(base)/update_system.1h.sh"),
              let sumsURL = URL(string: "\(base)/SHA256SUMS") else {
            return [DebugFact(id: label, value: "bad URL", isProblem: true, detail: base)]
        }

        guard let body = await Self.fetch(scriptURL) else {
            return [DebugFact(id: label, value: "unreachable", isProblem: true, detail: scriptURL.absoluteString)]
        }

        let remoteHash = Self.sha256(body)
        let remoteVersion = Self.version(in: body) ?? "unreadable"
        let published = await Self.fetch(sumsURL).flatMap { Self.expectedHash(in: $0, for: "update_system.1h.sh") }

        var facts = [
            DebugFact(id: "\(label) version", value: remoteVersion, detail: scriptURL.absoluteString),
            DebugFact(
                id: "\(label) SHA256",
                value: remoteHash,
                detail: localHash == remoteHash ? "identical to the installed copy" : "differs from the installed copy"
            )
        ]

        if let published {
            facts.append(DebugFact(
                id: "\(label) SHA256SUMS",
                value: published == remoteHash ? "verified" : "MISMATCH",
                isProblem: published != remoteHash,
                detail: published
            ))
        } else {
            facts.append(DebugFact(
                id: "\(label) SHA256SUMS",
                value: "no entry for update_system.1h.sh",
                isProblem: true,
                detail: sumsURL.absoluteString
            ))
        }

        return facts
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same `<bitbar.version>` header `ToolkitVersion.read` looks for -
    /// read out of memory here rather than off disk.
    private static func version(in data: Data) -> String? {
        // Lossy on purpose: a stray byte anywhere in a 150 KB script must
        // not nil out the whole version check. The header this reads is
        // plain ASCII either way.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        for line in text.split(separator: "\n").prefix(12) {
            guard let open = line.range(of: "<bitbar.version>"),
                  let close = line.range(of: "</bitbar.version>") else { continue }
            return String(line[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: "v "))
        }
        return nil
    }

    /// SHA256SUMS lines are `<64 hex>  <filename>` - two spaces, per the
    /// format `shasum` writes and `lib/selfupdate.sh` parses.
    private static func expectedHash(in data: Data, for fileName: String) -> String? {
        // Lossy for the same reason as `version(in:)` above.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1] == fileName || parts[1].hasSuffix("/" + fileName) else { continue }
            return String(parts[0])
        }
        return nil
    }
}
