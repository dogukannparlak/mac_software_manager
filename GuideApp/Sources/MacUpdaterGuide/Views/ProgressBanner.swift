import SwiftUI

/// Names what an update run is doing right now, and - where the caller wires
/// up `onCancel` - offers a way to stop it without switching to a terminal.
struct ProgressBanner: View {
    @Environment(LocalizationStore.self) private var loc

    let progress: UpdateProgress
    var compact: Bool = false
    /// Only passed where there is a real process to stop (the full Updates
    /// page) - the menu bar's copy of this banner stays read-only, as
    /// documented on `MenuBarView`.
    var onCancel: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            indicator

            VStack(alignment: .leading, spacing: 2) {
                Text(progress.title(for: loc.language))
                    .font(compact ? .callout.weight(.medium) : .body.weight(.medium))
                    .lineLimit(1)

                if let detail = progress.detail(for: loc.language) {
                    Text(detail)
                        .font(compact ? .caption : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Terminal output used to be the fallback proof that something
                // was still happening during phases with no package count to
                // show (refreshing Homebrew, cleaning up, verifying results).
                // With no terminal by default, this bar has to carry that on
                // its own - determinate when a count is known, indeterminate
                // otherwise, but always present while running.
                if progress.isRunning {
                    Group {
                        if let fraction = progress.fractionCompleted {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: compact ? 220 : 320)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            if progress.isRunning, let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(compact ? .body : .title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(UIStrings.cancelUpdate[loc.language])
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch progress.state {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
        }
    }

    private var tint: Color {
        switch progress.state {
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .orange
        }
    }
}
