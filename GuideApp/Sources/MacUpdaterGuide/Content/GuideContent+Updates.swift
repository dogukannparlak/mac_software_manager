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
                        days and the last 30 days. Selecting an entry opens its page.
                        """,
                        """
                        Son 7 gün ve son 30 gün içinde hangi uygulamanın hangi sürümden hangi sürüme geçtiğini günlere \
                        göre gruplanmış şekilde görebilirsiniz. Bir kayda tıklayınca sayfası açılır.
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
                        If you want to stay on an older version of something, choose \"Ignore\" and it stops appearing \
                        in the update list. You can bring it back at any time from \"Manage Ignored Apps\".
                        """,
                        """
                        Bir uygulamada eski sürümde kalmak isterseniz \"Ignore\" deyin, güncelleme listesinde görünmez \
                        olur. İstediğiniz zaman \"Manage Ignored Apps\" menüsünden geri alabilirsiniz.
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
