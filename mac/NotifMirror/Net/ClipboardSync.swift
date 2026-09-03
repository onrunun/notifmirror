import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Bridges the macOS pasteboard to the phone. Polls
/// `NSPasteboard.general.changeCount` because there's no notification for
/// pasteboard changes. Echo-suppresses by remembering the SHA-256 of anything
/// we just wrote ourselves.
@MainActor
final class ClipboardSync {
    static let shared = ClipboardSync()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private var lastWrittenHash: String? = nil
    private var outboundSeq: Int = 0
    private var timer: Timer?

    /// Hard cap per PROTOCOL.md — anything bigger is not mirrored.
    private let textCap = 64 * 1024

    /// Text that arrived while sync was off, kept only in memory; tapping the
    /// arrival banner enables sync and copies this.
    private var pendingRemoteClipText: String?

    private static let arrivalNotificationID = "notifmirror.clip.arrival"

    private init() {}

    func start() {
        lastChangeCount = pasteboard.changeCount
        // 500 ms polling — rare enough to be cheap, fast enough to feel live.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
    }

    private func tick() {
        guard Preferences.shared.clipboardSyncEnabled else { return }
        let cc = pasteboard.changeCount
        if cc == lastChangeCount { return }
        lastChangeCount = cc

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        if text.utf8.count > textCap { return }

        let h = Self.sha256(text)
        // If the pasteboard change was caused by our own write of a remote
        // clip, don't bounce it back.
        if h == lastWrittenHash { return }

        outboundSeq &+= 1
        WsServer.shared.send(.clip(text: text, origin: "mac", seq: outboundSeq))
        AppState.shared.lastClipDirection = .outgoing
        AppState.shared.lastClipAt = Date()
    }

    func handleRemoteClip(text: String, origin: String, seq: Int) {
        guard Preferences.shared.clipboardSyncEnabled else {
            // Don't drop silently — hold the text and say so.
            pendingRemoteClipText = text
            postArrivalNotification(text: text, syncDisabled: true)
            return
        }
        writeIncoming(text)
        postArrivalNotification(text: text, syncDisabled: false)
    }

    /// Banner tap action for a clip that arrived while sync was off: turn
    /// sync on and copy the held text.
    func acceptPendingClip() {
        guard let text = pendingRemoteClipText else { return }
        pendingRemoteClipText = nil
        Preferences.shared.clipboardSyncEnabled = true
        writeIncoming(text)
    }

    private func writeIncoming(_ text: String) {
        lastWrittenHash = Self.sha256(text)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Our own write bumps changeCount — remember it so `tick()` doesn't
        // treat it as a local change.
        lastChangeCount = pasteboard.changeCount
        AppState.shared.lastClipDirection = .incoming
        AppState.shared.lastClipAt = Date()
    }

    private func postArrivalNotification(text: String, syncDisabled: Bool) {
        let center = UNUserNotificationCenter.current()
        Task {
            // The launch-time prompt often never surfaces for LSUIElement
            // apps — ask here if it was never determined.
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            if syncDisabled {
                content.title = "Clipboard sync is off"
                content.body = "Tap to copy the text from your phone: \(Self.preview(of: text))"
            } else {
                content.title = "Text received from phone"
                content.body = Self.preview(of: text)
            }
            content.sound = .default
            // Fixed identifier — a rapid-fire resend replaces the old banner
            // instead of stacking up.
            let req = UNNotificationRequest(
                identifier: Self.arrivalNotificationID, content: content, trigger: nil)
            do {
                try await center.add(req)
            } catch {
                NSLog("clip-arrival notification add error: \(error)")
            }
        }
    }

    /// First line only, trimmed — banners don't fit much, and the full text
    /// lives in the pasteboard, not the banner.
    private static func preview(of text: String) -> String {
        let firstLine = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed }
        return trimmed.prefix(80) + "…"
    }

    private static func sha256(_ s: String) -> String {
        let d = Data(s.utf8)
        let h = SHA256.hash(data: d)
        return h.map { String(format: "%02x", $0) }.joined()
    }
}
