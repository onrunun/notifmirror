import AppKit
import Foundation
import UserNotifications

@MainActor
final class NotificationPresenter {
    static let shared = NotificationPresenter()

    private var registry = CategoryRegistry()
    private let appIconCache = AppIconCache()

    private init() {}

    func start() {
        NSLog("NotificationPresenter started")
    }

    func handlePosted(_ p: WireMessage.Posted) {
        Task { @MainActor in
            if p.silent && Preferences.shared.hideSilent {
                NSLog("dropping silent notification from \(p.pkg)")
                return
            }
            let blocked = BlockedApps.shared.recordAndCheck(pkg: p.pkg, name: p.app)
            if blocked {
                NSLog("dropping notification from blocked pkg: \(p.pkg)")
                return
            }
            let categoryId = p.key
            let actions: [UNNotificationAction] = p.actions.map { a in
                let identifier = "\(p.key)#\(a.id)"
                if a.isReply {
                    return UNTextInputNotificationAction(
                        identifier: identifier,
                        title: a.title,
                        options: [.authenticationRequired],
                        textInputButtonTitle: "Send",
                        textInputPlaceholder: "Type a reply"
                    )
                } else {
                    return UNNotificationAction(
                        identifier: identifier,
                        title: a.title,
                        options: []
                    )
                }
            }
            let category = UNNotificationCategory(
                identifier: categoryId,
                actions: actions,
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            await registry.register(category: category)

            let content = UNMutableNotificationContent()
            content.title = p.title?.nilIfEmpty ?? p.app
            if let sub = p.subText, !sub.isEmpty { content.subtitle = sub }
            else if (p.title?.isEmpty == false) { content.subtitle = p.app }
            content.body = p.text ?? ""

            if let text = p.text, !text.isEmpty,
               let code = CodeExtractor.shared.code(in: text) {
                content.subtitle = "Code: \(code)"
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(code, forType: .string)
            }
            content.categoryIdentifier = categoryId
            content.userInfo = ["notifKey": p.key, "pkg": p.pkg]
            content.sound = .default

            // Cache and use app icon as a thumbnail when no picture.
            if let appIconB64 = p.appIcon {
                appIconCache.store(pkg: p.pkg, base64: appIconB64)
            }

            // Attachment: prefer picture (the WhatsApp-photo case),
            // else largeIcon, else cached app icon.
            let preferredB64 = p.picture ?? p.largeIcon ?? appIconCache.base64(forPkg: p.pkg)
            var attachmentPath: String? = nil
            if let b64 = preferredB64,
               let result = AttachmentWriter.makeAttachment(base64: b64) {
                content.attachments = [result.attachment]
                attachmentPath = result.url.path
            }

            NotificationHistory.shared.record(p, attachmentPath: attachmentPath)

            let request = UNNotificationRequest(
                identifier: p.key,
                content: content,
                trigger: nil
            )
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                NSLog("notification add error: \(error)")
            }
        }
    }

    func handleRemoved(key: String) {
        Task { @MainActor in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [key])
            await registry.markStale(categoryId: key)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
