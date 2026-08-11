import Foundation

/// Abstracts over "how we talk to the phone's filesystem". We have two
/// implementations: one goes through adb (requires the user to have
/// developer options + USB/wireless debugging enabled) and one goes through
/// the paired WebSocket protocol (zero setup, gated on the phone granting
/// `MANAGE_EXTERNAL_STORAGE`).
///
/// The protocol is designed around `AdbEntry` on purpose — it predates the
/// WebSocket variant, and the UI/model already speaks this type.
protocol FileBackend: Sendable {
    /// Lists `path`. When `onBatch` is provided, the backend *may* emit
    /// entries in small groups as they arrive (adb streams stdout line by
    /// line); when the backend has no way to stream (the protocol backend
    /// gets one FsListResult atomically), `onBatch` is simply not called.
    /// The final full list is always returned on completion.
    func list(path: String,
              onBatch: (@Sendable ([AdbEntry]) -> Void)?) async throws -> [AdbEntry]
    func delete(path: String) async throws
    func mkdir(path: String) async throws
    func rename(from: String, to: String) async throws
    func diskUsage(path: String) async throws -> (free: Int64, total: Int64)
    func diskAnalyze(path: String) async throws -> DiskUsageReport
    func pull(remote: String, to local: URL,
              onProgress: (@Sendable (Double) -> Void)?) async throws
    func push(local: URL, to remote: String,
              onProgress: (@Sendable (Double) -> Void)?) async throws
}

extension FileBackend {
    /// Convenience for non-streaming callers.
    func list(path: String) async throws -> [AdbEntry] {
        try await list(path: path, onBatch: nil)
    }
}

/// Result of a recursive disk-usage scan. `entries` are the immediate
/// children of `path`; each `totalSize` is the recursive on-disk size of
/// that child's subtree (in bytes).
struct DiskUsageReport: Sendable {
    let path: String
    let totalSize: Int64
    let entries: [WireMessage.FsDuEntry]
}

struct AdbFileBackend: FileBackend {
    let serial: String

    func list(path: String,
              onBatch: (@Sendable ([AdbEntry]) -> Void)?) async throws -> [AdbEntry] {
        try await AdbClient.list(path: path, serial: serial, onBatch: onBatch)
    }
    func delete(path: String) async throws {
        try await AdbClient.delete(path: path, serial: serial)
    }
    func mkdir(path: String) async throws {
        try await AdbClient.mkdir(path: path, serial: serial)
    }
    func rename(from: String, to: String) async throws {
        try await AdbClient.rename(from: from, to: to, serial: serial)
    }
    func diskUsage(path: String) async throws -> (free: Int64, total: Int64) {
        try await AdbClient.diskUsage(path: path, serial: serial)
    }
    func diskAnalyze(path: String) async throws -> DiskUsageReport {
        try await AdbClient.diskAnalyze(path: path, serial: serial)
    }
    func pull(remote: String, to local: URL,
              onProgress: (@Sendable (Double) -> Void)?) async throws {
        try await AdbClient.pull(remote: remote, to: local, serial: serial, onProgress: onProgress)
    }
    func push(local: URL, to remote: String,
              onProgress: (@Sendable (Double) -> Void)?) async throws {
        try await AdbClient.push(local: local, to: remote, serial: serial, onProgress: onProgress)
    }
}

struct ProtocolFileBackend: FileBackend {
    func list(path: String,
              onBatch: (@Sendable ([AdbEntry]) -> Void)?) async throws -> [AdbEntry] {
        // Wi-Fi/fsbrowse returns one FsListResult atomically — no native
        // streaming. `onBatch` is intentionally unused here; the caller
        // still gets the full list on return.
        try await ProtocolFileClient.shared.list(path: path)
    }
    func delete(path: String) async throws {
        try await ProtocolFileClient.shared.delete(path: path)
    }
    func mkdir(path: String) async throws {
        try await ProtocolFileClient.shared.mkdir(path: path)
    }
    func rename(from: String, to: String) async throws {
        try await ProtocolFileClient.shared.rename(from: from, to: to)
    }
    func diskUsage(path: String) async throws -> (free: Int64, total: Int64) {
        try await ProtocolFileClient.shared.diskUsage(path: path)
    }
    func diskAnalyze(path: String) async throws -> DiskUsageReport {
        try await ProtocolFileClient.shared.diskAnalyze(path: path)
    }
    func pull(remote: String, to local: URL,
              onProgress: (@Sendable (Double) -> Void)?) async throws {
        try await ProtocolFileClient.shared.pull(
            remote: remote, to: local,
            onProgress: onProgress.map { cb in { pct in cb(pct) } }
        )
    }
    func push(local: URL, to remote: String,
              onProgress: (@Sendable (Double) -> Void)?) async throws {
        try await ProtocolFileClient.shared.push(
            local: local, to: remote,
            onProgress: onProgress.map { cb in { pct in cb(pct) } }
        )
    }
}
