import Foundation

// MARK: - Character themes

/// Color palette for the axolotl character. Eight knobs drive every shape
/// in `AxolCharacterView.buildCharacter`:
///
///   - `gillBase` — upper gill pair on each side (the lighter pink in the default)
///   - `gillTip`  — lower (rear) gill on each side, traditionally darker
///   - `body`     — main body ellipse + the two arms
///   - `belly`    — the inner belly ellipse layered on top of the body
///   - `eye`      — pupils and the "closed mouth" arc
///   - `highlight` — tiny dots on each eye (keep this white in most skins)
///   - `cheek`    — blush circles (rendered at 45% opacity regardless of the
///                  alpha you pick, since opacity is baked into the layer)
///   - `mouth`    — mouth-open fill (matches eye color in the default but
///                  can diverge for skins where the mouth should stand out)
///
/// UI chrome (bubbles, pills, badges) is intentionally NOT themable — skins
/// only re-color the character. This keeps the cost and complexity small
/// and most "I want a green axol" requests genuinely stop at the character.
struct CharacterColors: Equatable {
    let gillBase: String
    let gillTip: String
    let body: String
    let belly: String
    let eye: String
    let highlight: String
    let cheek: String
    let mouth: String

    static let allowedKeys: Set<String> = [
        "gillBase", "gillTip", "body", "belly", "eye", "highlight", "cheek", "mouth",
    ]
}

struct Theme: Equatable {
    /// Human-readable theme identifier; also matches the file stem on disk.
    let name: String
    let character: CharacterColors

    /// Hardcoded safety-net palette — identical to the original axolotl
    /// colors. Used when no theme file is found, or when a provided file
    /// fails validation. Guarantees Axol always has a valid palette to
    /// render with, even on a fresh install.
    static let builtin = Theme(
        name: "builtin",
        character: CharacterColors(
            gillBase:  "E066A0",
            gillTip:   "BF4F85",
            body:      "F29BC5",
            belly:     "F0B5D3",
            eye:       "2D2533",
            highlight: "FFFFFF",
            cheek:     "FF7AA3",
            mouth:     "7A2D4D"
        )
    )
}

enum ThemeLoader {
    private static let topLevelKeys: Set<String> = ["name", "character"]

    /// Resolve a theme at startup, trying in order:
    ///   1. `~/Library/Application Support/Axol/theme.json` (user override)
    ///   2. `<exe-dir>/themes/pink.json` (bundled default)
    ///   3. `Theme.builtin` — hardcoded fallback so a broken install still runs.
    static func loadAtStartup() -> Theme {
        let fm = FileManager.default

        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let userTheme = support.appendingPathComponent("Axol/theme.json")
            if fm.fileExists(atPath: userTheme.path) {
                switch load(from: userTheme) {
                case .ok(let theme):
                    NSLog("axol: theme %@ loaded from user override", theme.name)
                    return theme
                case .error(let reason):
                    NSLog("axol: user theme.json rejected — %@; falling back", reason)
                }
            }
        }

        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let bundled = exeDir.appendingPathComponent("themes/pink.json")
        if fm.fileExists(atPath: bundled.path) {
            switch load(from: bundled) {
            case .ok(let theme):
                NSLog("axol: theme %@ loaded from bundle", theme.name)
                return theme
            case .error(let reason):
                NSLog("axol: bundled pink.json rejected — %@; using builtin", reason)
            }
        }

        NSLog("axol: no theme files found — using builtin palette")
        return .builtin
    }

    enum LoadResult {
        case ok(Theme)
        case error(String)
    }

    /// Parse + validate a theme file. Returns a concrete reason string on
    /// failure so callers can log something more useful than "bad theme".
    static func load(from url: URL) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else {
            return .error("unreadable")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .error("not a JSON object")
        }

        let unknownTop = json.keys.filter { !topLevelKeys.contains($0) }.sorted()
        if !unknownTop.isEmpty {
            return .error("unknown top-level key(s): \(unknownTop.joined(separator: ", "))")
        }
        guard let name = json["name"] as? String, !name.isEmpty else {
            return .error("missing 'name' (non-empty string)")
        }
        guard let charJson = json["character"] as? [String: Any] else {
            return .error("missing 'character' (object)")
        }

        let unknownChar = charJson.keys.filter { !CharacterColors.allowedKeys.contains($0) }.sorted()
        if !unknownChar.isEmpty {
            return .error("'character' has unknown key(s): \(unknownChar.joined(separator: ", "))")
        }

        // Build each color with a single require-and-normalize helper so
        // every missing/bad-hex diagnostic reads the same.
        var resolved: [String: String] = [:]
        for key in CharacterColors.allowedKeys {
            guard let raw = charJson[key] as? String else {
                return .error("'character.\(key)' missing or not a string")
            }
            guard let hex = normalizeHex(raw) else {
                return .error("'character.\(key)' not a valid hex color (got \(raw))")
            }
            resolved[key] = hex
        }

        let chars = CharacterColors(
            gillBase:  resolved["gillBase"]!,
            gillTip:   resolved["gillTip"]!,
            body:      resolved["body"]!,
            belly:     resolved["belly"]!,
            eye:       resolved["eye"]!,
            highlight: resolved["highlight"]!,
            cheek:     resolved["cheek"]!,
            mouth:     resolved["mouth"]!
        )
        return .ok(Theme(name: name, character: chars))
    }

    /// Accepts `#rgb`, `#rrggbb`, `rgb`, or `rrggbb`. Returns the 6-hex form
    /// with no leading hash, matching the shape `AxolCharacterView.hexColor`
    /// already expects. Returns nil if the input isn't a valid hex color.
    static func normalizeHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        s = s.uppercased()
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        if s.count == 3 {
            // Expand shorthand `F0A` → `FF00AA`.
            return s.map { "\($0)\($0)" }.joined()
        }
        if s.count == 6 { return s }
        return nil
    }
}
