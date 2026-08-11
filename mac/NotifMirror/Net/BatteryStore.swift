import Foundation
import UserNotifications

/// Receives battery snapshots from the phone, parks them on `AppState.battery`,
/// and surfaces a one-shot low-battery banner on the Mac when the phone
/// crosses into the low state. Edge-triggered: re-firing requires the phone
/// to first leave the low state and return to it.
@MainActor
final class BatteryStore {
    static let shared = BatteryStore()

    private var lastDeliveredLow: Bool = false

    private init() {}

    func handleRemoteState(_ b: WireMessage.BatteryState) {
        let snap = BatterySnapshot(
            level: b.level,
            charging: b.charging,
            status: b.status,
            plugged: b.plugged,
            temperatureC: b.temperatureC,
            voltageMv: b.voltageMv,
            low: b.low,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(b.updatedAt) / 1000.0)
        )
        AppState.shared.battery = snap

        let nowLow = b.low || (b.level >= 0 && b.level <= 15 && !b.charging)
        if nowLow && !lastDeliveredLow {
            postLowBatteryNotification(level: b.level)
        }
        lastDeliveredLow = nowLow
    }

    /// Called when the WS peer drops so the menu bar reverts to the
    /// disconnected look (no stale battery indicator).
    func peerDisconnected() {
        AppState.shared.battery = nil
        lastDeliveredLow = false
    }

    private func postLowBatteryNotification(level: Int) {
        let content = UNMutableNotificationContent()
        content.title = AppState.shared.pairedDeviceName ?? "Phone battery low"
        content.body = level >= 0 ? "Battery at \(level) %." : "Battery is low."
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: "notifmirror.battery.low",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err { NSLog("low-battery notify failed: \(err)") }
        }
    }
}
