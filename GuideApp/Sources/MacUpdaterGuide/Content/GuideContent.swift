import Foundation

/// Everything the guide displays.
///
/// Content is data rather than hard-coded views, so the same structure renders
/// in any language and a new topic is one entry rather than a new screen.
enum GuideContent {

    static let appName = Localized(
        "Mac Software Manager",
        "Mac Software Manager"
    )

    static let appTagline = Localized(
        "Every update on your Mac, in one place in the menu bar.",
        "Mac'inizdeki tüm güncellemeler, menü çubuğunda tek yerde."
    )

    static let sidebarHeading = Localized("Guide", "Rehber")

    static let languagePickerLabel = Localized("Language", "Dil")

    static let topics: [GuideTopic] = [
        overview,
        menuBar,
        updating,
        history,
        ignoring,
        migration,
        selfUpdating,
        security,
        settings,
        maintenance
    ]

}
