import Foundation

// MARK: - Alert history storage

struct AlertEntry {
    let id: Int
    let envelope: [String: Any]
    let time: Date
    var seenAt: Date?
    /// Set when the user clicks through the bubble (or a history row) to run
    /// the entry's action. Actioned entries are filtered out of the bubble
    /// rotation — they remain in the history panel but won't replay.
    var actionedAt: Date?

    var title: String   { (envelope["title"] as? String) ?? "" }
    var body: String?   { envelope["body"] as? String }
    var source: String  { (envelope["source"] as? String) ?? "unknown" }
    var priority: String { (envelope["priority"] as? String) ?? "normal" }
    var action: [String: Any]? { (envelope["actions"] as? [[String: Any]])?.first }
    var icon: String? { envelope["icon"] as? String }
}

/// Centralized alert history + seen-set. Newest first; capped at maxEntries.
final class AlertStore {
    private(set) var entries: [AlertEntry] = []
    private var nextId: Int = 0
    let maxEntries: Int = 5
    let ttlAfterSeen: TimeInterval = 5 * 60

    /// True if at least one archived entry has an action and is unseen.
    /// Drives the "character has a pending alert" signal (worry bubbles).
    var hasUnseenAlerts: Bool {
        entries.contains { $0.seenAt == nil && $0.action != nil }
    }

    /// Most-recent archived entry that the user can still act on (has an
    /// action and hasn't been clicked through yet).
    var lastActionableAlert: AlertEntry? {
        entries.first { $0.action != nil && $0.actionedAt == nil }
    }

    /// Count of entries the user hasn't seen yet.
    var unseenCount: Int {
        entries.filter { $0.seenAt == nil }.count
    }

    @discardableResult
    func push(envelope: [String: Any]) -> AlertEntry {
        nextId += 1
        let entry = AlertEntry(id: nextId, envelope: envelope, time: Date(), seenAt: nil, actionedAt: nil)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        return entry
    }

    func markSeen(id: Int) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[idx].seenAt == nil { entries[idx].seenAt = Date() }
    }

    func markAllSeen() {
        let now = Date()
        for i in entries.indices where entries[i].seenAt == nil {
            entries[i].seenAt = now
        }
    }

    /// Records that the user clicked through to run the entry's action. Also
    /// marks it seen (can't act on something without seeing it).
    func markActioned(id: Int) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        if entries[idx].actionedAt == nil { entries[idx].actionedAt = now }
        if entries[idx].seenAt == nil { entries[idx].seenAt = now }
    }

    /// Marks every entry as actioned — used by the explicit "clear alerts"
    /// menu action, which dismisses the whole backlog at once.
    func markAllActioned() {
        let now = Date()
        for i in entries.indices {
            if entries[i].actionedAt == nil { entries[i].actionedAt = now }
            if entries[i].seenAt == nil { entries[i].seenAt = now }
        }
    }

    /// Remove entries that were marked seen more than `ttlAfterSeen` ago.
    /// Returns the number of entries removed (for UI refresh decisions).
    @discardableResult
    func sweep() -> Int {
        let cutoff = Date().addingTimeInterval(-ttlAfterSeen)
        let before = entries.count
        entries.removeAll { e in
            if let seen = e.seenAt, seen < cutoff { return true }
            return false
        }
        return before - entries.count
    }
}
