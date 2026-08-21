import Foundation

/// An application Homebrew does not manage but could, and what would happen if
/// it were handed over.
///
/// See CACHE_FORMAT.md ("`migration_candidates`") for the format this and the
/// shell writer (`migration_scan()` in lib/migrate.sh) both agree on.
///
/// Everything here was decided **without running anything**: the engine reads
/// the cask's own JSON metadata and the installed bundle's `Info.plist`, so a
/// scan never downloads, installs or moves a thing. That is what makes it safe
/// to show the whole list up front and let the user pick.
///
/// The entry carries no TTL and is written only when the user asks for a scan -
/// it costs one `brew info` round trip per candidate token across every
/// unmanaged app on the machine. Readers must treat it as a snapshot of
/// whenever it was taken, not as current state, which is also why
/// `migrate_app` re-derives the state from a fresh `brew info` rather than
/// trusting this.
struct MigrationCandidate: Identifiable, Equatable, Sendable {

    /// How sure the pairing between this app and this cask is.
    ///
    /// Closed set, and deliberately not falling back: an unknown token means
    /// the record came from a newer engine, and the one thing a reader must
    /// never do is present an unverified pairing as a verified one. `parse`
    /// rejects the whole line instead - the same rule `UpdateProgress` applies
    /// to `state` and `ItemRunResult` to `status`.
    enum Match: String, Sendable {
        /// A hand-written `app_token_map.conf` entry. The user stated the
        /// answer; nothing is guessed after it.
        case override
        /// The cask installs a bundle whose file name is exactly the
        /// installed `.app`'s.
        case artifact
        /// The cask names this exact `CFBundleIdentifier` in its `uninstall`
        /// `quit`/`launchctl` list - written by the cask author against the
        /// real application.
        case bundle
        /// A token derived from the app's name resolved to *a* cask, and that
        /// is all that is known. The weakest match, and the one to show as
        /// unverified.
        case token

        /// Whether this pairing is evidence about the application itself
        /// rather than about its name.
        ///
        /// `override` counts because a person wrote it down on purpose;
        /// `artifact` and `bundle` because the cask's own metadata names this
        /// exact bundle. `token` is the one that does not, and it is exactly
        /// the kind of match that pairs an app with an unrelated cask - the
        /// engine's own comment cites "ClearDisk" resolving to "clearvpn".
        var isVerified: Bool { self != .token }

        var label: Localized {
            switch self {
            case .override:
                return Localized(
                    "You mapped this name to this cask by hand.",
                    "Bu adı bu cask'e elle siz eşlediniz."
                )
            case .artifact:
                return Localized(
                    "The cask installs an application with exactly this file name.",
                    "Cask tam olarak bu dosya adına sahip bir uygulama kuruyor."
                )
            case .bundle:
                return Localized(
                    "The cask names this application's exact bundle identifier.",
                    "Cask bu uygulamanın tam bundle kimliğini adıyla anıyor."
                )
            case .token:
                return Localized(
                    "Matched only by a name guess - nothing confirms this is the same application.",
                    "Yalnızca ad tahminiyle eşleşti - bunun aynı uygulama olduğunu doğrulayan bir şey yok."
                )
            }
        }
    }

    /// What migrating would do, worked out from metadata alone.
    ///
    /// Unlike `Match` this *does* fall back to `.unknown`, following
    /// `ItemRunResult.Reason`: a state is a label plus a decision about which
    /// section to file the row under, and an unknown one from a newer engine
    /// belongs in "cannot be moved" - never in the actionable list. Rejecting
    /// the whole record over it would instead hide an app the user can see on
    /// disk.
    enum State: String, Sendable {
        /// `brew install --cask --adopt` should succeed.
        case adoptable
        /// There is an app artifact, but the versions do not line up, so
        /// `--adopt` will refuse. A replace would work.
        case versionMismatch = "version-mismatch"
        /// The cask installs no `.app` (a pkg or installer cask such as
        /// `logitech-g-hub`). There is nothing to adopt and nothing to put
        /// back: not migratable.
        case noAppArtifact = "no-app-artifact"
        /// An installer script declaring `sudo`, or a target under
        /// `/Library`. The engine does not escalate - a headless run has no
        /// tty for a password prompt.
        case needsRoot = "needs-root"
        /// The cask installs somewhere other than where the app already is.
        /// The `~/Applications` trap: adopting does not *move* a bundle, it
        /// installs a second copy at the cask's target and leaves the
        /// original where it was.
        case targetMismatch = "target-mismatch"
        /// The cask is deprecated or disabled. A disabled cask cannot be
        /// installed at all, so nothing else matters.
        case deprecated
        /// A state this build does not know, from a newer engine. Treated as
        /// not actionable, never as `.adoptable`.
        case unknown

