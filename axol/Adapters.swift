import Foundation

// MARK: - Adapter plugin framework

/// Declarative predicate used by both `match` (select-the-adapter) and
/// `skip_if` (silence-this-case). Conditions are AND'd together: all
/// populated checks must hold for the predicate to return true. `field`
/// supports dot-paths so `workflow_run.conclusion` works without a wrapper.
///
/// Supported conditions:
///   - `exists: bool` — whether the field is present and non-null
///   - `equals: string` — exact string match on the resolved value
///   - `matches: string` — case-insensitive substring on the resolved value
///
/// `match` historically AND'd `exists` + `equals`; `skip_if` historically
/// OR'd `matches` vs `equals`. In practice `skip_if` callers only ever set
/// one field at a time, so AND'ing across a unified shape preserves every
/// real-world behavior while deleting two near-duplicate structs.
struct Predicate {
    static let allowedKeys: Set<String> = ["field", "exists", "equals", "matches"]

    let field: String
    let exists: Bool?
    let equals: String?
    /// Substring patterns. Stored as an array so a single adapter rule can
    /// silence several known-noise messages at once (e.g. both CC's
    /// "waiting for your input" and "needs your permission" nags). JSON
    /// accepts either a bare string or an array of strings — if any
    /// pattern is a substring of the resolved field, the match succeeds.
    let matches: [String]?

    init?(json: [String: Any]?) {
        guard let json = json, let field = json["field"] as? String else { return nil }
        self.field = field
        self.exists = json["exists"] as? Bool
        self.equals = json["equals"] as? String
        if let arr = json["matches"] as? [String] {
            self.matches = arr
        } else if let s = json["matches"] as? String {
            self.matches = [s]
        } else {
            self.matches = nil
        }
    }

    /// Validate a predicate object loudly at load time. Returns nil if the
    /// shape is clean; otherwise a human-readable reason. Callers log this
    /// against the adapter filename so a typo'd `match_es` key surfaces
    /// immediately instead of silently turning the predicate into a no-op.
    static func validationError(_ json: [String: Any]?, context: String) -> String? {
        guard let json = json else { return "\(context) missing (expected object)" }
        let unknown = json.keys.filter { !allowedKeys.contains($0) }.sorted()
        if !unknown.isEmpty {
            return "\(context) has unknown key(s): \(unknown.joined(separator: ", "))"
        }
        if !(json["field"] is String) {
            return "\(context) missing 'field' (string)"
        }
        if json["exists"] != nil && !(json["exists"] is Bool) {
            return "\(context) 'exists' must be bool"
        }
        if json["equals"] != nil && !(json["equals"] is String) {
            return "\(context) 'equals' must be string"
        }
        if let m = json["matches"], !(m is String) {
            guard let arr = m as? [Any], arr.allSatisfy({ $0 is String }) else {
                return "\(context) 'matches' must be string or array of strings"
            }
        }
        return nil
    }

    func evaluate(_ payload: [String: Any]) -> Bool {
        let value = AdapterTemplate.resolvePath(field, payload: payload)
        let present = value != nil && !(value is NSNull)
        if let exists = exists, exists != present { return false }
        if let equals = equals {
            guard let str = value as? String, str == equals else { return false }
        }
        if let patterns = matches, !patterns.isEmpty {
            let str = (value as? String) ?? ""
            let anyHit = patterns.contains { str.range(of: $0, options: .caseInsensitive) != nil }
            if !anyHit { return false }
        }
        return true
    }
}

struct AlertAdapter {
    /// Keys the adapter loader knows about at the top level. Anything else
    /// is either a silent no-op field or (more likely) a typo — we reject
    /// the adapter and log the unknown keys so the author notices.
    private static let topLevelKeys: Set<String> = ["name", "match", "switch", "cases", "template"]

    let name: String
    let match: Predicate
    let switchField: String?
    let cases: [String: [String: Any]]
    let flatTemplate: [String: Any]?

    static func load(from url: URL) -> AlertAdapter? {
        let file = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            NSLog("axol: adapter %@ — unreadable", file)
            return nil
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            NSLog("axol: adapter %@ — not a JSON object", file)
            return nil
        }

        let unknownTop = json.keys.filter { !topLevelKeys.contains($0) }.sorted()
        if !unknownTop.isEmpty {
            NSLog("axol: adapter %@ — unknown top-level key(s): %@", file, unknownTop.joined(separator: ", "))
            return nil
        }

        guard let name = json["name"] as? String else {
            NSLog("axol: adapter %@ — missing 'name' (string)", file)
            return nil
        }

