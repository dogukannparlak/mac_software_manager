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
            "Everything you can change, in the Settings section of the sidebar.",
            "Kenar çubuğundaki Ayarlar bölümünden değiştirebileceğiniz her şey."
        ),
        sections: [
            GuideSection(
                id: "settings.where",
                blocks: [
                    .paragraph(Localized(
                        """
                        Settings are pages in this window rather than a separate preferences panel: look under Settings \
                        in the sidebar. ⌘, opens General.
                        """,
                        """
                        Ayarlar ayrı bir tercihler penceresi değil, bu pencerenin sayfaları: kenar çubuğundaki Ayarlar \
                        bölümüne bakın. ⌘, Genel'i açar.
                        """
                    ))
                ]
            ),
            GuideSection(
                id: "settings.general",
                heading: Localized("General", "Genel"),
                blocks: [
                    .bullets([
                        Localized(
                            "Language, and how often to check - every 30 minutes, every hour, every 2, 6 or 12 hours, or once a day.",
                            "Dil ve kontrol sıklığı — 30 dakikada bir, saatte bir, 2, 6 veya 12 saatte bir, ya da günde bir."
                        ),
                        Localized(
                            """
                            \"Run updates in Terminal\" - off by default, so updates run in the background. With it on \
                            they open in your terminal of choice: Terminal, iTerm2, Warp, Alacritty or Ghostty.
                            """,
                            """
                            \"Güncellemeleri Terminal'de çalıştır\" — varsayılan kapalı, yani güncellemeler arka planda \
                            çalışır. Açıkken seçtiğiniz terminalde açılırlar: Terminal, iTerm2, Warp, Alacritty veya Ghostty.
                            """
                        ),
                        Localized(
                            """
                            \"Open Terminal automatically when a password is needed\" - for the few packages a background \
                            update cannot finish without administrator rights.
                            """,
                            """
                            \"Parola gerektiğinde Terminal'i kendiliğinden aç\" — arka planda çalışan bir güncellemenin \
                            yönetici izni olmadan bitiremediği birkaç paket için.
                            """
                        ),
                        Localized(
                            "\"Simultaneous Updates\" - how many background updates run at once. Two by default; the rest queue.",
                            "\"Aynı Anda Yapılabilecek Güncelleme Sayısı\" — arka planda aynı anda kaç güncelleme çalışır. Varsayılan iki; kalanı kuyruğa girer."
                        ),
                        Localized(
                            "\"Menu bar only (hide Dock icon)\" and \"Open at login\".",
                            "\"Sadece menü çubuğu (Dock simgesini gizle)\" ve \"Girişte aç\"."
                        )
                    ])
                ]
            ),
            GuideSection(
                id: "settings.updates",
                heading: Localized("Updates", "Güncellemeler"),
                blocks: [
                    .bullets([
                        Localized(
                            "\"Include App Store apps\" - turn it off if you would rather manage Store apps yourself.",
                            "\"App Store uygulamalarını dahil et\" — Store uygulamalarını kendiniz yönetmek isterseniz kapatabilirsiniz."
                        ),
                        Localized(
                            """
                            \"Clean up after updating\" - frees disk space by removing old versions and cached downloads, \
                            but makes going back to an older version harder. Can be turned off.
                            """,
                            """
                            \"Güncelleme sonrası temizlik\" — eski sürümleri ve indirme önbelleğini silerek yer kazandırır \
                            ama eski sürüme dönmeyi zorlaştırır. Kapatılabilir.
                            """
                        ),
                        Localized(
                            "\"Install self-updating apps automatically\" - the optional install described above. Off by default.",
                            "\"Kendi kendini güncelleyen uygulamaları kur\" — yukarıda anlatılan isteğe bağlı kurulum. Varsayılan kapalı."
                        ),
                        Localized(
                            "Update channel for the toolkit itself - stable or beta.",
                            "Aracın kendi güncelleme kanalı — kararlı sürüm veya beta."
                        )
                    ])
                ]
            ),
            GuideSection(
                id: "settings.rules",
                heading: Localized("Rules and lists", "Kurallar ve listeler"),
                blocks: [
                    .bullets([
                        Localized(
                            """
                            \"Tracked Apps\" - state exactly how a given application should be checked, with \"Add Rule\" \
                            and \"Remove\". Apps without a rule are detected automatically. Saved in tracked_apps.conf.
                            """,
                            """
                            \"Takip Edilen Uygulamalar\" — belirli bir uygulamanın tam olarak nasıl kontrol edileceğini \
                            \"Kural Ekle\" ve \"Kaldır\" ile belirtirsiniz. Kuralı olmayanlar otomatik algılanır. \
                            tracked_apps.conf dosyasına kaydedilir.
                            """
                        ),
                        Localized(
                            "\"Name Mapping\" - the Homebrew names that cannot be guessed from the app name, in app_token_map.conf.",
                            "\"İsim Eşlemesi\" — uygulama adından tahmin edilemeyen Homebrew adları; app_token_map.conf dosyasında."
                        ),
                        Localized(
                            "\"Ignored\" - everything hidden from the update list, each with a \"Restore\" button. Kept in ignored_apps.conf.",
                            "\"Yoksayılanlar\" — güncelleme listesinden gizlenen her şey, her birinin yanında bir \"Geri al\" butonuyla. ignored_apps.conf dosyasında tutulur."
                        )
                    ])
                ]
            ),
            GuideSection(
                id: "settings.advanced",
                heading: Localized("Advanced and About", "Gelişmiş ve Hakkında"),
                blocks: [
                    .bullets([
                        Localized(
                            """
                            Advanced finds the engine script again with \"Locate Again\", or lets you point at it \
                            yourself with \"Choose…\".
                            """,
                            """
                            Gelişmiş, motor betiğini \"Yeniden Ara\" ile tekrar bulur ya da \"Seç…\" ile yerini \
                            kendiniz göstermenizi sağlar.
                            """
                        ),
                        Localized(
                            """
                            It also shows the cached data's size on disk with \"Clear Cache\", and \"Reveal support \
                            folder in Finder\" for the files themselves.
                            """,
                            """
                            Ayrıca önbelleğin diskteki boyutunu \"Önbelleği Temizle\" ile birlikte gösterir; \
                            dosyaların kendisi için de \"Destek klasörünü Finder'da göster\" vardır.
                            """
                        ),
                        Localized(
                            "\"Show the Debug page\" adds a Developer section to the sidebar for testing the app by hand.",
                            "\"Hata Ayıklama sayfasını göster\", uygulamayı elle test etmek için kenar çubuğuna bir Geliştirici bölümü ekler."
                        ),
                        Localized(
                            """
                            About lists the app version and the toolkit version, plus the Homebrew version and how fresh \
                            its database is, with \"Check Homebrew\" next to it.
                            """,
                            """
                            Hakkında, uygulama sürümünü ve araç sürümünü listeler; ayrıca Homebrew sürümünü ve \
                            veritabanının ne kadar taze olduğunu, yanında \"Homebrew'u Denetle\" ile birlikte gösterir.
                            """
                        ),
                        Localized(
                            """
                            It is also where the toolkit updates itself - \"Check for Updates\", then \"Install \
                            Update\" - and where the \"Project page\" and \"Mirror\" links live.
                            """,
                            """
                            Aracın kendini güncellediği yer de burasıdır — \"Güncelleme Denetle\", ardından \
                            \"Güncellemeyi Kur\" — ve \"Proje sayfası\" ile \"Yansı\" bağlantıları da buradadır.
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