        /// Whether the app can be handed over with a plain adopt.
        var isAdoptable: Bool { self == .adoptable }

        /// Whether migrating is possible at all but wants the user to look
        /// first - the version does not line up, so an adopt is refused and a
        /// replace is the only route.
        var needsConfirmation: Bool { self == .versionMismatch }

        /// Everything the user can only be told about. An unknown state lands
        /// here on purpose: this build cannot say what migrating would do, so
        /// it does not offer to.
        var isBlocked: Bool { !isAdoptable && !needsConfirmation }

        var label: Localized {
            switch self {
            case .adoptable:
                return Localized("Ready to move", "Taşınmaya hazır")
            case .versionMismatch:
                return Localized("Version differs", "Sürüm farklı")
            case .noAppArtifact:
                return Localized("Not an app cask", "Uygulama cask'i değil")
            case .needsRoot:
                return Localized("Needs an administrator", "Yönetici izni gerekiyor")
            case .targetMismatch:
                return Localized("Installs elsewhere", "Başka yere kuruluyor")
            case .deprecated:
                return Localized("Cask is deprecated", "Cask kullanımdan kaldırılmış")
            case .unknown:
                return Localized("Not recognised", "Tanınmıyor")
            }
        }

        /// The wording comes straight from the `state` table in
        /// CACHE_FORMAT.md, which is where what each one means is defined.
        var detail: Localized {
            switch self {
            case .adoptable:
                return Localized(
                    "Homebrew can take over the copy already installed, without downloading it again.",
                    "Homebrew hâlihazırda kurulu kopyayı yeniden indirmeden devralabilir."
                )
            case .versionMismatch:
                return Localized(
                    "The installed copy is not the version the cask ships, so Homebrew will refuse to adopt it. Moving it replaces the app with the cask's version.",
                    "Kurulu kopya cask'in getirdiği sürüm değil, bu yüzden Homebrew devralmayı reddeder. Taşımak uygulamayı cask'in sürümüyle değiştirir."
                )
            case .noAppArtifact:
                return Localized(
                    "This cask installs a package rather than an application bundle, so there is nothing for Homebrew to take over.",
                    "Bu cask bir uygulama paketi yerine bir yükleyici kuruyor, dolayısıyla Homebrew'in devralabileceği bir şey yok."
                )
            case .needsRoot:
                return Localized(
                    "Installing this cask needs an administrator password, which a background run has nowhere to ask for. Install it yourself with 'brew install --cask'.",
                    "Bu cask'i kurmak yönetici parolası gerektiriyor; arka planda çalışan bir işlemin bunu soracağı bir yer yok. 'brew install --cask' ile kendiniz kurun."
                )
            case .targetMismatch:
                return Localized(
                    "The cask installs to a different location than this app. Moving it would leave a second copy behind instead of taking this one over.",
                    "Cask bu uygulamadan farklı bir konuma kuruyor. Taşımak bu kopyayı devralmak yerine geride ikinci bir kopya bırakır."
                )
            case .deprecated:
                return Localized(
                    "This cask is deprecated or disabled and is on its way out of Homebrew.",
                    "Bu cask kullanımdan kaldırılmış veya devre dışı; Homebrew'den çıkarılma yolunda."
                )
            case .unknown:
                return Localized(
                    "The engine reported something this version of the app does not understand. Update the app or the toolkit.",
                    "Motor, uygulamanın bu sürümünün anlamadığı bir şey bildirdi. Uygulamayı veya araç setini güncelleyin."
                )
            }
        }
    }

    /// Bundle name without `.app`, as it appears on disk. This is the id the
    /// `migrate_app` action is invoked with - not the cask token.
    let appName: String
    /// Where the bundle actually is. A `~/Applications` path is normal here
    /// and is exactly what `.targetMismatch` is about.
    let appPath: String
    /// `CFBundleIdentifier`, empty when the plist could not be read.
    let bundleID: String
    /// `CFBundleShortVersionString`, raw and un-normalized. May be empty -
    /// not every bundle has one.
    let installedVersion: String
    /// The candidate cask. Never a `brew search` result.
    let token: String
    /// What migrating would move the app to. May be empty.
    let caskVersion: String
    let match: Match
    let state: State
    /// The cask's homepage, empty unless it is an https URL.
    let homepage: String

