import Foundation
import UserNotifications

/// Maintains a bounded set of per-notification categories.
/// macOS keeps the categories live across launches; we evict LRU to avoid
/// unbounded growth.
actor CategoryRegistry {
    private let cap: Int = 200
    private var lruOrder: [String] = []
    private var staleSince: [String: Date] = [:]

    func register(category: UNNotificationCategory) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.notificationCategories()
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier, $0) })
        byId[category.identifier] = category
        touch(category.identifier)
        evictIfNeeded(&byId)
        center.setNotificationCategories(Set(byId.values))
    }

    func markStale(categoryId: String) {
        staleSince[categoryId] = Date()
    }

    private func touch(_ id: String) {
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
    }

    private func evictIfNeeded(_ byId: inout [String: UNNotificationCategory]) {
        let now = Date()
        // First evict stale ones older than 30 s.
        for (id, since) in staleSince where now.timeIntervalSince(since) > 30 {
            byId.removeValue(forKey: id)
            lruOrder.removeAll { $0 == id }
            staleSince.removeValue(forKey: id)
        }
        // Then bound by LRU.
        while byId.count > cap, let oldest = lruOrder.first {
            byId.removeValue(forKey: oldest)
            lruOrder.removeFirst()
        }
    }
}

private extension UNUserNotificationCenter {
    func notificationCategories() async -> Set<UNNotificationCategory> {
        await withCheckedContinuation { (cont: CheckedContinuation<Set<UNNotificationCategory>, Never>) in
            self.getNotificationCategories { cats in cont.resume(returning: cats) }
        }
    }
}
