import Foundation

/// Interface copy, kept apart from the guide's article text.
enum UIStrings {

    // MARK: - Menu bar

    static let everythingUpToDate = Localized("Everything is up to date", "Her şey güncel")
    static let updatesWaitingFormat = Localized("%d updates waiting", "%d güncelleme bekliyor")
    static let nothingPending = Localized("Nothing pending right now.", "Şu an bekleyen bir şey yok.")
    static let neverChecked = Localized("Not checked yet", "Henüz kontrol edilmedi")
    static let lastCheckedFormat = Localized("Last checked %@", "Son kontrol %@")

    static let toolkitNotFound = Localized("Toolkit not found", "Araç bulunamadı")
    static let toolkitNotFoundDetail = Localized(
        "The update_system script could not be located. Point at it under Settings › Advanced.",
        "update_system betiği bulunamadı. Ayarlar › Gelişmiş bölümünden yerini gösterin."
    )

    static let updateEverything = Localized("Update Everything", "Hepsini Güncelle")
    /// Menu bar row that opens the native "Pending Updates" flyout menu -
    /// "%d" is the pending count.
    static let pendingUpdatesFormat = Localized("Pending Updates (%d)", "Bekleyen Güncellemeler (%d)")
    /// Row at the bottom of that flyout - jumps to the full app window
    /// (sidebar, Installed Apps, History, Settings, ...) for anyone who
    /// wants more than the quick list.
    static let openFullApp = Localized("Open Full App", "Tüm Uygulamayı Aç")
    /// Cancel button on the progress banner, and its confirmation dialog -
    /// only shown for a headless run, where there is a real process to stop.
    static let cancelUpdate = Localized("Cancel", "İptal Et")
    static let cancelUpdateConfirmTitle = Localized("Cancel this update?", "Bu güncelleme iptal edilsin mi?")
    static let cancelUpdateConfirmMessage = Localized(
        "Stopping now may leave a package partially installed. You can update it again afterward.",
        "Şimdi durdurmak bir paketi yarım kurulmuş halde bırakabilir. Daha sonra tekrar güncelleyebilirsiniz."
    )
    static let cancelUpdateConfirmAction = Localized("Cancel Update", "Güncellemeyi İptal Et")
    static let cancelUpdateKeepGoing = Localized("Keep Going", "Devam Et")

    static let maxConcurrentUpdates = Localized("Simultaneous Updates", "Aynı Anda Yapılabilecek Güncelleme Sayısı")
    static let maxConcurrentUpdatesHelp = Localized(
        "How many background updates can run at once. Anything started beyond this is queued and starts automatically once a slot frees up.",
        "Arka planda aynı anda kaç güncellemenin çalışabileceği. Bunun ötesinde başlatılanlar kuyruğa alınır ve bir yuva boşaldığında otomatik başlar."
    )
    /// Per-row status while a single-item update is waiting for a free slot.
    static let queuedRowStatus = Localized("Queued", "Sırada")
    static let refreshNow = Localized("Refresh Now", "Şimdi Yenile")
    static let openGuide = Localized("Open Guide", "Rehberi Aç")
    static let settings = Localized("Settings…", "Ayarlar…")
    static let quit = Localized("Quit", "Çık")

    // MARK: - Settings tabs

    static let tabGeneral = Localized("General", "Genel")
    static let tabUpdates = Localized("Updates", "Güncellemeler")
    static let tabIgnored = Localized("Ignored", "Yoksayılanlar")
    static let tabAdvanced = Localized("Advanced", "Gelişmiş")

    // MARK: - General tab

    static let language = Localized("Language", "Dil")
    static let sectionRunning = Localized("Running updates", "Güncellemeleri çalıştırma")
    static let terminal = Localized("Terminal", "Terminal")
    static let terminalHelp = Localized(
        "Updates run in a visible terminal window so you can follow every step and stop if needed.",
        "Güncellemeler görünür bir terminal penceresinde çalışır; her adımı izleyebilir, gerekirse durdurabilirsiniz."
    )

    static let checkInterval = Localized("Check every", "Kontrol sıklığı")

