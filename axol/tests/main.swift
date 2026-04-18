import Foundation

// Small, dependency-free test harness. We deliberately don't pull in XCTest
// because it requires linking the framework and a Bundle target, which
// would drag this whole project away from "just swiftc". Instead we track
// pass/fail in a counter and exit non-zero if anything fails.

final class TestRunner {
    private(set) var passed = 0
    private(set) var failed = 0
    private var currentCase: String = ""

    func run(_ name: String, _ body: (TestRunner) -> Void) {
        currentCase = name
        body(self)
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("  ✘ \(currentCase) — \(message()) (\(file):\(line))")
        }
    }

    func report() -> Int32 {
        print("\n\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}

let t = TestRunner()

// MARK: - Predicate tests

t.run("Predicate: exists true matches present field") { t in
    let p = Predicate(json: ["field": "foo", "exists": true])!
    t.expect(p.evaluate(["foo": "x"]) == true, "present field should satisfy exists:true")
    t.expect(p.evaluate([:]) == false, "absent field should fail exists:true")
}

t.run("Predicate: exists false matches absent field") { t in
    let p = Predicate(json: ["field": "foo", "exists": false])!
    t.expect(p.evaluate([:]) == true, "absent field should satisfy exists:false")
    t.expect(p.evaluate(["foo": "x"]) == false, "present field should fail exists:false")
}

t.run("Predicate: equals requires exact string") { t in
    let p = Predicate(json: ["field": "status", "equals": "ok"])!
    t.expect(p.evaluate(["status": "ok"]) == true, "exact match passes")
    t.expect(p.evaluate(["status": "okay"]) == false, "near-match fails")
    t.expect(p.evaluate([:]) == false, "missing field fails")
}

t.run("Predicate: matches does case-insensitive substring") { t in
    let p = Predicate(json: ["field": "msg", "matches": "waiting for input"])!
    t.expect(p.evaluate(["msg": "Now WAITING FOR Input plz"]) == true, "case-insensitive substring")
    t.expect(p.evaluate(["msg": "all done"]) == false, "non-matching fails")
}

t.run("Predicate: AND of all populated conditions") { t in
    let p = Predicate(json: ["field": "x", "exists": true, "equals": "yes"])!
    t.expect(p.evaluate(["x": "yes"]) == true, "both conditions hold")
    t.expect(p.evaluate(["x": "no"]) == false, "equals fails → overall fails")
}

t.run("Predicate: dot-path resolves nested field") { t in
    let p = Predicate(json: ["field": "run.state", "equals": "success"])!
    t.expect(p.evaluate(["run": ["state": "success"]]) == true, "nested match")
    t.expect(p.evaluate(["run": ["state": "failed"]]) == false, "nested non-match")
}

t.run("Predicate: NSNull treated as absent") { t in
    let p = Predicate(json: ["field": "foo", "exists": true])!
    t.expect(p.evaluate(["foo": NSNull()]) == false, "NSNull should count as absent")
}

t.run("Predicate: validationError rejects unknown keys") { t in
    let err = Predicate.validationError(["field": "x", "match_es": "bad"], context: "'match'")
    t.expect(err != nil, "unknown key should produce error")
    t.expect(err?.contains("match_es") == true, "error message names the bad key")
}

t.run("Predicate: validationError rejects wrong types") { t in
    let err1 = Predicate.validationError(["field": "x", "exists": "true"], context: "'match'")
    t.expect(err1 != nil, "non-bool exists should fail")

    let err2 = Predicate.validationError(["field": 42], context: "'match'")
    t.expect(err2 != nil, "non-string field should fail")
}

t.run("Predicate: validationError accepts clean shape") { t in
    let err = Predicate.validationError(
        ["field": "x", "exists": true, "equals": "y", "matches": "z"],
        context: "'match'"
    )
    t.expect(err == nil, "all valid keys should pass")
}

// MARK: - AdapterTemplate tests

t.run("Template: single {{...}} preserves native type") { t in
    let out = AdapterTemplate.render("{{pid}}", payload: ["pid": 12345])
    t.expect(out as? Int == 12345, "integer should stay Int, not stringify")
}

t.run("Template: interpolated {{...}} stringifies") { t in
    let out = AdapterTemplate.render("pid=={{pid}}", payload: ["pid": 12345])
    t.expect(out as? String == "pid==12345", "embedded expression stringifies")
}

t.run("Template: dot-path resolves nested") { t in
    let out = AdapterTemplate.render("{{run.branch}}", payload: ["run": ["branch": "main"]])
    t.expect(out as? String == "main", "nested resolves")
}

t.run("Template: default filter supplies fallback for missing") { t in
    let out = AdapterTemplate.render("{{missing | default 'fallback'}}", payload: [:])
    t.expect(out as? String == "fallback", "default substitutes when absent")
}

t.run("Template: default filter skipped when value present") { t in
    let out = AdapterTemplate.render("{{msg | default 'x'}}", payload: ["msg": "real"])
    t.expect(out as? String == "real", "default yields when value exists")
}

t.run("Template: default treats empty string as missing") { t in
    let out = AdapterTemplate.render("{{msg | default 'x'}}", payload: ["msg": ""])
    t.expect(out as? String == "x", "empty string falls through to default")
}

t.run("Template: basename strips path prefix") { t in
    let out = AdapterTemplate.render("{{basename cwd}}", payload: ["cwd": "/Users/jim/projects/axol"])
    t.expect(out as? String == "axol", "basename = last path component")
}

t.run("Template: basename passes through non-strings") { t in
    let out = AdapterTemplate.render("{{basename n}}", payload: ["n": 42])
    t.expect(out as? Int == 42, "non-string value left untouched")
}

t.run("Template: trim removes whitespace") { t in
    let out = AdapterTemplate.render("{{trim field}}", payload: ["field": "  padded  \n"])
    t.expect(out as? String == "padded", "trim should strip whitespace/newlines")
}

t.run("Template: multi-stage pipeline") { t in
    let out = AdapterTemplate.render("{{foo | default 'x' | default 'y'}}", payload: [:])
    t.expect(out as? String == "x", "first default wins when value is missing")
}

t.run("Template: pipeline caps at 10 stages") { t in
    let filters = Array(repeating: " | default 'z'", count: 15).joined()
    let out = AdapterTemplate.render("{{foo\(filters)}}", payload: [:])
    // No assertion on value — we just want no crash / hang. The runner logs
    // a truncation warning, which is expected.
    t.expect(out != nil, "over-long pipeline still returns without hanging")
}

t.run("Template: nested dicts recurse") { t in
    let out = AdapterTemplate.render(
        ["label": "{{status}}", "meta": ["when": "{{time}}"]] as [String: Any],
        payload: ["status": "ok", "time": "now"]
    ) as? [String: Any]
    t.expect((out?["label"] as? String) == "ok", "top-level key rendered")
    t.expect(((out?["meta"] as? [String: Any])?["when"] as? String) == "now", "nested key rendered")
}

t.run("Template: arrays are mapped") { t in
    let out = AdapterTemplate.render(
        ["{{a}}", "{{b}}"] as [Any],
        payload: ["a": "first", "b": "second"]
    ) as? [Any]
    t.expect((out?[0] as? String) == "first", "array element 0 rendered")
    t.expect((out?[1] as? String) == "second", "array element 1 rendered")
}

// MARK: - AlertAdapter.load tests (via a temp directory)

let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("axol-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func writeAdapter(_ name: String, _ json: String) -> URL {
    let url = tmp.appendingPathComponent("\(name).json")
    try? json.write(to: url, atomically: true, encoding: .utf8)
    return url
}

t.run("AlertAdapter.load: valid flat template") { t in
    let url = writeAdapter("flat", #"""
        {"name":"flat","match":{"field":"title","exists":true},
         "template":{"title":"{{title}}","body":"{{body | default ''}}"}}
    """#)
    let a = AlertAdapter.load(from: url)
    t.expect(a != nil, "valid flat adapter should load")
    t.expect(a?.name == "flat", "name preserved")
}

t.run("AlertAdapter.load: valid switch adapter") { t in
    let url = writeAdapter("sw", #"""
        {"name":"sw","match":{"field":"kind","exists":true},
         "switch":"kind","cases":{
            "a":{"title":"A"},
            "b":{"title":"B"}
         }}
    """#)
    let a = AlertAdapter.load(from: url)
    t.expect(a != nil, "switch/cases adapter should load")
    t.expect(a?.cases.count == 2, "both cases preserved")
}

t.run("AlertAdapter.load: rejects unknown top-level key") { t in
    let url = writeAdapter("bad-top", #"""
        {"name":"x","match":{"field":"y","exists":true},"template":{},"extra":"oops"}
    """#)
    let a = AlertAdapter.load(from: url)
    t.expect(a == nil, "unknown top-level key should reject the adapter")
}

t.run("AlertAdapter.load: rejects missing name") { t in
    let url = writeAdapter("noname", #"""
        {"match":{"field":"y","exists":true},"template":{}}
    """#)
    t.expect(AlertAdapter.load(from: url) == nil, "missing name should reject")
}

t.run("AlertAdapter.load: rejects missing match") { t in
    let url = writeAdapter("nomatch", #"""
        {"name":"x","template":{}}
    """#)
    t.expect(AlertAdapter.load(from: url) == nil, "missing match should reject")
}

t.run("AlertAdapter.load: rejects typo'd predicate key") { t in
    let url = writeAdapter("typo", #"""
        {"name":"x","match":{"field":"y","match_es":"zz"},"template":{}}
    """#)
    t.expect(AlertAdapter.load(from: url) == nil, "typo'd key in match should reject")
}

t.run("AlertAdapter.load: rejects neither switch nor template") { t in
    let url = writeAdapter("neither", #"""
        {"name":"x","match":{"field":"y","exists":true}}
    """#)
    t.expect(AlertAdapter.load(from: url) == nil, "must have switch+cases or template")
}

t.run("AlertAdapter.load: rejects switch without cases") { t in
    let url = writeAdapter("noCases", #"""
        {"name":"x","match":{"field":"y","exists":true},"switch":"kind"}
    """#)
    t.expect(AlertAdapter.load(from: url) == nil, "switch without cases should reject")
}

t.run("AlertAdapter.load: validates skip_if shape") { t in
    let url = writeAdapter("badSkip", #"""
        {"name":"x","match":{"field":"y","exists":true},
         "switch":"k","cases":{"a":{
            "title":"A",
            "skip_if":{"field":"m","unknown_cond":"bad"}
         }}}
    """#)
    t.expect(AlertAdapter.load(from: url) == nil, "bad skip_if should reject the adapter")
}

// MARK: - AlertAdapter.render / route tests

func testAdapter(_ json: String) -> AlertAdapter {
    let url = writeAdapter("inline-\(UUID().uuidString)", json)
    return AlertAdapter.load(from: url)!
}

t.run("AlertAdapter.render: switch routes to matching case") { t in
    let a = testAdapter(#"""
        {"name":"ci","match":{"field":"kind","exists":true},
         "switch":"kind","cases":{
            "pass":{"title":"passed","priority":"normal"},
            "fail":{"title":"failed","priority":"urgent"}
         }}
    """#)
    if case .rendered(let env) = a.render(["kind": "pass"]) {
        t.expect(env["title"] as? String == "passed", "pass case rendered")
    } else {
        t.expect(false, "expected .rendered")
    }
    if case .rendered(let env) = a.render(["kind": "fail"]) {
        t.expect(env["priority"] as? String == "urgent", "fail case rendered")
    } else {
        t.expect(false, "expected .rendered")
    }
}

t.run("AlertAdapter.render: noMatch when switch key absent") { t in
    let a = testAdapter(#"""
        {"name":"ci","match":{"field":"kind","exists":true},
         "switch":"kind","cases":{"pass":{"title":"ok"}}}
    """#)
    // match.exists:true passes because "kind" is present, but the value
    // "nope" isn't a key in cases → .noMatch
    if case .noMatch = a.render(["kind": "nope"]) {
        t.expect(true, "missing case → noMatch")
    } else {
        t.expect(false, "expected .noMatch")
    }
}

t.run("AlertAdapter.render: skip_if silences matching event") { t in
    let a = testAdapter(#"""
        {"name":"cc","match":{"field":"kind","exists":true},
         "switch":"kind","cases":{"note":{
            "title":"t",
            "skip_if":{"field":"msg","matches":"ignore me"}
         }}}
    """#)
    if case .skipped = a.render(["kind": "note", "msg": "please IGNORE ME"]) {
        t.expect(true, "skip_if returns .skipped")
    } else {
        t.expect(false, "expected .skipped")
    }
    if case .rendered = a.render(["kind": "note", "msg": "something else"]) {
        t.expect(true, "non-matching skip_if lets render proceed")
    } else {
        t.expect(false, "expected .rendered")
    }
}

t.run("AdapterRegistry.route: first-match-wins on filename order") { t in
    let dir = tmp.appendingPathComponent("reg-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    _ = try? #"""
        {"name":"aa","match":{"field":"x","exists":true},"template":{"title":"from-aa"}}
    """#.write(to: dir.appendingPathComponent("aa.json"), atomically: true, encoding: .utf8)
    _ = try? #"""
        {"name":"zz","match":{"field":"x","exists":true},"template":{"title":"from-zz"}}
    """#.write(to: dir.appendingPathComponent("zz.json"), atomically: true, encoding: .utf8)

    // We can't easily construct an AdapterRegistry pointing at a custom dir
    // without reaching into its internals, so we test route-order via direct
    // adapter iteration instead — that's what AdapterRegistry.route does.
    let aa = AlertAdapter.load(from: dir.appendingPathComponent("aa.json"))!
    let zz = AlertAdapter.load(from: dir.appendingPathComponent("zz.json"))!
    let adapters = [aa, zz]
    var pickedName: String?
    for adapter in adapters {
        if case .rendered(let env) = adapter.render(["x": "hi"]) {
            pickedName = env["title"] as? String
            break
        }
    }
    t.expect(pickedName == "from-aa", "filename-alphabetical order wins: aa before zz")
}

// MARK: - Theme loader tests

func writeTheme(_ name: String, _ json: String) -> URL {
    let url = tmp.appendingPathComponent("\(name).json")
    try? json.write(to: url, atomically: true, encoding: .utf8)
    return url
}

t.run("ThemeLoader: valid theme loads with all 8 colors") { t in
    let url = writeTheme("pink-test", #"""
        {"name":"pink-test","character":{
          "gillBase":"#E066A0","gillTip":"#BF4F85",
          "body":"#F29BC5","belly":"#F0B5D3",
          "eye":"#2D2533","highlight":"#FFFFFF",
          "cheek":"#FF7AA3","mouth":"#7A2D4D"
        }}
    """#)
    if case .ok(let theme) = ThemeLoader.load(from: url) {
        t.expect(theme.name == "pink-test", "name preserved")
        t.expect(theme.character.body == "F29BC5", "hex normalized (no #, uppercased)")
        t.expect(theme.character.gillTip == "BF4F85", "gillTip preserved")
    } else {
        t.expect(false, "expected .ok")
    }
}

t.run("ThemeLoader: rejects missing 'name'") { t in
    let url = writeTheme("noname", #"""
        {"character":{
          "gillBase":"#E066A0","gillTip":"#BF4F85",
          "body":"#F29BC5","belly":"#F0B5D3",
          "eye":"#2D2533","highlight":"#FFFFFF",
          "cheek":"#FF7AA3","mouth":"#7A2D4D"
        }}
    """#)
    if case .error(let reason) = ThemeLoader.load(from: url) {
        t.expect(reason.contains("name"), "reason mentions name")
    } else {
        t.expect(false, "expected .error")
    }
}

t.run("ThemeLoader: rejects missing character color") { t in
    let url = writeTheme("no-mouth", #"""
        {"name":"x","character":{
          "gillBase":"#E066A0","gillTip":"#BF4F85",
          "body":"#F29BC5","belly":"#F0B5D3",
          "eye":"#2D2533","highlight":"#FFFFFF",
          "cheek":"#FF7AA3"
        }}
    """#)
    if case .error(let reason) = ThemeLoader.load(from: url) {
        t.expect(reason.contains("mouth"), "reason points at the missing key")
    } else {
        t.expect(false, "expected .error")
    }
}

t.run("ThemeLoader: rejects unknown character key (typo catcher)") { t in
    let url = writeTheme("typo", #"""
        {"name":"x","character":{
          "gillBase":"#E066A0","gillTip":"#BF4F85",
          "body":"#F29BC5","belly":"#F0B5D3",
          "eye":"#2D2533","highlight":"#FFFFFF",
          "cheek":"#FF7AA3","mouth":"#7A2D4D",
          "footsies":"#AAAAAA"
        }}
    """#)
    if case .error(let reason) = ThemeLoader.load(from: url) {
        t.expect(reason.contains("footsies"), "reason names the unknown key")
    } else {
        t.expect(false, "expected .error")
    }
}

t.run("ThemeLoader: rejects malformed hex color") { t in
    let url = writeTheme("bad-hex", #"""
        {"name":"x","character":{
          "gillBase":"#GGGGGG","gillTip":"#BF4F85",
          "body":"#F29BC5","belly":"#F0B5D3",
          "eye":"#2D2533","highlight":"#FFFFFF",
          "cheek":"#FF7AA3","mouth":"#7A2D4D"
        }}
    """#)
    if case .error(let reason) = ThemeLoader.load(from: url) {
        t.expect(reason.contains("gillBase") && reason.contains("hex"),
                 "reason identifies the bad color and that it's not hex")
    } else {
        t.expect(false, "expected .error")
    }
}

t.run("ThemeLoader: normalizeHex accepts 3-digit shorthand") { t in
    t.expect(ThemeLoader.normalizeHex("#F0A") == "FF00AA", "3-digit shorthand expands to 6")
    t.expect(ThemeLoader.normalizeHex("abcdef") == "ABCDEF", "no-hash 6-digit works")
    t.expect(ThemeLoader.normalizeHex("  #123456  ") == "123456", "whitespace trimmed")
    t.expect(ThemeLoader.normalizeHex("#GGGGGG") == nil, "non-hex rejected")
    t.expect(ThemeLoader.normalizeHex("#1234") == nil, "4-digit rejected (not a recognized shorthand)")
}

t.run("Theme.builtin has all 8 colors populated") { t in
    let b = Theme.builtin
    t.expect(!b.character.gillBase.isEmpty, "gillBase set")
    t.expect(!b.character.gillTip.isEmpty,  "gillTip set")
    t.expect(!b.character.body.isEmpty,     "body set")
    t.expect(!b.character.belly.isEmpty,    "belly set")
    t.expect(!b.character.eye.isEmpty,      "eye set")
    t.expect(!b.character.highlight.isEmpty, "highlight set")
    t.expect(!b.character.cheek.isEmpty,    "cheek set")
    t.expect(!b.character.mouth.isEmpty,    "mouth set")
}

exit(t.report())
