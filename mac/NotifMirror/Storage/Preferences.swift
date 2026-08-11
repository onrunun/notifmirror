import Combine
import Foundation
import ServiceManagement

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let hideSilentKey = "hideSilentNotifications"
    private let clipKey = "clipboardSyncEnabled"
    private let mediaKey = "mediaControlEnabled"
    private let fileInboxKey = "fileInboxPath"
    private let launchAtLoginKey = "launchAtLogin"

    @Published var hideSilent: Bool {
        didSet { UserDefaults.standard.set(hideSilent, forKey: hideSilentKey) }
    }

    @Published var clipboardSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(clipboardSyncEnabled, forKey: clipKey) }
    }

    @Published var mediaControlEnabled: Bool {
        didSet { UserDefaults.standard.set(mediaControlEnabled, forKey: mediaKey) }
    }

    /// Path where incoming files are written. Defaults to ~/Downloads.
    @Published var fileInboxPath: String {
        didSet { UserDefaults.standard.set(fileInboxPath, forKey: fileInboxKey) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: launchAtLoginKey)
            applyLaunchAtLogin()
        }
    }

    private init() {
        let d = UserDefaults.standard
        self.hideSilent = d.bool(forKey: hideSilentKey)
        // Default both new features OFF so users opt in — these move
        // potentially sensitive data over plaintext WS.
        self.clipboardSyncEnabled = d.object(forKey: clipKey) as? Bool ?? false
        self.mediaControlEnabled = d.object(forKey: mediaKey) as? Bool ?? true
        let defaultInbox = (NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first)
            ?? NSHomeDirectory() + "/Downloads"
        self.fileInboxPath = (d.string(forKey: fileInboxKey)?.nilIfEmpty) ?? defaultInbox
        self.launchAtLogin = d.bool(forKey: launchAtLoginKey)
    }

    /// Reconcile the stored preference with the real system state. The user
    /// may have toggled the login item from System Settings while the app
    /// was closed — trust the OS, not UserDefaults.
    func syncLaunchAtLoginWithSystem() {
        let registered = SMAppService.mainApp.status == .enabled
        if launchAtLogin != registered {
            // Avoid re-triggering applyLaunchAtLogin from didSet.
            UserDefaults.standard.set(registered, forKey: launchAtLoginKey)
            launchAtLogin = registered
        }
    }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            NSLog("launch-at-login toggle failed: \(error)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