    // MARK: - Updates tab

    static let appStoreUpdates = Localized("Include App Store apps", "App Store uygulamalarını dahil et")
    static let appStoreHelp = Localized(
        "Turn this off to manage App Store applications yourself.",
        "App Store uygulamalarını kendiniz yönetmek isterseniz kapatın."
    )

    static let cleanup = Localized("Clean up after updating", "Güncelleme sonrası temizlik")
    static let cleanupHelp = Localized(
        "Removes old versions and cached downloads. Frees disk space, but makes going back to a previous version harder.",
        "Eski sürümleri ve indirme önbelleğini siler. Yer kazandırır ama önceki sürüme dönmeyi zorlaştırır."
    )

    static let autoInstall = Localized(
        "Install self-updating apps automatically",
        "Kendi kendini güncelleyen uygulamaları kur"
    )
    static let autoInstallHelp = Localized(
        "Adds an Install option for apps with a direct download. Off by default, because it replaces a running application.",
        "Doğrudan indirmesi olan uygulamalar için Kur seçeneği ekler. Çalışan bir uygulamayı değiştirdiği için varsayılan kapalıdır."
    )
    static let autoInstallWarning = Localized(
        "Every install still verifies the developer identity, the signature and Gatekeeper before anything is replaced.",
        "Her kurulum, bir şey değiştirilmeden önce geliştirici kimliğini, imzayı ve Gatekeeper'ı yine de doğrular."
    )

    static let sectionToolkit = Localized("Toolkit updates", "Araç güncellemeleri")
    static let channelHelp = Localized(
        "Beta receives changes earlier and is less tested.",
        "Beta değişiklikleri daha erken alır ve daha az test edilmiştir."
    )

    // MARK: - Ignored tab

    static let noIgnoredApps = Localized("Nothing is ignored", "Yoksayılan bir şey yok")
    static let noIgnoredAppsDetail = Localized(
        "Applications you hide from the update list will appear here.",
        "Güncelleme listesinden gizlediğiniz uygulamalar burada görünür."
    )
    static let restore = Localized("Restore", "Geri al")

    // MARK: - Advanced tab

    static let sectionEngine = Localized("Engine", "Motor")
    static let notFound = Localized("Not found", "Bulunamadı")
    static let locateAgain = Localized("Locate Again", "Yeniden Ara")
    static let chooseManually = Localized("Choose…", "Seç…")
    static let chooseScriptPrompt = Localized(
        "Select the update_system script",
        "update_system betiğini seçin"
    )
    static let engineHelp = Localized(
        "The shell script that talks to Homebrew, the App Store and update feeds. This app reads what it produces and asks it to do the work.",
        "Homebrew, App Store ve güncelleme kaynaklarıyla konuşan kabuk betiği. Bu uygulama onun ürettiğini okur ve işi ona yaptırır."
    )

    static let sectionFiles = Localized("Configuration files", "Yapılandırma dosyaları")
    static let revealSupportFolder = Localized("Reveal support folder in Finder", "Destek klasörünü Finder'da göster")

    // MARK: - Sidebar

    static let sidebarStatus = Localized("Status", "Durum")

    // MARK: - Updates page

    static let navUpdates = Localized("Updates", "Güncellemeler")

    // MARK: - Installed applications page

    static let navInstalled = Localized("Installed Apps", "Yüklü Uygulamalar")
    static let installedAppsSummaryFormat = Localized("%d applications", "%d uygulama")
    static let applications = Localized("Applications", "Uygulamalar")
    static let searchApps = Localized("Search applications", "Uygulama ara")
    static let filterAll = Localized("All", "Tümü")
    static let noMatches = Localized("Nothing matches that search.", "Aramaya uyan bir şey yok.")
    static let scanning = Localized("Scanning applications…", "Uygulamalar taranıyor…")
    static let revealInFinder = Localized("Reveal in Finder", "Finder'da göster")
    static let pinned = Localized("Pinned to this version", "Bu sürüme sabitlenmiş")
}

