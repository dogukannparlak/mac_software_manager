import Foundation

/// What the toolkit will and will not do on its own, and why each of those
/// is the way it is.
///
/// Split out of `GuideContent.swift` by subject; see that file's header.
extension GuideContent {

    // MARK: - Security

    static let security = GuideTopic(
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
                        """
                        During an install the old version is set aside rather than deleted. If the new one does not land \
                        properly, the old one is put straight back and the application is reopened if it was running.
                        """,
                        """
                        Kurulum sırasında eski sürüm silinmez, kenara alınır. Yenisi düzgün yerleşmezse eskisi olduğu gibi \
                        geri konur ve uygulama açıksa yeniden başlatılır.
                        """
                    ))
                ]
            ),
            GuideSection(
                id: "security.selfupdate",
                heading: Localized("The toolkit updating itself", "Aracın kendini güncellemesi"),
                blocks: [
                    .paragraph(Localized(
                        """
                        When a new version of the toolkit is available it tells you in the menu. Before installing, the \
                        download is compared against the checksum published on GitHub. If the file is damaged or the two \
                        disagree, the update does not happen and your working version stays as it is.
                        """,
                        """
                        Aracın yeni sürümü çıktığında menüde bildirir. Kurmadan önce indirilen dosya, GitHub'da yayınlanmış \
                        kontrol toplamıyla karşılaştırılır. Dosya bozuksa veya ikisi uyuşmazsa güncelleme yapılmaz, çalışan \
                        sürümünüz olduğu gibi kalır.
                        """
                    )),
                    .paragraph(Localized(
                        """
                        The second server is optional. If a Codeberg mirror is set up - the CODEBERG_USERNAME line in \
                        settings.conf, which setup_mac.sh asks for and Settings › About shows as \"Mirror\" - the \
                        checksum it publishes has to agree as well, so one tampered or half-pushed server is caught. \
                        If the main server cannot be reached, the mirror is used instead.
                        """,
                        """
                        İkinci sunucu isteğe bağlıdır. Bir Codeberg yansısı kurulmuşsa — setup_mac.sh'nin sorduğu, \
                        settings.conf'taki CODEBERG_USERNAME satırı; Ayarlar › Hakkında'da \"Yansı\" olarak görünür — \
                        onun yayınladığı kontrol toplamının da tutması gerekir; böylece kurcalanmış ya da yarım \
                        yüklenmiş tek bir sunucu yakalanır. Ana sunucuya erişilemezse onun yerine yansı kullanılır.
                        """
                    )),
                    .note(Localized(
                        """
                        With no mirror configured, downloads are verified against GitHub alone and there is nothing to \
                        fall back to when GitHub is unreachable.
                        """,
                        """
                        Yansı yapılandırılmamışsa indirmeler yalnızca GitHub'a karşı doğrulanır ve GitHub'a \
                        erişilemediğinde geçilecek bir yedek olmaz.
                        """
                    ))
                ]
            )
        ]
    )
}