    /// The app name, because that is what `migrate_app` is keyed on and what
    /// the user is picking. Two candidates for the same app cannot exist - the
    /// engine emits one line per bundle.
    var id: String { appName }

    var homepageURL: URL? {
        guard homepage.hasPrefix("https://") else { return nil }
        return URL(string: homepage)
    }

    /// Where to read about the cask this row would move the app to. Offered
    /// for every row but *needed* for the unverified ones: it is the only way
    /// to check that the token really is this application before pressing a
    /// button that replaces it.
    var caskPageURL: URL? {
        guard !token.isEmpty else { return nil }
        return URL(string: "https://formulae.brew.sh/cask/\(token)")
    }

    /// The only format version this build understands. See CACHE_FORMAT.md -
    /// the shell writer (`MIGRATION_FORMAT_VERSION` in lib/migrate.sh) and
    /// this must agree, or `parse` fails closed instead of misreading.
    static let formatVersion = "v1"

    /// The number of fields a v1 record has. Checked exactly, not as a
    /// minimum: a line with more fields is a newer format that happens to
    /// start with `v1`, and reading the first ten of it would be guessing.
    static let fieldCount = 10

    /// `v1|app_name|app_path|bundle_id|installed_version|token|cask_version|match|state|homepage`
    ///
    /// Fails closed on anything it cannot read whole - a missing or unknown
    /// version, the wrong number of fields, an unknown `match`. `nil` means
    /// "no usable record", which every caller treats as "there is nothing to
    /// show for this line", never as a candidate with defaults filled in.
    static func parse(raw: String) -> MigrationCandidate? {
        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard fields.count == fieldCount, fields[0] == formatVersion else { return nil }

        // No fallback, unlike `state` below. A match token this build does not
        // know says nothing about whether the pairing was verified, and
        // guessing either way is wrong in a way the user pays for: guess
        // "verified" and an unrelated cask is offered without a warning, guess
        // "unverified" and a hand-written mapping is second-guessed.
        guard let match = Match(rawValue: fields[7]) else { return nil }

        // An app name is what `migrate_app` is invoked with and what the row
        // is keyed on - a blank one is not a record anybody can act on.
        guard !fields[1].isEmpty, !fields[5].isEmpty else { return nil }

        return MigrationCandidate(
            appName: fields[1],
            appPath: fields[2],
            bundleID: fields[3],
            installedVersion: fields[4],
            token: fields[5],
            caskVersion: fields[6],
            match: match,
            state: State(rawValue: fields[8]) ?? .unknown,
            homepage: fields[9]
        )
    }

    /// Every candidate in a `migration_candidates` payload, skipping lines
    /// that cannot be read whole.
    ///
    /// One bad line does not throw the rest away: the entry is a list of
    /// independent records, and an app the user can see on disk should not
    /// vanish from the page because a different app's line came from a newer
    /// engine.
    static func parseAll(_ raw: String) -> [MigrationCandidate] {
        raw.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parse(raw: String($0)) }
    }
}

/// The `cache/migration_candidates` file: what the last scan found.
enum MigrationCandidateStore {

    /// What the last scan left behind, or an empty list when no scan has ever
    /// run. Absence is not an error - it is the normal state until the user
    /// presses Scan, since nothing writes this entry in the background.
    static func load() -> [MigrationCandidate] {
        guard let data = try? Data(contentsOf: ToolkitPaths.cacheFile("migration_candidates")),
              let raw = String(data: data, encoding: .utf8) else { return [] }
        return MigrationCandidate.parseAll(raw)
    }

    /// Whether a scan has ever been run on this machine - which is a different
    /// question from whether it found anything. An empty file means "scanned,
    /// nothing to move"; a missing one means "never scanned", and the page
    /// says so instead of claiming a clean result nobody asked for.
    static var hasScanned: Bool {
        FileManager.default.fileExists(
            atPath: ToolkitPaths.cacheFile("migration_candidates").path(percentEncoded: false)
        )
    }
}
