import Foundation

/// The two topics that describe the app itself: what it is, and the menu
/// bar item that is the whole of its day-to-day surface.
///
/// Split out of `GuideContent.swift` by subject; see that file's header.
extension GuideContent {

    // MARK: - Overview

    static let overview = GuideTopic(
        id: "overview",
        symbol: "sparkles.rectangle.stack",
        title: Localized("Overview", "Genel Bakış"),
        summary: Localized(
            "What the toolkit is and what the two parts do.",
            "Aracın ne olduğu ve iki parçasının ne yaptığı."
        ),
        sections: [
            GuideSection(
                id: "overview.intro",
                blocks: [
                    .paragraph(Localized(
                        """
                        A menu bar tool that lets you follow updates for every application on your Mac from a single place. \
                        It comes in two parts: a setup assistant you run once, and a monitor that lives in the menu bar.
                        """,
                        """
                        Mac'inizdeki tüm uygulamaların güncellemelerini tek yerden takip etmenizi sağlayan bir menü çubuğu \
                        aracı. İki parçadan oluşuyor: bir kez çalıştırdığınız kurulum sihirbazı ve menü çubuğunda sürekli \
                        duran bir monitör.
                        """
                    ))
                ]
            ),
            GuideSection(
                id: "overview.parts",
                heading: Localized("The two parts", "İki parça"),
                blocks: [
                    .bullets([
                        Localized(
                            "The setup assistant scans your Applications folder and helps you move manually installed apps under proper management.",
                            "Kurulum sihirbazı Uygulamalar klasörünüzü tarar ve elle kurduğunuz uygulamaları düzgün yönetime almanıza yardım eder."
                        ),
                        Localized(
                            "The menu bar monitor keeps watching for new versions and lets you install them with a click.",
                            "Menü çubuğu monitörü yeni sürümleri izlemeye devam eder ve tek tıkla kurmanızı sağlar."
                        )
                    ])
                ]
            ),
            GuideSection(
                id: "overview.covers",
                heading: Localized("What it keeps track of", "Neleri takip eder"),
                blocks: [
                    .bullets([
                        Localized(
                            "Applications and command line tools installed through Homebrew.",
                            "Homebrew üzerinden kurulan uygulamalar ve komut satırı araçları."
                        ),
                        Localized(
                            "App Store applications, including the Apple titles the App Store sometimes leaves out.",
                            "App Store uygulamaları — App Store'un bazen atladığı Apple uygulamaları dahil."
                        ),
                        Localized(
                            "Applications that update themselves, which normally nothing else keeps an eye on.",
                            "Kendi kendini güncelleyen uygulamalar — normalde hiçbir aracın gözü üzerinde olmayanlar."
                        )
                    ])
                ]
            )
        ]
    )

    // MARK: - Menu bar

    static let menuBar = GuideTopic(
        id: "menubar",
        symbol: "menubar.rectangle",
        title: Localized("The Menu Bar", "Menü Çubuğu"),
        summary: Localized(
            "The indicator, what the menu shows, and why it opens instantly.",
            "Gösterge, menüde neler olduğu ve neden anında açıldığı."
        ),
        sections: [
            GuideSection(
                id: "menubar.indicator",
                blocks: [
                    .paragraph(Localized(
                        """
                        A small icon sits at the top right of your screen. When updates are waiting it shows how many; \
                        when everything is current it shows a check mark.
                        """,
                        "Ekranın sağ üstünde küçük bir ikon durur. Bekleyen güncelleme varsa sayıyı gösterir, her şey güncelse bir onay işareti."
                    ))
                ]
            ),
            GuideSection(
                id: "menubar.contents",
                heading: Localized("What the menu shows", "Menüde neler var"),
                blocks: [
                    .bullets([
                        Localized(
                            "Homebrew applications and command line tools, with the current and the new version side by side.",
                            "Homebrew uygulamaları ve komut satırı araçları — mevcut ve yeni sürüm yan yana."
                        ),
                        Localized(
                            """
                            App Store applications, including titles such as Keynote, Xcode and Final Cut that Apple's \
                            own updater sometimes misses.
                            """,
                            """
                            App Store uygulamaları — Apple'ın kendi güncelleyicisinin bazen atladığı Keynote, Xcode, Final \
                            Cut gibi uygulamalar dahil.
                            """
                        ),
                        Localized(
                            "Applications that are in neither place and update themselves.",
                            "İkisinde de olmayan, kendi kendini güncelleyen uygulamalar."
                        )
                    ])
                ]
            ),
            GuideSection(
                id: "menubar.speed",
                heading: Localized("It opens instantly", "Anında açılır"),
                blocks: [
                    .paragraph(Localized(
                        """
                        The menu never makes you wait. It gathers data in the background on a schedule and shows what it \
                        already has, so opening it is immediate even on a slow connection.
                        """,
                        """
                        Menü sizi asla bekletmez. Veriyi arka planda düzenli olarak toplar ve hazır olanı gösterir; yavaş \
                        bağlantıda bile anında açılır.
                        """
                    )),
                    .note(Localized(
                        "The \"Last check\" line tells you when that data was collected. \"Refresh now\" rebuilds it immediately.",
                        "\"Last check\" satırı verinin ne zaman toplandığını söyler. \"Refresh now\" hemen yeniden toplar."
                    ))
                ]
            )
        ]
    )
}
