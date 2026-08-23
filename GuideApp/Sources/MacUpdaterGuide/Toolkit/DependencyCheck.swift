import Foundation

/// What this app needs on the Mac that it cannot bring with it, and whether
/// it is there.
///
/// The list is deliberately short, and what is *not* on it is the point. The
/// update engine used to be here, listed as something to install, with a
/// progress log and a button - for files this project writes and ships inside
/// the app. That was the app installing itself in front of the user: an extra
/// step, an extra thing to go wrong, and a scary-looking prerequisite before a
/// single update had been checked. The engine now runs straight out of the
/// bundle (see `BundledEngine`) and is not a dependency at all.
///
/// What remains is software this project did not write and may not ship:
/// Homebrew, and the `mas` command line tool. Those are the user's Mac's
/// business, so they are offered rather than assumed.

/// One piece of third-party software the toolkit needs.
enum Dependency: String, CaseIterable, Identifiable, Sendable {
    /// The package manager everything is installed through.
    case homebrew
    /// The App Store command line tool.
    case mas

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .homebrew: return "shippingbox"
        case .mas:      return "bag"
        }
    }

    var title: Localized {
        switch self {
        case .homebrew:
            return Localized("Homebrew", "Homebrew")
        case .mas:
            return Localized("mas (App Store command line tool)", "mas (App Store komut satırı aracı)")
        }
    }

    var detail: Localized {
        switch self {
        case .homebrew:
            return Localized(
                "The package manager every update in this app goes through.",
                "Bu uygulamadaki her güncellemenin üzerinden geçtiği paket yöneticisi."
            )
        case .mas:
            return Localized(
                "Only needed for App Store applications. Everything else works without it.",
                "Yalnızca App Store uygulamaları için gerekir. Geri kalan her şey onsuz da çalışır."
            )
        }
    }

    /// Whether the app is unusable without it.
    ///
    /// `mas` is the one that is not: a Mac with no App Store applications
    /// never needs it, and treating its absence as a fault would put a setup
    /// sheet in front of people whose installation is complete. It is still
    /// listed, and still installable, because "nothing here mentions App
    /// Store updates" is how the absence used to read.
    var isRequired: Bool {
        switch self {
        case .homebrew: return true
        case .mas:      return false
        }
    }

    /// Whether this can be installed from inside the app at all.
    ///
    /// Homebrew cannot: its installer asks for an administrator password, and
    /// this app never asks for one (see `BootstrapInstaller`). Its "install"
    /// hands the job to Terminal.app and watches for the result instead,
    /// which is a different enough promise that the sheet words the button
    /// differently.
    var isInstalledInApp: Bool { self != .homebrew }
}

/// Where one dependency stands.
///
/// `checking` is a real state rather than an optional wrapped around the
/// others: the sheet draws its rows before the first probe returns, and a row
/// that appears out of nowhere a moment later reads as a glitch.
enum DependencyState: Equatable, Sendable {
    /// Still being probed - the first draw, and every re-probe after an
    /// install.
    case checking
    /// Present and good enough. `detail` is the path or version found, shown
    /// as the row's second line so "satisfied" can be checked rather than
    /// taken on trust.
    case satisfied(detail: String)
    /// Not on this Mac.
    case missing
    /// The probe or an install of it went wrong, with whatever was printed.
    /// Distinct from `missing` because the answer here is "try again", not
    /// "install it".
    case failed(String)

    /// Whether the sheet should offer to do something about it.
    var needsAction: Bool {
        switch self {
        case .missing, .failed: return true
        case .checking, .satisfied:        return false
        }
    }

    /// Whether this is still being worked out, which is what keeps the
    /// primary button disabled rather than acting on a half-read state.
    var isChecking: Bool { self == .checking }
}

enum DependencyCheck {

    // MARK: - Probing

    /// The state of every dependency, probed together.
    ///
    /// Off the main actor: it stats files and reads one small file, which is
    /// fast but not free, and the call sites are a window's `.task` and a
    /// sheet that re-probes after every install.
    static func probe() async -> [Dependency: DependencyState] {
        await Task.detached(priority: .userInitiated) {
            var states: [Dependency: DependencyState] = [:]
            states[.homebrew] = brewState(path: executablePath(named: "brew"))
            states[.mas] = masState(path: executablePath(named: "mas"))
            return states
        }.value
    }

    /// Just one, for the re-probe after a single row's install finishes.
    static func probe(_ dependency: Dependency) async -> DependencyState {
        await probe()[dependency] ?? .checking
    }

    // MARK: - Finding executables

    /// The two prefixes Homebrew installs into: Apple silicon first, then
    /// Intel.
    ///
    /// Deliberately not a `PATH` search. `PATH` inside this app is whatever
    /// `launchd` handed it, which on a Mac launched from Finder is
    /// `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else - no login shell ever
    /// runs, so none of the `brew shellenv` lines in the user's `.zprofile`
    /// have happened. A `PATH` lookup here reports "Homebrew is not
    /// installed" on a machine that has had it for years, and the whole point
    /// of this file is to stop guessing wrong about that.
    static let homebrewPrefixes = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The first of those prefixes holding an executable of this name, or
    /// `nil`. Internal so `BootstrapInstaller` resolves `brew` the same way
    /// rather than growing a second list of prefixes.
    static func executablePath(named name: String) -> String? {
        for prefix in homebrewPrefixes {
            let candidate = "\(prefix)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Deciding, without touching the disk

    /// Split out from the probe so the decisions can be exercised without a
    /// Homebrew installation, an engine or a Mac - see DependencyCheckTests.
    static func brewState(path: String?) -> DependencyState {
        guard let path else { return .missing }
        return .satisfied(detail: path)
    }

    static func masState(path: String?) -> DependencyState {
        guard let path else { return .missing }
        return .satisfied(detail: path)
    }

    // MARK: - Reading the states as a whole

    /// Whether anything the app cannot work without is unaccounted for. This
    /// is what opens the sheet at launch, so `checking` deliberately does not
    /// count: the sheet must not flash open on the way to finding out that
    /// everything is fine.
    static func hasBlockingGap(_ states: [Dependency: DependencyState]) -> Bool {
        Dependency.allCases.contains { dependency in
            dependency.isRequired && (states[dependency]?.needsAction ?? false)
        }
    }

    /// Everything the "Install What's Missing" button would act on, in
    /// declaration order so the log reads top to bottom the way the rows do.
    ///
    /// Optional dependencies are included: someone who presses a button
    /// offering to install what is missing means all of it. A row they do not
    /// want is installed from its own button instead, and `mas` never opened
    /// the sheet on its own in the first place.
    static func installable(from states: [Dependency: DependencyState]) -> [Dependency] {
        Dependency.allCases.filter { states[$0]?.needsAction ?? false }
    }
}