extension UIStrings {
    static let updateThis = Localized("Update", "Güncelle")
    static let dryRun = Localized("Dry run (no changes)", "Kuru çalıştırma (değişiklik yok)")
    static let ignoreThis = Localized("Ignore this app", "Bu uygulamayı yoksay")
    /// Per-row outcome, shown in place of the Update button once a single-item
    /// run finishes - the App Store-style "Updated"/"Update failed" state.
    static let updatedRowStatus = Localized("Updated", "Güncellendi")
    static let updateFailedRowStatus = Localized("Update failed", "Güncelleme başarısız")
}

// MARK: - Failed actions

/// Copy for `ToolkitController.ActionFailure` - the actions that have no
/// progress banner and no row of their own to fail on, and so used to fail
/// with nothing said at all. The headline is the app's own wording and is
/// translated; the detail underneath is whatever brew/mas/the script printed
/// and is shown exactly as it came.
extension UIStrings {
    static let actionFailedRefresh = Localized(
        "Could not refresh the update list",
        "Güncelleme listesi yenilenemedi"
    )
    static let actionFailedHomebrewCheck = Localized(
        "Could not check Homebrew",
        "Homebrew kontrol edilemedi"
    )
    static let actionFailedStartRun = Localized(
        "Could not start the update",
        "Güncelleme başlatılamadı"
    )
    /// "%@" is the package or application name.
    static let actionFailedUpdateItemFormat = Localized("Could not update %@", "%@ güncellenemedi")
    static let actionFailedHideItemFormat = Localized("Could not ignore %@", "%@ yoksayılamadı")
    static let actionFailedUnhideItemFormat = Localized(
        "Could not stop ignoring %@",
        "%@ için yoksayma kaldırılamadı"
    )
    static let actionFailedToolkitUpdateCheck = Localized(
        "Could not check for toolkit updates",
        "Araç güncellemesi denetlenemedi"
    )
    /// Stands in for the detail line when the run ended without printing
    /// anything and without a bad exit status - see `Reason.noOutput`.
    static let actionFailedNoReason = Localized(
        "The toolkit gave no reason. The package is still listed as outdated.",
        "Araç bir neden bildirmedi. Paket hâlâ güncel değil olarak listeleniyor."
    )
    static let dismissFailure = Localized("Dismiss", "Kapat")
}

// MARK: - History, About, login item

extension UIStrings {
    static let navHistory = Localized("History", "Geçmiş")
    static let last7Days = Localized("Last 7 days", "Son 7 gün")
    static let last30Days = Localized("Last 30 days", "Son 30 gün")
    static let historySucceededFormat = Localized("%d updated", "%d güncellendi")
    static let historyFailedFormat = Localized("%d failed", "%d başarısız")
    static let failedBadge = Localized("FAILED", "BAŞARISIZ")
    static let historyEmpty = Localized("No updates recorded yet", "Henüz kayıtlı güncelleme yok")
    static let historyEmptyDetail = Localized(
        "Once you install updates they are listed here, including the ones that failed.",
        "Güncelleme yaptıkça burada listelenir — başarısız olanlar dahil."
    )

    static let tabAbout = Localized("About", "Hakkında")
    static let appVersionLabel = Localized("App version", "Uygulama sürümü")
    static let toolkitVersionLabel = Localized("Toolkit version", "Araç sürümü")
    static let checkForToolkitUpdate = Localized("Check for Updates", "Güncelleme Denetle")
    static let toolkitUpdateAvailable = Localized(
        "A new version of the toolkit is available",
        "Aracın yeni sürümü mevcut"
    )
    static let installToolkitUpdate = Localized("Install Update", "Güncellemeyi Kur")
    static let toolkitUpdateHelp = Localized(
        "The download is verified against the published checksum on both mirrors before it replaces anything.",
        "İndirilen dosya, bir şey değiştirilmeden önce her iki yansıdaki yayınlanmış kontrol toplamıyla doğrulanır."
    )
    static let visitProject = Localized("Project page", "Proje sayfası")
    static let visitMirror = Localized("Mirror", "Yansı")
    static let mirrorNotConfigured = Localized(
        "No Codeberg mirror configured. Downloads are verified against GitHub only.",
        "Codeberg yansısı yapılandırılmamış. İndirmeler yalnızca GitHub'a karşı doğrulanıyor."
    )

