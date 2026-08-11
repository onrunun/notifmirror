import Foundation

/// Diagnostic file logger. NSLog output from dynamically-loaded Swift apps
/// doesn't always land in the unified log the way you'd expect, so while
/// we're chasing the Wi-Fi pull stall we write straight to a flat file at
/// /tmp/notifmirror.log for easy tailing.
enum DebugLog {
    private static let path = "/tmp/notifmirror.log"
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static let queue = DispatchQueue(label: "com.notifmirror.app.debuglog")

    static func line(_ message: String) {
        let stamped = "\(fmt.string(from: Date())) \(message)\n"
        queue.async {
            if let data = stamped.data(using: .utf8) {
                if let fh = FileHandle(forWritingAtPath: path) {
                    _ = try? fh.seekToEnd()
                    try? fh.write(contentsOf: data)
                    try? fh.close()
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
}

/// Browses / reads / writes the paired phone's filesystem over the existing
/// WebSocket. Used when the phone advertises the `fsbrowse` feature; otherwise
/// the app falls back to `AdbClient`.
///
/// Every public method is async and correlates a request with its response(s)
/// via a `reqId` (8 random hex chars). In-flight ops are tracked in
/// `pendingOps`; `WsServer` calls `deliver(_:)` for each inbound `fs_*` frame.
@MainActor
final class ProtocolFileClient {
    static let shared = ProtocolFileClient()

    private init() {}

    private static let chunkSize: Int = 256 * 1024

    /// Serial background queue for base64-decoding incoming `fs_chunk`
    /// payloads and writing them to disk. Keeps the heavy work off the
    /// main actor so the pull can keep up with Android's 256 KiB chunk
    /// stream even while other main-actor work (folder-size analyze,
    /// SwiftUI rendering, etc.) is in flight.
    private static let chunkWriteQueue = DispatchQueue(
        label: "com.notifmirror.app.fsChunkWrite",
        qos: .userInitiated
    )

    // MARK: - Pending op tracking

    /// One in-flight op's continuations + state. Only one kind is active per
    /// `reqId`, so we use a single struct with all optional slots.
    private final class Pending {
        // Simple RPCs (list/delete/mkdir/disk) — resolved by one response.
        var resumeList: CheckedContinuation<([WireMessage.FsEntry], String?), Error>? = nil
        var resumeOp: CheckedContinuation<Void, Error>? = nil
        var resumeDisk: CheckedContinuation<(Int64, Int64), Error>? = nil
        var resumeDu: CheckedContinuation<DiskUsageReport, Error>? = nil

        // Read: header → many chunks → last chunk. We write chunks to a
        // FileHandle as they arrive, report progress, and resume `resumeRead`
        // when `last=true` is seen.
        var resumeRead: CheckedContinuation<Void, Error>? = nil
        var readHandle: FileHandle? = nil
        var readExpectedSize: Int64 = 0
        var readBytesSoFar: Int64 = 0
        var readProgress: ((Double) -> Void)? = nil
        var lastProgressAt: CFAbsoluteTime = 0
        /// Time of the last chunk received (or start of pull). Used by the
        /// watchdog in `pull()` to detect stalls and fail the transfer.
        var lastChunkAt: CFAbsoluteTime = 0

        // Write: wait for `fs_write_ready`, stream chunks, wait for final
        // `fs_op_result{ok}`. Between ready and op_result, the sending loop
        // owns the flow — we stash the URL and progress handler so the loop
        // can run after `resumeWriteReady` fires.
        var resumeWriteReady: CheckedContinuation<Void, Error>? = nil
        var resumeWriteDone: CheckedContinuation<Void, Error>? = nil
    }

    private var pending: [String: Pending] = [:]

    // MARK: - Public API

    struct FsError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func list(path: String) async throws -> [AdbEntry] {
        let reqId = Self.makeReqId()
        let result: ([WireMessage.FsEntry], String?) = try await withCheckedThrowingContinuation { cont in
            let slot = Pending()
            slot.resumeList = cont
            pending[reqId] = slot
            WsServer.shared.send(.fsList(reqId: reqId, path: path))
        }
        if let err = result.1 {
            throw FsError(message: err)
        }
        return result.0.map { Self.toAdbEntry($0) }
    }

    func delete(path: String) async throws {
        try await opCall { reqId in .fsDelete(reqId: reqId, path: path) }
    }

    func mkdir(path: String) async throws {
        try await opCall { reqId in .fsMkdir(reqId: reqId, path: path) }
    }

    func rename(from: String, to: String) async throws {
        try await opCall { reqId in .fsRename(reqId: reqId, from: from, to: to) }
    }

    func diskUsage(path: String) async throws -> (free: Int64, total: Int64) {
        let reqId = Self.makeReqId()
        let pair: (Int64, Int64) = try await withCheckedThrowingContinuation { cont in
            let slot = Pending()
            slot.resumeDisk = cont
            pending[reqId] = slot
            WsServer.shared.send(.fsDisk(reqId: reqId, path: path))
        }
        return (free: pair.0, total: pair.1)
    }

    /// Walks `path` recursively on the phone and returns per-immediate-child
    /// totals. Slow on big roots like `/sdcard` (seconds, sometimes tens of
    /// seconds) — callers should show a spinner.
    func diskAnalyze(path: String) async throws -> DiskUsageReport {
        let reqId = Self.makeReqId()
        return try await withCheckedThrowingContinuation { cont in
            let slot = Pending()
            slot.resumeDu = cont
            pending[reqId] = slot
            WsServer.shared.send(.fsDu(reqId: reqId, path: path))
        }
    }

    func pull(
        remote: String,
        to local: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        let reqId = Self.makeReqId()
        DebugLog.line("[fspull] start reqId=\(reqId) remote=\(remote)")

        // Prepare destination. Open for writing before sending fs_read so
        // chunks that arrive fast have a handle ready.
        let fm = FileManager.default
        try? fm.removeItem(at: local)
        fm.createFile(atPath: local.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: local) else {
            throw FsError(message: "cannot open \(local.path) for write")
        }

        let slot = Pending()
        slot.readHandle = handle
        slot.readProgress = onProgress
        slot.lastChunkAt = CFAbsoluteTimeGetCurrent()
        pending[reqId] = slot

        // Watchdog: the old 60 s threshold was too aggressive — real-world
        // Wi-Fi routinely goes 60–90 s quiet between radio wake cycles and
        // then resumes happily. Killing the transfer at 60 s meant we
        // abandoned transfers that would have completed a few seconds later,
        // and because the phone never heard about it, it kept pumping chunks
        // into a nonexistent pending slot ("unknown reqId" storm in the log).
        // 5 minutes is far more forgiving; if the link is truly dead, TCP
        // keep-alive will close the socket and peerDisconnected fires anyway.
        let watchdog = Task { [reqId] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let slot = ProtocolFileClient.shared.pending[reqId] else { return }
                    let age = CFAbsoluteTimeGetCurrent() - slot.lastChunkAt
                    if age > 300 {
                        DebugLog.line("[fspull] watchdog timeout reqId=\(reqId) ageSinceLastChunk=\(Int(age))s")
                        ProtocolFileClient.shared.pending.removeValue(forKey: reqId)
                        // Tell the phone to stop pumping; otherwise its
                        // read-ahead will keep firing chunks for a reqId that
                        // no longer exists here, burning the Wi-Fi link.
                        WsServer.shared.send(.fsCancel(reqId: reqId, reason: "mac_watchdog_timeout"))
                        slot.resumeRead?.resume(throwing: FsError(
                            message: "Transfer stalled (no chunks for 5 min). Retry, or switch to adb mode."
                        ))
                    }
                }
            }
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                slot.resumeRead = cont
                WsServer.shared.send(.fsRead(reqId: reqId, path: remote))
            }
            watchdog.cancel()
            DebugLog.line("[fspull] done reqId=\(reqId) bytes=\(slot.readBytesSoFar)/\(slot.readExpectedSize)")
        } catch {
            watchdog.cancel()
            DebugLog.line("[fspull] failed reqId=\(reqId) err=\(error)")
            try? handle.close()
            try? fm.removeItem(at: local)
            pending.removeValue(forKey: reqId)
            throw error
        }

        try? handle.close()
        pending.removeValue(forKey: reqId)
    }

    func push(
        local: URL,
        to remotePath: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        let reqId = Self.makeReqId()
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: local.path)[.size] as? Int64),
              let handle = try? FileHandle(forReadingFrom: local) else {
            throw FsError(message: "cannot read \(local.path)")
        }

