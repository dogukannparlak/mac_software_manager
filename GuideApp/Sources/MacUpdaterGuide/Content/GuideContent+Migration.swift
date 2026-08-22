import Foundation

/// Getting applications under Homebrew's management, and what to do about
/// the ones that refuse to be.
///
/// Split out of `GuideContent.swift` by subject; see that file's header.
extension GuideContent {

    // MARK: - Migration

    static let migration = GuideTopic(
        id: "migration",
        symbol: "wand.and.stars",
        title: Localized("Setup Assistant", "Kurulum Sihirbazı"),
        summary: Localized(
            "Bring the apps you dragged in by hand under proper management.",
            "Elle sürükleyip bıraktığınız uygulamaları düzgün yönetime alın."
        ),
        sections: [
            GuideSection(
                id: "migration.scan",
                blocks: [
                    .paragraph(Localized(
                        """
                        On first run it scans your Applications folder and sorts every application: did it come from Homebrew, \
                        from the App Store, or did you download it yourself and drag it in?
                        """,
                        """
                        İlk çalıştırmada Uygulamalar klasörünüzü tarar ve her uygulamayı sınıflandırır: Homebrew'dan mı \
                        geldi, App Store'dan mı, yoksa siz mi indirip sürükleyip bıraktınız?
                        """
                    )),
                    .paragraph(Localized(
                        """
                        For the ones you installed by hand it offers a choice: move it to the Homebrew-managed version, \
                        to the App Store version, or leave it exactly as it is. Whatever you move over is tracked automatically \
                        from then on.
                        """,
                        """
                        Elle kurduklarınız için size seçenek sunar: Homebrew'un yönettiği sürüme mi geçirelim, App Store \
                        sürümüne mi, yoksa olduğu gibi mi kalsın? Geçirdikleriniz bundan sonra otomatik takip edilir.
                        """
                    ))
                ]
            ),
            GuideSection(
                id: "migration.safety",
                heading: Localized("Your app is never lost", "Uygulamanız kaybolmaz"),
                blocks: [
                    .steps([
                        Localized(
                            """
                            First it asks Homebrew to simply adopt the application already on your disk. Nothing is downloaded \
                            and your settings stay untouched.
                            """,
                            """
                            Önce Homebrew'a diskinizdeki uygulamayı olduğu gibi sahiplenmesini söyler. Hiçbir şey indirilmez, \
                            ayarlarınız yerinde kalır.
                            """
                        ),
                        Localized(
                            "If that is not possible it makes a backup and then installs the managed version.",
                            "Bu mümkün değilse yedek alır ve yönetilen sürümü kurar."
                        ),
                        Localized(
                            "If anything goes wrong at that point, the backup is put straight back.",
                            "O noktada bir aksilik olursa yedek olduğu gibi geri konur."
                        )
                    ]),
                    .note(Localized(
                        "There is no step in which you are left without a working application.",
                        "Hiçbir adımda uygulamasız kalmazsınız."
                    ))
                ]
            ),
            GuideSection(
                id: "migration.naming",
                heading: Localized("When the name does not match", "İsim tutmadığında"),
                blocks: [
                    .paragraph(Localized(
                        """
                        Sometimes an application's name is nothing like its Homebrew name - \"lghub\" is really \"logitech-g-hub\". \
                        When that happens the assistant asks you, then remembers your answer and never asks again.
                        """,
                        """
                        Bazen uygulamanın adı Homebrew'daki adıyla hiç ilgisiz olur — \"lghub\" aslında \"logitech-g-hub\". \
                        Böyle bir durumda sihirbaz size sorar, cevabınızı kaydeder ve bir daha sormaz.
                        """
                    ))
                ]
            )
        ]
    )

    // MARK: - Self updating apps

