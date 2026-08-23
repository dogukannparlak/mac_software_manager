import AppKit
import Foundation
import UserNotifications

/// One request file's worth of content - see CACHE_FORMAT.md ("Notification
/// queue") for the format both this and the shell writer (`notify()` in
/// lib/utils.sh) agree on.
///
/// Parsing kept separate from the filesystem/UNUserNotificationCenter side
/// (NotificationBridge below), the same split ToolkitRunner uses for
/// ProcessOutcome and UpdateProgress uses for its own `parse` - so the format
/// itself can be unit-tested without touching a notification center or disk.
struct NotificationRequest: Equatable, Sendable {
    let title: String
    let subtitle: String
    let body: String

    /// The only format version this build understands. A missing or
    /// unrecognized version fails closed (returns nil) rather than guessing.
    static let formatVersion = "v1"

    static func parse(raw: String) -> NotificationRequest? {
        let fields = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard fields.count == 4, fields[0] == formatVersion else { return nil }
        return NotificationRequest(title: fields[1], subtitle: fields[2], body: fields[3])
    }
}

/// Turns notification requests dropped by the shell engine into native
/// UNUserNotificationCenter alerts.
///
/// The shell engine can run headless - cron, a terminal - with no
/// guarantee this app is even running, so it cannot call into a specific
/// process directly. Instead it drops one file per notification into
/// ToolkitPaths.notificationsDirectory, the same file-based handoff the rest
/// of this app already uses for cache/progress/history, and only bothers
/// doing that when a process named MacUpdaterGuide is already running - see
/// `notify()` in lib/utils.sh. This watches that directory and consumes
/// whatever it finds. A raw `osascript display notification` (labeled
/// "Script Editor", no actions) is the shell's own fallback for whenever
/// this bridge cannot be reached at all.
@MainActor
final class NotificationBridge: NSObject {
    static let shared = NotificationBridge()

    private static let categoryIdentifier = "com.macupdater.guide.notification"
    private static let openActionIdentifier = "com.macupdater.guide.notification.open"

    private var source: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1

    private override init() {}

    /// Requests permission, registers the "Open" action category, drains
    /// anything already waiting from before this launch, then starts
    /// watching for new files. Safe to call more than once - re-arms the
    /// watcher instead of duplicating it.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let openAction = UNNotificationAction(
            identifier: Self.openActionIdentifier,
            title: "Open",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let directory = ToolkitPaths.notificationsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        drainPending()
        watch(directory: directory)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    // MARK: - Watching

    /// A kevent-driven watch on the directory itself (not polling): the
    /// shell writes rarely - a handful of notifications per run at most - so
    /// there is no reason to wake up on a timer the rest of the time this
    /// app is running.
    private func watch(directory: URL) {
        let path = directory.path(percentEncoded: false)
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            self?.drainPending()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        self.source = source
    }

    /// Consumes every request file currently in the directory. Files are
    /// removed as they are read, so a request is delivered at most once even
    /// if several write events coalesce into a single callback, and a file
    /// that fails to parse is discarded rather than retried forever.
    private func drainPending() {
        let directory = ToolkitPaths.notificationsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in entries {
            defer { try? FileManager.default.removeItem(at: fileURL) }
            guard let data = try? Data(contentsOf: fileURL),
                  let raw = String(data: data, encoding: .utf8),
                  let request = NotificationRequest.parse(raw: raw) else { continue }
            post(request)
        }
    }

    private func post(_ request: NotificationRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        if !request.subtitle.isEmpty { content.subtitle = request.subtitle }
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        let notificationRequest = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(notificationRequest)
    }
}

extension NotificationBridge: UNUserNotificationCenterDelegate {
    /// Without this the system suppresses the banner because the app is
    /// already frontmost - these notifications matter even then.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Clicking the notification body or its "Open" action both bring the
    /// guide window forward - the same thing clicking the Dock icon does.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        completionHandler()
    }
}
