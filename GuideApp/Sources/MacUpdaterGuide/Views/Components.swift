import SwiftUI

/// A rounded icon tile in the style System Settings uses for its sections.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 52
    var tint: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: tint.opacity(0.25), radius: 4, y: 2)
            .accessibilityHidden(true)
    }
}

/// Grouped container matching the inset cards used across macOS settings UI.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}

/// The one place an action that failed with nothing else on screen to show it
/// gets said out loud - see `ToolkitController.lastFailure`.
///
/// Shaped like `ProgressBanner` on purpose: the two are the same kind of
/// message about the same kind of work, and appear in the same places. The
/// detail line is selectable, because the useful thing to do with a line of
/// brew output is paste it somewhere.
struct FailureBanner: View {
    @Environment(LocalizationStore.self) private var loc

    let failure: ToolkitController.ActionFailure
    let onDismiss: () -> Void
    var compact: Bool = false
    /// Called with the failure's own recovery when the user presses the
    /// button offering it. Absent where the surface showing the banner
    /// cannot act on one.
    var onRecover: ((ToolkitController.ActionFailure.Recovery) -> Void)?

    /// Shell output starts hidden. The headline above it is the app's own
    /// sentence saying what to do; the twelve lines brew printed are evidence
    /// for whoever wants them, and burying the instruction under them is how
    /// this banner stopped being read.
    @State private var showsEvidence = false

    private var headline: String? { failure.reason.headline(for: loc.language) }
    private var evidence: String { failure.reason.evidence }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(compact ? .body : .title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title(for: loc.language))
                    .font(compact ? .callout.weight(.medium) : .body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)

                // The app's own sentence, or - when there is none - the
                // output itself, because the only account there is never
                // gets hidden behind a toggle.
                Text(headline ?? evidence)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(compact ? 3 : 8)
                    .fixedSize(horizontal: false, vertical: true)

                if headline != nil, !evidence.isEmpty {
                    // No withAnimation: this banner also renders inside the
                    // MenuBarExtra(.window) panel, and an animated height
                    // change there crashes AppKit mid-transition. A plain
                    // toggle still redraws instantly; it just skips the
                    // slide.
                    Button {
                        showsEvidence.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .rotationEffect(.degrees(showsEvidence ? 90 : 0))
                            Text(UIStrings.failureDetails[loc.language])
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                    if showsEvidence {
                        Text(evidence)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }

                // Only for the failures the app knows a way out of, and only
                // ever as an offer: opening a terminal window is the user's
                // call to make, not something to do to them because an
                // update failed.
                if let recovery = failure.recovery, let onRecover {
                    Button(recovery.label(for: loc.language)) { onRecover(recovery) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(compact ? .small : .regular)
                        .padding(.top, 8)
                }
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(compact ? .body : .title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(UIStrings.dismissFailure[loc.language])
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.22), lineWidth: 0.5)
        }
    }
}

/// A single bullet, aligned so wrapped lines stay indented under the text.
struct BulletRow: View {
    let text: String
    var symbol: String = "circle.fill"
    var symbolSize: CGFloat = 5
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(tint)
                .frame(width: 14)
                .offset(y: -1)
                .accessibilityHidden(true)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Numbered step, for anything that has to happen in order.
struct StepRow: View {
    let index: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)

            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A single toggleable filter pill with a count badge - the "All / source /
/// category" row used above both the Installed Apps and CLI Tools lists.
struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            .font(.callout)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(isSelected ? tint : Color.secondary.opacity(0.12))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Note / caution box, tinted by role.
struct Callout: View {
    enum Role {
        case note
        case caution

        var symbol: String {
            switch self {
            case .note: return "info.circle.fill"
            case .caution: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .note: return .accentColor
            case .caution: return .orange
            }
        }
    }

    let role: Role
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: role.symbol)
                .font(.system(size: 15))
                .foregroundStyle(role.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(role.tint.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(role.tint.opacity(0.22), lineWidth: 0.5)
        }
    }
}