    static let launchAtLogin = Localized("Open at login", "Girişte aç")
    static let launchAtLoginHelp = Localized(
        "Starts this app when you log in, so the menu bar item is always there.",
        "Girişte bu uygulamayı başlatır, böylece menü çubuğu simgesi hep orada olur."
    )
    static let launchAtLoginBlocked = Localized(
        "macOS needs your approval in System Settings › General › Login Items.",
        "macOS'in onayınıza ihtiyacı var: Sistem Ayarları › Genel › Giriş Öğeleri."
    )
    static let openLoginItems = Localized("Open Login Items", "Giriş Öğelerini Aç")

    static let configWarnings = Localized("Configuration warnings", "Yapılandırma uyarıları")
    static let ignoreApp = Localized("Ignore", "Yoksay")
    static let unignoreApp = Localized("Stop ignoring", "Yoksaymayı bırak")
    static let pinFormula = Localized("Pin to this version", "Bu sürüme sabitle")
    static let unpinFormula = Localized("Unpin", "Sabitlemeyi kaldır")
}

extension UIStrings {
    static let showToolsFormat = Localized(
        "Command line tools (%d)",
        "Komut satırı araçları (%d)"
    )
    static let navCLITools = Localized("CLI Tools", "Komut Satırı Araçları")
    static let cliToolsSummaryFormat = Localized(
        "%d command line tools from Homebrew",
        "Homebrew üzerinden %d komut satırı aracı"
    )
    static let searchCLITools = Localized("Search CLI tools", "Komut satırı aracı ara")
}

extension UIStrings {
    static let hideDockIcon = Localized(
        "Menu bar only (hide Dock icon)",
        "Sadece menü çubuğu (Dock simgesini gizle)"
    )
    static let hideDockIconHelp = Localized(
        "Removes the Dock icon and the app menu. Settings, the guide and Quit stay in the menu bar panel.",
        "Dock simgesini ve uygulama menüsünü kaldırır. Ayarlar, rehber ve Çık menü çubuğu panelinde kalır."
    )
}

// MARK: - Settings pages moved into the main window

extension UIStrings {
    static let sidebarSettingsSection = Localized("Settings", "Ayarlar")

    static let generalIntro = Localized(
        "Language, where updates run, and how often they are checked.",
        "Dil, güncellemelerin nerede çalışacağı ve ne sıklıkla kontrol edileceği."
    )
    static let updatesIntro = Localized(
        "What gets updated and how the toolkit updates itself.",
        "Nelerin güncelleneceği ve aracın kendini nasıl güncelleyeceği."
    )
    static let ignoredIntro = Localized(
        "Applications hidden from the update list.",
        "Güncelleme listesinden gizlenen uygulamalar."
    )
    static let advancedIntro = Localized(
        "The engine script, cached data and where everything is stored.",
        "Motor betiği, önbelleğe alınan veri ve her şeyin saklandığı yer."
    )
    static let notInstalled = Localized("not installed", "kurulu değil")

    static let navTracked = Localized("Tracked Apps", "Takip Edilen Uygulamalar")
    static let trackedIntro = Localized(
        "Tell the toolkit how to check a specific application. Apps without a rule are detected automatically.",
        "Belirli bir uygulamanın nasıl kontrol edileceğini belirtin. Kuralı olmayanlar otomatik algılanır."
    )
    static let trackedEmpty = Localized("No rules yet", "Henüz kural yok")
    static let trackedEmptyDetail = Localized(
        "Every application is detected automatically. Add a rule only when the automatic guess is wrong.",
        "Tüm uygulamalar otomatik algılanıyor. Yalnızca otomatik tahmin yanlışsa kural ekleyin."
    )
    static let trackedAutoNote = Localized(
        "Apps without a rule are detected automatically",
        "Kuralı olmayanlar otomatik algılanır"
    )
    static let addRule = Localized("Add Rule", "Kural Ekle")
    static let removeRule = Localized("Remove", "Kaldır")
    static let method = Localized("Method", "Yöntem")
    static let choosePlaceholder = Localized("Choose…", "Seçin…")
    static let cancel = Localized("Cancel", "Vazgeç")
    static let add = Localized("Add", "Ekle")