    static let selfUpdating = GuideTopic(
        id: "self-updating",
        symbol: "sparkles",
        title: Localized("Self-Updating Apps", "Kendi Kendini Güncelleyenler"),
        summary: Localized(
            "Apps in neither Homebrew nor the App Store are watched too.",
            "Ne Homebrew'da ne App Store'da olanlar da izlenir."
        ),
        sections: [
            GuideSection(
                id: "self.detect",
                blocks: [
                    .paragraph(Localized(
                        """
                        Some applications are in neither Homebrew nor the App Store - usually the ones that pop up their \
                        own \"a new version is available\" notice. The toolkit follows these as well, by checking the application's \
                        own update channel or its release page.
                        """,
                        """
                        Bazı uygulamalar ne Homebrew'da ne App Store'dadır — genelde kendi içlerinde \"yeni sürüm var\" \
                        uyarısı çıkaranlar. Araç bunları da takip eder: uygulamanın kendi güncelleme kanalına veya sürüm \
                        sayfasına bakar.
                        """
                    )),
                    .paragraph(Localized(
                        "When a new version turns up it appears under \"Manual Update Required\" with a link to the download.",
                        "Yeni sürüm çıkınca \"Manual Update Required\" başlığı altında, indirme bağlantısıyla birlikte görünür."
                    )),
                    .note(Localized(
                        "Beta and preview releases are filtered out, so you are never quietly moved onto a test channel.",
                        "Beta ve deneme sürümleri filtrelenir; sizi farkında olmadan test kanalına düşürmez."
                    ))
                ]
            ),
            GuideSection(
                id: "self.install",
                heading: Localized("Optional automatic install", "İsteğe bağlı otomatik kurulum"),
                blocks: [
                    .paragraph(Localized(
                        """
                        If you turn it on in settings, you can install these updates straight from the menu. It is off \
                        by default, because replacing a running application is the riskiest thing the toolkit can do.
                        """,
                        """
                        Ayarlardan açarsanız bu güncellemeleri doğrudan menüden kurabilirsiniz. Varsayılan olarak kapalıdır, \
                        çünkü çalışan bir uygulamayı değiştirmek aracın yapabileceği en riskli iştir.
                        """
                    )),
                    .paragraph(Localized(
                        "Every install checks the download first - see the Security topic. If a check fails, nothing is touched.",
                        "Her kurulum önce indirileni kontrol eder — Güvenlik bölümüne bakın. Kontrol geçmezse hiçbir şeye dokunulmaz."
                    ))
                ]
            ),
            GuideSection(
                id: "self.dryrun",
                heading: Localized("Dry run", "Kuru çalıştırma"),
                blocks: [
                    .paragraph(Localized(
                        """
                        Each app also offers a \"Dry run\": it downloads and runs every security check, shows you the result, \
                        and changes nothing at all. Use it to see what would happen before you trust it.
                        """,
                        """
                        Her uygulamada bir de \"Dry run\" seçeneği vardır: indirir, tüm güvenlik kontrollerini yapar, sonucu \
                        gösterir ve hiçbir şeyi değiştirmez. Güvenmeden önce ne olacağını görmek için kullanın.
                        """
                    ))
                ]
            ),
            GuideSection(
                id: "self.limits",
                heading: Localized("Limits", "Sınırlar"),
                blocks: [
                    .bullets([
                        Localized(
                            """
                            Only .dmg and .zip downloads can be installed for you. A .pkg runs its own installer scripts \
                            with administrator rights and cannot be undone, so those always open the publisher's page instead.
                            """,
                            """
                            Sadece .dmg ve .zip dosyaları sizin yerinize kurulabilir. Bir .pkg kendi kurulum betiklerini \
                            yönetici yetkisiyle çalıştırır ve geri alınamaz; onlarda daima yayıncının sayfası açılır.
                            """
                        ),
                        Localized(
                            "Applications that came with a Setapp subscription are left alone entirely - Setapp has its own updater.",
                            "Setapp aboneliğiyle gelen uygulamalara hiç dokunulmaz — onların kendi güncelleyicisi vardır."
                        ),
                        Localized(
                            """
                            Small open-source apps are often signed for development rather than for distribution. macOS \
                            refuses those, and they have to be installed by hand.
                            """,
                            """
                            Küçük açık kaynak uygulamalar çoğu zaman dağıtım için değil geliştirme için imzalanır. macOS \
                            bunları reddeder, elle kurulmaları gerekir.
                            """
                        )
                    ])
                ]
            )
        ]
    )
}
