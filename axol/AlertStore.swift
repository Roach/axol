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
    /// For permission-request entries: "allow" once approved, "deny" once
    /// refused, nil while pending (or for regular alerts). Drives the small
    /// colored dot on history rows.
    var permissionDecision: String?

    var title: String   { (envelope["title"] as? String) ?? "" }
    var body: String?   { envelope["body"] as? String }
    var source: String  { (envelope["source"] as? String) ?? "unknown" }
    var priority: String { (envelope["priority"] as? String) ?? "normal" }
    var action: [String: Any]? { (envelope["actions"] as? [[String: Any]])?.first }
    var icon: String? { envelope["icon"] as? String }
    var isPermissionRequest: Bool { (envelope["kind"] as? String) == "permission" }
}

/// Centralized alert history + seen-set. Newest first; capped at maxEntries.
final class AlertStore {
    private(set) var entries: [AlertEntry] = []
    private var nextId: Int = 0
    let maxEntries: Int = 5
    let ttlAfterSeen: TimeInterval = 5 * 60
    /// Cap on how long an unseen/unactioned entry can keep worry bubbles
    /// alive. Without this, a bubble that auto-dismissed while the user
    /// was away from the screen pins `hasUnseenAlerts == true` forever.
    /// Give the user a generous window (they might step away), but
    /// eventually let the noise stop on its own.
    let ttlUnseen: TimeInterval = 30 * 60

    /// True if at least one archived entry has an action and is unseen.
    /// Drives the "character has a pending alert" signal (worry bubbles).
    var hasUnseenAlerts: Bool {
        entries.contains { $0.seenAt == nil && $0.action != nil }
    }

    /// Count of unseen + actionable entries — feeds worry-bubble density.
    var unseenActionableCount: Int {
        entries.reduce(0) { $0 + (($1.seenAt == nil && $1.action != nil) ? 1 : 0) }
    }

    /// True if any unseen actionable entry is urgent — bumps worry-bubble
    /// tempo so the user picks up on the higher-priority thing faster.
    var hasUrgentUnseenAlert: Bool {
        entries.contains { $0.seenAt == nil && $0.action != nil && $0.priority == "urgent" }
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
        let entry = AlertEntry(id: nextId, envelope: envelope, time: Date(),
                               seenAt: nil, actionedAt: nil, permissionDecision: nil)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        return entry
    }

    /// Stamp a permission entry with the user's decision after they click
    /// Allow / Deny. Also marks the entry as actioned + seen — the decision
    /// is the terminal state, the row shouldn't stay "pending" in history.
    func setPermissionDecision(id: Int, decision: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        entries[idx].permissionDecision = decision
        if entries[idx].actionedAt == nil { entries[idx].actionedAt = now }
        if entries[idx].seenAt == nil { entries[idx].seenAt = now }
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

    /// Remove entries that are either (a) marked seen more than
    /// `ttlAfterSeen` ago or (b) unseen but older than `ttlUnseen`. The
    /// second clause is the escape hatch that stops worry bubbles from
    /// running forever when an auto-dismissed alert never got
    /// acknowledged. Returns the number of entries removed.
    @discardableResult
    func sweep() -> Int {
        let now = Date()
        let seenCutoff   = now.addingTimeInterval(-ttlAfterSeen)
        let unseenCutoff = now.addingTimeInterval(-ttlUnseen)
        let before = entries.count
        entries.removeAll { e in
            if let seen = e.seenAt, seen < seenCutoff { return true }
            if e.seenAt == nil && e.time < unseenCutoff { return true }
            return false
        }
        return before - entries.count
    }
}