    static let navTokenMap = Localized("Name Mapping", "İsim Eşlemesi")
    static let tokenMapIntro = Localized(
        "Some Homebrew names cannot be guessed from the application name. Map them here.",
        "Bazı Homebrew adları uygulama adından tahmin edilemez. Burada eşleyin."
    )
    static let tokenMapEmpty = Localized("No mappings yet", "Henüz eşleme yok")
    static let tokenMapEmptyDetail = Localized(
        "Add one when an app is not recognised as Homebrew-managed — \"lghub\" is the cask \"logitech-g-hub\", for instance.",
        "Bir uygulama Homebrew yönetiminde görünmüyorsa ekleyin — örneğin \"lghub\" aslında \"logitech-g-hub\" cask'i."
    )
    static let addMapping = Localized("Add Mapping", "Eşleme Ekle")
    static let caskToken = Localized("Cask token", "Cask adı")

    static let sectionCache = Localized("Cached data", "Önbellek")
    static let cacheSize = Localized("Size on disk", "Diskteki boyut")
    static let clearCache = Localized("Clear Cache", "Önbelleği Temizle")
    static let cacheCleared = Localized("Cleared", "Temizlendi")
    static let cacheHelp = Localized(
        "The menu reads this instead of querying Homebrew every time. Safe to clear; it is rebuilt on the next check.",
        "Menü her seferinde Homebrew'a sormak yerine bunu okur. Silmek güvenlidir, sonraki kontrolde yeniden oluşur."
    )
    static let filesHelp = Localized(
        "Settings, rules and history live here. Everything on these pages is written to those files, so the terminal and the app always agree.",
        "Ayarlar, kurallar ve geçmiş burada. Bu sayfalardaki her şey o dosyalara yazılır, böylece terminal ile uygulama hep aynı şeyi görür."
    )
}

extension UIStrings {
    static let application = Localized("Application", "Uygulama")
}

extension UIStrings {
    static let openGitHubReleases = Localized("Open GitHub releases", "GitHub sürümlerini aç")
}

extension UIStrings {
    static let mappingApplied = Localized(
        "Applied — this app is now shown as Homebrew-managed",
        "Uygulandı — bu uygulama artık Homebrew yönetiminde görünüyor"
    )
    static let mappingValid = Localized(
        "That cask is installed",
        "Bu cask kurulu"
    )
    static let mappingUnknownCask = Localized(
        "No installed cask with that name — the mapping will have no effect",
        "Bu isimde kurulu bir cask yok — eşleme etkisiz kalır"
    )
}

extension UIStrings {
    static let manuallyMappedHelp = Localized(
        "Manually mapped in Name Mapping — this is not the automatic guess",
        "İsim Eşlemesi'nde elle eşlendi — otomatik tahmin değil"
    )
    static let homebrewPageTitle = Localized(
        "Open the Homebrew page for this app?",
        "Bu uygulamanın Homebrew sayfası açılsın mı?"
    )
    static let githubReleasesTitle = Localized(
        "Open the GitHub releases page for this app?",
        "Bu uygulamanın GitHub sürümler sayfası açılsın mı?"
    )
    static let openInBrowser = Localized("Open in Browser", "Tarayıcıda Aç")
}

extension UIStrings {
    static let officialWebsiteTitle = Localized(
        "Open the official website for this app?",
        "Bu uygulamanın resmi sitesi açılsın mı?"
    )
    static let openOfficialWebsite = Localized("Open official website", "Resmi siteyi aç")
}

