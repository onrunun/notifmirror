import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isServerListening: Bool = false
    @Published var listenerPort: UInt16 = 0
    @Published var isClientConnected: Bool = false
    @Published var pairedDeviceName: String? = nil
    @Published var peerHost: String? = nil
    @Published var scrcpyRunning: Bool = false
    @Published var notificationsMirroredCount: Int = 0
    @Published var lastError: String? = nil
    @Published var showPairingWindow: Bool = false
    @Published var openMainWindowRequest: UUID? = nil
    @Published var pairingRevision: Int = 0

    @Published var peerFeatures: Set<String> = []

    // Media control state, mirrored from the phone.
    @Published var media: MediaSnapshot = .empty

    // Phone battery, mirrored. `nil` until the first battery_state arrives.
    @Published var battery: BatterySnapshot? = nil

    // Clipboard sync last-activity indicator (for the menu bar).
    @Published var lastClipDirection: ClipDirection? = nil
    @Published var lastClipAt: Date? = nil

    // File transfers, keyed by xid.
    @Published var transfers: [String: TransferProgress] = [:]

    /// Set while an end-to-end notification test is in flight. Cleared by
    /// the WS receive loop the moment a `posted` arrives whose body contains
    /// this nonce — UI polls for that transition to distinguish success
    /// from timeout.
    @Published var pendingE2ETestReqId: String? = nil

    private init() {}

    func incrementMirrored() { notificationsMirroredCount += 1 }
}

enum ClipDirection: String {
    case incoming, outgoing
}

struct MediaSnapshot: Equatable {
    var pkg: String?
    var app: String?
    var title: String?
    var artist: String?
    var album: String?
    var artworkBase64: String?
    var playing: Bool
    var positionMs: Int64
    var durationMs: Int64
    var canPause: Bool
    var canSkipNext: Bool
    var canSkipPrev: Bool
    var volume: Int
    var maxVolume: Int
    var updatedAt: Date

    static let empty = MediaSnapshot(
        pkg: nil, app: nil, title: nil, artist: nil, album: nil, artworkBase64: nil,
        playing: false, positionMs: 0, durationMs: 0,
        canPause: false, canSkipNext: false, canSkipPrev: false,
        volume: 0, maxVolume: 0,
        updatedAt: .distantPast
    )

    var hasSession: Bool { pkg != nil && (title != nil || artist != nil) }
}

struct BatterySnapshot: Equatable {
    var level: Int
    var charging: Bool
    var status: String
    var plugged: String
    var temperatureC: Double?
    var voltageMv: Int?
    var low: Bool
    var updatedAt: Date

    /// True when we have a usable level (the phone actually reported one).
    var hasLevel: Bool { level >= 0 }

    /// The SF Symbol that best represents this battery state. Falls back to
    /// a level-bracketed symbol when not charging, and to the bolt-bearing
    /// symbol whenever charging.
    var sfSymbol: String {
        if !hasLevel { return "battery.0" }
        if charging { return "battery.100.bolt" }
        switch level {
        case ...10:  return "battery.0"
        case 11...30: return "battery.25"
        case 31...60: return "battery.50"
        case 61...85: return "battery.75"
        default:      return "battery.100"
        }
    }

    /// Tint colour for the indicator. Red below 15 %, orange 15–25 %, green
    /// while charging, secondary otherwise.
    var tint: Color {
        if low || (hasLevel && level <= 15) { return .red }
        if hasLevel && level <= 25 { return .orange }
        if charging { return .green }
        return .secondary
    }
}

struct TransferProgress: Identifiable, Equatable {
    enum Direction { case incoming, outgoing }
    enum Status: Equatable {
        case pending        // offer sent, waiting for accept
        case active
        case done
        case failed(String)
        case cancelled
    }

    let id: String           // xid
    let direction: Direction
    let name: String
    let size: Int64
    var bytesTransferred: Int64
    var status: Status
    var destinationPath: String? = nil
}
