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

    // MARK: - Overview

    private static let overview = GuideTopic(
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
                        "A menu bar tool that lets you follow updates for every application on your Mac from a single place. It comes in two parts: a setup assistant you run once, and a monitor that lives in the menu bar.",
                        "Mac'inizdeki tüm uygulamaların güncellemelerini tek yerden takip etmenizi sağlayan bir menü çubuğu aracı. İki parçadan oluşuyor: bir kez çalıştırdığınız kurulum sihirbazı ve menü çubuğunda sürekli duran bir monitör."
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

    private static let menuBar = GuideTopic(
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
                        "A small icon sits at the top right of your screen. When updates are waiting it shows how many; when everything is current it shows a check mark.",
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
                            "App Store applications, including titles such as Keynote, Xcode and Final Cut that Apple's own updater sometimes misses.",
                            "App Store uygulamaları — Apple'ın kendi güncelleyicisinin bazen atladığı Keynote, Xcode, Final Cut gibi uygulamalar dahil."
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
                        "The menu never makes you wait. It gathers data in the background on a schedule and shows what it already has, so opening it is immediate even on a slow connection.",
                        "Menü sizi asla bekletmez. Veriyi arka planda düzenli olarak toplar ve hazır olanı gösterir; yavaş bağlantıda bile anında açılır."
                    )),
                    .note(Localized(
                        "The \"Last check\" line tells you when that data was collected. \"Refresh now\" rebuilds it immediately.",
                        "\"Last check\" satırı verinin ne zaman toplandığını söyler. \"Refresh now\" hemen yeniden toplar."
                    ))
                ]
            )
        ]
    )

    // MARK: - Updating

    private static let updating = GuideTopic(
        id: "updating",
        symbol: "arrow.triangle.2.circlepath",
        title: Localized("Installing Updates", "Güncelleme Yapmak"),
        summary: Localized(
            "Update everything at once or one app at a time, and see what really happened.",
            "Her şeyi birden ya da tek tek güncelleyin, gerçekte ne olduğunu görün."
        ),
        sections: [
            GuideSection(
                id: "updating.how",
                blocks: [
                    .steps([
                        Localized(
                            "Choose \"Update Everything\" to update all of them in order.",
                            "Hepsini sırayla güncellemek için \"Update Everything\" seçin."
                        ),
                        Localized(
                            "A terminal window opens so you can watch each step as it happens.",
                            "Bir terminal penceresi açılır, her adımı olurken izleyebilirsiniz."
                        ),
                        Localized(
                            "To update a single application instead, use the \"Update\" option on its own row.",
                            "Tek bir uygulamayı güncellemek için kendi satırındaki \"Update\" seçeneğini kullanın."
                        )
                    ])
                ]
            ),
            GuideSection(
                id: "updating.verified",
                heading: Localized("Results are checked, not assumed", "Sonuç varsayılmaz, kontrol edilir"),
                blocks: [
                    .paragraph(Localized(
                        "When an update run finishes, the toolkit checks whether each package really did move to the new version. Anything that did not is recorded in the history as failed, in red.",
                        "Güncelleme bittiğinde araç her paketin gerçekten yeni sürüme geçip geçmediğini kontrol eder. Geçemeyenler geçmişe kırmızı renkte, başarısız olarak kaydedilir."
                    )),
                    .note(Localized(
                        "This is why the history can be trusted: a failed update is never counted as a success.",
                        "Geçmişe bu yüzden güvenebilirsiniz: başarısız bir güncelleme asla başarılı sayılmaz."
                    ))
                ]
            ),
            GuideSection(
                id: "updating.concurrent",
                heading: Localized("One run at a time", "Aynı anda tek çalıştırma"),
                blocks: [
                    .paragraph(Localized(
                        "If an update is already running, starting a second one waits for the first to finish instead of competing with it.",
                        "Zaten bir güncelleme çalışıyorsa, ikincisini başlatmak onunla yarışmak yerine ilkinin bitmesini bekler."
                    ))
                ]
            )
        ]
    )

    // MARK: - History

    private static let history = GuideTopic(
        id: "history",
        symbol: "clock.arrow.circlepath",
        title: Localized("History", "Geçmiş"),
        summary: Localized(
            "What was updated over the last 7 and 30 days.",
            "Son 7 ve 30 günde neyin güncellendiği."
        ),
        sections: [
            GuideSection(
                id: "history.body",
                blocks: [
                    .paragraph(Localized(
                        "You can see which application went from which version to which, grouped by day, for the last 7 days and the last 30 days. Selecting an entry opens its page.",
                        "Son 7 gün ve son 30 gün içinde hangi uygulamanın hangi sürümden hangi sürüme geçtiğini günlere göre gruplanmış şekilde görebilirsiniz. Bir kayda tıklayınca sayfası açılır."
                    )),
                    .bullets([
                        Localized(
                            "Successful updates are counted in the totals.",
                            "Başarılı güncellemeler toplamlara dahil edilir."
                        ),
                        Localized(
                            "Failed attempts stay visible, marked in red, but are left out of the counts.",
                            "Başarısız denemeler kırmızı işaretle görünür kalır ama sayıya dahil edilmez."
                        )
                    ])
                ]
            )
        ]
    )

    // MARK: - Ignoring

    private static let ignoring = GuideTopic(
        id: "ignoring",
        symbol: "eye.slash",
        title: Localized("Silencing Updates", "Güncellemeleri Susturmak"),
        summary: Localized(
            "Stay on an older version without being reminded about it.",
            "Hatırlatılmadan eski sürümde kalın."
        ),
        sections: [
            GuideSection(
                id: "ignoring.body",
                blocks: [
                    .paragraph(Localized(
                        "If you want to stay on an older version of something, choose \"Ignore\" and it stops appearing in the update list. You can bring it back at any time from \"Manage Ignored Apps\".",
                        "Bir uygulamada eski sürümde kalmak isterseniz \"Ignore\" deyin, güncelleme listesinde görünmez olur. İstediğiniz zaman \"Manage Ignored Apps\" menüsünden geri alabilirsiniz."
                    )),
                    .note(Localized(
                        "For Homebrew command line tools this uses Homebrew's own \"pin\" feature, so your choice survives even if you remove this toolkit.",
                        "Homebrew komut satırı araçları için bu, Homebrew'un kendi \"pin\" özelliğini kullanır; yani bu aracı kaldırsanız bile tercihiniz korunur."
                    ))
                ]
            )
        ]
    )

    // MARK: - Migration

    private static let migration = GuideTopic(
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
                        "On first run it scans your Applications folder and sorts every application: did it come from Homebrew, from the App Store, or did you download it yourself and drag it in?",
                        "İlk çalıştırmada Uygulamalar klasörünüzü tarar ve her uygulamayı sınıflandırır: Homebrew'dan mı geldi, App Store'dan mı, yoksa siz mi indirip sürükleyip bıraktınız?"
                    )),
                    .paragraph(Localized(
                        "For the ones you installed by hand it offers a choice: move it to the Homebrew-managed version, to the App Store version, or leave it exactly as it is. Whatever you move over is tracked automatically from then on.",
                        "Elle kurduklarınız için size seçenek sunar: Homebrew'un yönettiği sürüme mi geçirelim, App Store sürümüne mi, yoksa olduğu gibi mi kalsın? Geçirdikleriniz bundan sonra otomatik takip edilir."
                    ))
                ]
            ),
            GuideSection(
                id: "migration.safety",
                heading: Localized("Your app is never lost", "Uygulamanız kaybolmaz"),
                blocks: [
                    .steps([
                        Localized(
                            "First it asks Homebrew to simply adopt the application already on your disk. Nothing is downloaded and your settings stay untouched.",
                            "Önce Homebrew'a diskinizdeki uygulamayı olduğu gibi sahiplenmesini söyler. Hiçbir şey indirilmez, ayarlarınız yerinde kalır."
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
                        "Sometimes an application's name is nothing like its Homebrew name - \"lghub\" is really \"logitech-g-hub\". When that happens the assistant asks you, then remembers your answer and never asks again.",
                        "Bazen uygulamanın adı Homebrew'daki adıyla hiç ilgisiz olur — \"lghub\" aslında \"logitech-g-hub\". Böyle bir durumda sihirbaz size sorar, cevabınızı kaydeder ve bir daha sormaz."
                    ))
                ]
            )
        ]
    )

    // MARK: - Self updating apps

    private static let selfUpdating = GuideTopic(
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
                        "Some applications are in neither Homebrew nor the App Store - usually the ones that pop up their own \"a new version is available\" notice. The toolkit follows these as well, by checking the application's own update channel or its release page.",
                        "Bazı uygulamalar ne Homebrew'da ne App Store'dadır — genelde kendi içlerinde \"yeni sürüm var\" uyarısı çıkaranlar. Araç bunları da takip eder: uygulamanın kendi güncelleme kanalına veya sürüm sayfasına bakar."
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
                        "If you turn it on in settings, you can install these updates straight from the menu. It is off by default, because replacing a running application is the riskiest thing the toolkit can do.",
                        "Ayarlardan açarsanız bu güncellemeleri doğrudan menüden kurabilirsiniz. Varsayılan olarak kapalıdır, çünkü çalışan bir uygulamayı değiştirmek aracın yapabileceği en riskli iştir."
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
                        "Each app also offers a \"Dry run\": it downloads and runs every security check, shows you the result, and changes nothing at all. Use it to see what would happen before you trust it.",
                        "Her uygulamada bir de \"Dry run\" seçeneği vardır: indirir, tüm güvenlik kontrollerini yapar, sonucu gösterir ve hiçbir şeyi değiştirmez. Güvenmeden önce ne olacağını görmek için kullanın."
                    ))
                ]
            ),
            GuideSection(
                id: "self.limits",
                heading: Localized("Limits", "Sınırlar"),
                blocks: [
                    .bullets([
                        Localized(
                            "Only .dmg and .zip downloads can be installed for you. A .pkg runs its own installer scripts with administrator rights and cannot be undone, so those always open the publisher's page instead.",
                            "Sadece .dmg ve .zip dosyaları sizin yerinize kurulabilir. Bir .pkg kendi kurulum betiklerini yönetici yetkisiyle çalıştırır ve geri alınamaz; onlarda daima yayıncının sayfası açılır."
                        ),
                        Localized(
                            "Applications that came with a Setapp subscription are left alone entirely - Setapp has its own updater.",
                            "Setapp aboneliğiyle gelen uygulamalara hiç dokunulmaz — onların kendi güncelleyicisi vardır."
                        ),
                        Localized(
                            "Small open-source apps are often signed for development rather than for distribution. macOS refuses those, and they have to be installed by hand.",
                            "Küçük açık kaynak uygulamalar çoğu zaman dağıtım için değil geliştirme için imzalanır. macOS bunları reddeder, elle kurulmaları gerekir."
                        )
                    ])
                ]
            )
        ]
    )

    // MARK: - Security

    private static let security = GuideTopic(
        id: "security",
        symbol: "lock.shield",
        title: Localized("Security", "Güvenlik"),
        summary: Localized(
            "What is verified before anything on your Mac is replaced.",
            "Mac'inizde bir şey değiştirilmeden önce neler doğrulanır."
        ),
        sections: [
            GuideSection(
                id: "security.checks",
                heading: Localized("Before an app is installed", "Bir uygulama kurulmadan önce"),
                blocks: [
                    .bullets([
                        Localized(
                            "Is the download from the same developer as the app you already have? Apple's developer identity is compared directly.",
                            "İndirilen dosya elinizdekiyle aynı geliştiriciye mi ait? Apple'ın verdiği geliştirici kimliği doğrudan karşılaştırılır."
                        ),
                        Localized(
                            "Is the signature intact and undamaged?",
                            "İmza sağlam ve bozulmamış mı?"
                        ),
                        Localized(
                            "Does macOS's own security system, Gatekeeper, accept it?",
                            "macOS'in kendi güvenlik sistemi Gatekeeper onaylıyor mu?"
                        ),
                        Localized(
                            "If the publisher provides an extra signature of their own, does that match too?",
                            "Yayıncı kendi ek imzasını sağlıyorsa o da tutuyor mu?"
                        ),
                        Localized(
                            "Is the downloaded version actually the version that was promised?",
                            "İndirilen sürüm gerçekten vaat edilen sürüm mü?"
                        )
                    ]),
                    .caution(Localized(
                        "If even one of these fails, the installation stops. You are told why, and your application is left exactly as it was.",
                        "Bunlardan biri bile geçmezse kurulum durur. Size sebebi söylenir ve uygulamanız olduğu gibi kalır."
                    ))
                ]
            ),
            GuideSection(
                id: "security.rollback",
                heading: Localized("If something goes wrong anyway", "Yine de bir şey ters giderse"),
                blocks: [
                    .paragraph(Localized(
                        "During an install the old version is set aside rather than deleted. If the new one does not land properly, the old one is put straight back and the application is reopened if it was running.",
                        "Kurulum sırasında eski sürüm silinmez, kenara alınır. Yenisi düzgün yerleşmezse eskisi olduğu gibi geri konur ve uygulama açıksa yeniden başlatılır."
                    ))
                ]
            ),
            GuideSection(
                id: "security.selfupdate",
                heading: Localized("The toolkit updating itself", "Aracın kendini güncellemesi"),
                blocks: [
                    .paragraph(Localized(
                        "When a new version of the toolkit is available it tells you in the menu. Before installing, the download is compared against the published checksum on both the main server and the backup one. If they disagree, or the file is damaged, the update does not happen and your working version stays as it is.",
                        "Aracın yeni sürümü çıktığında menüde bildirir. Kurmadan önce indirilen dosya, hem ana sunucudaki hem yedek sunucudaki yayınlanmış kontrol toplamıyla karşılaştırılır. İkisi uyuşmazsa veya dosya bozuksa güncelleme yapılmaz, çalışan sürümünüz olduğu gibi kalır."
                    )),
                    .note(Localized(
                        "If the main server cannot be reached the toolkit switches to the backup automatically, so one service being down does not block you.",
                        "Ana sunucuya erişilemezse araç otomatik olarak yedeğe geçer; tek bir servisin çökmesi sizi engellemez."
                    ))
                ]
            )
        ]
    )

    // MARK: - Settings

    private static let settings = GuideTopic(
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
                            "Cleanup after updates - frees disk space by removing old versions and cached downloads, but makes going back to an older version harder. Can be turned off.",
                            "Güncelleme sonrası temizlik — eski sürümleri ve indirme önbelleğini silerek yer kazandırır ama eski sürüme dönmeyi zorlaştırır. Kapatılabilir."
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
                            "Tracked applications - a plain text file where you can state exactly how a given app should be checked. It opens straight from the menu.",
                            "Takip edilen uygulamalar — bir uygulamanın tam olarak nasıl kontrol edileceğini yazabileceğiniz düz metin dosyası. Menüden doğrudan açılır."
                        )
                    ])
                ]
            )
        ]
    )

    // MARK: - Maintenance

    private static let maintenance = GuideTopic(
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
