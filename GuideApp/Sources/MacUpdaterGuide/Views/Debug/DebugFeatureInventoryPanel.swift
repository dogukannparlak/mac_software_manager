import AppKit
import SwiftUI

/// The `/Applications` scan and the icon cache in front of it.
///
/// **What the icon numbers are and are not.** `AppIconCache` keeps no
/// counters and exposes no size, and adding them would be a change to
/// `Toolkit/` for a debug readout. So the hit rate here is measured rather
/// than reported: the same URLs are asked for twice and both passes are
/// timed. The first pass is misses by construction (whatever was not already
/// cached goes to `NSWorkspace`), the second is hits. The memory figure is
/// an estimate from that count at 32×32 RGBA - the size the cache sets on
/// every image it stores - not a reading of the dictionary.
///
/// There is no "clear icon cache" for the same reason: the dictionary is
/// private with no method to empty it. Quitting the app is the only clear
/// there is today.
///
/// English-only string literals - see the header of `DebugView.swift`.
struct DebugFeatureInventoryPanel: View {
    @Environment(InventoryStore.self) private var inventory
    @Environment(AppIconCache.self) private var icons
    @Environment(DebugLog.self) private var log

    @State private var loadSeconds: Double?
    @State private var iconResult: IconBenchmark?

    private struct IconBenchmark: Sendable {
        let count: Int
        let coldSeconds: Double
        let warmSeconds: Double

        /// 32×32 at 4 bytes a pixel is what `AppIconCache` sets on every
        /// image before storing it. The real backing store is a bitmap
        /// `NSImage` whose true footprint is larger; this is a floor, and it
        /// is labelled as one.
        var estimatedBytes: Int { count * 32 * 32 * 4 }

        var speedup: String {
            guard warmSeconds > 0 else { return "—" }
            return String(format: "%.0f×", coldSeconds / warmSeconds)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Installed apps / inventory")
                    .font(.headline)

                actions
                counts
                Divider()
                iconSection
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("InventoryStore.load()") {
                Task { await measureLoad(reload: false) }
            }
            .disabled(inventory.isLoading)

            Button("reload() — force rescan") {
                Task { await measureLoad(reload: true) }
            }
            .disabled(inventory.isLoading)

            if inventory.isLoading {
                ProgressView().controlSize(.small)
            }

            if let loadSeconds {
                Text(String(format: "%.3fs", loadSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var counts: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(InstallSource.allCases) { source in
                countRow(source.label.en, inventory.apps.filter { $0.source == source }.count)
            }
            Divider().padding(.vertical, 2)
            countRow("CLI tools", inventory.tools.count)
            countRow("Installed cask tokens", inventory.installedCaskTokens.count)
            countRow("Rule candidates (manual + homebrew)", inventory.ruleCandidates.count)
        }
    }

    private func countRow(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .frame(width: 280, alignment: .leading)
            Text("\(value)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("AppIconCache")
                    .font(.subheadline.weight(.medium))

                Button("Benchmark cold vs warm") {
                    benchmarkIcons()
                }
                .controlSize(.small)
                .disabled(inventory.apps.isEmpty)

                Spacer(minLength: 0)
            }

            if let result = iconResult {
                VStack(alignment: .leading, spacing: 2) {
                    countRow("Icons requested", result.count)
                    countRow("Cold pass (ms)", Int(result.coldSeconds * 1000))
                    countRow("Warm pass (ms)", Int(result.warmSeconds * 1000))
                    HStack(spacing: 8) {
                        Text("Speed-up / estimated size")
                            .font(.callout)
                            .frame(width: 280, alignment: .leading)
                        Text("\(result.speedup) / ≥ \(ByteCountFormatter.string(fromByteCount: Int64(result.estimatedBytes), countStyle: .memory))")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }

            Text("""
            The cache has no counters and no way to empty it, so this measures rather than reports: \
            the same icons are fetched twice and both passes are timed. The size is a floor derived \
            from the count, not a reading. Quitting the app is the only cache clear there is.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Measuring

    private func measureLoad(reload: Bool) async {
        let started = Date()
        if reload {
            await inventory.reload()
        } else {
            await inventory.load()
        }
        let elapsed = Date().timeIntervalSince(started)
        loadSeconds = elapsed
        log.note("""
        InventoryStore.\(reload ? "reload" : "load")() took \(String(format: "%.3f", elapsed))s: \
        \(inventory.apps.count) app(s), \(inventory.tools.count) CLI tool(s).
        """)
    }

    private func benchmarkIcons() {
        let urls = inventory.apps.map(\.self.url)
        guard !urls.isEmpty else { return }

        let coldStart = Date()
        for url in urls { _ = icons.icon(for: url) }
        let cold = Date().timeIntervalSince(coldStart)

        let warmStart = Date()
        for url in urls { _ = icons.icon(for: url) }
        let warm = Date().timeIntervalSince(warmStart)

        iconResult = IconBenchmark(count: urls.count, coldSeconds: cold, warmSeconds: warm)
        log.note("""
        Icon cache: \(urls.count) icon(s), cold \(String(format: "%.0f", cold * 1000))ms, \
        warm \(String(format: "%.0f", warm * 1000))ms.
        """)
    }
}
