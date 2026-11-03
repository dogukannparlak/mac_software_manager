import AppKit
import Foundation
import Observation

/// Keeps the app itself up to date from GitHub Releases.
///
/// Three stages, and only the last one touches the installed app:
///
/// 1. **Check** - `releases/latest` on GitHub. Once at launch (after a short
///    delay, so it never competes with drawing the first window) and then
///    once a day, while "Check automatically" is on; any time from the About
///    page.
/// 2. **Download and verify, in the background** - the release's `.zip` and
///    its `SHA256SUMS.txt`. The archive must match its published checksum,
///    unpack to an app with this app's bundle identifier and the version the
///    release claims, and pass `codesign --verify --deep --strict`. Anything
///    else is thrown away and reported; nothing is installed.
/// 3. **Install, only when asked** - "Restart and Update". Refused while any
///    update run is active or queued, so quitting cannot cut a `brew upgrade`
///    in half. A small helper script waits for this process to exit, moves
///    the current app aside, moves the new one into its place and relaunches
///    it. If the new one cannot be moved in, the old one is put back and
///    relaunched instead.
///
/// **What is never touched.** Settings live in UserDefaults (keyed by the
/// bundle identifier, which the update keeps) and everything else - cache,
/// history, ignored list, config - in `~/Library/Application Support/
/// MacSoftwareUpdater`, outside the bundle. Only the `.app` is swapped, and
/// the previous one is kept under `app-update/previous` rather than deleted.
@Observable
@MainActor
final class AppUpdater {

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String)
        case ready(version: String)
        case installing(version: String)
        case failed(Localized)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastCheck: Date?
    /// The release's GitHub page, for "What's new".
    private(set) var releasePage: URL?
    /// Set on the launch after an install whose new version did not come up:
    /// the helper restored the previous app (see `installLog` for why).
    private(set) var installDidNotTake: String?

    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Self.autoCheckKey) }
    }

    /// False while an update run is active or queued - installing means
    /// quitting, and quitting mid-run would leave a package half-upgraded.
    var canInstallNow: Bool { !toolkit.isUpdating }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var readyVersion: String? {
        if case .ready(let version) = phase { return version }
        return nil
    }

    // MARK: - Constants

    /// The name `tools/build_release.sh` gives the app and its archives.
    static let appName = "MacUpdaterGuide"
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/dogukannparlak/mac_software_manager/releases/latest"
    )!
    private static let autoCheckKey = "com.macupdater.guide.appUpdateAutoCheck"
    private static let pendingInstallKey = "com.macupdater.guide.appUpdatePendingVersion"
    private static let checkInterval: Duration = .seconds(24 * 60 * 60)
    private static let firstCheckDelay: Duration = .seconds(20)

    static var currentVersion: AppVersion? {
        AppVersion(ToolkitVersion.appVersion)
    }

    static var workDirectory: URL {
        ToolkitPaths.supportDirectory.appending(path: "app-update", directoryHint: .isDirectory)
    }
    private static var stagingDirectory: URL {
        workDirectory.appending(path: "staging", directoryHint: .isDirectory)
    }
    /// The app this one replaced - kept, not deleted, so a bad release can be
    /// rolled back by hand.
    static var previousAppURL: URL {
        workDirectory.appending(path: "previous/\(appName).app", directoryHint: .isDirectory)
    }
    static var installLog: URL {
        workDirectory.appending(path: "install.log")
    }

    // MARK: - State

    private let toolkit: ToolkitController
    private var stagedApp: URL?
    private var schedulerTask: Task<Void, Never>?

    init(toolkit: ToolkitController) {
        self.toolkit = toolkit
        checksAutomatically =
            (UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool) ?? true
    }

    // MARK: - Scheduling

    /// Starts the daily check. Idempotent: the app's window and menu bar both
    /// call it, and only the first call does anything.
    func start() {
        guard schedulerTask == nil else { return }
        confirmPreviousInstall()

        schedulerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                guard let self else { return }
                if self.checksAutomatically { await self.check() }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// The previous run started an install and quit. If this process is that
    /// new version, the install worked: clear the leftovers. If not, the
    /// helper rolled back - say so instead of silently offering it again.
    private func confirmPreviousInstall() {
        let defaults = UserDefaults.standard
        guard let attempted = defaults.string(forKey: Self.pendingInstallKey) else { return }
        defaults.removeObject(forKey: Self.pendingInstallKey)

        if let current = Self.currentVersion, let wanted = AppVersion(attempted), current >= wanted {
            try? FileManager.default.removeItem(at: Self.stagingDirectory)
        } else {
            installDidNotTake = attempted
        }
    }

    // MARK: - Check and download

    func check() async {
        guard !isBusy else { return }
        // A finished download is not thrown away just because it is checked
        // again; `stagedCopy` below picks it straight back up.
        phase = .checking

        do {
            let release = try await fetchLatestRelease()
            lastCheck = Date()

            guard let release,
                  let current = Self.currentVersion,
                  release.isInstallable(over: current, appName: Self.appName),
                  let version = release.version?.description else {
                stagedApp = nil
                try? FileManager.default.removeItem(at: Self.stagingDirectory)
                phase = .upToDate
                return
            }
            releasePage = release.pageURL

            if let staged = await stagedCopy(of: version) {
                stagedApp = staged
                phase = .ready(version: version)
                return
            }

            phase = .downloading(version: version)
            stagedApp = try await downloadAndVerify(release, version: version)
            phase = .ready(version: version)
        } catch let failure as UpdateFailure {
            stagedApp = nil
            phase = .failed(failure.message)
        } catch {
            stagedApp = nil
            phase = .failed(UpdateFailure.network.message)
        }
    }

    /// `nil` when the repository has no published release yet (GitHub answers
    /// 404 for that, not an empty body).
    private func fetchLatestRelease() async throws -> AppRelease? {
        let (data, response) = try await URLSession.shared.data(for: Self.request(Self.latestReleaseURL))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw UpdateFailure.network }
        do {
            return try AppRelease.decode(data)
        } catch {
            throw UpdateFailure.network
        }
    }

    private func downloadAndVerify(_ release: AppRelease, version: String) async throws -> URL {
        guard let archive = release.appArchive(appName: Self.appName),
              let checksumAsset = release.checksumFile else { throw UpdateFailure.checksumMissing }

        let fileManager = FileManager.default
        let staging = Self.stagingDirectory.appending(path: version, directoryHint: .isDirectory)
        try? fileManager.removeItem(at: Self.stagingDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        // The checksum first: an archive with nothing to check it against is
        // not worth downloading.
        let (sumsData, sumsResponse) = try await URLSession.shared.data(for: Self.request(checksumAsset.downloadURL))
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.network }
        let sums = ChecksumList.parse(String(decoding: sumsData, as: UTF8.self))
        guard let expected = sums[archive.name] else { throw UpdateFailure.checksumMissing }

        let (downloaded, response) = try await URLSession.shared.download(for: Self.request(archive.downloadURL))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? fileManager.removeItem(at: downloaded)
            throw UpdateFailure.network
        }
        let zip = staging.appending(path: archive.name)
        try fileManager.moveItem(at: downloaded, to: zip)

        let actual = try await Task.detached(priority: .utility) {
            try ChecksumList.sha256(of: zip)
        }.value
        guard actual == expected else {
            try? fileManager.removeItem(at: staging)
            throw UpdateFailure.checksumMismatch
        }

        // ditto, the same tool build_release.sh packed it with: it keeps the
        // bundle's symlinks and signature intact where a plain unzip may not.
        let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
        let status = await Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path(percentEncoded: false), unpacked.path(percentEncoded: false)])
        try? fileManager.removeItem(at: zip)
        guard status == 0 else {
            try? fileManager.removeItem(at: staging)
            throw UpdateFailure.unpackFailed
        }

        let app = unpacked.appending(path: "\(Self.appName).app", directoryHint: .isDirectory)
        do {
            try await Self.validate(app, expectedVersion: version)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return app
    }

    /// A download from an earlier check (or launch) that is still on disk
    /// and still passes every check.
    private func stagedCopy(of version: String) async -> URL? {
        let app = Self.stagingDirectory
            .appending(path: "\(version)/unpacked/\(Self.appName).app", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: app.path(percentEncoded: false)) else { return nil }
        do {
            try await Self.validate(app, expectedVersion: version)
            return app
        } catch {
            return nil
        }
    }

    /// The unpacked app must be this app, at the version the release claims,
    /// with an intact signature.
    private static func validate(_ app: URL, expectedVersion: String) async throws {
        guard let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == Bundle.main.bundleIdentifier else {
            throw UpdateFailure.wrongApp
        }
        guard let shortVersion = info["CFBundleShortVersionString"] as? String,
              let found = AppVersion(shortVersion),
              let wanted = AppVersion(expectedVersion),
              found == wanted else {
            throw UpdateFailure.wrongApp
        }
        let status = await runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path(percentEncoded: false)])
        guard status == 0 else { throw UpdateFailure.signatureInvalid }
    }

    // MARK: - Install

    /// Hands the swap to the helper and quits. Every reason it could fail is
    /// checked here, before anything is moved.
    func installAndRelaunch() {
        guard case .ready(let version) = phase, let staged = stagedApp else { return }
        // The buttons are disabled in this state and say why
        // (`UpdateFailure.busy`); this is the backstop, and it keeps the
        // download ready rather than turning it into a failure.
        guard canInstallNow else { return }

        let current = Bundle.main.bundleURL
        do {
            try Self.checkInstallLocation(current)
            try FileManager.default.createDirectory(
                at: Self.previousAppURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let script = Self.workDirectory.appending(path: "install.sh")
            try Self.helperScript.write(to: script, atomically: true, encoding: .utf8)

            let helper = Process()
            helper.executableURL = URL(filePath: "/bin/zsh")
            helper.arguments = [
                script.path(percentEncoded: false),
                String(ProcessInfo.processInfo.processIdentifier),
                current.path(percentEncoded: false),
                staged.path(percentEncoded: false),
                Self.previousAppURL.path(percentEncoded: false),
                Self.installLog.path(percentEncoded: false)
            ]
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
        } catch let failure as UpdateFailure {
            phase = .failed(failure.message)
            return
        } catch {
            phase = .failed(UpdateFailure.helperFailed.message)
            return
        }

        UserDefaults.standard.set(version, forKey: Self.pendingInstallKey)
        UserDefaults.standard.synchronize()
        phase = .installing(version: version)

        // A beat for the UI to show "Installing…" before the window goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    /// Places this app can run from but cannot be replaced in: a mounted
    /// disk image, Gatekeeper's randomized read-only copy (App Translocation)
    /// and a folder this user cannot write to. A SwiftPM build has no `.app`
    /// at all.
    private static func checkInstallLocation(_ app: URL) throws {
        let path = app.path(percentEncoded: false)
        guard app.pathExtension == "app" else { throw UpdateFailure.notInstallable }
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            throw UpdateFailure.notInstallable
        }
        let fileManager = FileManager.default
        guard fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path(percentEncoded: false)),
              fileManager.isWritableFile(atPath: path) else {
            throw UpdateFailure.notWritable
        }
    }

    /// Run detached after this app has asked to quit.
    ///
    /// Arguments: pid, installed app, staged new app, where to keep the old
    /// one, log file. Every step that can fail leaves a working app in the
    /// original place: the old one is only moved aside, never deleted, and
    /// moved back if the new one cannot take its place.
    static let helperScript = #"""
    #!/bin/zsh
    pid="$1" current="$2" staged="$3" previous="$4" log="$5"
    exec >>"$log" 2>&1
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') installing $staged"

    # Up to 30 s for the app to finish quitting.
    for i in {1..150}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "The app did not quit; nothing was changed."
        exit 1
    fi

    if [[ ! -d "$staged" ]]; then
        echo "The downloaded app is gone; nothing was changed."
        /usr/bin/open "$current"
        exit 1
    fi

    mkdir -p "${previous:h}"
    rm -rf "$previous"
    if ! mv "$current" "$previous"; then
        echo "Could not move the installed app aside; nothing was changed."
        /usr/bin/open "$current"
        exit 1
    fi

    if ! mv "$staged" "$current"; then
        echo "Could not move the new app into place; restoring the previous one."
        rm -rf "$current"
        mv "$previous" "$current"
        /usr/bin/open "$current"
        exit 1
    fi

    echo "Installed. Previous version kept at $previous"
    /usr/bin/open "$current"
    """#

    // MARK: - Helpers

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(appName)/\(ToolkitVersion.appVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Exit status of a short, non-interactive tool; -1 if it could not start.
    nonisolated private static func runTool(_ path: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let process = Process()
            process.executableURL = URL(filePath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}
