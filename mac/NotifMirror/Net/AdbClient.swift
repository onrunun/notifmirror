import Foundation

/// Thin wrapper around the `adb` CLI. All methods spawn `adb` as a child
/// process; nothing here uses the adb daemon socket directly.
///
/// Listings rely on `find ... -exec stat {} +`. We avoid `find -printf`
/// because toybox find on Android drops that extension. Filenames with
/// literal `|` or newlines (extremely rare) will parse oddly.
enum AdbError: Error, LocalizedError {
    case adbNotFound
    case noDevice
    case failed(code: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "adb not found. Install via `brew install scrcpy`."
        case .noDevice:
            return "No Android device detected. Connect via USB or enable wireless debugging."
        case .failed(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "adb exited with code \(code)" : trimmed
        }
    }
}

struct AdbDevice: Identifiable, Hashable {
    let serial: String
    let model: String?
    var id: String { serial }
    var label: String { model.map { "\($0) (\(serial))" } ?? serial }
}

struct AdbEntry: Identifiable, Hashable {
    enum Kind { case directory, file, symlink, other }
    let name: String
    let kind: Kind
    let size: Int64
    let mtime: Date
    var id: String { name }
    var isDirectory: Bool { kind == .directory }
}

enum AdbClient {
    private static let searchDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
    ]

    static func findAdb() -> String? {
        let fm = FileManager.default
        for dir in searchDirs {
            let p = "\(dir)/adb"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let p = "\(dir)/adb"
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    // MARK: - Device management

    static func listDevices() async throws -> [AdbDevice] {
        let out = try await run(["devices", "-l"])
        var devices: [AdbDevice] = []
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1] == "device" else { continue }
            let serial = String(parts[0])
            var model: String? = nil
            for extra in parts.dropFirst(2) {
                if extra.hasPrefix("model:") {
                    model = String(extra.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
                }
            }
            devices.append(AdbDevice(serial: serial, model: model))
        }
        return devices
    }

    /// Best-effort `adb connect <host>:5555`. Errors are swallowed; the
    /// caller just uses whatever devices adb can see afterwards.
    static func connectWireless(host: String, port: Int = 5555) async {
        _ = try? await run(["connect", "\(host):\(port)"], timeout: 3)
    }

    // MARK: - File ops

    static func list(
        path: String,
        serial: String,
        onBatch: (@Sendable ([AdbEntry]) -> Void)? = nil
    ) async throws -> [AdbEntry] {
        let escaped = shellQuote(path)
        // Fast path: `find -printf` does all the formatting in a single
        // process with no per-entry `stat` spawn. Modern Android toybox
        // (0.8.3+, ~Android 12+) supports it. Older toybox errors out on
        // `-printf`, so we `||`-fall-back to the classic find+stat pipeline.
        //
        // Format from -printf: `y|s|T@|p` = single-char type (f/d/l/...),
        // size, epoch mtime, `./name`.
        // Format from stat: `F|s|Y|n` = full-word type ("regular file",
        // "directory", ...), size, epoch mtime, `./name`.
        // parseStatLine handles both.
        let fastCmd = "find . -mindepth 1 -maxdepth 1 -printf '%y|%s|%T@|%p\\n' 2>/dev/null"
        let slowCmd = "find . -mindepth 1 -maxdepth 1 -exec stat -c '%F|%s|%Y|%n' -- {} +"
        let cmd = "cd \(escaped) && { \(fastCmd) || \(slowCmd); }"

        // Non-streaming path: single wait, one-shot parse.
        guard let onBatch else {
            do {
                let out = try await run(["-s", serial, "shell", cmd])
                return parseStatOutput(out)
            } catch let AdbError.failed(_, payload) {
                let salvaged = parseStatOutput(payload)
                if !salvaged.isEmpty { return salvaged }
                throw AdbError.failed(code: 1, stderr: payload)
            }
        }

        // Streaming path: emit entries in small time-batched groups while
        // adb stdout arrives. The UI appends rows live instead of waiting
        // for the whole listing.
        let batcher = StreamBatcher(onEmit: onBatch)
        let accumulated = BoxedEntries()
        do {
            _ = try await runStream(
                ["-s", serial, "shell", cmd],
                timeout: 300,
                onStdoutLine: { line in
                    if let e = parseStatLine(line) {
                        accumulated.append(e)
                        batcher.add(e)
                    }
                }
            )
            batcher.flush()
            return accumulated.values
        } catch let AdbError.failed(_, payload) {
            batcher.flush()
            // Same salvage as the non-streaming path: fall back to parsing
            // whatever the process printed (which at this point already
            // went through the streaming parser too, but keep the safety
            // net for the rare case stdout was only drained on exit).
            let soFar = accumulated.values
            if !soFar.isEmpty { return soFar }
            let salvaged = parseStatOutput(payload)
            if !salvaged.isEmpty {
                onBatch(salvaged)
                return salvaged
            }
            throw AdbError.failed(code: 1, stderr: payload)
        }
    }

    static func pull(
        remote: String,
        to local: URL,
        serial: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if let onProgress {
            _ = try await runStream(
                ["-s", serial, "pull", remote, local.path],
                onStderrLine: { line in
                    if let pct = Self.parsePercent(line) { onProgress(pct) }
                }
            )
        } else {
            _ = try await run(["-s", serial, "pull", remote, local.path])
        }
    }

    static func push(
        local: URL,
        to remote: String,
        serial: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if let onProgress {
            _ = try await runStream(
                ["-s", serial, "push", local.path, remote],
                onStderrLine: { line in
                    if let pct = Self.parsePercent(line) { onProgress(pct) }
                }
            )
        } else {
            _ = try await run(["-s", serial, "push", local.path, remote])
        }
    }

    /// adb push/pull prints progress lines like `[ 50%] /path/file` to stderr,
    /// often separated by `\r` so the same line overwrites in a terminal.
    private static func parsePercent(_ line: String) -> Double? {
        guard let lb = line.firstIndex(of: "["),
              let pct = line.firstIndex(of: "%"),
              lb < pct else { return nil }
        let inside = line[line.index(after: lb)..<pct].trimmingCharacters(in: .whitespaces)
        guard let n = Int(inside), n >= 0, n <= 100 else { return nil }
        return Double(n) / 100.0
    }

    static func delete(path: String, serial: String) async throws {
        let escaped = shellQuote(path)
        _ = try await run(["-s", serial, "shell", "rm -rf \(escaped)"])
    }

    static func mkdir(path: String, serial: String) async throws {
        let escaped = shellQuote(path)
        _ = try await run(["-s", serial, "shell", "mkdir -p \(escaped)"])
    }

    static func rename(from: String, to: String, serial: String) async throws {
        let src = shellQuote(from)
        let dst = shellQuote(to)
        _ = try await run(["-s", serial, "shell", "mv -n \(src) \(dst)"])
    }

    /// Returns (free, total) bytes for the filesystem containing `path`.
    /// Parses `df -k` output; toybox on Android keeps the data on one line.
    static func diskUsage(path: String, serial: String) async throws -> (free: Int64, total: Int64) {
        let escaped = shellQuote(path)
        let out = try await run(["-s", serial, "shell", "df -k \(escaped) 2>/dev/null | tail -n 1"])
        let parts = out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .filter { !$0.isEmpty }
            .map(String.init)
        // Expected: Filesystem 1K-blocks Used Available Use% Mounted
        guard parts.count >= 4,
              let totalK = Int64(parts[1]),
              let availK = Int64(parts[3]) else {
            throw AdbError.failed(code: 1, stderr: "df output unparseable: \(out)")
        }
        return (free: availK * 1024, total: totalK * 1024)
    }

    /// Recursive disk-usage scan for `path`. Two parallel shell calls:
    ///
    /// - `list(path:)` — reuses the existing toybox-compatible kind detection
    ///   (`find -printf` with a stat fallback). Tells us which immediate
    ///   children are dirs vs files vs symlinks.
    /// - `du -kxd 1 .` — recursive sizes for the path itself (`.`) plus each
    ///   immediate subdirectory.
    ///
    /// Earlier versions tried to derive kinds from `du` alone, but `du` can't
    /// distinguish dirs from files — every line looks the same. The result
    /// was that the Storage Analyzer in adb mode treated every entry as a
    /// folder, and tapping into a regular file silently failed because the
    /// rescan tried to `cd` into something that wasn't a directory.
    ///
    /// `du` doesn't give us a file count cheaply — set to 0 in adb mode and
    /// let the UI suppress the count rather than spawning per-child
    /// `find ... | wc -l` calls.
    static func diskAnalyze(path: String, serial: String) async throws -> DiskUsageReport {
        let escaped = shellQuote(path)
        // -x keeps `du` on one filesystem so a `/sdcard` scan doesn't wander
        // into mounted bind points.
        async let listTask: [AdbEntry] = list(path: path, serial: serial)
        async let duTask: String = run(
            ["-s", serial, "shell",
             "cd \(escaped) 2>/dev/null && du -kxd 1 . 2>/dev/null"],
            // /sdcard scans on a heavily-loaded phone can run well over 30s.
            timeout: 300
        )
        let entries = try await listTask
        let duOut = try await duTask

        // Parse du: "<kb>\t./<name>" for children, "<kb>\t." for the total.
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        for line in duOut.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard f.count == 2, let kb = Int64(f[0]) else { continue }
            var name = String(f[1])
            if name.hasPrefix("./") { name.removeFirst(2) }
            let bytes = kb * 1024
            if name.isEmpty || name == "." {
                total = bytes
            } else {
                sizes[name] = bytes
            }
        }

        let duEntries: [WireMessage.FsDuEntry] = entries.map { entry in
            let kind: WireMessage.FsEntry.Kind
            switch entry.kind {
            case .directory: kind = .dir
            case .file:      kind = .file
            case .symlink:   kind = .link
            case .other:     kind = .other
            }
            // Files have a known size from list()/stat. Directories take the
            // recursive total from du. Symlinks contribute 0 (we never follow,
            // matching the Wi-Fi/fsbrowse backend).
            let totalSize: Int64
            switch entry.kind {
            case .file:      totalSize = entry.size
            case .directory: totalSize = sizes[entry.name] ?? 0
            case .symlink:   totalSize = 0
            case .other:     totalSize = sizes[entry.name] ?? 0
            }
            return WireMessage.FsDuEntry(
                name: entry.name, kind: kind, totalSize: totalSize, fileCount: 0
            )
        }
        return DiskUsageReport(path: path, totalSize: total, entries: duEntries)
    }

    // MARK: - Parsing

    /// Parse a single stat/`find -printf` line (`type|size|mtime|./name`)
    /// into an `AdbEntry`. Returns nil for malformed lines.
    static func parseStatLine<S: StringProtocol>(_ line: S) -> AdbEntry? {
        let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }

        let type = fields[0].lowercased()
        let kind: AdbEntry.Kind
        // `find -printf '%y'` emits single chars: f/d/l/... while
        // `stat -c '%F'` emits full words ("regular file", "directory",
        // "symbolic link", ...). Handle both.
        if type == "d" || type.contains("directory") {
            kind = .directory
        } else if type == "l" || type.contains("symbolic link") {
            kind = .symlink
        } else if type == "f" || type.contains("file") {
            kind = .file
        } else {
            kind = .other
        }

        let size = Int64(fields[1]) ?? 0

        let mtime: Date
        if let secs = Double(fields[2]) {
            mtime = Date(timeIntervalSince1970: secs)
        } else {
            mtime = Date.distantPast
        }

        var name = String(fields[3])
        if name.hasPrefix("./") { name.removeFirst(2) }
        return AdbEntry(name: name, kind: kind, size: size, mtime: mtime)
    }

    private static func parseStatOutput(_ out: String) -> [AdbEntry] {
        var entries: [AdbEntry] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            if let e = parseStatLine(line) { entries.append(e) }
        }
        return entries
    }

    // MARK: - Process runner

    @discardableResult
    private static func run(_ args: [String], timeout: TimeInterval = 30) async throws -> String {
        guard let adb = findAdb() else { throw AdbError.adbNotFound }

        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: adb)
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            var env = ProcessInfo.processInfo.environment
            let extraPath = searchDirs.joined(separator: ":")
            env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
            proc.environment = env

            var didFinish = false
            let lock = NSLock()

            proc.terminationHandler = { p in
                lock.lock()
                if didFinish { lock.unlock(); return }
                didFinish = true
                lock.unlock()

                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: out, encoding: .utf8) ?? ""
                let stderr = String(data: err, encoding: .utf8) ?? ""

                if p.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: AdbError.failed(
                        code: p.terminationStatus,
                        stderr: stderr.isEmpty ? stdout : stderr
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Timeout watchdog.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                lock.lock()
                let alreadyDone = didFinish
                lock.unlock()
                if !alreadyDone && proc.isRunning {
                    proc.terminate()
                }
            }
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Like `run`, but streams output line-by-line while the process is
    /// alive. adb push/pull emits `[ NN%] /path` progress lines on stderr
    /// (often separated by `\r`), which we want to surface live — that's
    /// what `onStderrLine` is for. `onStdoutLine` lets callers consume
    /// stdout as it arrives (used by `list` for lazy-loading table rows).
    @discardableResult
    private static func runStream(
        _ args: [String],
        timeout: TimeInterval = 3600,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard let adb = findAdb() else { throw AdbError.adbNotFound }

        return try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: adb)
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            var env = ProcessInfo.processInfo.environment
            let extraPath = searchDirs.joined(separator: ":")
            env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
            proc.environment = env

            let stdoutBuf = StringBuffer()
            let stderrBuf = StringBuffer()

            // Lines that span across pipe chunks need a buffered splitter
            // or we'd drop/mangle a row at each boundary. Stderr uses the
            // older split-per-chunk behavior because adb's \r-separated
            // progress output tolerates it.
            let stdoutLines = LineSplitter()

            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                guard let text = String(data: data, encoding: .utf8) else { return }
                stderrBuf.append(text)
                if let onStderrLine {
                    // adb refreshes progress with \r; split on both.
                    for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let s = String(line).trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty { onStderrLine(s) }
                    }
                }
            }
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                guard let text = String(data: data, encoding: .utf8) else { return }
                stdoutBuf.append(text)
                if let onStdoutLine {
                    for line in stdoutLines.feed(text) where !line.isEmpty {
                        onStdoutLine(line)
                    }
                }
            }

            var didFinish = false
            let lock = NSLock()

            proc.terminationHandler = { p in
                lock.lock()
                if didFinish { lock.unlock(); return }
                didFinish = true
                lock.unlock()

                errPipe.fileHandleForReading.readabilityHandler = nil
                outPipe.fileHandleForReading.readabilityHandler = nil

                // Drain any final data.
                let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingOut.isEmpty, let s = String(data: remainingOut, encoding: .utf8) {
                    stdoutBuf.append(s)
                    if let onStdoutLine {
                        for line in stdoutLines.feed(s) where !line.isEmpty {
                            onStdoutLine(line)
                        }
                    }
                }
                if !remainingErr.isEmpty, let s = String(data: remainingErr, encoding: .utf8) {
                    stderrBuf.append(s)
                }
                if let onStdoutLine, let tail = stdoutLines.flush(), !tail.isEmpty {
                    onStdoutLine(tail)
                }

                let stdout = stdoutBuf.value
                let stderr = stderrBuf.value

                if p.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: AdbError.failed(
                        code: p.terminationStatus,
                        stderr: stderr.isEmpty ? stdout : stderr
                    ))
                }
            }

            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                lock.lock()
                let alreadyDone = didFinish
                lock.unlock()
                if !alreadyDone && proc.isRunning {
                    proc.terminate()
                }
            }
        }
    }
}

