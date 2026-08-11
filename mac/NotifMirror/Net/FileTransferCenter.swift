import AppKit
import CryptoKit
import Foundation
import UserNotifications

/// Coordinates chunked file transfers in both directions over the shared
/// WebSocket. Chunk size is 256 KiB (encoded as base64 ~= 340 KiB) which
/// stays well under the 8 MiB frame cap.
@MainActor
final class FileTransferCenter {
    static let shared = FileTransferCenter()

    private let chunkSize = 256 * 1024

    /// In-flight incoming transfers: xid → open file handle + expected size.
    private var incoming: [String: IncomingState] = [:]
    /// In-flight outgoing transfers: xid → source url + progress.
    private var outgoing: [String: OutgoingState] = [:]

    private struct IncomingState {
        let url: URL
        let handle: FileHandle
        let expectedSize: Int64
        var received: Int64
        let expectedSha256: String?
    }

    private struct OutgoingState {
        let url: URL
        let size: Int64
        var offset: Int64
    }

    private init() {}

    // MARK: - Outgoing (Mac → Android)

    func sendFile(url: URL) {
        guard WsServer.shared.isClientAuthed else {
            AppState.shared.lastError = "No paired device is connected."
            return
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            AppState.shared.lastError = "Not a regular file."
            return
        }
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let xid = Self.newXid()
        outgoing[xid] = OutgoingState(url: url, size: size, offset: 0)
        AppState.shared.transfers[xid] = TransferProgress(
            id: xid,
            direction: .outgoing,
            name: url.lastPathComponent,
            size: size,
            bytesTransferred: 0,
            status: .pending
        )

        let mime = Self.mimeType(for: url)
        WsServer.shared.send(.fileOffer(.init(
            xid: xid,
            name: url.lastPathComponent,
            size: size,
            mime: mime,
            sha256: nil // skipping — big files would stall the UI
        )))
    }

    func handleAccept(xid: String) {
        guard var s = outgoing[xid] else { return }
        AppState.shared.transfers[xid]?.status = .active
        // Start pumping chunks.
        pump(xid: xid, state: &s)
    }

    func handleReject(xid: String, reason: String) {
        outgoing.removeValue(forKey: xid)
        AppState.shared.transfers[xid]?.status = .failed("rejected: \(reason)")
    }

    func handleAck(xid: String, ok: Bool, error: String?) {
        outgoing.removeValue(forKey: xid)
        if ok {
            AppState.shared.transfers[xid]?.status = .done
        } else {
            AppState.shared.transfers[xid]?.status = .failed(error ?? "unknown")
        }
    }

    private func pump(xid: String, state: inout OutgoingState) {
        outgoing[xid] = state
        let url = state.url
        let size = state.size
        let chunk = chunkSize
        Task.detached { [weak self] in
            await Self.pumpOffMain(xid: xid, url: url, size: size, chunk: chunk, center: self)
        }
    }

    private static func pumpOffMain(
        xid: String, url: URL, size: Int64, chunk: Int, center: FileTransferCenter?
    ) async {
        let fh: FileHandle
        do {
            fh = try FileHandle(forReadingFrom: url)
        } catch {
            await MainActor.run {
                WsServer.shared.send(.fileCancel(xid: xid, reason: "io_error"))
                AppState.shared.transfers[xid]?.status = .failed("open: \(error.localizedDescription)")
                center?.outgoing.removeValue(forKey: xid)
            }
            return
        }
        defer { try? fh.close() }

        var offset: Int64 = 0
        while true {
            // Check for cancellation/disconnection.
            let shouldContinue: Bool = await MainActor.run {
                guard let c = center, c.outgoing[xid] != nil else { return false }
                guard case .active = AppState.shared.transfers[xid]?.status else { return false }
                return true
            }
            if !shouldContinue { return }

            let remaining = size - offset
            if remaining <= 0 {
                await MainActor.run {
                    WsServer.shared.send(.fileDone(xid: xid))
                }
                return
            }

            let toRead = Int(min(Int64(chunk), remaining))
            let data: Data
            do {
                try fh.seek(toOffset: UInt64(offset))
                data = try fh.read(upToCount: toRead) ?? Data()
            } catch {
                await MainActor.run {
                    WsServer.shared.send(.fileCancel(xid: xid, reason: "io_error"))
                    AppState.shared.transfers[xid]?.status = .failed("read: \(error.localizedDescription)")
                    center?.outgoing.removeValue(forKey: xid)
                }
                return
            }
            if data.isEmpty { return }

            let last = (offset + Int64(data.count)) >= size
            let sentOffset = offset
            offset += Int64(data.count)

            // Push raw binary on the existing WebSocket. No base64, no
            // separate data-plane socket — just a WS binary frame on the
            // OkHttp/NWConnection pipe that's proven to stay healthy
            // end-to-end.
            WsServer.shared.sendBinaryChunk(
                kind: WsServer.chunkKindFile, id: xid,
                offset: sentOffset, payload: data, last: last
            )

            await MainActor.run {
                if var s = center?.outgoing[xid] {
                    s.offset = offset
                    center?.outgoing[xid] = s
                }
                AppState.shared.transfers[xid]?.bytesTransferred = offset
                if last {
                    WsServer.shared.send(.fileDone(xid: xid))
                }
            }

            if last { return }
        }
    }

