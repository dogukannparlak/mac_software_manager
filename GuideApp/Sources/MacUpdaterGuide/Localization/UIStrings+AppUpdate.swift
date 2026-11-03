import Foundation

/// Copy for the app's own self-update (`AppUpdater`, `AppUpdateCard`).
extension UIStrings {

    static let appUpdateTitle = Localized("App Updates", "Uygulama Güncellemeleri")
    static let appUpdateCheckNow = Localized("Check Now", "Şimdi Denetle")
    static let appUpdateAutoCheck = Localized("Check for new versions every day", "Yeni sürümleri her gün denetle")
    static let appUpdateChecking = Localized("Checking GitHub…", "GitHub denetleniyor…")
    static let appUpdateUpToDate = Localized("You have the latest version.", "En son sürümü kullanıyorsunuz.")
    static let appUpdateDownloadingFormat = Localized(
        "Downloading and verifying version %@…",
        "%@ sürümü indiriliyor ve doğrulanıyor…"
    )
    static let appUpdateReadyFormat = Localized(
        "Version %@ is downloaded and verified.",
        "%@ sürümü indirildi ve doğrulandı."
    )
    static let appUpdateInstallFormat = Localized("Restart and Update to %@", "Yeniden Başlat ve %@ Sürümüne Güncelle")
    static let appUpdateInstallingFormat = Localized("Installing %@…", "%@ kuruluyor…")
    static let appUpdateWhatsNew = Localized("What's New", "Yenilikler")
    static let appUpdateDidNotTakeFormat = Localized(
        "Version %@ could not be installed, so the previous version was kept.",
        "%@ sürümü kurulamadı, bu yüzden önceki sürüm korundu."
    )
    static let appUpdateHelp = Localized(
        """
        New versions come from GitHub Releases and are checked against the published checksum and the app's \
        signature before anything is installed. Installing replaces only the app itself: settings, history, \
        ignored apps and cache stay where they are, and the previous version is kept.
        """,
        """
        Yeni sürümler GitHub Releases'ten gelir ve kurulmadan önce yayınlanan kontrol toplamı ile uygulamanın \
        imzasına göre doğrulanır. Kurulum yalnızca uygulamanın kendisini değiştirir: ayarlar, geçmiş, yok sayılan \
        uygulamalar ve önbellek yerinde kalır, önceki sürüm de saklanır.
        """
    )
    /// Menu bar row once a new version is downloaded - "%@" is the version.
    static let appUpdateMenuFormat = Localized("Update App to %@", "Uygulamayı %@ Sürümüne Güncelle")
}
