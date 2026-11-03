import Foundation

/// Why an app self-update (`AppUpdater`) stopped. Every case ends with
/// the installed app untouched.
enum UpdateFailure: Error {
    case network
    case checksumMissing
    case checksumMismatch
    case unpackFailed
    case wrongApp
    case signatureInvalid
    case busy
    case notInstallable
    case notWritable
    case helperFailed

    var message: Localized {
        switch self {
        case .network:
            return Localized(
                "Could not reach GitHub to check for a new version.",
                "Yeni sürümü denetlemek için GitHub'a ulaşılamadı."
            )
        case .checksumMissing:
            return Localized(
                "The release has no checksum for its download, so it was not installed.",
                "Sürümde indirilen dosya için kontrol toplamı yok, bu yüzden kurulmadı."
            )
        case .checksumMismatch:
            return Localized(
                "The download did not match its published checksum and was discarded.",
                "İndirilen dosya yayınlanan kontrol toplamıyla eşleşmedi ve silindi."
            )
        case .unpackFailed:
            return Localized(
                "The downloaded archive could not be unpacked.",
                "İndirilen arşiv açılamadı."
            )
        case .wrongApp:
            return Localized(
                "The download is not the expected version of this app and was discarded.",
                "İndirilen dosya bu uygulamanın beklenen sürümü değil ve silindi."
            )
        case .signatureInvalid:
            return Localized(
                "The downloaded app's signature is broken, so it was not installed.",
                "İndirilen uygulamanın imzası bozuk, bu yüzden kurulmadı."
            )
        case .busy:
            return Localized(
                "Wait for the running updates to finish, then restart to update.",
                "Çalışan güncellemelerin bitmesini bekleyin, ardından güncellemek için yeniden başlatın."
            )
        case .notInstallable:
            return Localized(
                "The app is running from a disk image or a temporary location. Move it to Applications first.",
                "Uygulama bir disk görüntüsünden ya da geçici bir konumdan çalışıyor. Önce Uygulamalar klasörüne taşıyın."
            )
        case .notWritable:
            return Localized(
                "This user cannot replace the app in its current folder. Download the new version from the release page instead.",
                "Bu kullanıcı uygulamayı bulunduğu klasörde değiştiremiyor. Yeni sürümü sürüm sayfasından indirin."
            )
        case .helperFailed:
            return Localized(
                "The installer could not be started. Nothing was changed.",
                "Kurulum başlatılamadı. Hiçbir şey değiştirilmedi."
            )
        }
    }
}