    // MARK: - Incoming (Android → Mac)

    func handleOffer(_ offer: WireMessage.FileOffer) {
        // Auto-accept everything into the inbox. Users can reject by
        // deleting afterwards — the UX for a modal accept prompt is a future
        // polish item.
        let inbox = Preferences.shared.fileInboxPath
        let dir = URL(fileURLWithPath: inbox, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            WsServer.shared.send(.fileReject(xid: offer.xid, reason: "io_error"))
            AppState.shared.lastError = "Inbox create failed: \(error.localizedDescription)"
            return
        }

        let dest = Self.uniqueDestination(in: dir, name: offer.name)
        // Create empty file we can append to.
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            WsServer.shared.send(.fileReject(xid: offer.xid, reason: "io_error"))
            return
        }

        incoming[offer.xid] = IncomingState(
            url: dest,
            handle: handle,
            expectedSize: offer.size,
            received: 0,
            expectedSha256: offer.sha256
        )

        AppState.shared.transfers[offer.xid] = TransferProgress(
            id: offer.xid,
            direction: .incoming,
            name: offer.name,
            size: offer.size,
            bytesTransferred: 0,
            status: .active,
            destinationPath: dest.path
        )

        WsServer.shared.send(.fileAccept(xid: offer.xid))
    }

    /// Entry point from the raw-TCP data channel. Replaces the old
    /// `handleChunk(data: String)` WS path — no base64 on the wire anymore.
    func handleBinaryChunk(xid: String, offset: Int64, bytes: Data, last: Bool) {
        guard var s = incoming[xid] else { return }
        do {
            if !bytes.isEmpty {
                try s.handle.seek(toOffset: UInt64(offset))
                try s.handle.write(contentsOf: bytes)
                s.received = offset + Int64(bytes.count)
                incoming[xid] = s
                AppState.shared.transfers[xid]?.bytesTransferred = s.received
            }
            _ = last // fileDone still arrives on WS and drives close+ack
        } catch {
            failIncoming(xid: xid, msg: "write: \(error.localizedDescription)")
        }
    }

    func handleDone(xid: String) {
        guard let s = incoming.removeValue(forKey: xid) else {
            WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "unknown xid"))
            return
        }
        do { try s.handle.close() } catch { /* ignore */ }

        if s.received != s.expectedSize {
            AppState.shared.transfers[xid]?.status = .failed(
                "size mismatch (got \(s.received), expected \(s.expectedSize))"
            )
            WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "size_mismatch"))
            return
        }

        if let expected = s.expectedSha256 {
            if let actual = Self.sha256(of: s.url), actual != expected {
                AppState.shared.transfers[xid]?.status = .failed("sha256 mismatch")
                WsServer.shared.send(.fileAck(xid: xid, ok: false, error: "sha256_mismatch"))
                return
            }
        }

        AppState.shared.transfers[xid]?.status = .done
        WsServer.shared.send(.fileAck(xid: xid, ok: true, error: nil))
        notifyArrived(name: s.url.lastPathComponent, path: s.url.path)
    }

    private func notifyArrived(name: String, path: String) {
        let content = UNMutableNotificationContent()
        content.title = "File received from phone"
        content.body = name
        content.sound = .default
        content.userInfo = ["filePath": path]
        let id = "file-arrived-\(UUID().uuidString)"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { NSLog("file-arrived notification add error: \(err)") }
        }
    }

    func handleCancel(xid: String, reason: String) {
        if let s = incoming.removeValue(forKey: xid) {
            try? s.handle.close()
            try? FileManager.default.removeItem(at: s.url)
        }
        outgoing.removeValue(forKey: xid)
        AppState.shared.transfers[xid]?.status = .cancelled
    }

    func peerDisconnected() {
        for (_, s) in incoming {
            try? s.handle.close()
            try? FileManager.default.removeItem(at: s.url)
        }
        incoming.removeAll()
        outgoing.removeAll()
        // Mark in-flight as failed.
        for (k, var v) in AppState.shared.transfers {
            if case .active = v.status {
                v.status = .failed("disconnected")
                AppState.shared.transfers[k] = v
            } else if case .pending = v.status {
                v.status = .failed("disconnected")
                AppState.shared.transfers[k] = v
            }
        }
    }

    private func failIncoming(xid: String, msg: String) {
        if let s = incoming.removeValue(forKey: xid) {
            try? s.handle.close()
            try? FileManager.default.removeItem(at: s.url)
        }
        AppState.shared.transfers[xid]?.status = .failed(msg)
        WsServer.shared.send(.fileCancel(xid: xid, reason: "io_error"))
    }

    // MARK: - Helpers

    private static func newXid() -> String {
        // 8 hex chars of random = 32 bits, plenty to avoid collisions between
        // two in-flight transfers.
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func uniqueDestination(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: url.path) { return url }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for i in 1...999 {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            url = dir.appendingPathComponent(candidate)
            if !fm.fileExists(atPath: url.path) { return url }
        }
        return url
    }

    private static func mimeType(for url: URL) -> String? {
        // Minimal best-effort; a full UTType lookup would be nicer.
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "mp3": return "audio/mpeg"
        case "mp4", "m4v": return "video/mp4"
        default: return nil
        }
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
