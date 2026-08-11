import AppKit
import SwiftUI
import UserNotifications

/// NotifMirror is a menu-bar app (`LSUIElement=YES`), so by default it has no
/// Dock icon or App Switcher entry. While a real window is on screen (the
/// main NavigationSplitView or the screen-mirror NSWindow) we promote the
/// activation policy to `.regular` so the user can ⌘-tab to it and see it in
/// the Dock. A simple refcount keeps the two window sources from stomping on
/// each other.
@MainActor
final class DockIconController {
    static let shared = DockIconController()
    private var count = 0
    private init() {}

    func acquire() {
        count += 1
        if count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func release() {
        count = max(0, count - 1)
        if count < 1 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@main
struct NotifMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .frame(width: 320)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)

        Window("NotifMirror", id: "main") {
            MainWindow()
                .environmentObject(state)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 640)
        .windowToolbarStyle(.unified(showsTitle: true))
    }
}

/// MenuBarExtra label. Lives in the SwiftUI scene tree for the entire app
/// lifetime (the bell icon is always rendered), so this is the only reliable
/// place to host `\.openWindow` calls that need to fire even when the menu
/// popup is closed — e.g. opening the main window in response to a clicked
/// macOS notification while the user isn't interacting with the app.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: state.isClientConnected ? "bell.badge.fill" : "bell")
            .onChange(of: state.openMainWindowRequest) { _, token in
                guard token != nil else { return }
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                state.openMainWindowRequest = nil
            }
            .onChange(of: state.showPairingWindow) { _, shouldShow in
                guard shouldShow else { return }
                MainWindowSelection.shared.pending = .pairing
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                state.showPairingWindow = false
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = DelegateHandler.shared

        Task { @MainActor in
            Preferences.shared.syncLaunchAtLoginWithSystem()
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                NSLog("notification authorization error: \(error)")
            }
            // Surface the current state so the user can tell when banners are
            // silently disabled (denied, or only the notification center list
            // is allowed — no banner).
            let settings = await center.notificationSettings()
            NSLog("notification settings — authorization=\(settings.authorizationStatus.rawValue) "
                  + "alert=\(settings.alertStyle.rawValue) banner=\(settings.alertSetting.rawValue) "
                  + "list=\(settings.notificationCenterSetting.rawValue)")
            if settings.authorizationStatus == .denied {
                AppState.shared.lastError =
                    "Notifications are disabled. Enable them in System Settings › Notifications › NotifMirror."
            } else if settings.alertStyle == .none && settings.authorizationStatus == .authorized {
                AppState.shared.lastError =
                    "Banner style is off. Set it to Banners or Alerts in System Settings › Notifications › NotifMirror."
            }
        }

        NotificationPresenter.shared.start()

        Task { @MainActor in
            ClipboardSync.shared.start()
        }

        // Run on a background queue: WsServer.start() does a one-time
        // openssl shell-out to mint the TLS cert on first launch, which
        // blocks the calling thread for ~1–2 s. Doing that on the main
        // actor freezes the run loop during initial UI render and was
        // observed to crash SwiftUI's MainActor executor lookup
        // (swift_task_isCurrentExecutorWithFlagsImpl) on macOS 26.4 inside
        // an NSSwitch layout pass. Background queue avoids both the freeze
        // and the crash; failure paths hop back to the main actor for UI.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try WsServer.shared.start()
            } catch {
                NSLog("server start failed: \(error)")
                Task { @MainActor in
                    AppState.shared.lastError =
                        "Server failed: \(error.localizedDescription)"
                }
            }
        }

        if Pairing.shared.loadSecret() == nil {
            // Brand-new install — generate secret and ask SwiftUI to open the
            // main window on the Pairing tab via the shared deep-link bridge.
            _ = Pairing.shared.regenerateSecret()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                MainWindowSelection.shared.pending = .pairing
                AppState.shared.showPairingWindow = true
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