        let matchJson = json["match"] as? [String: Any]
        if let err = Predicate.validationError(matchJson, context: "'match'") {
            NSLog("axol: adapter %@ — %@", file, err)
            return nil
        }
        guard let match = Predicate(json: matchJson) else {
            NSLog("axol: adapter %@ — could not build match predicate", file)
            return nil
        }

        let switchField = json["switch"] as? String
        let cases = (json["cases"] as? [String: [String: Any]]) ?? [:]
        let flatTemplate = json["template"] as? [String: Any]
        if switchField == nil && flatTemplate == nil {
            NSLog("axol: adapter %@ — needs either 'switch'+'cases' or 'template'", file)
            return nil
        }
        if switchField != nil && cases.isEmpty {
            NSLog("axol: adapter %@ — 'switch' set but 'cases' is empty", file)
            return nil
        }

        // Validate any skip_if predicates inside cases / flatTemplate.
        let allCaseBodies = flatTemplate.map { [$0] } ?? Array(cases.values)
        for body in allCaseBodies {
            if let skipJson = body["skip_if"] {
                guard let skipDict = skipJson as? [String: Any] else {
                    NSLog("axol: adapter %@ — 'skip_if' must be an object", file)
                    return nil
                }
                if let err = Predicate.validationError(skipDict, context: "'skip_if'") {
                    NSLog("axol: adapter %@ — %@", file, err)
                    return nil
                }
            }
        }

        return AlertAdapter(
            name: name,
            match: match,
            switchField: switchField,
            cases: cases,
            flatTemplate: flatTemplate
        )
    }

    func render(_ payload: [String: Any]) -> AdapterOutcome {
        guard match.evaluate(payload) else { return .noMatch }
        let template: [String: Any]?
        if let switchField = switchField {
            let key = (AdapterTemplate.resolvePath(switchField, payload: payload) as? String) ?? ""
            template = cases[key]
        } else {
            template = flatTemplate
        }
        guard var t = template else { return .noMatch }
        if let skipJson = t["skip_if"] as? [String: Any],
           let skip = Predicate(json: skipJson),
           skip.evaluate(payload) {
            return .skipped
        }
        t.removeValue(forKey: "skip_if")
        guard let out = AdapterTemplate.render(t, payload: payload) as? [String: Any] else {
            return .noMatch
        }
        return .rendered(out)
    }
}

enum AdapterOutcome {
    case rendered([String: Any])
    case skipped
    case noMatch
}

/// Registry of filter functions available inside `{{ ... }}` expressions.
///
/// Each filter has signature `(value, arg?) -> value'` and is usable in two
/// forms:
///
///   {{ basename some.path }}        — prefix: `arg` comes from the payload
///   {{ field | default 'fallback' }} — pipe: `arg` is a literal (quotes stripped)
///
/// To extend the template language, add an entry here. No compile-time
/// coupling to the parser — the parser just looks the name up.
enum TemplateFilters {
    static let registry: [String: (Any?, String?) -> Any?] = [
        "basename": { value, _ in
            guard let s = value as? String else { return value }
            return s.split(separator: "/").last.map(String.init) ?? s
        },
        "trim": { value, _ in
            guard let s = value as? String else { return value }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        },
        "default": { value, arg in
            // Matches README: "Fallback when missing or empty." So the
            // fallback path covers nil, NSNull, AND the empty string.
            // Non-string non-null values (e.g. numeric 0, a dict) pass
            // through unchanged.
            if let s = value as? String { return s.isEmpty ? (arg ?? "") : value }
            if value != nil && !(value is NSNull) { return value }
            return arg ?? ""
        },
    ]
}

enum AdapterTemplate {
    /// Upper bound on nested dict/array recursion in a rendered template.
    /// Real templates are 1–3 levels deep; 20 is generous headroom that
    /// still bounds a pathological adapter (wide or deep nesting) from
    /// blowing the stack.
    private static let maxRenderDepth = 20

    static func render(_ obj: Any, payload: [String: Any]) -> Any? {
        return render(obj, payload: payload, depth: 0)
    }

