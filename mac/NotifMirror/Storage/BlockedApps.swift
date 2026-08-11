import Combine
import Foundation

/// Package-level mute list and seen-apps tracker.
/// Persisted to UserDefaults. Independent of the phone's own filter —
/// if either side blocks a pkg, the user won't see a macOS banner for it.
///
/// The muted list is stored as timestamped entries (pkg → blocked state +
/// last-edit time). That snapshot is shipped to the paired phone, which
/// merges "newest edit wins" per package so mutes and unmutes both propagate.
@MainActor
final class BlockedApps: ObservableObject {
    static let shared = BlockedApps()

    private let seenKey = "seenPackages"
    private let stateKey = "blockedStateV2"

    /// Package names the user has opted out of (derived from [state]).
    @Published private(set) var blocked: Set<String>

    /// Package → friendly app name, in the order we first saw each pkg.
    @Published private(set) var seen: [SeenApp]

    private var state: [String: BlockState]

    struct SeenApp: Identifiable, Hashable {
        var id: String { pkg }
        let pkg: String
        var name: String
        var lastSeen: Date
        var count: Int
    }

    struct BlockState: Codable {
        let pkg: String
        let blocked: Bool
        let updatedAt: Double   // epoch ms
    }

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode([BlockState].self, from: data) {
            self.state = Dictionary(uniqueKeysWithValues: decoded.map { ($0.pkg, $0) })
        } else {
            self.state = [:]
        }
        self.blocked = Set(state.values.filter { $0.blocked }.map { $0.pkg })
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
        state[pkg] = BlockState(
            pkg: pkg,
            blocked: blocked,
            updatedAt: Date().timeIntervalSince1970 * 1000
        )
        persistState()
        rebuildBlockedSet()
        pushToPeer()
    }

    func isBlocked(_ pkg: String) -> Bool {
        blocked.contains(pkg)
    }

    /// Merge a snapshot from the paired phone. For each package the newer edit
    /// wins; never echoes back.
    func applyRemote(_ entries: [WireMessage.BlocklistEntry]) {
        var changed = false
        for e in entries {
            let incoming = BlockState(pkg: e.pkg, blocked: e.blocked, updatedAt: Double(e.updatedAt))
            if let cur = state[e.pkg] {
                if incoming.updatedAt > cur.updatedAt {
                    state[e.pkg] = incoming
                    changed = true
                }
            } else {
                state[e.pkg] = incoming
                changed = true
            }
        }
        if changed {
            persistState()
            rebuildBlockedSet()
        }
    }

    func snapshot() -> [WireMessage.BlocklistEntry] {
        state.values.map {
            WireMessage.BlocklistEntry(
                pkg: $0.pkg,
                blocked: $0.blocked,
                updatedAt: Int64($0.updatedAt)
            )
        }
    }

    func clearSeen() {
        seen.removeAll()
        persistSeen()
    }

    private func pushToPeer() {
        WsServer.shared.send(.blocklist(packages: snapshot()))
    }

    private func rebuildBlockedSet() {
        blocked = Set(state.values.filter { $0.blocked }.map { $0.pkg })
    }

    private func persistState() {
        let stored = Array(state.values)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
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
