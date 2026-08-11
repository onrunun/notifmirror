import AppKit
import CryptoKit
import Foundation

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
        guard Preferences.shared.clipboardSyncEnabled else { return }
        let h = Self.sha256(text)
        lastWrittenHash = h
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Our own write bumps changeCount — remember it so `tick()` doesn't
        // treat it as a local change.
        lastChangeCount = pasteboard.changeCount
        AppState.shared.lastClipDirection = .incoming
        AppState.shared.lastClipAt = Date()
    }

    private static func sha256(_ s: String) -> String {
        let d = Data(s.utf8)
        let h = SHA256.hash(data: d)
        return h.map { String(format: "%02x", $0) }.joined()
    }
}
