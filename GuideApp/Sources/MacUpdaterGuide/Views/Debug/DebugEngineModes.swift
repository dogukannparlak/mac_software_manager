import Foundation

/// The engine's `run` modes, and what each one really does.
///
/// The wording here is the point of the file. `run all` and `run single` read
/// like test fixtures and are not: they download and install packages on the
/// machine the app is being developed on. Every mode that does carries the
/// sentence that says so, and that same sentence is what the confirmation
/// dialog shows - so there is one description of the consequences, not one
/// for the panel and a vaguer one for the dialog.
///
/// English-only string literals - see the header of `DebugView.swift`.
enum EngineMode: String, CaseIterable, Identifiable, Hashable {
    case plugin
    case system
    case all
    case single
    case install
    case migrate

    var id: String { rawValue }

    /// Whether running this mode installs software. Drives the red tint, the
    /// destructive button role and the confirmation dialog.
    ///
    /// `plugin` is deliberately not in this set: it replaces the toolkit's
    /// own shell files when an update is pending and installs no packages.
    /// It still carries a caution of its own below.
    var installsPackages: Bool {
        switch self {
        case .plugin: return false
        case .system, .all, .single, .install, .migrate: return true
        }
    }

    /// Whether the engine has a dry-run form for this mode. Only two do, and
    /// in both the dry token is a positional the caller appends - there is no
    /// global flag.
    var supportsDryRun: Bool {
        switch self {
        case .install, .migrate: return true
        case .plugin, .system, .all, .single: return false
        }
    }

    var takesArguments: Bool {
        switch self {
        case .single, .install, .migrate: return true
        case .plugin, .system, .all: return false
        }
    }

    var summary: String {
        switch self {
        case .plugin:
            return """
            Applies a pending toolkit update: re-downloads setup_mac.sh, uninstall.sh, \
            update_system.1h.sh and lib/*.sh, verifies them, and replaces the installed copies. \
            Does nothing when no update is pending.
            """
        case .system:
            return """
            The full system update: brew update, brew upgrade, mas upgrade, optional cleanup, \
            then a verify pass over what it claimed to have done.
            """
        case .all:
            return "plugin followed by system - what the menu bar's Update Everything runs."
        case .single:
            return "Updates one package. Positionals: kind id name currentVersion newVersion, where kind is brew, cask or mas."
        case .install:
            return "Replaces one self-updating app (Sparkle or GitHub) with its latest build. Positionals: app name, then live or dry."
        case .migrate:
            return "Hands one application over to a Homebrew cask. Positionals: app name, cask token, then adopt, replace or dry."
        }
    }

    var argumentHint: String {
        switch self {
        case .plugin, .system, .all: return "this mode takes no arguments"
        case .single: return "brew ripgrep ripgrep 14.1.0 14.1.1"
        case .install: return "BetterDisplay"
        case .migrate: return "Rectangle rectangle adopt"
        }
    }

    /// Shown in the panel whenever it is non-nil, and - for the modes that
    /// install - in the confirmation dialog too.
    var caution: String? {
        switch self {
        case .plugin:
            return """
            Overwrites the installed engine scripts when a toolkit update is pending. \
            Nothing is installed through brew or mas, but the copy of the toolkit this app \
            is talking to will change underneath it.
            """
        case .system:
            return """
            This runs a real system update: brew update, brew upgrade, mas upgrade and cleanup. \
            Packages will be downloaded and installed on this machine. There is no dry-run form.
            """
        case .all:
            return """
            This applies any pending toolkit update and then runs a real system update: \
            brew update, brew upgrade, mas upgrade and cleanup. Packages will be downloaded \
            and installed on this machine. There is no dry-run form.
            """
        case .single:
            return """
            This really updates the package named in the arguments - it will be downloaded \
            and installed on this machine. There is no dry-run form.
            """
        case .install:
            return """
            This downloads the app's latest build and replaces the copy in /Applications. \
            Turn on Dry run to ask what would happen instead.
            """
        case .migrate:
            return """
            This hands the application over to Homebrew. With replace, the installed app is \
            moved aside and the cask's version installed in its place. Turn on Dry run to ask \
            what would happen instead.
            """
        }
    }
}

/// What `ToolkitController.launchUpdate(scope:)` is asked to run - the same
/// three scopes the engine's `run` accepts.
enum LaunchScope: String, CaseIterable, Identifiable, Hashable {
    case all
    case system
    case plugin

    var id: String { rawValue }
}

/// Something the panel will not do until it has been confirmed.
///
/// One type for both kinds of confirmation because the dialog is one dialog:
/// SwiftUI presents `confirmationDialog` off a single binding, and two
/// competing presentations off two booleans is how a dialog ends up showing
/// the wrong message for the wrong button.
enum PendingAction: Identifiable, Hashable {
    case engine(EngineMode)
    case launchUpdate(LaunchScope)

    var id: String {
        switch self {
        case .engine(let mode): return "engine.\(mode.rawValue)"
        case .launchUpdate(let scope): return "launch.\(scope.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .engine(let mode): return "Run \(mode.rawValue) for real?"
        case .launchUpdate(let scope): return "Start a real update run (\(scope.rawValue))?"
        }
    }

    var message: String {
        switch self {
        case .engine(let mode):
            return mode.caution ?? ""
        case .launchUpdate(let scope):
            return """
            launchUpdate(scope: "\(scope.rawValue)") starts a real update run. \
            With Settings › General › Run updates in Terminal off it runs headless in the background; \
            with it on, the configured terminal opens and runs it there. \
            Packages will be downloaded and installed on this machine.
            """
        }
    }

    var confirmLabel: String {
        switch self {
        case .engine(let mode): return "Run \(mode.rawValue)"
        case .launchUpdate: return "Start update"
        }
    }
}

/// Splitting the arguments field into the positionals the engine will see.
enum DebugArguments {

    /// Whitespace-separated, with double quotes grouping.
    ///
    /// Quoting is not optional here: `run install Google Chrome` is three
    /// positionals and the engine reads the third as the live/dry token, so
    /// an app whose name has a space in it silently becomes a different
    /// command. `"Google Chrome"` is what a shell would take, and it is what
    /// anybody typing into this field will reach for.
    static func split(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in input {
            switch character {
            case "\"":
                inQuotes.toggle()
            case " ", "\t":
                if inQuotes {
                    current.append(character)
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            default:
                current.append(character)
            }
        }

        // An unterminated quote is still an argument the user typed; taking
        // it rather than dropping it means the command preview shows what
        // went wrong instead of quietly losing the last positional.
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
