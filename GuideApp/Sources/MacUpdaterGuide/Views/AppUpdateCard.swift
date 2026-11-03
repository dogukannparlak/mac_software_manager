import SwiftUI

/// The About page's "App Updates" card - the one place `AppUpdater` is
/// driven by hand. The menu bar only ever shows its finished state (a
/// download ready to install), never the progress.
struct AppUpdateCard: View {
    @Environment(LocalizationStore.self) private var loc
    @Environment(AppUpdater.self) private var updater
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var updater = updater

        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(UIStrings.appUpdateTitle[loc.language])
                    .font(.headline)

                if let version = updater.installDidNotTake {
                    Label(
                        String(format: UIStrings.appUpdateDidNotTakeFormat[loc.language], version),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                status

                if let version = updater.readyVersion {
                    Button {
                        updater.installAndRelaunch()
                    } label: {
                        Label(
                            String(format: UIStrings.appUpdateInstallFormat[loc.language], version),
                            systemImage: "arrow.down.app"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.canInstallNow)

                    if !updater.canInstallNow {
                        Text(UpdateFailure.busy.message[loc.language])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await updater.check() }
                    } label: {
                        Label(UIStrings.appUpdateCheckNow[loc.language], systemImage: "arrow.clockwise")
                    }
                    .disabled(updater.isBusy)

                    if let page = updater.releasePage, updater.readyVersion != nil {
                        Button(UIStrings.appUpdateWhatsNew[loc.language]) {
                            openURL(page)
                        }
                    }

                    Spacer()
                }

                Toggle(UIStrings.appUpdateAutoCheck[loc.language], isOn: $updater.checksAutomatically)

                Text(UIStrings.appUpdateHelp[loc.language])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(UIStrings.appUpdateChecking[loc.language])
            }
            .foregroundStyle(.secondary)
        case .upToDate:
            Label(UIStrings.appUpdateUpToDate[loc.language], systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading(let version):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(format: UIStrings.appUpdateDownloadingFormat[loc.language], version))
            }
            .foregroundStyle(.secondary)
        case .ready(let version):
            Label(
                String(format: UIStrings.appUpdateReadyFormat[loc.language], version),
                systemImage: "arrow.down.circle.fill"
            )
            .foregroundStyle(.orange)
        case .installing(let version):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(format: UIStrings.appUpdateInstallingFormat[loc.language], version))
            }
        case .failed(let message):
            Label(message[loc.language], systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
