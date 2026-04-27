import Foundation

/// Evaluates Claude Code permission rules against a PreToolUse payload so
/// Axol can auto-allow or auto-deny tool calls that match existing
/// user / project rules — only unresolved cases surface as a bubble.
///
/// Sources (merged, in CC's declared precedence):
///   - ~/.claude/settings.json                 (user)
///   - <cwd>/.claude/settings.json             (project shared)
///   - <cwd>/.claude/settings.local.json       (project local)
///
/// Decision precedence is deny > ask > allow — first match in each bucket
/// wins and deny beats everything (matches CC's docs). Anything unmatched
/// returns `.undecided`; the caller (Axol.swift onPermission) bubbles.
///
/// ─── Why this file exists ──────────────────────────────────────────────
/// This is a reimplementation of CC's permission evaluator, which is not
/// something we want to own long-term. We wrote it because CC's current
/// hook surface leaves no clean seam for a sidecar UI that needs to show
/// a bubble and wait for a human click:
///
///   - `PermissionRequest` hook fires only-ish when CC would prompt, but
///     has a ~1.5s race (anthropics/claude-code#12176) — if the hook's
///     response arrives later than that, CC's TTY prompt shows anyway and
///     the hook's decision is ignored. Human clicks take longer than 1.5s.
///   - `PreToolUse` fires for *every* tool call (anthropics/claude-code
///     #29212, closed "not planned"), so to avoid flooding the user with
///     bubbles for already-allowed calls, the hook has to replicate CC's
///     allow/deny/ask evaluation — which is this file.
///   - Agent SDK's `canUseTool` callback is the clean primitive but is
///     SDK-only; there's no path to bind it to a running CC CLI session.
///     Tracking feature request: anthropics/claude-code#7228.
///
/// When any of those issues resolves (particularly #7228), revisit this
/// file — the whole PermissionRules + applyMode layer becomes deletable.
enum PermissionDecision: String {
    case allow, deny, ask, undecided
}

extension PermissionRules {
    /// Overlay CC's session-level `permission_mode` on top of the rule-eval
    /// result so `/auto` runs aren't blocked behind a bubble when the user
    /// has explicitly opted out of prompting. Rule-level explicit decisions
    /// (allow / deny) always pass through — mode never downgrades them.
    ///
    /// - `auto` / `bypassPermissions` — user directed autonomous execution.
    ///   Allow any unresolved call.
    /// - `acceptEdits` — user opted to auto-accept file edits only. Allow
    ///   Edit / Write / NotebookEdit; still bubble Bash / WebFetch / MCP.
    /// - `plan` — read-only planning mode. Deny any unresolved mutation.
    /// - `dontAsk` — inverse of `auto`: anything not pre-approved by an
    ///   allow rule is denied (per CC docs). Falling through to a bubble
    ///   here would defeat the user's "don't ask me" intent.
    /// - `default` (or unknown) — pass through (bubble on ask / undecided).
    static func applyMode(_ ruleDecision: PermissionDecision, mode: String, toolName: String) -> PermissionDecision {
        if ruleDecision == .deny || ruleDecision == .allow { return ruleDecision }
        switch mode {
        case "auto", "bypassPermissions":
            return .allow
        case "acceptEdits":
            let edits: Set<String> = ["Edit", "Write", "NotebookEdit"]
            return edits.contains(toolName) ? .allow : ruleDecision
        case "plan", "dontAsk":
            return .deny
        default:
            return ruleDecision
        }
    }
}

struct PermissionRules {
    private let deny: [String]
    private let ask: [String]
    private let allow: [String]
    private let cwd: String

