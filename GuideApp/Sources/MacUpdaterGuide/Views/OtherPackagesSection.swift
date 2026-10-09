import AppKit
import SwiftUI

/// The CLI Tools page's "Beyond Homebrew" part: one card per source (npm,
/// pipx, uv, Cargo, Go, standalone tools, app shims, installer packages),
/// below the Homebrew categories that stay the primary list.
struct OtherPackagesSection: View {
    @Environment(LocalizationStore.self) private var loc

    let packages: [OtherPackage]

    private var groups: [(source: PackageSource, packages: [OtherPackage])] {
        Dictionary(grouping: packages, by: \.source)
            .map { source, members in
                (source: source,
                 packages: members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
            .sorted { $0.source.sortRank < $1.source.sortRank }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.teal)
                Text(UIStrings.otherSourcesSection[loc.language])
                    .font(.headline)
                Text("\(packages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)

            ForEach(groups, id: \.source) { group in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: group.source.symbol)
                            .foregroundStyle(.secondary)
                        Text(group.source.label[loc.language])
                            .font(.subheadline.weight(.semibold))
                        Text("\(group.packages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Card {
                        VStack(spacing: 0) {
                            ForEach(Array(group.packages.enumerated()), id: \.element.id) { index, package in
                                if index > 0 { Divider().padding(.vertical, 2) }
                                OtherPackageRow(package: package)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One package: name, where it lives, version - or the pending update with an
/// Update button, for the sources that can say so (npm today).
private struct OtherPackageRow: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit

    let package: OtherPackage

    /// The second line: what the package belongs to or where it is.
    private var detail: String? {
        guard let location = package.location else { return nil }
        switch package.source {
        case .app:
            let app = URL(filePath: location).deletingPathExtension().lastPathComponent
            return "\(app) · \(UIStrings.partOfApp[loc.language])"
        case .local, .pkg, .go:
            return (location as NSString).abbreviatingWithTildeInPath
        case .npm, .pipx, .uv, .cargo:
            return nil
        }
    }

    /// A file Finder can point at, for the sources that carry one.
    private var revealURL: URL? {
        guard let location = package.location,
              [.app, .local].contains(package.source),
              FileManager.default.fileExists(atPath: location)
        else { return nil }
        return URL(filePath: location)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: package.source == .pkg ? "archivebox" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if let latest = package.latestVersion {
                HStack(spacing: 6) {
                    Text(package.version)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(latest)
                }
                .font(.callout.monospacedDigit())
                .lineLimit(1)

                Button(UIStrings.updateThis[loc.language]) {
                    toolkit.updateTool(package)
                }
                .buttonStyle(.bordered)
                .disabled(toolkit.isUpdating)
            } else {
                Text(package.version.isEmpty ? "—" : package.version)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            if package.source.isUpdatable {
                Button(UIStrings.updateInTerminal[loc.language]) {
                    toolkit.updateTool(package)
                }
                .disabled(toolkit.isUpdating)
            }

            if let revealURL {
                Button(UIStrings.showInFinder[loc.language]) {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
            }

            Button(UIStrings.copyName[loc.language]) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(package.name, forType: .string)
            }
        }
    }
}
