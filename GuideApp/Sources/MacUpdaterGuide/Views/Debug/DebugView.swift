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

    var body: some View {
        SettingsPage(
            symbol: "ladybug",
            tint: .pink,
            title: "Debug",
            subtitle: "Manual test surface for every screen, state and engine output. Not shown to users."
        ) {
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
            }
        }
        .environment(log)
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .environment: return "Environment"
        case .engine: return "Engine"
        case .cache: return "Cache"
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
