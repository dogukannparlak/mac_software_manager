import Foundation

/// Copy for the setup sheet.
///
/// A file of its own rather than more of `UIStrings`: that one is already at
/// the length where finding anything in it is a search, and these all belong
/// to one screen that did not exist before.
extension UIStrings {

    static let onboardingTitle = Localized("Finish setting up", "Kurulumu tamamlayın")
    static let onboardingIntro = Localized(
        "This app is the interface on top of a small shell toolkit. Here is what it needs, and what is already here.",
        "Bu uygulama, küçük bir kabuk aracının üzerindeki arayüzdür. Neye ihtiyaç duyduğu ve hâlihazırda neyin kurulu olduğu aşağıda."
    )
    static let onboardingInstallMissing = Localized("Install What's Missing", "Eksik Olanları Kur")
    static let onboardingInstall = Localized("Install", "Kur")
    static let onboardingRetry = Localized("Try Again", "Yeniden Dene")
    static let onboardingLater = Localized("Later", "Daha Sonra")
    static let onboardingDone = Localized("Done", "Bitti")
    static let onboardingChecking = Localized("Checking…", "Kontrol ediliyor…")
    static let onboardingInstalling = Localized("Installing…", "Kuruluyor…")
    static let onboardingNotInstalled = Localized("Not installed", "Kurulu değil")
    static let onboardingOptional = Localized("Optional", "İsteğe bağlı")
    static let onboardingAllSet = Localized(
        "Everything this app needs is installed.",
        "Bu uygulamanın ihtiyaç duyduğu her şey kurulu."
    )

    /// The one sentence on this sheet that is a promise rather than a status.
    /// It is on screen before any install starts, because the moment to say
    /// it is before the user is looking at a password prompt - not after.
    static let onboardingNoPasswordNote = Localized(
        """
        This app never asks for your password. Homebrew's installer needs one, \
        so it is opened in Terminal instead, where the prompt comes from macOS \
        and you can read the command before it runs.
        """,
        """
        Bu uygulama parolanızı asla istemez. Homebrew'un kurulum betiği parola \
        gerektirdiğinden bunun yerine Terminal'de açılır; orada istem macOS'tan \
        gelir ve komutu çalışmadan önce okuyabilirsiniz.
        """
    )
    static let onboardingOpenTerminal = Localized("Open Terminal", "Terminal'i Aç")
    static let onboardingWaitingForHomebrew = Localized(
        "Enter your password in the Terminal window. This sheet is watching for Homebrew and will carry on by itself.",
        "Terminal penceresinde parolanızı girin. Bu pencere Homebrew'u bekliyor ve kendiliğinden devam edecek."
    )

    static let onboardingOpenWizard = Localized("Open Setup Assistant", "Kurulum Sihirbazını Aç")
    static let onboardingWizardHelp = Localized(
        "Checks for Homebrew, the update engine and mas, and installs whatever is missing without opening a terminal.",
        "Homebrew, güncelleme motoru ve mas'ı kontrol eder; eksik olanları terminal açmadan kurar."
    )
}
