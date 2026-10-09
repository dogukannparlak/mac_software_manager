import Foundation

/// Copy for everything outside Homebrew and the App Store: the setting that
/// turns it on and the CLI Tools page section that lists it.
extension UIStrings {

    static let otherSources = Localized(
        "Also look beyond Homebrew",
        "Homebrew dışını da tara"
    )
    static let otherSourcesHelp = Localized(
        "Lists npm, pipx, uv, Cargo and Go installs, standalone tools such as Claude Code, and installer packages (.pkg). Homebrew stays the primary source.",
        "npm, pipx, uv, Cargo ve Go kurulumlarını, Claude Code gibi bağımsız araçları ve kurulum paketlerini (.pkg) da listeler. Homebrew yine ana kaynak olarak kalır."
    )

    static let otherSourcesSection = Localized("Beyond Homebrew", "Homebrew dışı")
    static let otherSourcesFilter = Localized("Beyond Homebrew", "Homebrew dışı")
    static let otherSourcesOff = Localized(
        "Only Homebrew is listed. Turn on \"Also look beyond Homebrew\" in Settings › Updates to see npm, pipx, standalone tools and installer packages too.",
        "Yalnızca Homebrew listeleniyor. npm, pipx, bağımsız araçlar ve kurulum paketlerini de görmek için Ayarlar › Güncellemeler altındaki \"Homebrew dışını da tara\" seçeneğini açın."
    )
    static let otherSourcesSummaryFormat = Localized(
        "%d from Homebrew, %d from other sources",
        "%d Homebrew'dan, %d diğer kaynaklardan"
    )
    static let partOfApp = Localized("Updated with its app", "Uygulamasıyla güncellenir")
    static let showInFinder = Localized("Show in Finder", "Finder'da Göster")
    static let copyName = Localized("Copy Name", "Adı Kopyala")
}
