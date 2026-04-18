import Foundation

// MARK: - Envelope validator

/// Canonicalizes the incoming envelope and drops anything outside the closed
/// vocabulary. Action types not in `allowedActions` (and anything that looks
/// like shell execution) are silently dropped here — this is the narrow
/// trust boundary between adapter-rendered output and the rest of the app.
enum EnvelopeValidator {
    static let allowedPriorities: Set<String> = ["low", "normal", "high", "urgent"]
    static let allowedActions: Set<String> = ["focus-pid", "open-url", "reveal-file", "noop"]
    static let allowedAttention: Set<String> = ["wiggle", "hop", "none"]

    static func validate(_ input: [String: Any]) -> [String: Any]? {
        guard let title = input["title"] as? String, !title.isEmpty else { return nil }
        let priority = (input["priority"] as? String).flatMap { allowedPriorities.contains($0) ? $0 : nil } ?? "normal"
        var out: [String: Any] = [
            "title": title,
            "priority": priority,
            "source": (input["source"] as? String) ?? "unknown"
        ]
        if let body = input["body"] as? String, !body.isEmpty { out["body"] = body }
        if let icon = input["icon"] as? String, !icon.isEmpty { out["icon"] = icon }
        if let attn = input["attention"] as? String, allowedAttention.contains(attn) { out["attention"] = attn }
        if let ctx = input["context"] as? [String: Any], !ctx.isEmpty { out["context"] = ctx }
        if let actions = input["actions"] as? [[String: Any]] {
            let valid = actions.compactMap { validateAction($0) }
            if !valid.isEmpty { out["actions"] = valid }
        }
        return out
    }

    private static func validateAction(_ a: [String: Any]) -> [String: Any]? {
        guard let type = a["type"] as? String, allowedActions.contains(type) else { return nil }
        var out: [String: Any] = ["type": type]
        if let label = a["label"] as? String { out["label"] = label }
        switch type {
        case "focus-pid":
            let pid: Int? = (a["pid"] as? Int) ?? (a["pid"] as? NSNumber)?.intValue ?? Int((a["pid"] as? String) ?? "")
            guard let p = pid, p > 0 else { return nil }
            out["pid"] = p
        case "open-url":
            guard let url = a["url"] as? String,
                  url.hasPrefix("http://") || url.hasPrefix("https://") else { return nil }
            out["url"] = url
        case "reveal-file":
            guard let path = a["path"] as? String, !path.isEmpty else { return nil }
            out["path"] = path
        case "noop":
            break
        default:
            return nil
        }
        return out
    }
}