private final class StringBuffer: @unchecked Sendable {
    private var _s: String = ""
    private let lock = NSLock()
    var value: String { lock.lock(); defer { lock.unlock() }; return _s }
    func append(_ chunk: String) { lock.lock(); _s += chunk; lock.unlock() }
}

/// Thread-safe rolling buffer for the streaming list path. The stdout
/// handler adds entries as they parse; the caller reads `.values` at the
/// end to return the full list.
private final class BoxedEntries: @unchecked Sendable {
    private var _v: [AdbEntry] = []
    private let lock = NSLock()
    var values: [AdbEntry] { lock.lock(); defer { lock.unlock() }; return _v }
    func append(_ e: AdbEntry) { lock.lock(); _v.append(e); lock.unlock() }
}

/// Coalesces streamed entries into batches so the UI doesn't re-render
/// the Table 5000 times for a 5000-file folder. Emits when either the
/// buffer hits `maxBatch` rows or at least `flushAfter` seconds have
/// elapsed since the last emit.
private final class StreamBatcher: @unchecked Sendable {
    private var buf: [AdbEntry] = []
    private var lastEmit = Date.distantPast
    private let lock = NSLock()
    private let onEmit: @Sendable ([AdbEntry]) -> Void
    private let maxBatch: Int
    private let flushAfter: TimeInterval

