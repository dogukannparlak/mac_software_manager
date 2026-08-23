import AppKit
import SwiftUI

@main
struct MacUpdaterGuideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @State private var localization = LocalizationStore()
    @State private var preferences = AppPreferences()
    @State private var toolkit: ToolkitController
    @State private var iconCache = AppIconCache()
    @State private var navigation = NavigationStore()
    @State private var inventory = InventoryStore()
    @State private var onboarding = OnboardingStore()

    init() {
        let preferences = AppPreferences()
        _preferences = State(initialValue: preferences)
        _toolkit = State(initialValue: ToolkitController(preferences: preferences))
    }

    var body: some Scene {
        // The window scene has to come first. SwiftUI presents the first
        // window-bearing scene at launch, and with MenuBarExtra ahead of it
        // nothing opened at all - the app started, drew its menu bar icon and
        // looked to the user like it had failed.
        Window(GuideContent.appName[localization.language], id: "guide") {
            ContentView()
                .environment(localization)
                .environment(toolkit)
                .environment(iconCache)
                .environment(navigation)
                .environment(inventory)
                .environment(onboarding)
                .frame(minWidth: 920, minHeight: 600)
                .task {
                    toolkit.reload()
                    toolkit.startScheduler()
                    await inventory.load()
                    // Last, and only after the cheap local work: this stats a
                    // few files, and a first launch on a Mac that is fully set
                    // up must not wait on it to draw anything.
                    await onboarding.presentIfNeeded()
                }
                .sheet(isPresented: sheetBinding) {
                    OnboardingSheet()
                        .environment(localization)
                        .environment(toolkit)
                        .environment(onboarding)
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(replacing: .appSettings) {
                Button(UIStrings.settings[localization.language]) {
                    navigation.show(.settings(.general))
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button(UIStrings.refreshNow[localization.language]) {
                    toolkit.refresh(force: true)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        // The menu bar item is created by this app - no plugin host involved.
        // Its content is a read-only status panel; anything configurable lives
        // in Settings, because changing preferences through nested menu bar
        // submenus is tedious.
        MenuBarExtra {
            MenuBarView()
                .environment(localization)
                .environment(toolkit)
                .environment(iconCache)
                .environment(navigation)
                .environment(inventory)
                .environment(onboarding)
        } label: {
            MenuBarLabel(pending: toolkit.snapshot.count, isRefreshing: toolkit.isRefreshing)
        }
        .menuBarExtraStyle(.window)

    }

    /// `@Observable` state is not `@Bindable` from a `Scene`, so the sheet
    /// gets its binding built by hand rather than through `$onboarding`.
    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { onboarding.isPresented },
            set: { onboarding.isPresented = $0 }
        )
    }
}

/// The menu bar icon itself: a badge when something is waiting, a plain
/// check mark when it is not.
private struct MenuBarLabel: View {
    let pending: Int
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if pending > 0 {
                Text("\(pending)")
            }
        }
    }

    /// The same symbols the menu bar plugin always used, which is what the
    /// README documents and what people recognise.
    private var symbol: String {
        if isRefreshing { return "arrow.triangle.2.circlepath" }
        return pending > 0 ? "arrow.triangle.2.circlepath.circle" : "checkmark.circle"
    }
}

/// Switches between a normal app and a menu-bar-only one.
///
/// `.accessory` removes the Dock icon and the app menu. Everything that would
/// otherwise be unreachable - Settings, the guide window, Quit - is already in
/// the menu bar panel, so nothing is lost.
enum DockVisibility {
    @MainActor
    static func apply(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        if !hidden {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Without an explicit activation policy a bundle-less run stays in the
/// background; setting it here also means the app behaves the same whether it
/// is launched from Xcode, Finder or the command line.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let hidden = UserDefaults.standard.bool(forKey: "com.macupdater.guide.hideDockIcon")
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }

        NotificationBridge.shared.start()
    }

    /// Clicking the Dock icon with no window open should bring the guide back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The menu bar item keeps working after the window is closed.
        false
    }
}
