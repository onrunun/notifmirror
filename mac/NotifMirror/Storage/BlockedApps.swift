import Combine
import Foundation

/// Package-level mute list and seen-apps tracker.
/// Persisted to UserDefaults. Independent of the phone's own filter —
/// if either side blocks a pkg, the user won't see a macOS banner for it.
@MainActor
final class BlockedApps: ObservableObject {
    static let shared = BlockedApps()

    private let blockedKey = "blockedPackages"
    private let seenKey = "seenPackages"

    /// Package names the user has opted out of.
    @Published private(set) var blocked: Set<String>

    /// Package → friendly app name, in the order we first saw each pkg.
    @Published private(set) var seen: [SeenApp]

    struct SeenApp: Identifiable, Hashable {
        var id: String { pkg }
        let pkg: String
        var name: String
        var lastSeen: Date
        var count: Int
    }

    private init() {
        let defaults = UserDefaults.standard
        self.blocked = Set(defaults.stringArray(forKey: blockedKey) ?? [])
        if let data = defaults.data(forKey: seenKey),
           let decoded = try? JSONDecoder().decode([StoredSeen].self, from: data) {
            self.seen = decoded.map {
                SeenApp(pkg: $0.pkg, name: $0.name, lastSeen: $0.lastSeen, count: $0.count ?? 0)
            }
        } else {
            self.seen = []
        }
    }

    /// Call every time a `posted` arrives, before the drop check.
    /// Records the pkg → name mapping; returns `true` iff the user has blocked it.
    func recordAndCheck(pkg: String, name: String) -> Bool {
        let now = Date()
        if let idx = seen.firstIndex(where: { $0.pkg == pkg }) {
            seen[idx].name = name
            seen[idx].lastSeen = now
            seen[idx].count += 1
        } else {
            seen.append(SeenApp(pkg: pkg, name: name, lastSeen: now, count: 1))
        }
        persistSeen()
        return blocked.contains(pkg)
    }

    func setBlocked(_ pkg: String, blocked: Bool) {
        if blocked { self.blocked.insert(pkg) } else { self.blocked.remove(pkg) }
        UserDefaults.standard.set(Array(self.blocked), forKey: blockedKey)
    }

    func isBlocked(_ pkg: String) -> Bool {
        blocked.contains(pkg)
    }

    func clearSeen() {
        seen.removeAll()
        persistSeen()
    }

    private func persistSeen() {
        let stored = seen.map {
            StoredSeen(pkg: $0.pkg, name: $0.name, lastSeen: $0.lastSeen, count: $0.count)
        }
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: seenKey)
        }
    }

    private struct StoredSeen: Codable {
        let pkg: String
        let name: String
        let lastSeen: Date
        let count: Int?
    }
}