        let slot = Pending()
        pending[reqId] = slot

        // Wait for "ready" from the phone.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                slot.resumeWriteReady = cont
                WsServer.shared.send(.fsWrite(reqId: reqId, path: remotePath, size: size))
            }
        } catch {
            try? handle.close()
            pending.removeValue(forKey: reqId)
            throw error
        }

        // Stream chunks as WS binary frames. No base64, no JSON, no second
        // TCP connection — just the healthy WS socket with raw bytes.
        let streamResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            defer { try? handle.close() }
            var offset: Int64 = 0
            while true {
                let data = handle.readData(ofLength: Self.chunkSize)
                if data.isEmpty && offset > 0 { return .success(()) }
                let isLast = (offset + Int64(data.count) >= size)

                WsServer.shared.sendBinaryChunk(
                    kind: WsServer.chunkKindFs, id: reqId,
                    offset: offset, payload: data, last: isLast
                )

                offset += Int64(data.count)
                if let cb = onProgress {
                    let pct = size > 0 ? min(1.0, Double(offset) / Double(size)) : 1.0
                    await MainActor.run { cb(pct) }
                }
                if isLast { return .success(()) }
            }
        }.value

        if case let .failure(error) = streamResult {
            pending.removeValue(forKey: reqId)
            throw error
        }

        // Wait for the phone's final fs_op_result.
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                slot.resumeWriteDone = cont
            }
        } catch {
            pending.removeValue(forKey: reqId)
            throw error
        }
        pending.removeValue(forKey: reqId)
    }

    // MARK: - Inbound dispatch (called from WsServer)

    func deliver(_ message: WireMessage) {
        switch message {
        case let .fsListResult(reqId, _, entries, error):
            if let slot = pending.removeValue(forKey: reqId) {
                slot.resumeList?.resume(returning: (entries, error))
            }
        case let .fsOpResult(reqId, ok, error):
            guard let slot = pending[reqId] else { return }
            // This message serves two flows: generic ops (delete/mkdir) and
            // "write completed" for push.
            if let cont = slot.resumeOp {
                pending.removeValue(forKey: reqId)
                if ok { cont.resume() }
                else { cont.resume(throwing: FsError(message: error ?? "operation failed")) }
                return
            }
            if let cont = slot.resumeWriteDone {
                pending.removeValue(forKey: reqId)
                if ok { cont.resume() }
                else { cont.resume(throwing: FsError(message: error ?? "write failed")) }
                return
            }
        case let .fsDiskResult(reqId, free, total, error):
            if let slot = pending.removeValue(forKey: reqId) {
                if let err = error {
                    slot.resumeDisk?.resume(throwing: FsError(message: err))
                } else {
                    slot.resumeDisk?.resume(returning: (free, total))
                }
            }
        case let .fsDuResult(reqId, path, totalSize, entries, error):
            if let slot = pending.removeValue(forKey: reqId) {
                if let err = error {
                    slot.resumeDu?.resume(throwing: FsError(message: err))
                } else {
                    slot.resumeDu?.resume(returning: DiskUsageReport(
                        path: path, totalSize: totalSize, entries: entries
                    ))
                }
            }
        case let .fsReadResult(reqId, size, error):
            guard let slot = pending[reqId] else {
                DebugLog.line("[fspull] fsReadResult for unknown reqId=\(reqId)")
                return
            }
            if let err = error {
                DebugLog.line("[fspull] fsReadResult err reqId=\(reqId) msg=\(err)")
                pending.removeValue(forKey: reqId)
                slot.resumeRead?.resume(throwing: FsError(message: err))
                return
            }
            DebugLog.line("[fspull] fsReadResult reqId=\(reqId) size=\(size)")
            slot.readExpectedSize = size
        case let .fsChunk(reqId, offset, data, last):
            // Legacy WS chunk path (pre-data-channel peers). Decode base64 and
            // hand off to the binary handler. Current peers push these through
            // DataServer instead.
            let bytes = Data(base64Encoded: data) ?? Data()
            handleBinaryChunk(reqId: reqId, offset: offset, bytes: bytes, last: last)
        case let .fsWriteReady(reqId, error):
            guard let slot = pending[reqId] else { return }
            if let err = error {
                pending.removeValue(forKey: reqId)
                slot.resumeWriteReady?.resume(throwing: FsError(message: err))
                return
            }
            slot.resumeWriteReady?.resume()
            slot.resumeWriteReady = nil
        default:
            break  // not ours
        }
    }

    /// Set of reqIds we've already told the phone to cancel. Prevents spamming
    /// `fs_cancel` for every orphaned chunk when the pull has already been
    /// abandoned locally — one cancel is enough.
    private var cancelledReqs: Set<String> = []

    /// Entry point from the raw-TCP data channel. Binary payload, no
    /// base64 decode on the critical path. The DataServer reader dispatches
    /// in order already; heavy file I/O runs on `chunkWriteQueue` so the
    /// main actor stays free for other tasks (diskAnalyze, SwiftUI, etc.).
    func handleBinaryChunk(reqId: String, offset: Int64, bytes: Data, last: Bool) {
        guard let slot = pending[reqId] else {
            DebugLog.line("[fspull] binaryChunk for unknown reqId=\(reqId) offset=\(offset) last=\(last)")
            // First orphan chunk for this reqId — tell the phone to stop.
            // Without this, the phone's read-ahead keeps generating chunks
            // for a slot that's been cleaned up (watchdog timeout, user
            // cancel, etc.), wasting the Wi-Fi link for minutes.
            if cancelledReqs.insert(reqId).inserted {
                WsServer.shared.send(.fsCancel(reqId: reqId, reason: "unknown_reqId"))
            }
            return
        }
        DebugLog.line("[fspull] binaryChunk reqId=\(reqId) offset=\(offset) len=\(bytes.count) last=\(last)")
        guard let handle = slot.readHandle else {
            if last {
                pending.removeValue(forKey: reqId)
                slot.resumeRead?.resume()
            }
            return
        }
        Self.chunkWriteQueue.async {
            if !bytes.isEmpty {
                try? handle.seek(toOffset: UInt64(offset))
                try? handle.write(contentsOf: bytes)
            }
            let soFar = offset + Int64(bytes.count)
            Task { @MainActor in
                guard let slot = ProtocolFileClient.shared.pending[reqId] else { return }
                slot.readBytesSoFar = soFar
                slot.lastChunkAt = CFAbsoluteTimeGetCurrent()
                if let cb = slot.readProgress, slot.readExpectedSize > 0 {
                    let pct = min(1.0, Double(soFar) / Double(slot.readExpectedSize))
                    let now = CFAbsoluteTimeGetCurrent()
                    if last || now - slot.lastProgressAt > 0.1 {
                        slot.lastProgressAt = now
                        cb(pct)
                    }
                }
                if last {
                    ProtocolFileClient.shared.pending.removeValue(forKey: reqId)
                    slot.resumeRead?.resume()
                }
            }
        }
    }

    /// Called by WsServer when the connection drops; fail every in-flight op
    /// so UI doesn't hang.
    func peerDisconnected() {
        cancelledReqs.removeAll()
        let err = FsError(message: "disconnected")
        for (_, slot) in pending {
            slot.resumeList?.resume(throwing: err)
            slot.resumeOp?.resume(throwing: err)
            slot.resumeDisk?.resume(throwing: err)
            slot.resumeDu?.resume(throwing: err)
            slot.resumeRead?.resume(throwing: err)
            slot.resumeWriteReady?.resume(throwing: err)
            slot.resumeWriteDone?.resume(throwing: err)
            if let h = slot.readHandle { try? h.close() }
        }
        pending.removeAll()
    }

    // MARK: - Helpers

    private func opCall(_ makeMsg: (String) -> WireMessage) async throws {
        let reqId = Self.makeReqId()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let slot = Pending()
            slot.resumeOp = cont
            pending[reqId] = slot
            WsServer.shared.send(makeMsg(reqId))
        }
    }

    private static func makeReqId() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func toAdbEntry(_ e: WireMessage.FsEntry) -> AdbEntry {
        let kind: AdbEntry.Kind
        switch e.kind {
        case .dir:   kind = .directory
        case .file:  kind = .file
        case .link:  kind = .symlink
        case .other: kind = .other
        }
        return AdbEntry(
            name: e.name,
            kind: kind,
            size: e.size,
            mtime: Date(timeIntervalSince1970: TimeInterval(e.mtime))
        )
    }
}
