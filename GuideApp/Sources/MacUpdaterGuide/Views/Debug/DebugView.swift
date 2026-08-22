import SwiftUI

/// The Debug page: drive every screen, every state and every engine output by
/// hand, without waiting on brew, mas or the network - and without installing
/// anything unless it is asked for explicitly.
///
/// **Why nothing under `Views/Debug/` is localized.** Every other view goes
/// through `UIStrings`/`Localized` because it is read by whoever *installed*
/// the app. This page is read by whoever is *changing* it: its labels name
/// Swift properties, cache keys and shell verbs - `brew_outdated`,
/// `run single`, `EngineContract.supportsMigration` - and each of those has
/// exactly one spelling, here and in CACHE_FORMAT.md. Translating a row
/// called "supportsMigration" makes it harder to match against the property
/// it reports, not easier, and the few hundred developer-only keys it would
/// take would bury the strings in `UIStrings` that genuinely need
/// translating. So this folder is deliberately English-only string literals.
/// The two strings that *are* user-facing - the sidebar entry and the
/// Settings toggle that reveals it - live in `UIStrings` like everything
/// else.
///
/// Hidden unless `AppPreferences.showsDebugPage` says otherwise: always on in
/// DEBUG builds, behind Settings › Advanced in Release.
struct DebugView: View {
    @Environment(LocalizationStore.self) private var loc

    @State private var section: DebugSection = .environment
    /// One log for the whole page, not one per panel - see `DebugLog`.
    @State private var log = DebugLog()
    /// Shared for the same reason the log is: the warning strip below has to
    /// stay up while the user is looking at a different section, so the
    /// injection state cannot belong to the panel that caused it.
    @State private var stateStore = DebugStateStore()

    var body: some View {
        SettingsPage(
            symbol: "ladybug",
            tint: .pink,
            title: "Debug",
            subtitle: "Manual test surface for every screen, state and engine output. Not shown to users."
        ) {
            // Above the section picker, not inside the State panel: fake
            // state outlives the panel that wrote it, and so must the
            // warning about it.
            if stateStore.isInjecting {
                DebugInjectionBanner()
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $section) {
                        ForEach(DebugSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(section.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch section {
            case .environment: DebugSectionEnvironment()
            case .engine:      DebugSectionEngine()
            case .cache:       DebugSectionCache()
            case .state:       DebugSectionState()
            case .features:    DebugSectionFeatures()
            case .localization: DebugSectionLocalization()
            }
        }
        .environment(log)
        .environment(stateStore)
        // Anything left injected by an earlier launch has to raise the strip
        // as soon as the page is opened, not once something is written.
        .task { stateStore.rescan() }
    }
}

/// Which panel the Debug page is showing.
///
/// A flat list rather than a nested sidebar: the page already sits inside
/// one, and a second column inside the detail view would leave the content
/// squeezed into a third of the window on a laptop screen.
enum DebugSection: String, CaseIterable, Identifiable, Hashable {
    case environment
    case engine
    case cache
    case state
    case features
    case localization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .environment: return "Environment"
        case .engine: return "Engine"
        case .cache: return "Cache"
        case .state: return "State"
        case .features: return "Features"
        case .localization: return "Strings"
        }
    }

    var subtitle: String {
        switch self {
        case .environment:
            return "Read-only diagnostics: what this machine has installed, what the app found, and which permissions it was granted."
        case .engine:
            return "Run update_system.*.sh by hand. Modes that install packages are marked and confirmed first."
        case .cache:
            return "Every file the engine writes, how old it is, and what is actually in it."
        case .state:
            return "Write fake state over the engine's files to produce any UI state, with the real files backed up beside them."
        case .features:
            return "One trigger per feature - migration, inventory, config files, the ignore round trip, self-update - each reporting to the console."
        case .localization:
            return "Every Localized pair, with the three things that go wrong: no translation, an identical one, and mismatched format specifiers."
        }
    }
}

/// A label/value pair in one of the Debug page's tables, with its own Copy
/// button.
///
/// `id` doubles as the row's markdown label so "Copy all as markdown" and
/// the on-screen table cannot drift apart - the thing being pasted into an
/// issue has to be the thing that was on screen.
struct DebugFact: Identifiable, Sendable {
    let id: String
    var value: String
    /// Drawn in orange, for the rows where the answer is the problem: no
    /// script found, notifications denied, an engine that declares nothing.
    var isProblem = false
    /// Shown under the value in a smaller face - a path, an error, the raw
    /// line a value was parsed from.
    var detail: String?

    var markdownRow: String {
        let cell = detail.map { "\(value) — \($0)" } ?? value
        return "| \(id) | \(cell.replacingOccurrences(of: "|", with: "\\|")) |"
    }
}

/// A titled group of facts - one markdown section, one card on screen.
struct DebugFactGroup: Identifiable, Sendable {
    let id: String
    var facts: [DebugFact]
}
