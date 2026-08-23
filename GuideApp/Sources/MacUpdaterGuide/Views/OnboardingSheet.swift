import SwiftUI

/// The sheet that gets a fresh Mac working.
///
/// What it replaces: an app that started, found no engine, and said "the
/// engine is not installed" - with no account of what an engine is, where it
/// comes from, or what to do about it beyond finding a terminal and a README.
/// Everything the setup needs is a command someone else could have run for
/// you, so now the app runs it.
///
/// Two things it deliberately does not do. It never traps the user: "Later"
/// is enabled at all times, including mid-install, and the app behind it works
/// as well as it can without the missing pieces. And it never asks for a
/// password - see `BootstrapInstaller` for why that is not a convenience it
/// gave up on but the point of the design.
struct OnboardingSheet: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(ToolkitController.self) private var toolkit
    @Environment(OnboardingStore.self) private var onboarding

    /// The installer's own output starts hidden. It is evidence for whoever
    /// wants it; the rows above are the answer.
    @State private var showsLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    dependencyCard
                    if onboarding.installing == .homebrew {
                        Callout(role: .note, text: UIStrings.onboardingWaitingForHomebrew[loc.language])
                    }
                    if let failure = onboarding.failure {
                        Callout(role: .caution, text: failure[loc.language])
                    }
                    passwordNote
                    logSection
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: "sparkles", tint: .accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(UIStrings.onboardingTitle[loc.language])
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var subtitle: String {
        onboarding.hasBlockingGap
            ? UIStrings.onboardingIntro[loc.language]
            : UIStrings.onboardingAllSet[loc.language]
    }

    // MARK: - Rows

    private var dependencyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Dependency.allCases) { dependency in
                    row(for: dependency)
                    if dependency != Dependency.allCases.last { Divider() }
                }
            }
        }
    }

    private func row(for dependency: Dependency) -> some View {
        let state = onboarding.states[dependency] ?? .checking
        let isBusy = onboarding.installing == dependency

        return HStack(alignment: .top, spacing: 12) {
            statusIcon(for: state, dependency: dependency, isBusy: isBusy)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dependency.title[loc.language])
                        .font(.body.weight(.medium))
                    if !dependency.isRequired {
                        Text(UIStrings.onboardingOptional[loc.language])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }

                Text(statusLine(for: state, dependency: dependency, isBusy: isBusy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            rowButton(for: dependency, state: state)
        }
    }

    @ViewBuilder
    private func statusIcon(for state: DependencyState, dependency: Dependency, isBusy: Bool) -> some View {
        if isBusy || state.isChecking {
            ProgressView().controlSize(.small)
        } else {
            switch state {
            case .satisfied:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .missing, .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    // An optional row that is absent is information, not a
                    // warning - colouring it the same orange as a missing
                    // engine says the app is broken when it is not.
                    .foregroundStyle(dependency.isRequired ? .orange : .secondary)
            case .checking:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func statusLine(for state: DependencyState, dependency: Dependency, isBusy: Bool) -> String {
        if isBusy {
            return UIStrings.onboardingInstalling[loc.language]
        }
        switch state {
        case .checking:
            return UIStrings.onboardingChecking[loc.language]
        case .satisfied(let detail):
            return detail
        case .missing:
            return "\(UIStrings.onboardingNotInstalled[loc.language]) — \(dependency.detail[loc.language])"
        case .failed(let detail):
            return detail
        }
    }

    @ViewBuilder
    private func rowButton(for dependency: Dependency, state: DependencyState) -> some View {
        if state.needsAction {
            Button(rowButtonTitle(for: dependency)) {
                onboarding.install(dependency, toolkit: toolkit)
            }
            .controlSize(.small)
            .disabled(onboarding.isInstalling)
        }
    }

    /// Homebrew's button says what actually happens, because what happens is
    /// not what "Install" promises anywhere else on this sheet: a window
    /// opens and the user does the installing.
    private func rowButtonTitle(for dependency: Dependency) -> String {
        dependency.isInstalledInApp
            ? UIStrings.onboardingInstall[loc.language]
            : UIStrings.onboardingOpenTerminal[loc.language]
    }

    // MARK: - Notes and log

    private var passwordNote: some View {
        Text(UIStrings.onboardingNoPasswordNote[loc.language])
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var logSection: some View {
        if !onboarding.log.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showsLog.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showsLog ? 90 : 0))
                        Text(UIStrings.failureDetails[loc.language])
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showsLog {
                    // Selectable, because the useful thing to do with a line
                    // of brew output is paste it somewhere.
                    Text(onboarding.log.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if onboarding.isInstalling {
                Button(UIStrings.cancelUpdate[loc.language]) { onboarding.cancel() }
            }

            Spacer()

            // Always enabled, including mid-install: a setup sheet that holds
            // the app hostage until it succeeds is worse than the missing
            // engine it is offering to fix.
            Button(dismissTitle) {
                if onboarding.hasBlockingGap {
                    onboarding.skip()
                } else {
                    onboarding.close()
                }
            }
            .keyboardShortcut(.cancelAction)

            if !DependencyCheck.installable(from: onboarding.states).isEmpty {
                Button(primaryTitle) {
                    onboarding.installMissing(toolkit: toolkit)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(onboarding.isInstalling)
            }
        }
        .padding(18)
    }

    private var dismissTitle: String {
        onboarding.hasBlockingGap
            ? UIStrings.onboardingLater[loc.language]
            : UIStrings.onboardingDone[loc.language]
    }

    /// "Try Again" after a failure, because pressing a button labelled
    /// "Install What's Missing" a second time gives no sign that it was heard.
    private var primaryTitle: String {
        onboarding.failure == nil
            ? UIStrings.onboardingInstallMissing[loc.language]
            : UIStrings.onboardingRetry[loc.language]
    }
}
