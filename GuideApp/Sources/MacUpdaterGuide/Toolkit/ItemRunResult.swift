import Foundation

/// What one item's update run says about itself: which item, whether it
/// updated, and if it did not, why.
///
/// See CACHE_FORMAT.md ("Single-item run results") for the format this and
/// the shell writer (`result_write()` in lib/cache.sh) both agree on. The
/// point of it is that there is now one answer to "did that item update"
/// instead of three that could disagree - the history log's ok/fail, the
/// shared progress file's done/failed, and this app re-reading the outdated
/// list afterwards to see whether the item was still on it. Only the run
/// itself ever saw what happened; the list is a guess made afterwards, and it
/// is wrong whenever the cache was written a moment too late or the item is
/// legitimately still outdated after a partial upgrade.
///
/// Parsing is kept separate from the filesystem side (`ItemRunResultStore`
/// below), the same split `NotificationRequest`/`NotificationBridge` uses, so
/// the format can be unit-tested without touching disk.
struct ItemRunResult: Equatable, Sendable {

    /// Closed set: an unrecognized token makes `parse` reject the whole
    /// record rather than guess an outcome, exactly as `UpdateProgress` does
    /// with its `state`. A newer toolkit that adds one without bumping the
    /// version would otherwise have its runs read as something they are not.
    enum Status: String, Sendable {
        case ok
        case fail
    }

    /// Why the item did not update. Unlike `Status` this *does* fall back
    /// (`.unknown`): a reason is a label to print, not a verdict on the run -
    /// the same rule `UpdateProgress.Phase` follows.
    enum Reason: String, Sendable {
        /// Written on a successful run: there is nothing to explain.
        case none = ""
        /// The upgrade command reported success, but the item is still on the
        /// outdated list afterwards - the shell verifies, it does not trust
        /// an exit code.
        case stillOutdated = "still-outdated"
        /// `mas` was killed at `MAS_UPGRADE_TIMEOUT` (lib/utils.sh) - the
        /// download outran the hang guard, which is not the same as the App
        /// Store refusing it.
        case timedOut = "timeout"
        /// brew/mas exited non-zero. The run's stderr is the detail.
        case commandFailed = "command-failed"
        case masDisabled = "mas-disabled"
        case masMissing = "mas-missing"
        /// The install path found no pending update recorded for the app.
        case notPending = "not-pending"
        case notInstalled = "not-installed"
        case setappManaged = "setapp-managed"
        /// Only a .pkg or a download page was on offer, so the page was
        /// opened instead. The run exits 0, but nothing was installed.
        case noDirectDownload = "no-direct-download"
        case downloadFailed = "download-failed"
        case extractFailed = "extract-failed"
        case verifyFailed = "verify-failed"
        case replaceFailed = "replace-failed"
        // The migration reasons (kind "migrate", lib/migrate.sh). The first
        // four are the states the engine refuses on before running anything -
        // it re-derives them from a fresh `brew info` rather than trusting the
        // scan's cache entry, so a row that looked movable an hour ago can
        // still come back with one of these.
        /// No cask by that token exists, or the bundle is not where the scan
        /// recorded it.
        case caskNotFound = "cask-not-found"
        /// The cask installs a package rather than an app bundle: nothing to
        /// adopt, nothing to put back.
        case noAppArtifact = "no-app-artifact"
        /// The cask needs an administrator, which a headless run has nowhere
        /// to ask for.
        case needsRoot = "needs-root"
        /// The cask installs somewhere other than where the app is - adopting
        /// would leave a second copy rather than take this one over.
        case targetMismatch = "target-mismatch"
        /// `--adopt` refused because the installed copy is not the version the
        /// cask ships. Nothing was changed, and a replace would work.
        case adoptVersionMismatch = "adopt-version-mismatch"
        /// Homebrew could not install the cask, and nothing had been moved
        /// aside.
        case installFailed = "install-failed"
        /// A replace failed and the original application was moved back into
        /// place. Nothing changed.
        case restoredAfterFailure = "restored-after-failure"
        /// A token this build does not know, from a newer toolkit.
        case unknown

