import Foundation

/// Configuration and the housekeeping that keeps the caches honest.
///
/// Split out of `GuideContent.swift` by subject; see that file's header.
extension GuideContent {

    // MARK: - Settings

    static let settings = GuideTopic(
        id: "settings",
        symbol: "gearshape",
        title: Localized("Settings", "Ayarlar"),
        summary: Localized(
            "Everything you can change from the Preferences menu.",
            "Tercihler menüsünden değiştirebileceğiniz her şey."
        ),
        sections: [
            GuideSection(
                id: "settings.list",
                blocks: [
                    .bullets([
                        Localized(
                            "Check frequency - hourly, every 2, 6 or 12 hours, or once a day.",
                            "Kontrol sıklığı — saatte bir, 2, 6 veya 12 saatte bir, ya da günde bir."
                        ),
                        Localized(
                            "Terminal of choice - Terminal, iTerm2, Warp, Alacritty or Ghostty.",
                            "Terminal tercihi — Terminal, iTerm2, Warp, Alacritty veya Ghostty."
                        ),
                        Localized(
                            "App Store support - turn it off if you would rather manage Store apps yourself.",
                            "App Store desteği — Store uygulamalarını kendiniz yönetmek isterseniz kapatabilirsiniz."
                        ),
                        Localized(
                            """
                            Cleanup after updates - frees disk space by removing old versions and cached downloads, but \
                            makes going back to an older version harder. Can be turned off.
                            """,
                            """
                            Güncelleme sonrası temizlik — eski sürümleri ve indirme önbelleğini silerek yer kazandırır \
                            ama eski sürüme dönmeyi zorlaştırır. Kapatılabilir.
                            """
                        ),
                        Localized(
                            "App installation - the optional automatic install described above. Off by default.",
                            "Uygulama kurulumu — yukarıda anlatılan isteğe bağlı otomatik kurulum. Varsayılan kapalı."
                        )
                    ]),
                    .bullets([
                        Localized(
                            "Update channel - stable or beta.",
                            "Güncelleme kanalı — kararlı sürüm veya beta."
                        ),
                        Localized(
                            "Start at login.",
                            "Girişte otomatik başlatma."
                        ),
                        Localized(
                            """
                            Tracked applications - a plain text file where you can state exactly how a given app should \
                            be checked. It opens straight from the menu.
                            """,
                            """
                            Takip edilen uygulamalar — bir uygulamanın tam olarak nasıl kontrol edileceğini yazabileceğiniz \
                            düz metin dosyası. Menüden doğrudan açılır.
                            """
                        )
                    ])
                ]
            )
        ]
    )

    // MARK: - Maintenance

    static let maintenance = GuideTopic(
        id: "maintenance",
        symbol: "trash",
        title: Localized("Removing It", "Kaldırmak"),
        summary: Localized(
            "How to uninstall, and what stays behind.",
            "Nasıl kaldırılır ve geriye ne kalır."
        ),
        sections: [
            GuideSection(
                id: "maintenance.body",
                blocks: [
                    .paragraph(Localized(
                        "There is a separate uninstall script. It removes the toolkit, its settings and its records.",
                        "Ayrı bir kaldırma betiği vardır. Aracı, ayarlarını ve kayıtlarını temizler."
                    )),
                    .note(Localized(
                        "It does not touch the applications you installed, and it does not touch Homebrew.",
                        "Kurduğunuz uygulamalara dokunmaz, Homebrew'a da dokunmaz."
                    ))
                ]
            )
        ]
    )
}
