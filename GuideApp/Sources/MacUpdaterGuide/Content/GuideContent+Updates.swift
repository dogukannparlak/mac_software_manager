import Foundation

/// The update cycle, end to end: running one, reading what happened
/// afterwards, and holding a package back from it.
///
/// Split out of `GuideContent.swift` by subject; see that file's header.
extension GuideContent {

    // MARK: - Updating

    static let updating = GuideTopic(
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
                            "Hepsini sırayla güncellemek için \"Hepsini Güncelle\" seçin."
                        ),
                        Localized(
                            """
                            The run happens in the background and reports back inside the app: a progress bar on the row \
                            being updated, and a percentage next to it.
                            """,
                            """
                            Çalıştırma arka planda olur ve uygulama içinden bildirir: güncellenen satırda bir ilerleme \
                            çubuğu, yanında da yüzdesi.
                            """
                        ),
                        Localized(
                            "To update a single application instead, use the \"Update\" option on its own row.",
                            "Tek bir uygulamayı güncellemek için kendi satırındaki \"Güncelle\" seçeneğini kullanın."
                        )
                    ]),
                    .note(Localized(
                        """
                        A terminal window is not involved unless you ask for one: Settings › General › \"Run updates in \
                        Terminal\" moves every run into your terminal of choice instead.
                        """,
                        """
                        Siz istemedikçe terminal penceresi açılmaz: Ayarlar › Genel › \"Güncellemeleri Terminal'de \
                        çalıştır\" her çalıştırmayı seçtiğiniz terminale taşır.
                        """
                    ))
                ]
            ),
            GuideSection(
                id: "updating.verified",
                heading: Localized("Results are checked, not assumed", "Sonuç varsayılmaz, kontrol edilir"),
                blocks: [
                    .paragraph(Localized(
                        """
                        When an update run finishes, the toolkit checks whether each package really did move to the new \
                        version. Anything that did not is recorded in the history as failed, in red.
                        """,
                        """
                        Güncelleme bittiğinde araç her paketin gerçekten yeni sürüme geçip geçmediğini kontrol eder. Geçemeyenler \
                        geçmişe kırmızı renkte, başarısız olarak kaydedilir.
                        """
                    )),
                    .note(Localized(
                        "This is why the history can be trusted: a failed update is never counted as a success.",
                        "Geçmişe bu yüzden güvenebilirsiniz: başarısız bir güncelleme asla başarılı sayılmaz."
                    ))
                ]
            ),
            GuideSection(
                id: "updating.concurrent",
                heading: Localized("Several at once, the rest queued", "Aynı anda birkaç tane, kalanı kuyrukta"),
                blocks: [
                    .paragraph(Localized(
                        """
                        Single-application updates run in the background side by side, as many at a time as Settings › \
                        General › \"Simultaneous Updates\" allows - two, unless you change it. Anything started beyond \
                        that shows a \"Queued\" badge and begins on its own as soon as a slot frees up.
                        """,
                        """
                        Tek uygulamalık güncellemeler arka planda yan yana çalışır — aynı anda kaç tane olacağını Ayarlar › \
                        Genel › \"Aynı Anda Yapılabilecek Güncelleme Sayısı\" belirler; değiştirmezseniz iki. Bunun \
                        ötesinde başlatılanlar \"Sırada\" rozetiyle görünür ve bir yer açılır açılmaz kendiliğinden başlar.
                        """
                    )),
                    .note(Localized(
                        """
                        Only two things run alone: an update in Terminal, and \"Update Everything\". While the bulk run \
                        is going, single updates you start are queued behind it.
                        """,
                        """
                        Yalnızca iki şey tek başına çalışır: Terminal'deki bir güncelleme ve \"Hepsini Güncelle\". Toplu \
                        çalıştırma sürerken başlattığınız tek uygulama güncellemeleri onun arkasında kuyruğa girer.
                        """
                    ))
                ]
            ),
            GuideSection(
                id: "updating.page",
                heading: Localized("On the Updates page", "Güncellemeler sayfasında"),
                blocks: [
                    .bullets([
                        Localized(
                            "Cancel a single row, or the whole run from the progress banner. Both ask before stopping.",
                            "Tek bir satırı ya da ilerleme şeridinden çalıştırmanın tamamını iptal edebilirsiniz. İkisi de durdurmadan önce sorar."
                        ),
                        Localized(
                            "When something fails, the reason Homebrew or the App Store printed appears under its row.",
                            "Bir şey başarısız olursa Homebrew'un veya App Store'un yazdığı sebep, o satırın altında görünür."
                        ),
                        Localized(
                            """
                            A package that needs your password cannot be asked for one in the background, so it offers \
                            \"Update in Terminal\" - the same update, rerun where you can type it.
                            """,
                            """
                            Parola gerektiren bir paket bunu arka planda soramaz; bu yüzden \"Terminal'de Güncelle\" \
                            butonunu sunar — aynı güncelleme, parolanızı yazabileceğiniz yerde yeniden çalıştırılır.
                            """
                        ),
                        Localized(
                            "A mistake in settings.conf would otherwise change behaviour silently, so it is listed in a \"Configuration warnings\" card at the top.",
                            "settings.conf'taki bir hata davranışı sessizce değiştirirdi; bu yüzden sayfanın üstündeki \"Yapılandırma uyarıları\" kartında listelenir."
                        ),
                        Localized(
                            """
                            \"Check Homebrew\" in the toolbar refreshes Homebrew's own catalogue (\"brew update\"). \
                            It upgrades no package - it only makes the next check see the latest versions.
                            """,
                            """
                            Araç çubuğundaki \"Homebrew'u Denetle\", Homebrew'un kendi kataloğunu tazeler \
                            (\"brew update\"). Hiçbir paketi güncellemez — sadece sonraki kontrolün en son sürümleri \
                            görmesini sağlar.
                            """
                        )
                    ])
                ]
            )
        ]
    )

    // MARK: - History

    static let history = GuideTopic(
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
                        """
                        You can see which application went from which version to which, grouped by day, for the last 7 \
                        days and the last 30 days. Homebrew and App Store entries carry an arrow button on the right \
                        that opens their page; entries for self-updating apps have no page to open, so they have no button.
                        """,
                        """
                        Son 7 gün ve son 30 gün içinde hangi uygulamanın hangi sürümden hangi sürüme geçtiğini günlere \
                        göre gruplanmış şekilde görebilirsiniz. Homebrew ve App Store kayıtlarının sağında sayfalarını \
                        açan bir ok butonu vardır; kendi kendini güncelleyenlerin açılacak bir sayfası, dolayısıyla \
                        butonu da yoktur.
                        """
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

    static let ignoring = GuideTopic(
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
                        """
                        If you want to stay on an older version of something, choose \"Ignore this app\" from its row \
                        in Updates - or \"Ignore\" from the right-click menu in Installed Apps - and it stops appearing \
                        in the update list. Settings › Ignored lists everything you hid, each with a \"Restore\" button.
                        """,
                        """
                        Bir uygulamada eski sürümde kalmak isterseniz Güncellemeler'deki satırından \"Bu uygulamayı \
                        yoksay\" — ya da Yüklü Uygulamalar'da sağ tık menüsünden \"Yoksay\" — deyin; güncelleme \
                        listesinde görünmez olur. Gizlediklerinizin tamamı Ayarlar › Yoksayılanlar sayfasında, her \
                        birinin yanında bir \"Geri al\" butonuyla listelenir.
                        """
                    )),
                    .note(Localized(
                        """
                        For Homebrew command line tools this uses Homebrew's own \"pin\" feature, so your choice survives \
                        even if you remove this toolkit.
                        """,
                        """
                        Homebrew komut satırı araçları için bu, Homebrew'un kendi \"pin\" özelliğini kullanır; yani bu \
                        aracı kaldırsanız bile tercihiniz korunur.
                        """
                    ))
                ]
            )
        ]
    )
}
