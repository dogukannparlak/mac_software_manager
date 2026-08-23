import Foundation

/// The two browsing pages: everything installed on this Mac, and the command
/// line tools Homebrew put there.
///
/// Split out of `GuideContent.swift` by subject; see that file's header.
extension GuideContent {

    // MARK: - Inventory

    static let inventory = GuideTopic(
        id: "inventory",
        symbol: "square.grid.2x2",
        title: Localized("What You Have Installed", "Neler Kurulu"),
        summary: Localized(
            "The Installed Apps and CLI Tools pages, and what a row can do.",
            "Yüklü Uygulamalar ve Komut Satırı Araçları sayfaları ve bir satırın neler yapabildiği."
        ),
        sections: [
            GuideSection(
                id: "inventory.apps",
                heading: Localized("Installed Apps", "Yüklü Uygulamalar"),
                blocks: [
                    .paragraph(Localized(
                        """
                        Every application on this Mac, not only the ones with an update waiting. Search by name, or use \
                        the filter chips to narrow it to where an app came from: Homebrew, App Store, Setapp, Installed \
                        manually or Apple.
                        """,
                        """
                        Bu Mac'teki tüm uygulamalar — yalnızca güncellemesi bekleyenler değil. İsimle arayabilir ya da \
                        süzme etiketleriyle uygulamanın nereden geldiğine göre daraltabilirsiniz: Homebrew, App Store, \
                        Setapp, Elle kurulmuş veya Apple.
                        """
                    )),
                    .paragraph(Localized(
                        """
                        Right-clicking a row offers \"Reveal in Finder\", \"Edit Links…\", \"Edit Tracking Method…\", \
                        \"Edit Homebrew Mapping…\" and \"Ignore\". Everything the three editors write stays on this Mac.
                        """,
                        """
                        Bir satıra sağ tıklamak \"Finder'da göster\", \"Bağlantıları Düzenle…\", \"Takip Yöntemini \
                        Düzenle…\", \"Homebrew Eşlemesini Düzenle…\" ve \"Yoksay\" seçeneklerini sunar. Üç düzenleyicinin \
                        yazdığı her şey bu Mac'te kalır.
                        """
                    ))
                ]
            ),
            GuideSection(
                id: "inventory.cli",
                heading: Localized("CLI Tools", "Komut Satırı Araçları"),
                blocks: [
                    .paragraph(Localized(
                        """
                        The command line tools Homebrew installed, grouped by category - version control, languages and \
                        runtimes, databases, libraries and so on - and searchable by name.
                        """,
                        """
                        Homebrew'un kurduğu komut satırı araçları; kategorilere göre gruplanır — sürüm kontrolü, diller \
                        ve çalışma zamanları, veritabanları, kütüphaneler ve benzeri — ve isimle aranabilir.
                        """
                    )),
                    .paragraph(Localized(
                        """
                        A row's right-click menu has \"Pin to this version\" and \"Unpin\". These are Homebrew's own pin, \
                        so a tool held back stays held back even without this toolkit.
                        """,
                        """
                        Satırın sağ tık menüsünde \"Bu sürüme sabitle\" ve \"Sabitlemeyi kaldır\" bulunur. Bunlar \
                        Homebrew'un kendi pin özelliğidir; sabitlenen bir araç, bu araç olmadan da sabit kalır.
                        """
                    ))
                ]
            )
        ]
    )
}
