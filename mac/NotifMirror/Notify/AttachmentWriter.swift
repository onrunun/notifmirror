import Foundation
import UserNotifications

enum AttachmentWriter {
    static let attachmentDirectory: URL = {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("NotifMirror/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    struct Result {
        let attachment: UNNotificationAttachment
        let url: URL
    }

    /// Decode a base64 image into a persistent file under Application Support
    /// and wrap as UNNotificationAttachment. The file is kept so the History
    /// view can render it later.
    static func makeAttachment(base64: String) -> Result? {
        guard let data = Data(base64Encoded: base64) else { return nil }

        let ext = sniffExtension(data: data)
        let url = attachmentDirectory
            .appendingPathComponent("notifmirror-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            let attachment = try UNNotificationAttachment(
                identifier: UUID().uuidString,
                url: url,
                options: [UNNotificationAttachmentOptionsTypeHintKey: utiHint(ext)]
            )
            return Result(attachment: attachment, url: url)
        } catch {
            NSLog("attachment write/create error: \(error)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func utiHint(_ ext: String) -> String {
        switch ext {
        case "jpg": return "public.jpeg"
        case "png": return "public.png"
        case "gif": return "com.compuserve.gif"
        case "webp": return "org.webmproject.webp"
        default: return "public.image"
        }
    }

    /// Extremely small magic-byte sniff. Defaults to png.
    private static func sniffExtension(data: Data) -> String {
        if data.count >= 3,
           data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF { return "jpg" }
        if data.count >= 8,
           data[0] == 0x89, data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 { return "png" }
        if data.count >= 6,
           data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 { return "webp" }
        return "png"
    }
}