    private static func render(_ obj: Any, payload: [String: Any], depth: Int) -> Any? {
        if depth > maxRenderDepth {
            NSLog("axol: template render depth exceeded %d — truncating", maxRenderDepth)
            return nil
        }
        if let s = obj as? String {
            return renderString(s, payload: payload)
        }
        if let d = obj as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d {
                if let rendered = render(v, payload: payload, depth: depth + 1) {
                    out[k] = rendered
                }
            }
            return out
        }
        if let arr = obj as? [Any] {
            return arr.compactMap { render($0, payload: payload, depth: depth + 1) }
        }
        return obj
    }

    private static func renderString(_ s: String, payload: [String: Any]) -> Any {
        // If the whole string is a single {{...}}, preserve the value's native type
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"),
           let closeStart = trimmed.range(of: "}}") {
            let firstClose = closeStart.lowerBound
            if firstClose == trimmed.index(trimmed.endIndex, offsetBy: -2) {
                let inner = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                return evalExpr(inner, payload: payload) ?? ""
            }
        }
        // Otherwise interpolate each {{...}} as a string
        var result = s
        while let openRange = result.range(of: "{{"),
              let closeRange = result.range(of: "}}", range: openRange.upperBound..<result.endIndex) {
            let inner = String(result[openRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = evalExpr(inner, payload: payload)
            let rendered: String = {
                guard let v = value else { return "" }
                if let str = v as? String { return str }
                if let n = v as? NSNumber { return n.stringValue }
                return String(describing: v)
            }()
            result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: rendered)
        }
        return result
    }

    /// Upper bound on the number of pipeline stages in `{{ a | b | c }}`.
    /// In practice adapters use 1–2 filters; 10 is plenty of headroom and
    /// keeps a hostile or typo'd template from chewing CPU.
    private static let maxPipelineStages = 10

    private static func evalExpr(_ expr: String, payload: [String: Any]) -> Any? {
        let stages = expr.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !stages.isEmpty else { return nil }
        if stages.count > maxPipelineStages {
            NSLog("axol: template pipeline has %d stages (max %d) — truncating", stages.count, maxPipelineStages)
        }
        let bounded = stages.prefix(maxPipelineStages)
        var current: Any? = evalAtom(bounded.first!, payload: payload)
        for stage in bounded.dropFirst() {
            current = applyFilter(stage, value: current)
        }
        return current
    }

    private static func evalAtom(_ atom: String, payload: [String: Any]) -> Any? {
        let parts = atom.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        if parts.count == 2, let filter = TemplateFilters.registry[parts[0]] {
            // Prefix form: `{{ basename some.path }}`. The second token is a
            // path into the payload, not a literal; resolve before piping.
            return filter(resolvePath(parts[1], payload: payload), nil)
        }
        return resolvePath(atom, payload: payload)
    }

    static func resolvePath(_ path: String, payload: [String: Any]) -> Any? {
        var current: Any? = payload
        for part in path.split(separator: ".").map(String.init) {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[part]
        }
        if current is NSNull { return nil }
        return current
    }

    private static func applyFilter(_ stage: String, value: Any?) -> Any? {
        let parts = stage.split(separator: " ", maxSplits: 1).map(String.init)
        guard let fn = parts.first, let filter = TemplateFilters.registry[fn] else { return value }
        let arg = parts.count > 1 ? stripQuotes(parts[1]) : nil
        return filter(value, arg)
    }

    private static func stripQuotes(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if (t.hasPrefix("'") && t.hasSuffix("'")) || (t.hasPrefix("\"") && t.hasSuffix("\"")) {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}

final class AdapterRegistry {
    private(set) var adapters: [AlertAdapter] = []

    func load() {
        adapters = []
        let fm = FileManager.default

        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        loadFrom(dir: exeDir.appendingPathComponent("adapters"))

        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let userDir = support.appendingPathComponent("Axol/adapters")
            try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
            loadFrom(dir: userDir)
        }

        NSLog("axol: loaded \(adapters.count) adapter(s): \(adapters.map { $0.name }.joined(separator: ", "))")
    }

    private func loadFrom(dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard item.pathExtension == "json" else { continue }
            if let adapter = AlertAdapter.load(from: item) {
                adapters.append(adapter)
                NSLog("axol: adapter %@ — loaded as '%@'", item.lastPathComponent, adapter.name)
            }
            // AlertAdapter.load already logs its own skip reason on failure.
        }
    }

    /// Result of routing a payload through the registered adapters. `.rendered`
    /// means an adapter matched and produced an envelope; `.skipped` means an
    /// adapter matched but its case's `skip_if` predicate intentionally
    /// silenced the event (not an error); `.noMatch` means no adapter claimed
    /// the payload.
    enum RouteResult {
        case rendered([String: Any], adapterName: String)
        case skipped(adapterName: String)
        case noMatch
    }

    func route(_ payload: [String: Any]) -> RouteResult {
        var sawSkip: String? = nil
        for adapter in adapters {
            switch adapter.render(payload) {
            case .rendered(let env):
                return .rendered(env, adapterName: adapter.name)
            case .skipped:
                sawSkip = adapter.name
            case .noMatch:
                continue
            }
        }
        if let name = sawSkip { return .skipped(adapterName: name) }
        return .noMatch
    }
}
