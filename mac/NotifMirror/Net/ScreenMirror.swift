import AppKit
import Foundation

@MainActor
final class ScreenMirror: ObservableObject {
    static let shared = ScreenMirror()

    private var process: Process?
    private var stderrTail = Data()
    private let stderrCap = 8 * 1024
    private var stoppedByUser = false

    private static let searchDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
    ]

    private init() {}

    var isRunning: Bool { process != nil }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        guard process == nil else { return }

        guard let scrcpy = Self.findBinary("scrcpy") else {
            Self.showAlert(
                title: "scrcpy not found",
                message: "Install it with Homebrew, then try again:\n\nbrew install scrcpy"
            )
            return
        }

        let adb = Self.findBinary("adb")
        let peerHost = AppState.shared.peerHost

        // Best-effort: if we know the phone's IP and adb is available,
        // try `adb connect <host>:5555`. Any failure is silently ignored —
        // scrcpy will fall back to whichever device adb already sees (USB,
        // already-paired wireless debugging, etc).
        if let adb, let host = peerHost {
            Self.runBriefly(
                path: adb,
                args: ["connect", "\(host):5555"],
                timeout: 2.0
            )
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scrcpy)
        proc.arguments = [
            "--window-title=NotifMirror",
            "--stay-awake",
        ]

        var env = ProcessInfo.processInfo.environment
        let extraPath = Self.searchDirs.joined(separator: ":")
        env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
        if let adb { env["ADB"] = adb }
        proc.environment = env

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe() // discard stdout
        stderrTail.removeAll(keepingCapacity: true)

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.stderrTail.append(chunk)
                if self.stderrTail.count > self.stderrCap {
                    self.stderrTail.removeFirst(self.stderrTail.count - self.stderrCap)
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                AppState.shared.scrcpyRunning = false
                let wasStoppedByUser = self.stoppedByUser
                self.stoppedByUser = false
                let tail = String(data: self.stderrTail, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let exitedNormally = p.terminationStatus == 0
                    || p.terminationReason == .uncaughtSignal
                    || wasStoppedByUser
                    || Self.isBenignDisconnect(tail)
                if !exitedNormally {
                    Self.showAlert(
                        title: "scrcpy exited (code \(p.terminationStatus))",
                        message: tail.isEmpty ? "No output captured." : tail
                    )
                }
            }
        }

        do {
            try proc.run()
            process = proc
            AppState.shared.scrcpyRunning = true
        } catch {
            Self.showAlert(
                title: "Failed to launch scrcpy",
                message: error.localizedDescription
            )
        }
    }

    func stop() {
        guard let proc = process else { return }
        stoppedByUser = true
        proc.terminate()
        // Escalate to SIGKILL if it refuses to die within 2s.
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Helpers

    private static func isBenignDisconnect(_ stderrTail: String) -> Bool {
        let lower = stderrTail.lowercased()
        return lower.contains("device disconnected")
            || lower.contains("device asleep")
    }

    private static func findBinary(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in searchDirs {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // Fallback: whatever's on PATH (useful if user installed elsewhere).
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let p = "\(dir)/\(name)"
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    @discardableResult
    private static func runBriefly(path: String, args: [String], timeout: TimeInterval) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        return p.terminationStatus
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