    init(cwd: String) {
        var allDeny: [String] = []
        var allAsk: [String] = []
        var allAllow: [String] = []
        for path in Self.settingsPaths(cwd: cwd) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let perms = json["permissions"] as? [String: Any] else { continue }
            if let d = perms["deny"]  as? [String] { allDeny.append(contentsOf: d) }
            if let a = perms["ask"]   as? [String] { allAsk.append(contentsOf: a) }
            if let a = perms["allow"] as? [String] { allAllow.append(contentsOf: a) }
        }
        self.deny = allDeny
        self.ask = allAsk
        self.allow = allAllow
        self.cwd = cwd
    }

    /// Settings lookup order (matches CC's project-root discovery well enough
    /// for permission rules): user settings first, then every ancestor of
    /// `cwd` that contains a `.claude/` directory, walking up to `/`. Both
    /// `settings.json` and `settings.local.json` are picked up at each level.
    /// Rules merge across all matches — precedence is handled by the
    /// deny > ask > allow evaluation order in `evaluate`, not by path.
    private static func settingsPaths(cwd: String) -> [String] {
        let home = NSHomeDirectory()
        var paths: [String] = ["\(home)/.claude/settings.json"]
        let fm = FileManager.default
        var dir = cwd
        while !dir.isEmpty && dir != "/" {
            let claude = "\(dir)/.claude"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: claude, isDirectory: &isDir), isDir.boolValue {
                paths.append("\(claude)/settings.json")
                paths.append("\(claude)/settings.local.json")
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return paths
    }

    func evaluate(toolName: String, toolInput: [String: Any]) -> PermissionDecision {
        // Bash needs compound-command semantics: deny-any beats allow-all. We
        // split on `&&`/`||`/`;`/`|` and evaluate each subcommand against the
        // merged rule buckets per CC's docs ("each subcommand must match
        // independently"). Other tools evaluate per-rule against the whole
        // tool_input — their matchers are scalar (a path, a domain, a tool
        // name) so compound semantics don't apply.
        if toolName == "Bash", let cmd = toolInput["command"] as? String {
            let subs = Self.splitShellCommand(cmd)
            // deny: any sub matches any deny rule → deny the whole call.
            for sub in subs {
                let subInput: [String: Any] = ["command": sub]
                for rule in deny where matches(rule: rule, toolName: "Bash", toolInput: subInput) { return .deny }
            }
            // ask: same any-match semantics.
            for sub in subs {
                let subInput: [String: Any] = ["command": sub]
                for rule in ask where matches(rule: rule, toolName: "Bash", toolInput: subInput) { return .ask }
            }
            // allow: every subcommand must match some allow rule. Otherwise
            // fall through to undecided so the caller can bubble.
            let allAllowed = subs.allSatisfy { sub in
                let subInput: [String: Any] = ["command": sub]
                return allow.contains { rule in matches(rule: rule, toolName: "Bash", toolInput: subInput) }
            }
            return allAllowed ? .allow : .undecided
        }
        for rule in deny  where matches(rule: rule, toolName: toolName, toolInput: toolInput) { return .deny  }
        for rule in ask   where matches(rule: rule, toolName: toolName, toolInput: toolInput) { return .ask   }
        for rule in allow where matches(rule: rule, toolName: toolName, toolInput: toolInput) { return .allow }
        return .undecided
    }

    /// Splits a shell command string on unquoted `&&`, `||`, `;`, `|`. Not a
    /// full shell parser — quoted operators inside "..."/'...' are preserved,
    /// backticks and `$(...)` are not recursed into. This is good enough for
    /// CC's permission rules, which target common compound patterns like
    /// `cmd1 && cmd2 | cmd3`.
    static func splitShellCommand(_ cmd: String) -> [String] {
        var subs: [String] = []
        var current = ""
        var i = cmd.startIndex
        var inSingle = false
        var inDouble = false
        while i < cmd.endIndex {
            let ch = cmd[i]
            if ch == "'" && !inDouble { inSingle.toggle(); current.append(ch); i = cmd.index(after: i); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); current.append(ch); i = cmd.index(after: i); continue }
            if !inSingle && !inDouble {
                let next = cmd.index(after: i)
                if ch == "&" && next < cmd.endIndex && cmd[next] == "&" {
                    let s = current.trimmingCharacters(in: .whitespaces); if !s.isEmpty { subs.append(s) }
                    current = ""; i = cmd.index(after: next); continue
                }
                if ch == "|" && next < cmd.endIndex && cmd[next] == "|" {
                    let s = current.trimmingCharacters(in: .whitespaces); if !s.isEmpty { subs.append(s) }
                    current = ""; i = cmd.index(after: next); continue
                }
                if ch == ";" || ch == "|" {
                    let s = current.trimmingCharacters(in: .whitespaces); if !s.isEmpty { subs.append(s) }
                    current = ""; i = cmd.index(after: i); continue
                }
            }
            current.append(ch)
            i = cmd.index(after: i)
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { subs.append(tail) }
        return subs.isEmpty ? [cmd.trimmingCharacters(in: .whitespaces)] : subs
    }

    private func matches(rule: String, toolName: String, toolInput: [String: Any]) -> Bool {
        // MCP rules address a specific server+tool, not a field on the payload —
        // the rule is matched against the whole tool_name (e.g. mcp__webflow__publish).
        if rule.hasPrefix("mcp__") {
            return wildcardMatch(pattern: rule, string: toolName)
        }
        // "ToolName" (bare) — allow any invocation of that tool.
        guard let openIdx = rule.firstIndex(of: "("), rule.hasSuffix(")") else {
            return rule == toolName
        }
        let name = String(rule[..<openIdx])
        guard name == toolName else { return false }
        let afterOpen = rule.index(after: openIdx)
        let inner = String(rule[afterOpen..<rule.index(before: rule.endIndex)])

        switch toolName {
        case "Bash":
            // `evaluate` pre-splits compound commands and calls us with each
            // subcommand as `tool_input["command"]`, so here we just glob.
            guard let cmd = toolInput["command"] as? String else { return false }
            return wildcardMatch(pattern: inner, string: cmd)
        case "Read", "Write", "Edit", "NotebookEdit":
            guard let path = toolInput["file_path"] as? String else { return false }
            return pathGlobMatch(pattern: expandPathPattern(inner), path: path)
        case "WebFetch":
            guard inner.hasPrefix("domain:"),
                  let url = toolInput["url"] as? String,
                  let host = URL(string: url)?.host else { return false }
            let domain = String(inner.dropFirst("domain:".count))
            return host == domain || host.hasSuffix("." + domain)
        default:
            // Unknown tool with an inner pattern — fall back to matching a
            // `command`-like field if present, otherwise require bare match.
            if let cmd = toolInput["command"] as? String {
                return wildcardMatch(pattern: inner, string: cmd)
            }
            return false
        }
    }

    /// CC path-pattern prefixes (per docs):
    ///   //X   absolute
    ///   ~/X   home-relative
    ///   /X    project-root-relative
    ///   X     cwd-relative (with or without ./ prefix)
    private func expandPathPattern(_ pat: String) -> String {
        if pat.hasPrefix("//") { return String(pat.dropFirst()) }        // "//Users/..." → "/Users/..."
        if pat.hasPrefix("~/") { return NSHomeDirectory() + String(pat.dropFirst(1)) }
        if pat.hasPrefix("/")  { return cwd + pat }
        let trimmed = pat.hasPrefix("./") ? String(pat.dropFirst(2)) : pat
        return cwd + "/" + trimmed
    }

    /// Bash-style: `*` matches any sequence including spaces, everything
    /// else is literal. CC's docs note word-boundary behavior around `*`
    /// but we don't model it explicitly — the typical `Bash(cmd *)` idiom
    /// already has a space before the `*`, which in this translation acts
    /// as a literal space requirement.
    private func wildcardMatch(pattern: String, string: String) -> Bool {
        let regex = "^" + globToRegex(pattern) + "$"
        return string.range(of: regex, options: .regularExpression) != nil
    }

    /// Gitignore-style: `**` matches any path including `/`, `*` matches
    /// within a single segment, `?` matches one non-`/` char.
    private func pathGlobMatch(pattern: String, path: String) -> Bool {
        let regex = "^" + pathGlobToRegex(pattern) + "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }

    private func globToRegex(_ pattern: String) -> String {
        var result = ""
        for ch in pattern {
            if ch == "*" {
                result += ".*"
            } else {
                result += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return result
    }

    private func pathGlobToRegex(_ pattern: String) -> String {
        var result = ""
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            if ch == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    result += ".*"
                    i = pattern.index(after: next)
                    continue
                }
                result += "[^/]*"
            } else if ch == "?" {
                result += "[^/]"
            } else {
                result += NSRegularExpression.escapedPattern(for: String(ch))
            }
            i = pattern.index(after: i)
        }
        return result
    }
}