        /// Wording for the reasons the app can put into a sentence. `nil`
        /// where there is nothing worth saying beyond what the run printed:
        /// `.none` (it succeeded), `.unknown` (a token with no copy here),
        /// and `.commandFailed`, whose whole content is the stderr that came
        /// with it.
        var label: Localized? {
            switch self {
            case .none, .unknown, .commandFailed:
                return nil
            case .stillOutdated:
                return Localized(
                    "The update ran, but the package is still listed as outdated.",
                    "Güncelleme çalıştı, ancak paket hâlâ güncel değil olarak listeleniyor."
                )
            case .timedOut:
                return Localized(
                    "The download was still going when the time limit ran out.",
                    "Süre sınırı dolduğunda indirme hâlâ sürüyordu."
                )
            case .masDisabled:
                return Localized(
                    "App Store updates are turned off.",
                    "App Store güncellemeleri kapalı."
                )
            case .masMissing:
                return Localized(
                    "The 'mas' command is not installed, so App Store apps cannot be updated.",
                    "'mas' komutu kurulu değil, bu yüzden App Store uygulamaları güncellenemiyor."
                )
            case .notPending:
                return Localized(
                    "No pending update was recorded for this app. Refresh and try again.",
                    "Bu uygulama için bekleyen bir güncelleme kayıtlı değil. Yenileyip tekrar deneyin."
                )
            case .notInstalled:
                return Localized(
                    "The application was not found in /Applications.",
                    "Uygulama /Applications içinde bulunamadı."
                )
            case .setappManaged:
                return Localized(
                    "Setapp manages this application. Update it from Setapp.",
                    "Bu uygulamayı Setapp yönetiyor. Güncellemeyi Setapp üzerinden yapın."
                )
            case .noDirectDownload:
                return Localized(
                    "No direct download is available, so the download page was opened instead.",
                    "Doğrudan indirme bağlantısı yok, bunun yerine indirme sayfası açıldı."
                )
            case .downloadFailed:
                return Localized("The download failed.", "İndirme başarısız oldu.")
            case .extractFailed:
                return Localized(
                    "The downloaded archive did not contain a single application.",
                    "İndirilen arşivde tek bir uygulama bulunamadı."
                )
            case .verifyFailed:
                return Localized(
                    "The downloaded application failed verification, so nothing was changed.",
                    "İndirilen uygulama doğrulamayı geçemedi, hiçbir şey değiştirilmedi."
                )
            case .replaceFailed:
                return Localized(
                    "The application could not be replaced. The previous version was restored.",
                    "Uygulama değiştirilemedi. Önceki sürüm geri yüklendi."
                )
            case .caskNotFound:
                return Localized(
                    "Homebrew has no cask by that name, or the application is no longer where it was found.",
                    "Homebrew'de bu adda bir cask yok veya uygulama bulunduğu yerde değil."
                )
            case .noAppArtifact:
                return Localized(
                    "That cask installs a package rather than an application, so there is nothing for Homebrew to take over.",
                    "Bu cask bir uygulama yerine yükleyici kuruyor, dolayısıyla Homebrew'in devralabileceği bir şey yok."
                )
            case .needsRoot:
                return Localized(
                    "That cask needs an administrator password, which a background run has nowhere to ask for.",
                    "Bu cask yönetici parolası gerektiriyor; arka planda çalışan bir işlemin bunu soracağı bir yer yok."
                )
            case .targetMismatch:
                return Localized(
                    "The cask installs to a different location, so moving the app would leave a second copy behind.",
                    "Cask farklı bir konuma kuruyor, bu yüzden taşımak geride ikinci bir kopya bırakır."
                )
            case .adoptVersionMismatch:
                return Localized(
                    "The installed copy is not the version the cask ships, so Homebrew would not take it over. Nothing was changed.",
                    "Kurulu kopya cask'in getirdiği sürüm değil, bu yüzden Homebrew devralmadı. Hiçbir şey değiştirilmedi."
                )
            case .installFailed:
                return Localized(
                    "Homebrew could not install the cask. Nothing was changed.",
                    "Homebrew cask'i kuramadı. Hiçbir şey değiştirilmedi."
                )
            case .restoredAfterFailure:
                return Localized(
                    "The install failed and the original application was put back. Nothing changed.",
                    "Kurulum başarısız oldu ve özgün uygulama geri kondu. Hiçbir şey değişmedi."
                )
            }
        }
    }

    /// When the run wrote this record. Whole seconds - it comes from the
    /// shell's `EPOCHSECONDS`.
    let recordedAt: Date
    /// `brew`, `cask`, `mas`, `app` or `migrate`: what the run was invoked as,
    /// not a re-derived source. `candidateItemIDs` maps it back to this app's
    /// own item identity.
    let kind: String
    /// Formula/cask token, App Store id, or application name.
    let id: String
    let name: String
    let status: Status
    let reason: Reason

    var succeeded: Bool { status == .ok }

    /// The only format version this build understands. See CACHE_FORMAT.md -
    /// the shell writer (`RESULT_FORMAT_VERSION` in lib/cache.sh) and this
    /// must agree, or `parse` fails closed instead of misreading.
    static let formatVersion = "v1"