    init(
        maxBatch: Int = 200,
        flushAfter: TimeInterval = 0.1,
        onEmit: @Sendable @escaping ([AdbEntry]) -> Void
    ) {
        self.maxBatch = maxBatch
        self.flushAfter = flushAfter
        self.onEmit = onEmit
    }

    func add(_ e: AdbEntry) {
        lock.lock()
        buf.append(e)
        let now = Date()
        let ready = buf.count >= maxBatch || now.timeIntervalSince(lastEmit) >= flushAfter
        let drop: [AdbEntry]
        if ready {
            drop = buf
            buf = []
            lastEmit = now
        } else {
            drop = []
        }
        lock.unlock()
        if !drop.isEmpty { onEmit(drop) }
    }

    func flush() {
        lock.lock()
        let drop = buf
        buf = []
        lastEmit = Date()
        lock.unlock()
        if !drop.isEmpty { onEmit(drop) }
    }
}

/// Accumulates partial stdout/stderr chunks and emits complete lines —
/// because pipe reads don't necessarily align to newlines.
private final class LineSplitter: @unchecked Sendable {
    private var tail: String = ""
    private let lock = NSLock()

    func feed(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        tail += chunk
        var lines: [String] = []
        while let nl = tail.firstIndex(of: "\n") {
            let line = String(tail[..<nl]).trimmingCharacters(in: .whitespaces)
            lines.append(line)
            tail = String(tail[tail.index(after: nl)...])
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let t = tail.trimmingCharacters(in: .whitespaces)
        tail = ""
        return t.isEmpty ? nil : t
    }
}