extension UIStrings {
    static let editLinks = Localized("Edit Links…", "Bağlantıları Düzenle…")
    static let editLinksTitleFormat = Localized("Edit Links for %@", "%@ için Bağlantıları Düzenle")
    static let editLinksHelp = Localized(
        "Local only — this stays on this Mac and only affects what you see here. Leave a field blank to keep the automatically detected value.",
        "Sadece yerel — bu ayar yalnızca bu Mac'te kalır ve sadece burada gördüğünüzü etkiler. Otomatik bulunan değeri korumak için alanı boş bırakın."
    )
    static let officialWebsiteField = Localized("Official website", "Resmi site")
    static let githubRepoField = Localized("GitHub repository", "GitHub deposu")
    static let invalidWebsiteURL = Localized("Must be a valid https:// address", "Geçerli bir https:// adresi olmalı")
    static let invalidGithubRepo = Localized("Must look like owner/repository", "owner/repository biçiminde olmalı")
    static let resetToAutomatic = Localized("Reset to Automatic", "Otomatiğe Sıfırla")
    static let save = Localized("Save", "Kaydet")
    static let customLinksHelp = Localized(
        "One or both links were corrected by hand — right-click to edit or reset",
        "Bir veya iki bağlantı elle düzeltildi — düzenlemek veya sıfırlamak için sağ tıklayın"
    )
}

extension UIStrings {
    static let moreOptions = Localized("More options", "Daha fazla seçenek")
    static let editTrackingMethod = Localized("Edit Tracking Method…", "Takip Yöntemini Düzenle…")
    static let editHomebrewMapping = Localized("Edit Homebrew Mapping…", "Homebrew Eşlemesini Düzenle…")
    static let editTrackingTitleFormat = Localized("Edit Tracking for %@", "%@ için Takibi Düzenle")
    static let editTrackingHelp = Localized(
        "Local only. Only needed when the automatic detection is wrong or missing — most apps never need a rule here.",
        "Sadece yerel. Yalnızca otomatik tespit yanlış veya eksikse gerekir — çoğu uygulamanın buna ihtiyacı olmaz."
    )
    static let invalidIdentifier = Localized("This does not look right for the selected method", "Seçilen yöntem için bu doğru görünmüyor")
    static let editMappingTitleFormat = Localized("Edit Homebrew Mapping for %@", "%@ için Homebrew Eşlemesini Düzenle")
    static let editMappingHelp = Localized(
        "Local only. Maps this app to a specific Homebrew cask when the name cannot be guessed automatically.",
        "Sadece yerel. İsimden otomatik tahmin edilemeyen durumlarda bu uygulamayı belirli bir Homebrew cask'ine eşler."
    )
}

extension UIStrings {
    static let openGitHubRepository = Localized("Open GitHub repository", "GitHub deposunu aç")
    static let githubRepositoryTitle = Localized(
        "Open the GitHub repository for this app?",
        "Bu uygulamanın GitHub deposu açılsın mı?"
    )
}

extension UIStrings {
    static let homebrewVersionLabel = Localized("Homebrew version", "Homebrew sürümü")
    static let homebrewDatabaseLabel = Localized("Database last updated", "Veritabanı son güncelleme")
    static let homebrewStaleHelp = Localized(
        "Homebrew has no versions to check for the way an app does — \"Check Homebrew\" pulls the latest metadata without upgrading anything.",
        "Homebrew'un bir uygulama gibi kontrol edilecek sürümü yok — \"Homebrew'u Denetle\" hiçbir şeyi güncellemeden en son verileri çeker."
    )
    static let checkHomebrewNow = Localized("Check Homebrew", "Homebrew'u Denetle")
    static let checkHomebrewNowHelp = Localized(
        "Pulls the latest Homebrew and tap metadata (\"brew update\") without upgrading any package.",
        "En son Homebrew ve tap verilerini çeker (\"brew update\"), hiçbir paketi güncellemez."
    )
}

extension UIStrings {
    static let runInTerminal = Localized("Run updates in Terminal", "Güncellemeleri Terminal'de çalıştır")
    static let runInTerminalHelp = Localized(
        "Off by default: updates run in the background and show progress right here in the app. Turn this on to watch (and stop) them in a terminal window instead.",
        "Varsayılan kapalı: güncellemeler arka planda çalışır, ilerleme burada, uygulama içinde gösterilir. Bunu açarsanız güncellemeleri bir terminal penceresinde izleyebilir (ve durdurabilir)siniz."
    )
}