    /// `v1|epoch|kind|id|name|status|reason`
    ///
    /// Fails closed on anything it cannot read whole - a missing/unknown
    /// version, a short line, an unparseable timestamp, an unknown status.
    /// `nil` means "no usable data", which every caller treats as "fall back
    /// to the old check", never as an outcome.
    static func parse(raw: String) -> ItemRunResult? {
        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard fields.count == 7, fields[0] == formatVersion else { return nil }
        guard let epoch = TimeInterval(fields[1]) else { return nil }
        guard let status = Status(rawValue: fields[5]) else { return nil }

        return ItemRunResult(
            recordedAt: Date(timeIntervalSince1970: epoch),
            kind: fields[2],
            id: fields[3],
            name: fields[4],
            status: status,
            reason: Reason(rawValue: fields[6]) ?? .unknown
        )
    }

    /// The `UpdateItem.id`s this record could belong to.
    ///
    /// The shell knows the run by the arguments it was given, not by this
    /// app's item ids, so the mapping lives here. `mas` has two candidates
    /// because one kind covers two sources: an App Store app `mas outdated`
    /// reports (`mas:`) and an Apple app it misses that the iTunes lookup
    /// found instead (`manual:`) - both are updated by the same command with
    /// the same numeric id. A kind this build does not know matches nothing,
    /// so the record is left alone rather than attached to the wrong row.
    /// `migrate` is keyed on the cask token the app was being moved to, which
    /// is what `migrate_app` files as its `id` - the Move to Homebrew page
    /// uses `migrate:<token>` for the row waiting on it. The token is what the
    /// run was about; the app name rides along in `name`.
    var candidateItemIDs: [String] {
        switch kind {
        case "brew", "cask": return ["brew:\(id)"]
        case "mas": return ["mas:\(id)", "manual:\(id)"]
        case "app": return ["app:\(id)"]
        case "migrate": return ["migrate:\(id)"]
        default: return []
        }
    }

    func matches(itemID: String) -> Bool {
        candidateItemIDs.contains(itemID)
    }

    /// Whether this record can be the account of the run that is asking:
    /// right item, and not written before that run started.
    ///
    /// The timestamp check is what keeps an unconsumed record from an
    /// earlier run of the same item - one started from a terminal window,
    /// one cancelled after it had already filed its outcome - from
    /// answering for this one. It is kept here, next to the format it
    /// depends on, rather than inside the directory walk, so the rule can be
    /// tested without a filesystem.
    func belongs(toRun itemID: String, startedAt: Date) -> Bool {
        guard matches(itemID: itemID) else { return false }
        return recordedAt >= startedAt.addingTimeInterval(-ItemRunResultStore.timestampGranularity)
    }
}

/// The `results/` directory: one file per finished single-item run, dropped
/// by the shell engine and consumed here.
///
/// A directory rather than one shared file because several single-item runs
/// can be in flight at once (Settings → General → concurrent updates), and a
/// run must be able to report its own outcome without overwriting anybody
/// else's - the same reason those runs skip the shared progress file
/// entirely. See CACHE_FORMAT.md ("Single-item run results").
enum ItemRunResultStore {

    /// A record's timestamp is whole seconds while the run's start date is
    /// not, so a record written in the same second the run started can read
    /// as one second *older* than the run. Anything more than that really is
    /// from an earlier run.
    static let timestampGranularity: TimeInterval = 1

    /// The newest record for `itemID` that this run could have written,
    /// removing it from disk as it is read.
    ///
    /// `since` is when the run started: an older record belongs to an earlier
    /// run of the same item that nobody consumed (one started from a terminal
    /// window, or one that was cancelled after it had already reported), and
    /// letting it answer for this run would report an outcome that is not
    /// this one's. Those are left where they are - the shell prunes them by
    /// age (`result_prune`, lib/cache.sh) - because only the run that
    /// matched a record may delete it: a scan on one row must never consume
    /// another row's report.
    @discardableResult
    static func consume(itemID: String, since: Date) -> ItemRunResult? {
        let directory = ToolkitPaths.resultsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        var best: (url: URL, result: ItemRunResult)?

        for fileURL in entries {
            // A record is written to "<name>.tmp" and renamed into place, so
            // a .tmp entry is a write still in progress - not this run's
            // business to read or to delete. Nothing else about the name
            // carries meaning; the content is the record.
            guard !fileURL.lastPathComponent.hasSuffix(".tmp") else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let raw = String(data: data, encoding: .utf8),
                  let result = ItemRunResult.parse(raw: raw),
                  result.belongs(toRun: itemID, startedAt: since) else { continue }

            if let current = best, current.result.recordedAt >= result.recordedAt { continue }
            best = (fileURL, result)
        }

        guard let best else { return nil }
        try? FileManager.default.removeItem(at: best.url)
        return best.result
    }
}
