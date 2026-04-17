import Cocoa
import Network
import QuartzCore

/// Single-slot main-queue scheduler. Each instance owns at most one pending
/// block; scheduling a new one cancels the previous. Replaces the
/// "var x: DispatchWorkItem?; x?.cancel(); x = DispatchWorkItem {...}; asyncAfter(x)"
/// pattern that was repeated throughout this file.
final class Scheduled {
    private var item: DispatchWorkItem?
    func cancel() { item?.cancel(); item = nil }
    func run(after delay: TimeInterval, _ block: @escaping () -> Void) {
        cancel()
        let w = DispatchWorkItem(block: block)
        item = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

final class AxolServer {
    private var listener: NWListener?
    private let onEvent: ([String: Any]) -> Void
    private let queue = DispatchQueue(label: "axol.server")

    init(onEvent: @escaping ([String: Any]) -> Void) {
        self.onEvent = onEvent
    }

    func start(port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                guard let self = self else { conn.cancel(); return }
                if Self.isLoopback(conn) {
                    self.handle(conn)
                } else {
                    conn.cancel()
                }
            }
            l.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    NSLog("axol: listener failed: \(String(describing: err))")
                }
            }
            l.start(queue: queue)
            listener = l
            NSLog("axol: listening on 127.0.0.1:\(port)")
        } catch {
            NSLog("axol: could not start server on port \(port): \(error)")
        }
    }

    private static func isLoopback(_ conn: NWConnection) -> Bool {
        if case let .hostPort(host: host, port: _) = conn.endpoint {
            switch host {
            case .ipv4(let addr): return addr == .loopback
            case .ipv6(let addr): return addr == .loopback
            default: return false
            }
        }
        return false
    }

    private func handle(_ conn: NWConnection) {
        var buffer = Data()
        conn.start(queue: queue)
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data = data, !data.isEmpty { buffer.append(data) }
                if let parsed = Self.parseHTTP(buffer) {
                    if var json = try? JSONSerialization.jsonObject(with: parsed.body) as? [String: Any] {
                        if let pidStr = parsed.headers["x-claude-pid"], let pid = Int(pidStr) {
                            json["claude_pid"] = pid
                        }
                        DispatchQueue.main.async { self.onEvent(json) }
                    }
                    let resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                } else if isComplete || error != nil {
                    conn.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private static func parseHTTP(_ data: Data) -> (headers: [String: String], body: Data)? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let r = data.range(of: sep) else { return nil }
        let headerData = data.subdata(in: 0..<r.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        var headers: [String: String] = [:]
        var contentLength = 0
        for line in headerStr.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let k = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                headers[k] = v
                if k == "content-length" { contentLength = Int(v) ?? 0 }
            }
        }
        let bodyStart = r.upperBound
        if data.count - bodyStart < contentLength { return nil }
        return (headers, data.subdata(in: bodyStart..<(bodyStart + contentLength)))
    }
}

class AxolWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Adapter plugin framework

struct AdapterMatch {
    let field: String?
    let exists: Bool?
    let equals: String?

    init(json: [String: Any]) {
        self.field = json["field"] as? String
        self.exists = json["exists"] as? Bool
        self.equals = json["equals"] as? String
    }

    func evaluate(_ payload: [String: Any]) -> Bool {
        guard let field = field else { return false }
        let value = payload[field]
        let present = value != nil && !(value is NSNull)
        if let exists = exists {
            if exists != present { return false }
        }
        if let equals = equals {
            guard let str = value as? String, str == equals else { return false }
        }
        return true
    }
}

struct SkipIf {
    let field: String
    let matches: String?
    let equals: String?

    init?(json: [String: Any]?) {
        guard let json = json, let field = json["field"] as? String else { return nil }
        self.field = field
        self.matches = json["matches"] as? String
        self.equals = json["equals"] as? String
    }

    func evaluate(_ payload: [String: Any]) -> Bool {
        let value = (payload[field] as? String) ?? ""
        if let m = matches {
            return value.range(of: m, options: .caseInsensitive) != nil
        }
        if let e = equals {
            return value == e
        }
        return false
    }
}

struct AlertAdapter {
    let name: String
    let match: AdapterMatch
    let switchField: String?
    let cases: [String: [String: Any]]
    let flatTemplate: [String: Any]?

    static func load(from url: URL) -> AlertAdapter? {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = json["name"] as? String,
              let matchJson = json["match"] as? [String: Any] else {
            NSLog("axol: failed to load adapter at \(url.path)")
            return nil
        }
        return AlertAdapter(
            name: name,
            match: AdapterMatch(json: matchJson),
            switchField: json["switch"] as? String,
            cases: (json["cases"] as? [String: [String: Any]]) ?? [:],
            flatTemplate: json["template"] as? [String: Any]
        )
    }

    func render(_ payload: [String: Any]) -> [String: Any]? {
        guard match.evaluate(payload) else { return nil }
        let template: [String: Any]?
        if let switchField = switchField {
            let key = (payload[switchField] as? String) ?? ""
            template = cases[key]
        } else {
            template = flatTemplate
        }
        guard var t = template else { return nil }
        if let skipJson = t["skip_if"] as? [String: Any],
           let skip = SkipIf(json: skipJson),
           skip.evaluate(payload) {
            return nil
        }
        t.removeValue(forKey: "skip_if")
        return AdapterTemplate.render(t, payload: payload) as? [String: Any]
    }
}

enum AdapterTemplate {
    static func render(_ obj: Any, payload: [String: Any]) -> Any? {
        if let s = obj as? String {
            return renderString(s, payload: payload)
        }
        if let d = obj as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d {
                if let rendered = render(v, payload: payload) {
                    out[k] = rendered
                }
            }
            return out
        }
        if let arr = obj as? [Any] {
            return arr.compactMap { render($0, payload: payload) }
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

    private static func evalExpr(_ expr: String, payload: [String: Any]) -> Any? {
        let stages = expr.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !stages.isEmpty else { return nil }
        var current: Any? = evalAtom(stages[0], payload: payload)
        for stage in stages.dropFirst() {
            current = applyFilter(stage, value: current)
        }
        return current
    }

    private static func evalAtom(_ atom: String, payload: [String: Any]) -> Any? {
        let parts = atom.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        if parts.count == 2 {
            let fn = parts[0]
            let arg = parts[1]
            let val = resolvePath(arg, payload: payload)
            switch fn {
            case "basename":
                if let s = val as? String {
                    return s.split(separator: "/").last.map(String.init) ?? s
                }
                return val
            case "trim":
                if let s = val as? String {
                    return s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return val
            default:
                return nil
            }
        }
        return resolvePath(atom, payload: payload)
    }

    private static func resolvePath(_ path: String, payload: [String: Any]) -> Any? {
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
        guard let fn = parts.first else { return value }
        switch fn {
        case "default":
            let arg = parts.count > 1 ? stripQuotes(parts[1]) : ""
            if let s = value as? String, !s.isEmpty { return value }
            if value != nil && !(value is NSNull) { return value }
            return arg
        default:
            return value
        }
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
            }
        }
    }

    func route(_ payload: [String: Any]) -> [String: Any]? {
        for adapter in adapters {
            if let env = adapter.render(payload) {
                return env
            }
        }
        return nil
    }
}

// MARK: - Envelope validator

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

// MARK: - Native character rendering

/// Renders the Axol SVG artwork via CAShapeLayers.
/// Uses an internal 220x200 SVG coordinate space, scaled to fit the view.
final class AxolCharacterView: NSView {
    static let svgWidth: CGFloat = 220
    static let svgHeight: CGFloat = 200
    static let renderWidth: CGFloat = 150

    private let contentLayer = CALayer()
    // Grouped sublayers for later animation targeting.
    private let leftGillsLayer = CALayer()
    private let rightGillsLayer = CALayer()
    private let armLeftLayer = CALayer()
    private let armRightLayer = CALayer()
    private let napTwitchTimer = Scheduled()
    private let eyesLayer = CALayer()
    private let mouthClosedLayer = CAShapeLayer()
    private let mouthOpenLayer = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        layer = root

        // Set up a content sublayer with its own coordinate system matching SVG's
        // 220x200 top-left-origin space, then scale down to the view's size.
        contentLayer.bounds = CGRect(x: 0, y: 0, width: Self.svgWidth, height: Self.svgHeight)
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        contentLayer.isGeometryFlipped = true
        let scale = frame.width / Self.svgWidth
        contentLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        root.addSublayer(contentLayer)

        buildCharacter()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildCharacter() {
        // Group layers use the full SVG coordinate space as their bounds, with
        // their anchor points placed at the logical rotation/scale pivot. This
        // lets ambient animations (sway, blink) rotate/scale around the right
        // place without moving individual sublayers.
        configureGroup(leftGillsLayer,  pivotX: 110, pivotY: 95)
        configureGroup(rightGillsLayer, pivotX: 110, pivotY: 95)
        configureGroup(eyesLayer,       pivotX: 110, pivotY: 105)
        configureGroup(armLeftLayer,    pivotX: 58,  pivotY: 142)
        configureGroup(armRightLayer,   pivotX: 162, pivotY: 142)

        // Left gills (3 ellipses) — darker pink to stand out against the body
        leftGillsLayer.addSublayer(ellipse(cx: 52,  cy: 70,  rx: 16, ry: 9,  hex: "E066A0", rotateDeg: -35))
        leftGillsLayer.addSublayer(ellipse(cx: 42,  cy: 95,  rx: 18, ry: 10, hex: "E066A0", rotateDeg: -8))
        leftGillsLayer.addSublayer(ellipse(cx: 50,  cy: 122, rx: 20, ry: 11, hex: "BF4F85", rotateDeg: 22))
        contentLayer.addSublayer(leftGillsLayer)

        // Right gills (3 ellipses, mirrored)
        rightGillsLayer.addSublayer(ellipse(cx: 168, cy: 70,  rx: 16, ry: 9,  hex: "E066A0", rotateDeg: 35))
        rightGillsLayer.addSublayer(ellipse(cx: 178, cy: 95,  rx: 18, ry: 10, hex: "E066A0", rotateDeg: 8))
        rightGillsLayer.addSublayer(ellipse(cx: 170, cy: 122, rx: 20, ry: 11, hex: "BF4F85", rotateDeg: -22))
        contentLayer.addSublayer(rightGillsLayer)

        // Body — slightly deeper pink so she pops against lighter backgrounds.
        contentLayer.addSublayer(ellipse(cx: 110, cy: 110, rx: 72, ry: 62, hex: "F29BC5"))
        // Belly — corresponding half-shade deeper than the body.
        contentLayer.addSublayer(ellipse(cx: 110, cy: 125, rx: 50, ry: 38, hex: "F0B5D3"))

        // Arms — match the new body tone
        armLeftLayer.addSublayer(ellipse(cx: 58,  cy: 155, rx: 10, ry: 14, hex: "F29BC5", rotateDeg: -20))
        armRightLayer.addSublayer(ellipse(cx: 162, cy: 155, rx: 10, ry: 14, hex: "F29BC5", rotateDeg: 20))
        contentLayer.addSublayer(armLeftLayer)
        contentLayer.addSublayer(armRightLayer)

        // Eyes — pupils + highlights, grouped for blink animation
        eyesLayer.addSublayer(circle(cx: 88,  cy: 105, r: 7,   hex: "2D2533"))
        eyesLayer.addSublayer(circle(cx: 132, cy: 105, r: 7,   hex: "2D2533"))
        eyesLayer.addSublayer(circle(cx: 90,  cy: 102, r: 2.2, hex: "FFFFFF"))
        eyesLayer.addSublayer(circle(cx: 134, cy: 102, r: 2.2, hex: "FFFFFF"))
        contentLayer.addSublayer(eyesLayer)

        // Cheeks (semi-transparent pink)
        contentLayer.addSublayer(circle(cx: 78,  cy: 125, r: 7, hex: "FF7AA3", opacity: 0.45))
        contentLayer.addSublayer(circle(cx: 142, cy: 125, r: 7, hex: "FF7AA3", opacity: 0.45))

        // Mouth — closed arc + hidden open ellipse for talking
        let closedPath = CGMutablePath()
        closedPath.move(to: CGPoint(x: 98, y: 130))
        closedPath.addQuadCurve(to: CGPoint(x: 122, y: 130), control: CGPoint(x: 110, y: 138))
        mouthClosedLayer.path = closedPath
        mouthClosedLayer.strokeColor = Self.hexColor("7A2D4D")
        mouthClosedLayer.fillColor = NSColor.clear.cgColor
        mouthClosedLayer.lineWidth = 2.5
        mouthClosedLayer.lineCap = .round
        contentLayer.addSublayer(mouthClosedLayer)

        let openPath = CGPath(ellipseIn: CGRect(x: -6, y: -4, width: 12, height: 8), transform: nil)
        mouthOpenLayer.path = openPath
        mouthOpenLayer.fillColor = Self.hexColor("7A2D4D")
        mouthOpenLayer.position = CGPoint(x: 110, y: 134)
        mouthOpenLayer.bounds = CGRect(x: -6, y: -4, width: 12, height: 8)
        mouthOpenLayer.isHidden = true
        contentLayer.addSublayer(mouthOpenLayer)
    }

    // MARK: Shape helpers

    private func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, hex: String, rotateDeg: CGFloat = 0) -> CAShapeLayer {
        let layer = CAShapeLayer()
        let rect = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)
        layer.path = CGPath(ellipseIn: rect, transform: nil)
        layer.fillColor = Self.hexColor(hex)
        layer.bounds = rect
        layer.position = CGPoint(x: cx, y: cy)
        if rotateDeg != 0 {
            layer.setAffineTransform(CGAffineTransform(rotationAngle: rotateDeg * .pi / 180))
        }
        return layer
    }

    private func circle(cx: CGFloat, cy: CGFloat, r: CGFloat, hex: String, opacity: CGFloat = 1) -> CAShapeLayer {
        let layer = CAShapeLayer()
        let rect = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        layer.path = CGPath(ellipseIn: rect, transform: nil)
        layer.fillColor = Self.hexColor(hex)
        layer.opacity = Float(opacity)
        layer.bounds = rect
        layer.position = CGPoint(x: cx, y: cy)
        return layer
    }

    static func hexColor(_ hex: String) -> CGColor {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8)  & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    private func configureGroup(_ layer: CALayer, pivotX: CGFloat, pivotY: CGFloat) {
        layer.bounds = CGRect(x: 0, y: 0, width: Self.svgWidth, height: Self.svgHeight)
        layer.anchorPoint = CGPoint(x: pivotX / Self.svgWidth, y: pivotY / Self.svgHeight)
        layer.position = CGPoint(x: pivotX, y: pivotY)
    }

    // MARK: Mouse handling

    var onLeftClick:   (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick:  (() -> Void)?
    var onCmdClick:    (() -> Void)?
    var onDragStart:   (() -> Void)?
    var onDragEnd:     (() -> Void)?
    var onDragDelta:   ((CGFloat, CGFloat) -> Void)?

    private var isDragging = false
    private var moveAccum: CGFloat = 0
    private var lastMouseLocation: CGPoint = .zero
    private let pendingSingleClick = Scheduled()
    private let dragThreshold: CGFloat = 5.0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        moveAccum = 0
        lastMouseLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let dx = current.x - lastMouseLocation.x
        let dy = current.y - lastMouseLocation.y
        lastMouseLocation = current
        moveAccum += abs(dx) + abs(dy)
        if !isDragging && moveAccum > dragThreshold {
            isDragging = true
            onDragStart?()
        }
        if isDragging {
            onDragDelta?(dx, dy)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDragEnd?()
            isDragging = false
            return
        }
        if event.modifierFlags.contains(.command) {
            pendingSingleClick.cancel()
            onCmdClick?()
            return
        }
        if event.clickCount >= 2 {
            pendingSingleClick.cancel()
            onDoubleClick?()
        } else {
            pendingSingleClick.run(after: 0.28) { [weak self] in self?.onLeftClick?() }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    // MARK: Ambient animations (bob, sway, blink — always on)

    func startAmbientAnimations() {
        startBob()
        startSway()
        startBlink()
    }

    func stopAmbientAnimations() {
        layer?.removeAnimation(forKey: "bob")
        leftGillsLayer.removeAnimation(forKey: "sway")
        rightGillsLayer.removeAnimation(forKey: "sway")
        eyesLayer.removeAnimation(forKey: "blink")
    }

    /// Cancels any in-flight idle animation. Called when a bubble or history
    /// appears so the character settles instead of continuing the idle mid-reveal.
    func stopIdles() {
        layer?.removeAnimation(forKey: "hop")
        for key in ["tilt", "tilt-px", "tilt-py", "peek", "peek-px", "peek-py"] {
            layer?.removeAnimation(forKey: key)
        }
        armLeftLayer.removeAnimation(forKey: "stretch")
        armRightLayer.removeAnimation(forKey: "stretch")
        leftGillsLayer.removeAnimation(forKey: "wiggle")
        rightGillsLayer.removeAnimation(forKey: "wiggle")
    }

    private func startBob() {
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        bob.fromValue = 0
        bob.toValue = 6  // NSView coords: +y is up, matches CSS translateY(-6px) visually
        bob.duration = 1.6
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(bob, forKey: "bob")
    }

    private func startSway() {
        func sway(fromDeg: CGFloat, toDeg: CGFloat) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = fromDeg * .pi / 180
            a.toValue   = toDeg   * .pi / 180
            a.duration = 1.9
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return a
        }
        leftGillsLayer.add(sway(fromDeg: -2, toDeg: 3), forKey: "sway")
        rightGillsLayer.add(sway(fromDeg: 3, toDeg: -2), forKey: "sway")
    }

    private func startBlink() {
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values   = [1.0, 1.0, 0.08, 0.08, 1.0]
        blink.keyTimes = [0.0, 0.92, 0.94, 0.98, 1.0]
        blink.duration = 5.5
        blink.repeatCount = .infinity
        eyesLayer.add(blink, forKey: "blink")
    }

    // MARK: One-shot animations (talking, waving)

    private let talkingTimer = Scheduled()

    /// Opens the mouth and starts a repeating scale.y flap for `durationSeconds`
    /// or until `stopTalking()` is called explicitly.
    func startTalking(durationSeconds: TimeInterval = 3.0) {
        mouthClosedLayer.isHidden = true
        mouthOpenLayer.isHidden = false
        let talk = CABasicAnimation(keyPath: "transform.scale.y")
        talk.fromValue = 1.0
        talk.toValue   = 0.45
        talk.duration = 0.16
        talk.autoreverses = true
        talk.repeatCount = .infinity
        talk.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        mouthOpenLayer.add(talk, forKey: "talk")

        talkingTimer.run(after: durationSeconds) { [weak self] in self?.stopTalking() }
    }

    func stopTalking() {
        talkingTimer.cancel()
        mouthOpenLayer.removeAnimation(forKey: "talk")
        mouthOpenLayer.isHidden = true
        mouthClosedLayer.isHidden = false
    }

    // MARK: Idle animations (one-shot, pool-selected)

    enum IdleKind: String, CaseIterable {
        case peek, stretch, hop, tilt, wiggle
    }

    /// Idle animations available to the scheduler. `hop` is intentionally
    /// reserved for urgent-alert attention and not in this pool.
    static let idlePool: [IdleKind] = [.peek, .stretch, .tilt, .wiggle]

    func playIdle(_ kind: IdleKind) {
        switch kind {
        case .peek:    playPeek()
        case .stretch: playStretch()
        case .hop:     playHop()
        case .tilt:    playTilt()
        case .wiggle:  playWiggle()
        }
    }

    private func playPeek() {
        // Quick head-cock + return — reads as a curiosity glance. Rotation
        // on the whole character (additive) with a compensating translation
        // so the effective pivot sits below center (near her body) instead
        // of at the layer's geometric center, which would swing her body
        // out around her face.
        rotateWithGroundedPivot(key: "peek",
                                angleDeg: 4,
                                pivotBelow: 20,
                                keyTimes: [0.0, 0.25, 0.65, 1.0],
                                duration: 1.1)
    }

    private func playStretch() {
        // Brief hold at full extension for a natural stretch feel, then a
        // slightly softer return. Separate timing functions per segment so
        // the outbound feels eager and the hold/return feel relaxed.
        let up: CGFloat = CGFloat.pi * 30 / 180
        let keyTimes: [NSNumber] = [0.0, 0.38, 0.52, 1.0]
        let timingFns = [
            CAMediaTimingFunction(controlPoints: 0.25, 1.0, 0.5, 1.0),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.35, 1.0)
        ]
        let left = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        left.values   = [0.0, Double(up), Double(up), 0.0]
        left.keyTimes = keyTimes
        left.duration = 1.7
        left.timingFunctions = timingFns
        armLeftLayer.add(left, forKey: "stretch")

        let right = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        right.values   = [0.0, Double(-up), Double(-up), 0.0]
        right.keyTimes = keyTimes
        right.duration = 1.7
        right.timingFunctions = timingFns
        armRightLayer.add(right, forKey: "stretch")
    }

    private func playHop() {
        // Anticipation dip → first jump → settle → smaller second hop →
        // rest. Cubic spline between waypoints reads like a spring.
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values   = [0.0, -2.0, 14.0, 0.0, 6.0, 0.0]
        a.keyTimes = [0.0, 0.08, 0.32, 0.55, 0.78, 1.0]
        a.duration = 1.0
        a.calculationMode = .cubic
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.28, 0.84, 0.42, 1)
        a.isAdditive = true
        layer?.add(a, forKey: "hop")
    }

    private func playTilt() {
        // Small anticipation counter-tilt before the main swing, then
        // overshoot back past neutral before settling. Pivots below center
        // so the sway feels planted on her body rather than spinning
        // around her forehead.
        let pivotBelow: CGFloat = 20
        let values: [CGFloat] = [0, 1.5, -6, 5, -1, 0]
        let keyTimes: [NSNumber] = [0.0, 0.08, 0.38, 0.68, 0.88, 1.0]

        let rot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rot.values = values.map { Double(CGFloat.pi * $0 / 180) }
        rot.keyTimes = keyTimes
        rot.duration = 2.4
        rot.calculationMode = .cubic
        rot.isAdditive = true
        layer?.add(rot, forKey: "tilt")

        addPivotCompensation(key: "tilt",
                             anglesRad: values.map { CGFloat.pi * $0 / 180 },
                             pivotBelow: pivotBelow,
                             keyTimes: keyTimes,
                             duration: rot.duration,
                             calculationMode: .cubic,
                             timingFunction: nil)
    }

    /// Simple constant-peak rotation helper shared by peek-style animations
    /// (in/hold/out/rest). For multi-phase rotations, build the keyframes
    /// explicitly and call `addPivotCompensation` directly.
    private func rotateWithGroundedPivot(key: String,
                                         angleDeg: CGFloat,
                                         pivotBelow: CGFloat,
                                         keyTimes: [NSNumber],
                                         duration: CFTimeInterval) {
        let theta = CGFloat.pi * angleDeg / 180
        let vals: [CGFloat] = [0, theta, theta, 0]
        let rot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rot.values   = vals.map { Double($0) }
        rot.keyTimes = keyTimes
        rot.duration = duration
        rot.calculationMode = .cubic
        rot.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rot.isAdditive = true
        layer?.add(rot, forKey: key)

        addPivotCompensation(key: key,
                             anglesRad: vals,
                             pivotBelow: pivotBelow,
                             keyTimes: keyTimes,
                             duration: duration,
                             calculationMode: .cubic,
                             timingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    /// Additive translation keyframes that keep a point `pivotBelow` pixels
    /// below the layer anchor stationary under a rotation keyframe. For a
    /// rotation θ around the anchor, the point drifts by (h·sin θ, h·(1−cos θ))
    /// relative to its θ=0 position; we apply the opposite.
    private func addPivotCompensation(key: String,
                                      anglesRad: [CGFloat],
                                      pivotBelow h: CGFloat,
                                      keyTimes: [NSNumber],
                                      duration: CFTimeInterval,
                                      calculationMode: CAAnimationCalculationMode,
                                      timingFunction: CAMediaTimingFunction?) {
        let txValues = anglesRad.map { Double(-h * sin($0)) }
        let tyValues = anglesRad.map { Double(-h * (1 - cos($0))) }

        let tx = CAKeyframeAnimation(keyPath: "transform.translation.x")
        tx.values = txValues
        tx.keyTimes = keyTimes
        tx.duration = duration
        tx.calculationMode = calculationMode
        if let t = timingFunction { tx.timingFunction = t }
        tx.isAdditive = true
        layer?.add(tx, forKey: "\(key)-px")

        let ty = CAKeyframeAnimation(keyPath: "transform.translation.y")
        ty.values = tyValues
        ty.keyTimes = keyTimes
        ty.duration = duration
        ty.calculationMode = calculationMode
        if let t = timingFunction { ty.timingFunction = t }
        ty.isAdditive = true
        layer?.add(ty, forKey: "\(key)-py")
    }

    private func playWiggle() {
        // Additive layered on top of the ambient sway.
        let leftValues:  [Double] = [0,
                                     Double(CGFloat.pi * -8 / 180),
                                     Double(CGFloat.pi *  6 / 180),
                                     Double(CGFloat.pi * -2 / 180),
                                     0]
        let rightValues: [Double] = [0,
                                     Double(CGFloat.pi *  8 / 180),
                                     Double(CGFloat.pi * -6 / 180),
                                     Double(CGFloat.pi *  2 / 180),
                                     0]
        let keyTimes: [NSNumber] = [0.0, 0.28, 0.58, 0.82, 1.0]
        let left = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        left.values = leftValues
        left.keyTimes = keyTimes
        left.duration = 1.3
        left.calculationMode = .cubic
        left.isAdditive = true
        leftGillsLayer.add(left, forKey: "wiggle")
        let right = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        right.values = rightValues
        right.keyTimes = keyTimes
        right.duration = 1.3
        right.calculationMode = .cubic
        right.isAdditive = true
        rightGillsLayer.add(right, forKey: "wiggle")
    }

    // MARK: Nap state

    /// Replaces bob/blink/sway with slow/closed-eye versions and dims the
    /// mouth. Opposite of leaveNap().
    private let napFadeDuration: CFTimeInterval = 0.65

    func enterNap() {
        // Replace bob + sway with slow versions (snap is subtle, motion small).
        layer?.removeAnimation(forKey: "bob")
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = 0.0
        drift.toValue   = 2.0
        drift.duration = 3
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(drift, forKey: "bob")

        leftGillsLayer.removeAnimation(forKey: "sway")
        rightGillsLayer.removeAnimation(forKey: "sway")
        func slowSway(fromDeg: CGFloat, toDeg: CGFloat) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = Double(fromDeg * CGFloat.pi / 180)
            a.toValue   = Double(toDeg   * CGFloat.pi / 180)
            a.duration = 4
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            return a
        }
        leftGillsLayer.add(slowSway(fromDeg: -2, toDeg: 3), forKey: "sway")
        rightGillsLayer.add(slowSway(fromDeg: 3, toDeg: -2), forKey: "sway")

        // Cancel blink AND any in-flight idle before fading the eye scale.
        eyesLayer.removeAnimation(forKey: "blink")
        layer?.removeAnimation(forKey: "peek")

        // NSView-backed CALayers suppress implicit animations; use explicit
        // CABasicAnimations with fillMode=.forwards so the closed-eye and
        // dimmed-mouth poses are actually rendered.
        let closeEyes = CABasicAnimation(keyPath: "transform.scale.y")
        closeEyes.fromValue = 1.0
        closeEyes.toValue   = 0.08
        closeEyes.duration  = napFadeDuration
        closeEyes.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        closeEyes.fillMode  = .forwards
        closeEyes.isRemovedOnCompletion = false
        eyesLayer.add(closeEyes, forKey: "nap-eyes")

        func dimMouth(_ target: CALayer) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue   = 0.5
            fade.duration  = napFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.fillMode  = .forwards
            fade.isRemovedOnCompletion = false
            target.add(fade, forKey: "nap-mouth")
        }
        dimMouth(mouthClosedLayer)
        dimMouth(mouthOpenLayer)

        scheduleNapTwitch()
    }

    /// Occasional small foot twitch while napping — a tiny rotation on one
    /// arm layer that reads as a dream-state micromovement. Alternates sides,
    /// fires on a randomized 4–9s cadence, and stops when the nap ends.
    private func scheduleNapTwitch() {
        let delay = 4.0 + Double.random(in: 0...5.0)
        napTwitchTimer.run(after: delay) { [weak self] in
            guard let self = self else { return }
            self.playFootTwitch(leftSide: Bool.random())
            self.scheduleNapTwitch()
        }
    }

    private func playFootTwitch(leftSide: Bool) {
        let target = leftSide ? armLeftLayer : armRightLayer
        let peak: CGFloat = leftSide ? -6 : 6     // small outward kick
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values   = [0.0, Double(peak) * .pi / 180, 0.0, Double(peak * 0.4) * .pi / 180, 0.0]
        a.keyTimes = [0.0, 0.25, 0.55, 0.78, 1.0]
        a.duration = 0.7
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.isAdditive = true
        target.add(a, forKey: "nap-twitch")
    }

    func leaveNap() {
        napTwitchTimer.cancel()
        armLeftLayer.removeAnimation(forKey: "nap-twitch")
        armRightLayer.removeAnimation(forKey: "nap-twitch")

        // Reverse fades via explicit animations (see enterNap note on why).
        let openEyes = CABasicAnimation(keyPath: "transform.scale.y")
        openEyes.fromValue = 0.08
        openEyes.toValue   = 1.0
        openEyes.duration  = napFadeDuration
        openEyes.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        openEyes.fillMode  = .forwards
        openEyes.isRemovedOnCompletion = false
        eyesLayer.removeAnimation(forKey: "nap-eyes")
        eyesLayer.add(openEyes, forKey: "wake-eyes")

        func brightenMouth(_ target: CALayer) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.5
            fade.toValue   = 1.0
            fade.duration  = napFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.fillMode  = .forwards
            fade.isRemovedOnCompletion = false
            target.removeAnimation(forKey: "nap-mouth")
            target.add(fade, forKey: "wake-mouth")
        }
        brightenMouth(mouthClosedLayer)
        brightenMouth(mouthOpenLayer)

        // Restore normal bob + sway
        layer?.removeAnimation(forKey: "bob")
        leftGillsLayer.removeAnimation(forKey: "sway")
        rightGillsLayer.removeAnimation(forKey: "sway")
        startBob()
        startSway()

        // After the wake fade completes, drop the hold-forward animations
        // and restart the ambient blink.
        DispatchQueue.main.asyncAfter(deadline: .now() + napFadeDuration) { [weak self] in
            guard let self = self else { return }
            self.eyesLayer.removeAnimation(forKey: "wake-eyes")
            self.mouthClosedLayer.removeAnimation(forKey: "wake-mouth")
            self.mouthOpenLayer.removeAnimation(forKey: "wake-mouth")
            self.startBlink()
        }
    }

    /// 3-cycle arm wave via rotation.z on the right arm group.
    func wave() {
        let wave = CABasicAnimation(keyPath: "transform.rotation.z")
        wave.fromValue = 0.0
        wave.toValue   = CGFloat(-30) * CGFloat.pi / 180
        wave.duration = 0.2
        wave.autoreverses = true
        wave.repeatCount = 3
        wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        armRightLayer.add(wave, forKey: "wave")
    }
}

/// Native speech bubble. Presents a title (single line, ellipsized) plus an
/// optional body (up to 4 lines, ellipsized) in a rounded rect with a
/// downward tail. Priority drives fill, border, and auto-dismiss behavior.
final class BubbleView: NSView {
    private let backgroundLayer = CAShapeLayer()
    private let titleField = NSTextField(labelWithString: "")
    private let bodyField  = NSTextField(wrappingLabelWithString: "")

    /// Default icon names an adapter can pass via the envelope `icon` field.
    /// Each name resolves to an SF Symbol + tint color. Unknown strings fall
    /// through as a literal title prefix (emoji or short text).
    static let iconDefaults: [(name: String, symbol: String, color: String)] = [
        ("success",  "checkmark.circle.fill",         "2E8B57"),
        ("error",    "xmark.circle.fill",             "C0392B"),
        ("warn",     "exclamationmark.triangle.fill", "B8860B"),
        ("info",     "info.circle.fill",              "3A6EA5"),
        ("ship",     "paperplane.fill",               "D6457A"),
        ("review",   "eye.fill",                      "7A5A9F"),
        ("sparkle",  "sparkles",                      "D4A017"),
        ("bell",     "bell.fill",                     "D6457A"),
        ("bug",      "ant.fill",                      "C0392B"),
        ("metric",   "chart.line.uptrend.xyaxis",     "3A6EA5"),
        ("pending",  "clock.fill",                    "6E5F6B"),
        ("security", "checkmark.shield.fill",         "2E8B57"),
        ("message",  "bubble.left.fill",              "3A6EA5"),
        ("approved", "hand.thumbsup.fill",            "2E8B57"),
        ("git",      "arrow.triangle.branch",         "2D2533"),
    ]

    static func iconImage(for name: String, pointSize: CGFloat = 12) -> NSImage? {
        if let def = iconDefaults.first(where: { $0.name == name }),
           let base = NSImage(systemSymbolName: def.symbol, accessibilityDescription: nil) {
            var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            if #available(macOS 12.0, *) {
                config = config.applying(.init(paletteColors: [NSColor.fromHex(def.color)]))
            }
            return base.withSymbolConfiguration(config) ?? base
        }
        // Brand glyphs (no SF Symbol equivalent) — embedded SVG rendered via
        // NSImage's SVG loader (macOS 13+). On older systems this returns nil
        // and the caller falls back to showing the name as a literal prefix.
        if let svg = brandIcons[name], let img = brandImage(named: name, svg: svg) {
            let px = pointSize * 1.3
            img.size = NSSize(width: px, height: px)
            return img
        }
        return nil
    }

    /// Embedded Bootstrap Icons (MIT) — https://icons.getbootstrap.com
    /// Used for brands that don't have an SF Symbol equivalent. The `fill`
    /// attribute bakes the brand color into the SVG so no additional tinting
    /// is needed.
    private static let brandIcons: [String: String] = [
        "claude": ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="#D97757"><path d="m3.127 10.604 3.135-1.76.053-.153-.053-.085H6.11l-.525-.032-1.791-.048-1.554-.065-1.505-.08-.38-.081L0 7.832l.036-.234.32-.214.455.04 1.009.069 1.513.105 1.097.064 1.626.17h.259l.036-.105-.089-.065-.068-.064-1.566-1.062-1.695-1.121-.887-.646-.48-.327-.243-.306-.104-.67.435-.48.585.04.15.04.593.456 1.267.981 1.654 1.218.242.202.097-.068.012-.049-.109-.181-.9-1.626-.96-1.655-.428-.686-.113-.411a2 2 0 0 1-.068-.484l.496-.674L4.446 0l.662.089.279.242.411.94.666 1.48 1.033 2.014.302.597.162.553.06.17h.105v-.097l.085-1.134.157-1.392.154-1.792.052-.504.25-.605.497-.327.387.186.319.456-.045.294-.19 1.23-.37 1.93-.243 1.29h.142l.161-.16.654-.868 1.097-1.372.484-.545.565-.601.363-.287h.686l.505.751-.226.775-.707.895-.585.759-.839 1.13-.524.904.048.072.125-.012 1.897-.403 1.024-.186 1.223-.21.553.258.06.263-.218.536-1.307.323-1.533.307-2.284.54-.028.02.032.04 1.029.098.44.024h1.077l2.005.15.525.346.315.424-.053.323-.807.411-3.631-.863-.872-.218h-.12v.073l.726.71 1.331 1.202 1.667 1.55.084.383-.214.302-.226-.032-1.464-1.101-.565-.497-1.28-1.077h-.084v.113l.295.432 1.557 2.34.08.718-.112.234-.404.141-.444-.08-.911-1.28-.94-1.44-.759-1.291-.093.053-.448 4.821-.21.246-.484.186-.403-.307-.214-.496.214-.98.258-1.28.21-1.016.19-1.263.112-.42-.008-.028-.092.012-.953 1.307-1.448 1.957-1.146 1.227-.274.109-.477-.247.045-.44.266-.39 1.586-2.018.956-1.25.617-.723-.004-.105h-.036l-4.212 2.736-.75.096-.324-.302.04-.496.154-.162 1.267-.871z"/></svg>"##,
        "github": ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="#2D2533"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8"/></svg>"##,
    ]

    private static var brandImageCache: [String: NSImage] = [:]

    private static func brandImage(named name: String, svg: String) -> NSImage? {
        if let cached = brandImageCache[name] { return cached.copy() as? NSImage }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("axol-icon-\(name).svg")
        guard let data = svg.data(using: .utf8),
              (try? data.write(to: url)) != nil,
              let img = NSImage(contentsOf: url) else { return nil }
        brandImageCache[name] = img
        return img.copy() as? NSImage
    }

    // Layout constants — mirrored from styles.css
    private let horizPadding: CGFloat = 14
    private let vertPadding:  CGFloat = 10
    private let tailHeight:   CGFloat = 6
    private let cornerRadius: CGFloat = 14
    private let tailWidth:    CGFloat = 12
    private let maxBubbleWidth: CGFloat = 280
    private let minBubbleWidth: CGFloat = 130

    private var action: [String: Any]?
    private var isUrgent: Bool = false
    private let autoDismissTimer = Scheduled()

    var onAction: (([String: Any]) -> Void)?
    var onShow:   ((_ talkDuration: TimeInterval) -> Void)?
    var onHide:   (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        layer = root
        root.masksToBounds = false

        backgroundLayer.fillColor   = NSColor.white.cgColor
        backgroundLayer.strokeColor = nil
        backgroundLayer.lineWidth   = 0
        backgroundLayer.shadowColor = NSColor.black.cgColor
        backgroundLayer.shadowOpacity = 0.18
        backgroundLayer.shadowOffset  = CGSize(width: 0, height: -6)
        backgroundLayer.shadowRadius  = 10
        root.addSublayer(backgroundLayer)

        for f in [titleField, bodyField] {
            f.isEditable = false
            f.isSelectable = false
            f.isBezeled = false
            f.drawsBackground = false
            f.alignment = .center
            addSubview(f)
        }

        // Title: single line, ellipsis on overflow.
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.maximumNumberOfLines = 1
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true

        // Body: wraps to 4 lines, ellipsis on the last line.
        bodyField.font = NSFont.systemFont(ofSize: 12)
        bodyField.maximumNumberOfLines = 4
        bodyField.lineBreakMode = .byWordWrapping
        bodyField.usesSingleLineMode = false
        bodyField.cell?.wraps = true
        bodyField.cell?.isScrollable = false
        bodyField.cell?.truncatesLastVisibleLine = true

        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Show the bubble with the given content + styling.
    func present(title: String, body: String?, priority: String, icon: String? = nil, action: [String: Any]?) {
        self.action = action
        self.isUrgent = (priority == "urgent")
        let clickable = action != nil

        // Set a plain title first so applyStyle can set color via .textColor;
        // we upgrade to an attributed title below if an icon resolves.
        let prefix = clickable ? "↗ " : ""
        titleField.stringValue = prefix + title
        let bodyText = body?.trimmingCharacters(in: .whitespaces) ?? ""
        bodyField.stringValue = bodyText
        bodyField.isHidden = bodyText.isEmpty

        applyStyle(priority: priority, clickable: clickable)

        // Named icon → SF Symbol attachment in place of the ↗ prefix.
        // Unknown strings fall through as a literal prefix (emoji, short text).
        if let iconName = icon?.trimmingCharacters(in: .whitespaces), !iconName.isEmpty {
            if let image = Self.iconImage(for: iconName) {
                let attachment = NSTextAttachment()
                attachment.image = image
                let attachString = NSMutableAttributedString(attachment: attachment)
                attachString.addAttribute(.baselineOffset, value: -1,
                                          range: NSRange(location: 0, length: attachString.length))
                // Bake center alignment into the paragraph style — NSTextField's
                // .alignment property is ignored once attributedStringValue is set.
                let para = NSMutableParagraphStyle()
                para.alignment = .center
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: titleField.font!,
                    .foregroundColor: titleField.textColor ?? NSColor.labelColor,
                    .paragraphStyle: para
                ]
                let full = NSMutableAttributedString()
                full.append(attachString)
                full.append(NSAttributedString(string: "  " + title, attributes: titleAttrs))
                full.addAttribute(.paragraphStyle, value: para,
                                  range: NSRange(location: 0, length: full.length))
                titleField.attributedStringValue = full
            } else {
                titleField.stringValue = "\(iconName) \(title)"
            }
        }

        layoutContent()

        // Position centered in superview. Tail tip drops 13px into the top of
        // the character's head so the bubble reads as coming from her rather
        // than floating above. Edge-aware shift when near a screen edge.
        if let parent = superview {
            let idealX = (parent.frame.width - frame.width) / 2
            let adjustedX = Self.edgeAdjustedX(idealX: idealX, panelWidth: frame.width, in: parent)
            frame.origin = CGPoint(x: adjustedX, y: 128)
        }

        autoDismissTimer.cancel()

        // Fade in
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            animator().alphaValue = 1.0
        }

        let fullText = title + " " + bodyText
        let isAlert = priority == "high" || priority == "urgent"
        let fullDuration = Self.durationFor(text: fullText, isAlert: isAlert)
        let talkDuration = min(fullDuration, 3.5)
        onShow?(talkDuration)

        if !isUrgent {
            autoDismissTimer.run(after: fullDuration) { [weak self] in self?.hide() }
        }
    }

    func hide() {
        autoDismissTimer.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isHidden = true
            self.action = nil
            self.onHide?()
        })
    }

    var isVisible: Bool { !isHidden && alphaValue > 0 }
    var isUrgentlyPinned: Bool { isVisible && isUrgent }

    // MARK: - Click to run action

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only accept clicks when visible and clickable (has an action)
        guard !isHidden, action != nil else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if let a = action, let cb = onAction {
            cb(a)
            hide()
        }
    }

    override func resetCursorRects() {
        if action != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    // MARK: - Layout / styling

    private func applyStyle(priority: String, clickable: Bool) {
        var bgHex = "FFFFFF"
        var titleColor = "2D2533"
        var bodyColor = "6E5F6B"
        var borderHex: String? = nil
        var borderWidth: CGFloat = 0

        switch priority {
        case "low":
            bgHex = "FAF7F9"
            titleColor = "6E5F6B"
            bodyColor  = "9A8E95"
        case "urgent":
            bgHex = "FFEEF5"
            borderHex = "D6457A"
            borderWidth = 1.5
        default:
            if clickable {
                bgHex = "FFF4FA"
                borderHex = "FFC0DB"
                borderWidth = 1.0
            }
        }

        backgroundLayer.fillColor   = AxolCharacterView.hexColor(bgHex)
        backgroundLayer.strokeColor = borderHex.map { AxolCharacterView.hexColor($0) }
        backgroundLayer.lineWidth   = borderWidth

        titleField.textColor = NSColor.fromHex(titleColor)
        bodyField.textColor  = NSColor.fromHex(bodyColor)
        window?.invalidateCursorRects(for: self)
    }

    private func layoutContent() {
        let maxContentWidth = maxBubbleWidth - 2 * horizPadding

        // Measure the raw text width directly — more reliable than
        // NSTextField.sizeThatFits/intrinsicContentSize, which can under-report
        // and cause truncation when the frame matches their returned width.
        // Pad generously to cover NSTextField cell insets + ellipsis trigger
        // subpixel rounding.
        // Use sizeToFit for an authoritative "no truncation" width.
        titleField.sizeToFit()
        let titleNaturalWidth  = titleField.frame.width
        let titleNaturalHeight = titleField.frame.height
        let titleWidth  = ceil(min(titleNaturalWidth + 8, maxContentWidth))
        let titleHeight = ceil(titleNaturalHeight)

        var bodyWidth: CGFloat = 0
        var bodyHeight: CGFloat = 0
        if !bodyField.isHidden {
            // Use NSString bounding-rect calculation to get an accurate
            // wrapped height for up to 4 lines.
            let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyField.font!]
            let bodyText = bodyField.stringValue as NSString
            let oneLineHeight = ceil(bodyText.size(withAttributes: bodyAttrs).height)
            let maxBodyLines = oneLineHeight * 4
            let boundingRect = bodyText.boundingRect(
                with: CGSize(width: maxContentWidth, height: maxBodyLines),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: bodyAttrs
            )
            bodyWidth  = ceil(min(boundingRect.width, maxContentWidth))
            bodyHeight = ceil(min(boundingRect.height, maxBodyLines))
        }

        let rawWidth = max(titleWidth, bodyWidth)
        let contentWidth = max(min(rawWidth, maxContentWidth), minBubbleWidth - 2 * horizPadding)
        let bubbleWidth = contentWidth + 2 * horizPadding
        let gap: CGFloat = bodyField.isHidden ? 0 : 3
        let bodyAreaHeight = titleHeight + gap + bodyHeight + 2 * vertPadding
        let totalHeight = bodyAreaHeight + tailHeight

        let origin = frame.origin
        frame = CGRect(x: origin.x, y: origin.y, width: bubbleWidth, height: totalHeight)

        // Labels — view origin is bottom-left, so measure Y from bottom
        let titleY = tailHeight + bodyAreaHeight - vertPadding - titleHeight
        // Allow the title field to extend slightly into the horizontal padding
        // on each side — gives NSTextField extra rendering slack so the cell's
        // internal insets don't trigger truncation.
        let titleInset: CGFloat = 4
        titleField.frame = CGRect(
            x: horizPadding - titleInset,
            y: titleY,
            width: contentWidth + 2 * titleInset,
            height: titleHeight
        )
        if bodyField.isHidden {
            bodyField.frame = .zero
        } else {
            let bodyY = tailHeight + vertPadding
            bodyField.frame = CGRect(x: horizPadding, y: bodyY, width: contentWidth, height: bodyHeight)
        }

        backgroundLayer.frame = bounds
        backgroundLayer.path = BubbleShape.path(
            bubbleRect: bounds,
            tailHeight: tailHeight,
            cornerRadius: cornerRadius,
            tailWidth: tailWidth
        )
    }

    static func durationFor(text: String, isAlert: Bool) -> TimeInterval {
        return isAlert ? 6.0 : 3.5
    }

    /// Returns an x-origin for the panel that shifts toward the open side of
    /// the screen when the window is near a horizontal edge. Shift is clamped
    /// to the available slack inside the stage — small nudge only.
    static func edgeAdjustedX(idealX: CGFloat, panelWidth: CGFloat, in stage: NSView) -> CGFloat {
        let maxX = max(0, stage.frame.width - panelWidth)
        guard let window = stage.window,
              let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return min(max(0, idealX), maxX)
        }
        // Where the panel would land in screen coords at its ideal x.
        let idealScreenMinX = window.frame.minX + idealX
        let idealScreenMaxX = idealScreenMinX + panelWidth
        let margin: CGFloat = 8
        var shift: CGFloat = 0
        if idealScreenMaxX > screen.maxX - margin {
            shift = (screen.maxX - margin) - idealScreenMaxX
        } else if idealScreenMinX < screen.minX + margin {
            shift = (screen.minX + margin) - idealScreenMinX
        }
        let target = idealX + shift
        return min(max(0, target), maxX)
    }
}

extension NSColor {
    static func fromHex(_ hex: String, alpha: CGFloat = 1) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8)  & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

// MARK: - Alert history storage

struct AlertEntry {
    let id: Int
    let envelope: [String: Any]
    let time: Date
    var seenAt: Date?

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

    /// Most-recent archived entry that the user can still act on.
    var lastActionableAlert: AlertEntry? {
        entries.first { $0.action != nil }
    }

    /// Count of entries the user hasn't seen yet.
    var unseenCount: Int {
        entries.filter { $0.seenAt == nil }.count
    }

    @discardableResult
    func push(envelope: [String: Any]) -> AlertEntry {
        nextId += 1
        let entry = AlertEntry(id: nextId, envelope: envelope, time: Date(), seenAt: nil)
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

// MARK: - History panel UI

/// Small pink-accent pill showing the alert's source field.
final class SourcePillView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        let bg = CALayer()
        layer = bg
        bg.cornerRadius = 8
        bg.backgroundColor = AxolCharacterView.hexColor("FFE8F2")

        label.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        label.textColor = NSColor.fromHex("D6457A")
        label.stringValue = text
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.isSelectable = false
        label.sizeToFit()
        addSubview(label)

        let w = label.frame.width + 12
        let h: CGFloat = 16
        frame.size = CGSize(width: w, height: h)
        label.frame.origin = CGPoint(x: 6, y: (h - label.frame.height) / 2)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A single row inside the history panel.
final class HistoryRowView: NSView {
    let entry: AlertEntry
    var onClick: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel  = NSTextField(labelWithString: "")
    private let sourcePill: SourcePillView
    private let bodyLabel: NSTextField?
    private let hoverLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    init(entry: AlertEntry, width: CGFloat) {
        self.entry = entry
        self.sourcePill = SourcePillView(text: entry.source)
        let body = (entry.body ?? "").trimmingCharacters(in: .whitespaces)
        self.bodyLabel = body.isEmpty ? nil : NSTextField(labelWithString: body)
        super.init(frame: .zero)

        wantsLayer = true
        layer = CALayer()
        hoverLayer.backgroundColor = AxolCharacterView.hexColor("FFF4FA")
        hoverLayer.cornerRadius = 6
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)

        // Title (left, flex, single-line, ellipsized)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.fromHex("2D2533")
        titleLabel.isEditable = false; titleLabel.isBezeled = false
        titleLabel.drawsBackground = false; titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        if let iconName = entry.icon?.trimmingCharacters(in: .whitespaces), !iconName.isEmpty,
           let image = BubbleView.iconImage(for: iconName, pointSize: 11) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let attach = NSMutableAttributedString(attachment: attachment)
            attach.addAttribute(.baselineOffset, value: -1,
                                range: NSRange(location: 0, length: attach.length))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: titleLabel.font!,
                .foregroundColor: titleLabel.textColor ?? NSColor.labelColor
            ]
            let full = NSMutableAttributedString()
            full.append(attach)
            full.append(NSAttributedString(string: "  " + entry.title, attributes: attrs))
            titleLabel.attributedStringValue = full
        } else if let rawIcon = entry.icon?.trimmingCharacters(in: .whitespaces), !rawIcon.isEmpty {
            titleLabel.stringValue = "\(rawIcon) \(entry.title)"
        } else {
            titleLabel.stringValue = entry.title
        }
        addSubview(titleLabel)

        // Time (right)
        timeLabel.stringValue = Self.relativeTime(from: entry.time)
        timeLabel.font = NSFont.systemFont(ofSize: 10)
        timeLabel.textColor = NSColor.fromHex("A89CA3")
        timeLabel.isEditable = false; timeLabel.isBezeled = false
        timeLabel.drawsBackground = false; timeLabel.isSelectable = false
        timeLabel.alignment = .right
        addSubview(timeLabel)

        addSubview(sourcePill)

        // Optional body line below
        if let bodyLabel = bodyLabel {
            bodyLabel.font = NSFont.systemFont(ofSize: 11)
            bodyLabel.textColor = NSColor.fromHex("998F96")
            bodyLabel.isEditable = false; bodyLabel.isBezeled = false
            bodyLabel.drawsBackground = false; bodyLabel.isSelectable = false
            bodyLabel.lineBreakMode = .byTruncatingTail
            bodyLabel.maximumNumberOfLines = 1
            bodyLabel.usesSingleLineMode = true
            addSubview(bodyLabel)
        }

        layoutRow(width: width)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func layoutRow(width: CGFloat) {
        let padX: CGFloat = 4
        let rowTopPadding: CGFloat = 6
        let rowBottomPadding: CGFloat = 6
        let gap: CGFloat = 8

        let timeSize = timeLabel.intrinsicContentSize
        let timeWidth = ceil(timeSize.width) + 4
        let pillWidth = sourcePill.frame.width
        let headHeight: CGFloat = 16
        let titleWidth = max(0, width - 2 * padX - pillWidth - timeWidth - 2 * gap)

        // Row body vertical layout (Cocoa y = bottom-up)
        var totalHeight = rowTopPadding + headHeight + rowBottomPadding
        if bodyLabel != nil { totalHeight += 3 + 14 }

        frame.size = CGSize(width: width, height: totalHeight)
        hoverLayer.frame = CGRect(x: 2, y: 2, width: width - 4, height: totalHeight - 4)

        // Header line: title on the left (flex), pill in the middle, time on the right
        let headY = totalHeight - rowTopPadding - headHeight
        titleLabel.frame = CGRect(x: padX, y: headY, width: titleWidth, height: headHeight)
        let pillX = padX + titleWidth + gap
        sourcePill.frame.origin = CGPoint(x: pillX, y: headY + (headHeight - sourcePill.frame.height) / 2)
        timeLabel.frame = CGRect(x: pillX + pillWidth + gap, y: headY + 1, width: timeWidth, height: headHeight - 2)

        // Body line below
        if let bodyLabel = bodyLabel {
            bodyLabel.frame = CGRect(x: padX + 2, y: rowBottomPadding - 1, width: width - 2 * padX - 4, height: 14)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) { hoverLayer.opacity = 1 }
    override func mouseExited(with event: NSEvent)  { hoverLayer.opacity = 0 }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        if entry.action != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private static func relativeTime(from date: Date) -> String {
        let s = max(0, Int(-date.timeIntervalSinceNow))
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h"
    }
}

/// The "Recent alerts" popup shown on double-click. Rounded rect with a
/// sticky header, divider, and a stack of HistoryRowViews with a
/// downward-pointing tail that aligns with the character's head.
/// Flipped NSView used as the history rows document — so top rows render
/// at the top of the scrollable area by default.
private final class FlippedHistoryBody: NSView {
    override var isFlipped: Bool { true }
}

final class HistoryView: NSView {
    private let backgroundLayer = CAShapeLayer()
    private let headerLabel = NSTextField(labelWithString: "RECENT ALERTS")
    private let dividerLayer = CALayer()
    private let scrollView = NSScrollView()
    private let rowsContainer = FlippedHistoryBody()

    private let headerHeight:   CGFloat = 30
    private let horizPadding:   CGFloat = 10
    private let tailHeight:     CGFloat = 6
    private let cornerRadius:   CGFloat = 14
    private let tailWidth:      CGFloat = 12
    private let panelWidth:     CGFloat = 276
    private let maxBodyHeight:  CGFloat = 180

    var onRowClick: ((AlertEntry) -> Void)?
    private let autoHideTimer = Scheduled()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        layer = root
        root.masksToBounds = false

        backgroundLayer.fillColor   = NSColor.white.cgColor
        backgroundLayer.shadowColor = NSColor.black.cgColor
        backgroundLayer.shadowOpacity = 0.18
        backgroundLayer.shadowOffset  = CGSize(width: 0, height: -6)
        backgroundLayer.shadowRadius  = 10
        root.addSublayer(backgroundLayer)

        headerLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = NSColor.fromHex("999999")
        headerLabel.isEditable = false; headerLabel.isBezeled = false
        headerLabel.drawsBackground = false; headerLabel.isSelectable = false
        headerLabel.alignment = .left
        if let attr = NSMutableAttributedString(string: "RECENT ALERTS") as NSMutableAttributedString? {
            attr.addAttribute(.kern, value: 0.6, range: NSRange(location: 0, length: attr.length))
            headerLabel.attributedStringValue = attr
        }
        addSubview(headerLabel)

        dividerLayer.backgroundColor = NSColor.fromHex("F3E7EE").cgColor
        root.addSublayer(dividerLayer)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = rowsContainer
        addSubview(scrollView)

        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(in stage: NSView, entries: [AlertEntry]) {
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }

        let rowWidth = panelWidth - 2 * horizPadding
        var rows: [HistoryRowView] = []
        for entry in entries {
            let row = HistoryRowView(entry: entry, width: rowWidth)
            row.onClick = { [weak self] in
                self?.onRowClick?(entry)
                self?.hide()
            }
            rows.append(row)
        }
        let rowsTotalHeight = rows.reduce(0) { $0 + $1.frame.height }
        let scrollHeight = min(rowsTotalHeight, maxBodyHeight)
        let panelHeight = headerHeight + scrollHeight + tailHeight

        let idealX = (stage.frame.width - panelWidth) / 2
        let adjustedX = BubbleView.edgeAdjustedX(idealX: idealX, panelWidth: panelWidth, in: stage)
        frame = CGRect(x: adjustedX,
                       y: 128,
                       width: panelWidth, height: panelHeight)
        backgroundLayer.frame = bounds
        backgroundLayer.path = BubbleShape.path(
            bubbleRect: bounds, tailHeight: tailHeight,
            cornerRadius: cornerRadius, tailWidth: tailWidth)

        // Header label sized to its text height (~14 for 10pt) and centered
        // vertically in the 30px header band.
        let labelH: CGFloat = 14
        let labelY = panelHeight - headerHeight + (headerHeight - labelH) / 2
        headerLabel.frame = CGRect(x: horizPadding + 2,
                                   y: labelY,
                                   width: panelWidth - 2 * horizPadding,
                                   height: labelH)
        dividerLayer.frame = CGRect(x: 0, y: panelHeight - headerHeight,
                                    width: panelWidth, height: 1)

        // Scrollable rows area sits entirely below the header band.
        scrollView.frame = CGRect(x: horizPadding, y: tailHeight,
                                  width: rowWidth, height: scrollHeight)
        rowsContainer.setFrameSize(NSSize(width: rowWidth, height: rowsTotalHeight))

        // Stack rows top → bottom inside the flipped document view.
        var y: CGFloat = 0
        for (i, row) in rows.enumerated() {
            row.frame.origin = CGPoint(x: 0, y: y)
            rowsContainer.addSubview(row)
            y += row.frame.height
            if i < rows.count - 1 {
                let sep = NSView(frame: CGRect(x: 0, y: y - 0.5,
                                               width: rowWidth, height: 1))
                sep.wantsLayer = true
                sep.layer?.backgroundColor = NSColor.fromHex("FAEEF4").cgColor
                rowsContainer.addSubview(sep)
            }
        }
        // Pin scroll to the top (flipped doc: top = y 0).
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        if superview == nil { stage.addSubview(self) }
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            animator().alphaValue = 1
        }

        autoHideTimer.run(after: 10) { [weak self] in self?.hide() }
    }

    func presentEmpty(in stage: NSView) {
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }

        let empty = NSTextField(labelWithString: "No alerts yet.")
        empty.font = NSFont.systemFont(ofSize: 12)
        empty.textColor = NSColor.fromHex("A89CA3")
        empty.isEditable = false; empty.isBezeled = false
        empty.drawsBackground = false; empty.isSelectable = false
        empty.alignment = .left
        rowsContainer.addSubview(empty)

        let emptyBodyHeight: CGFloat = 28
        let panelHeight = headerHeight + emptyBodyHeight + tailHeight
        let idealX = (stage.frame.width - panelWidth) / 2
        let adjustedX = BubbleView.edgeAdjustedX(idealX: idealX, panelWidth: panelWidth, in: stage)
        frame = CGRect(x: adjustedX,
                       y: 128, width: panelWidth, height: panelHeight)

        backgroundLayer.frame = bounds
        backgroundLayer.path = BubbleShape.path(
            bubbleRect: bounds, tailHeight: tailHeight,
            cornerRadius: cornerRadius, tailWidth: tailWidth)

        let labelH: CGFloat = 14
        headerLabel.frame = CGRect(x: horizPadding + 2,
                                   y: panelHeight - headerHeight + (headerHeight - labelH) / 2,
                                   width: panelWidth - 2 * horizPadding,
                                   height: labelH)
        dividerLayer.frame = CGRect(x: 0, y: panelHeight - headerHeight,
                                    width: panelWidth, height: 1)

        let rowWidth = panelWidth - 2 * horizPadding
        scrollView.frame = CGRect(x: horizPadding, y: tailHeight,
                                  width: rowWidth, height: emptyBodyHeight)
        rowsContainer.setFrameSize(NSSize(width: rowWidth, height: emptyBodyHeight))
        empty.frame = CGRect(x: 4, y: 6, width: rowWidth - 8, height: 16)

        if superview == nil { stage.addSubview(self) }
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            animator().alphaValue = 1
        }
        autoHideTimer.run(after: 10) { [weak self] in self?.hide() }
    }

    func hide() {
        autoHideTimer.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
        })
    }

    var isVisible: Bool { !isHidden && alphaValue > 0 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

}

/// Rounded body with a downward-pointing triangle tail, drawn as one path so
/// fill + stroke apply cleanly along the whole outline (no seam at the tail).
enum BubbleShape {
    static func path(bubbleRect: CGRect, tailHeight: CGFloat,
                     cornerRadius r: CGFloat, tailWidth: CGFloat) -> CGPath {
        let body = CGRect(x: bubbleRect.minX, y: bubbleRect.minY + tailHeight,
                          width: bubbleRect.width, height: bubbleRect.height - tailHeight)
        let tailCX = body.midX
        let path = CGMutablePath()
        path.move(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                    tangent2End: CGPoint(x: body.maxX, y: body.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: body.maxX, y: body.minY + r))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                    tangent2End: CGPoint(x: body.maxX - r, y: body.minY), radius: r)
        path.addLine(to: CGPoint(x: tailCX + tailWidth / 2, y: body.minY))
        path.addLine(to: CGPoint(x: tailCX, y: bubbleRect.minY))
        path.addLine(to: CGPoint(x: tailCX - tailWidth / 2, y: body.minY))
        path.addLine(to: CGPoint(x: body.minX + r, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                    tangent2End: CGPoint(x: body.minX, y: body.minY + r), radius: r)
        path.addLine(to: CGPoint(x: body.minX, y: body.maxY - r))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX + r, y: body.maxY), radius: r)
        path.closeSubpath()
        return path
    }
}

/// Three small blue bubbles that rise from above Axol's head when an
/// alert is unresolved, each with a slightly different horizontal drift.
final class WorryBubblesView: NSView {
    private let bubbles: [CAShapeLayer]
    private var running = false

    override init(frame: NSRect) {
        // wb-1: 6px (drifts right), wb-2: 5px (drifts left), wb-3: 7px (slight waver)
        let sizes: [CGFloat] = [6, 5, 7]
        var layers: [CAShapeLayer] = []
        for size in sizes {
            let l = CAShapeLayer()
            let r = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
            l.path = CGPath(ellipseIn: r, transform: nil)
            l.fillColor   = AxolCharacterView.hexColor("B9E2F5")
            l.strokeColor = AxolCharacterView.hexColor("5EA6D0")
            l.lineWidth = 1
            l.bounds = r
            l.position = CGPoint(x: frame.width / 2, y: size / 2)
            l.opacity = 0
            layers.append(l)
        }
        self.bubbles = layers
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        for b in bubbles { layer?.addSublayer(b) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start() {
        guard !running else { return }
        running = true

        // Per-bubble rise paths with subtle horizontal drift. Y values are in
        // Cocoa coords (up is positive) — matching the CSS up-and-away trajectory.
        let paths: [[(t: Double, dx: CGFloat, dy: CGFloat, scale: CGFloat, opacity: Float)]] = [
            // wb-1: drifts right
            [(0,   0,  0,  0.4, 0.0),
             (0.15, 0, 0,  0.4, 0.85),
             (0.5,  3, 18, 0.95, 0.85),
             (0.85, 5, 32, 1.05, 0.7),
             (1.0,  7, 40, 1.1,  0.0)],
            // wb-2: drifts left
            [(0,   0,   0,  0.4, 0.0),
             (0.15, 0,  0,  0.4, 0.85),
             (0.5, -2, 18, 0.95, 0.85),
             (0.85,-6, 32, 1.05, 0.7),
             (1.0, -8, 40, 1.1,  0.0)],
            // wb-3: gentle waver
            [(0,   0,  0,  0.4, 0.0),
             (0.15, 0, 0,  0.4, 0.85),
             (0.5,  2, 19, 0.95, 0.85),
             (0.85, 1, 33, 1.05, 0.7),
             (1.0,  3, 40, 1.1,  0.0)],
        ]
        let delays: [Double] = [0, 0.87, 1.74]
        let now = CACurrentMediaTime()
        for (i, bubble) in bubbles.enumerated() {
            let frames = paths[i]
            let transformAnim = CAKeyframeAnimation(keyPath: "transform")
            transformAnim.values = frames.map { frame -> CATransform3D in
                var t = CATransform3DIdentity
                t = CATransform3DTranslate(t, frame.dx, frame.dy, 0)
                t = CATransform3DScale(t, frame.scale, frame.scale, 1)
                return t
            }
            transformAnim.keyTimes = frames.map { NSNumber(value: $0.t) }
            transformAnim.duration = 2.6
            transformAnim.repeatCount = .infinity
            transformAnim.beginTime = now + delays[i]
            transformAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
            opacityAnim.values   = frames.map { NSNumber(value: $0.opacity) }
            opacityAnim.keyTimes = frames.map { NSNumber(value: $0.t) }
            opacityAnim.duration = 2.6
            opacityAnim.repeatCount = .infinity
            opacityAnim.beginTime = now + delays[i]
            opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            bubble.add(transformAnim, forKey: "rise-transform")
            bubble.add(opacityAnim, forKey: "rise-opacity")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        for b in bubbles {
            b.removeAllAnimations()
            b.opacity = 0
        }
    }
}

/// Three "z" characters floating diagonally up-and-away. Shown while napping.
final class ZsView: NSView {
    private let zs: [CATextLayer]
    private var running = false

    override init(frame: NSRect) {
        let sizes: [CGFloat] = [14, 18, 22]
        var layers: [CATextLayer] = []
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for size in sizes {
            let l = CATextLayer()
            l.string = "z"
            l.font = NSFont.systemFont(ofSize: size, weight: .light) as CFTypeRef
            l.fontSize = size
            l.foregroundColor = AxolCharacterView.hexColor("8A849A")
            l.alignmentMode = .center
            l.contentsScale = scale
            l.frame = CGRect(x: frame.width / 2 - 6, y: 0, width: 14, height: size + 4)
            l.opacity = 0
            layers.append(l)
        }
        self.zs = layers
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        for z in zs { layer?.addSublayer(z) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start() {
        guard !running else { return }
        running = true

        let delays: [Double] = [0, 0.8, 1.6]
        let now = CACurrentMediaTime()
        for (i, z) in zs.enumerated() {
            // scale: 0.6 → 1.3; translate: (0,0) → (12, 34); rotate: -8° → 12°
            let startRot: CGFloat = CGFloat.pi * -8 / 180
            let endRot:   CGFloat = CGFloat.pi * 12 / 180
            func t(scale: CGFloat, dx: CGFloat, dy: CGFloat, rot: CGFloat) -> CATransform3D {
                var m = CATransform3DIdentity
                m = CATransform3DTranslate(m, dx, dy, 0)
                m = CATransform3DRotate(m, rot, 0, 0, 1)
                m = CATransform3DScale(m, scale, scale, 1)
                return m
            }
            let transformAnim = CAKeyframeAnimation(keyPath: "transform")
            transformAnim.values = [
                t(scale: 0.6, dx: 0,  dy: 0,  rot: startRot),
                t(scale: 1.3, dx: 12, dy: 34, rot: endRot)
            ]
            transformAnim.keyTimes = [0, 1.0]
            transformAnim.duration = 2.4
            transformAnim.repeatCount = .infinity
            transformAnim.beginTime = now + delays[i]
            transformAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
            opacityAnim.values   = [0.0, 0.85, 0.85, 0.0]
            opacityAnim.keyTimes = [0.0, 0.15, 0.85, 1.0]
            opacityAnim.duration = 2.4
            opacityAnim.repeatCount = .infinity
            opacityAnim.beginTime = now + delays[i]
            opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            z.add(transformAnim, forKey: "float-transform")
            z.add(opacityAnim, forKey: "float-opacity")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        for z in zs {
            z.removeAllAnimations()
            z.opacity = 0
        }
    }
}

/// Small static-character view with an optional alert-count badge, shown
/// when the user minimizes to compact mode via the right-click menu.
final class CompactView: NSView {
    static let size: CGFloat = 62
    let character: AxolCharacterView
    private let badgeLayer = CAShapeLayer()
    private let badgeLabel = NSTextField(labelWithString: "")

    var onTap: (() -> Void)?
    var onCmdClick: (() -> Void)?
    var onDragDelta: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    private var isDragging = false
    private var moveAccum: CGFloat = 0
    private var lastMouseLocation: CGPoint = .zero

    override init(frame: NSRect) {
        // Reuse AxolCharacterView for visual consistency but keep it static
        // (no startAmbientAnimations call).
        let charWidth: CGFloat = 50
        let charHeight = charWidth * (AxolCharacterView.svgHeight / AxolCharacterView.svgWidth)
        let charX = (frame.width - charWidth) / 2
        let charY = (frame.height - charHeight) / 2
        character = AxolCharacterView(frame: NSRect(x: charX, y: charY, width: charWidth, height: charHeight))

        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        addSubview(character)

        // The inner AxolCharacterView handles its own mouse events; forward
        // them up to the compact view so taps/drags reach the app delegate.
        character.onLeftClick   = { [weak self] in self?.onTap?() }
        character.onCmdClick    = { [weak self] in self?.onCmdClick?() }
        character.onDragDelta   = { [weak self] dx, dy in self?.onDragDelta?(dx, dy) }
        character.onDragEnd     = { [weak self] in self?.onDragEnd?() }

        badgeLayer.fillColor = AxolCharacterView.hexColor("D6457A")
        badgeLayer.isHidden = true
        badgeLayer.shadowColor = NSColor.black.cgColor
        badgeLayer.shadowOpacity = 0.2
        badgeLayer.shadowRadius = 2
        badgeLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(badgeLayer)

        badgeLabel.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.isEditable = false; badgeLabel.isBezeled = false
        badgeLabel.drawsBackground = false; badgeLabel.isSelectable = false
        badgeLabel.alignment = .center
        badgeLabel.isHidden = true
        addSubview(badgeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The badge label shouldn't swallow clicks — pass them through to the
    // inner character view so taps on the badge still expand / drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        if let hit = super.hitTest(point), hit === badgeLabel {
            return character.hitTest(convert(point, to: character))
        }
        return super.hitTest(point)
    }

    func updateBadge(count: Int) {
        if count > 0 {
            badgeLabel.stringValue = count > 99 ? "99+" : "\(count)"
            badgeLabel.isHidden = false
            badgeLayer.isHidden = false
            layoutBadge()
        } else {
            badgeLabel.isHidden = true
            badgeLayer.isHidden = true
        }
    }

    private func layoutBadge() {
        let text = badgeLabel.stringValue
        let textSize = (text as NSString).size(withAttributes: [.font: badgeLabel.font!])
        let badgeW = max(18, ceil(textSize.width) + 10)
        let badgeH: CGFloat = 18
        let rect = CGRect(x: 2,
                          y: bounds.height - badgeH - 5,
                          width: badgeW, height: badgeH)
        badgeLayer.frame = rect
        badgeLayer.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                                 cornerWidth: badgeH / 2, cornerHeight: badgeH / 2, transform: nil)
        badgeLabel.frame = rect.insetBy(dx: 0, dy: 1)
    }

    override func layout() {
        super.layout()
        if !badgeLayer.isHidden { layoutBadge() }
    }

    // Mouse events are handled by the inner AxolCharacterView whose callbacks
    // we wire to our own onTap / onDragDelta / onDragEnd in init.
}

/// Container view that composes the character + overlays + bubble + compact.
/// Subview order matters for z-order: later subviews paint on top.
final class StageView: NSView {
    let character: AxolCharacterView
    let worryBubbles: WorryBubblesView
    let zs: ZsView
    let bubble: BubbleView
    let history: HistoryView
    let compact: CompactView

    override init(frame: NSRect) {
        let charSize = NSSize(width: AxolCharacterView.renderWidth,
                              height: AxolCharacterView.renderWidth * (AxolCharacterView.svgHeight / AxolCharacterView.svgWidth))
        let charX = (frame.width - charSize.width) / 2
        let charY: CGFloat = 4
        character = AxolCharacterView(frame: NSRect(origin: CGPoint(x: charX, y: charY), size: charSize))

        let overlayWidth: CGFloat = 40
        let overlayHeight: CGFloat = 80
        let overlayX = (frame.width - overlayWidth) / 2
        let overlayFrame = NSRect(x: overlayX, y: 118, width: overlayWidth, height: overlayHeight)
        worryBubbles = WorryBubblesView(frame: overlayFrame)
        zs           = ZsView(frame: overlayFrame)

        bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        history = HistoryView(frame: NSRect(x: 0, y: 0, width: 236, height: 100))
        compact = CompactView(frame: NSRect(x: 0, y: 0, width: CompactView.size, height: CompactView.size))
        compact.isHidden = true

        super.init(frame: frame)
        wantsLayer = true
        addSubview(character)
        addSubview(worryBubbles)
        addSubview(zs)
        addSubview(bubble)
        addSubview(history)
        addSubview(compact)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: AxolWindow!
    var stage: StageView!
    var server: AxolServer?
    let saveWorkItem = Scheduled()
    let adapters = AdapterRegistry()

    let stateURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Axol")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()

    func loadSavedOrigin() -> NSPoint? {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = obj["x"] as? Double,
              let y = obj["y"] as? Double else { return nil }
        return NSPoint(x: x, y: y)
    }

    func originFitsOnAScreen(_ origin: NSPoint, size: NSSize) -> Bool {
        let rect = NSRect(origin: origin, size: size)
        for screen in NSScreen.screens where screen.frame.intersects(rect) {
            return true
        }
        return false
    }

    func savePosition() {
        guard let w = window else { return }
        let o = w.frame.origin
        let dict: [String: Any] = ["x": o.x, "y": o.y]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    func savePositionDebounced() {
        saveWorkItem.run(after: 0.4) { [weak self] in self?.savePosition() }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 300
        let h: CGFloat = 360
        let defaultOrigin = NSPoint(x: visible.maxX - w - 40, y: visible.minY + 40)
        let origin: NSPoint = {
            if let saved = loadSavedOrigin(),
               originFitsOnAScreen(saved, size: NSSize(width: w, height: h)) {
                return saved
            }
            return defaultOrigin
        }()

        window = AxolWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true

        stage = StageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        stage.autoresizingMask = [.width, .height]
        window.contentView = stage
        window.makeKeyAndOrderFront(nil)

        stage.character.startAmbientAnimations()
        wireMouseHandlers()
        scheduleIdle(firstRun: true)
        scheduleNap()
        startHistorySweeper()
        startMoodDecay()

        adapters.load()

        server = AxolServer(onEvent: { [weak self] data in
            self?.forwardToUI(data)
        })
        server?.start(port: 47329)
    }

    /// Routes an incoming server payload through the adapter pipeline and
    /// dispatches the resulting envelope to the native bubble on the main queue.
    func forwardToUI(_ data: [String: Any]) {
        var candidate: [String: Any]?
        if data["title"] is String {
            candidate = data
        } else if let adapted = adapters.route(data) {
            candidate = adapted
        }
        guard let raw = candidate,
              let envelope = EnvelopeValidator.validate(raw) else {
            let keys = data.keys.sorted().joined(separator: ", ")
            NSLog("axol: dropped payload — no matching adapter and not a valid envelope (keys: [\(keys)])")
            return
        }
        let priority  = (envelope["priority"] as? String) ?? "normal"
        let attention = envelope["attention"] as? String

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Priority gate: an urgent bubble stays pinned until handled. A
            // non-urgent alert arriving in the meantime is silently dropped
            // (in the JS version it also went to history; history comes in
            // Phase 8). A new urgent replaces the pinned one.
            // Mood bump — priority-scaled + stacking bonus if unseen alerts
            // already exist (applies regardless of whether the new alert
            // makes it to the bubble, so she still notices the volume).
            let stackBonus = self.alertStore.hasUnseenAlerts ? self.woundStackBonus : 0
            self.bumpWound((self.woundBumps[priority] ?? 0) + stackBonus)

            // Always archive the alert (except explicit low) first so downstream
            // branches see a consistent store.
            if priority != "low" {
                self.alertStore.push(envelope: envelope)
            }
            self.updateWorryBubbles()

            // If the history panel is open, update it in place and skip the
            // bubble — matches the "appended to the list" flow.
            if self.stage.history.isVisible {
                if priority != "low" {
                    self.stage.history.present(in: self.stage, entries: self.alertStore.entries)
                }
                return
            }

            // Priority gate: urgent stays pinned until handled.
            if self.stage.bubble.isUrgentlyPinned && priority != "urgent" {
                return
            }

            // Throttle: if a bubble was opened within the last
            // minBubbleDisplayTime and the new alert isn't urgent, queue it
            // rather than clobber the current one.
            let bubbleYoung: Bool = {
                guard self.stage.bubble.isVisible,
                      let opened = self.lastBubbleOpenedAt else { return false }
                return Date().timeIntervalSince(opened) < self.minBubbleDisplayTime
            }()
            if bubbleYoung && priority != "urgent" {
                if self.pendingBubbles.count < self.pendingBubbleCap {
                    self.pendingBubbles.append(PendingBubble(envelope: envelope, attention: attention))
                }
                return
            }

            if self.isNapping { self.endNap() }
            self.presentBubbleFromEnvelope(envelope, attention: attention)
        }
    }

    // Native action dispatcher for envelope actions (open-url, reveal-file, focus-pid).
    // Called from UI click handlers in later phases.
    func runAction(_ action: [String: Any]) {
        guard let type = action["type"] as? String else { return }
        switch type {
        case "focus-pid":
            if let pid = action["pid"] as? Int {
                focusTerminal(claudePid: Int32(pid))
            }
        case "open-url":
            if let url = action["url"] as? String,
               (url.hasPrefix("http://") || url.hasPrefix("https://")),
               let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        case "reveal-file":
            if let path = action["path"] as? String {
                let expanded = (path as NSString).expandingTildeInPath
                let home = NSHomeDirectory()
                if expanded.hasPrefix(home + "/") && FileManager.default.fileExists(atPath: expanded) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
                }
            }
        case "noop":
            break
        default:
            break
        }
    }

    func focusTerminal(claudePid: Int32) {
        let info = findTerminalFor(pid: claudePid)
        guard let app = info.appName else {
            NSLog("axol: no terminal app found walking up from pid \(claudePid)")
            return
        }
        let tty = info.tty ?? ""
        let script: String
        switch app {
        case "Terminal":
            script = """
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "iTerm2", "iTerm":
            script = """
            tell application "iTerm"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            script = "tell application \"\(app)\" to activate"
        }
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        do { try p.run() } catch { NSLog("axol: osascript failed: \(error)") }
    }

    func findTerminalFor(pid: Int32) -> (appName: String?, tty: String?) {
        var ttyName: String? = nil
        let rawTty = runPS(field: "tty", pid: pid).trimmingCharacters(in: .whitespaces)
        if !rawTty.isEmpty && rawTty != "??" {
            ttyName = rawTty.hasPrefix("/dev/") ? rawTty : "/dev/\(rawTty)"
        }
        var current = pid
        for _ in 0..<30 {
            if current <= 1 { break }
            let comm = runPS(field: "comm", pid: current)
            if let app = Self.extractAppName(from: comm) {
                return (app, ttyName)
            }
            let ppidStr = runPS(field: "ppid", pid: current).trimmingCharacters(in: .whitespaces)
            guard let next = Int32(ppidStr), next != current, next > 0 else { break }
            current = next
        }
        return (nil, ttyName)
    }

    func runPS(field: String, pid: Int32) -> String {
        let p = Process()
        p.launchPath = "/bin/ps"
        p.arguments = ["-o", "\(field)=", "-p", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
        } catch {
            return ""
        }
    }

    static func extractAppName(from processPath: String) -> String? {
        guard let appRange = processPath.range(of: ".app/") else { return nil }
        let prefix = processPath[..<appRange.lowerBound]
        if let slashRange = prefix.range(of: "/", options: .backwards) {
            return String(prefix[slashRange.upperBound...])
        }
        return String(prefix)
    }

    private var idleAnimationsEnabled = true
    private var nudgesEnabled = true

    @objc private func toggleIdles(_ sender: NSMenuItem) {
        idleAnimationsEnabled.toggle()
        if idleAnimationsEnabled {
            scheduleIdle(firstRun: false)
            scheduleNap()
        } else {
            idleTimer.cancel()
            napTimer.cancel()
            wakeTimer.cancel()
            if isNapping { endNap() }
        }
    }

    @objc private func toggleNudges(_ sender: NSMenuItem) {
        nudgesEnabled.toggle()
    }

    func showMenu() {
        let menu = NSMenu()

        let compactItem = NSMenuItem(title: isCompact ? "Expand" : "Compact Mode",
                                     action: #selector(doHide),
                                     keyEquivalent: "")
        compactItem.target = self
        menu.addItem(compactItem)

        menu.addItem(.separator())

        let idleItem = NSMenuItem(title: "Idle Animations",
                                  action: #selector(toggleIdles(_:)),
                                  keyEquivalent: "")
        idleItem.target = self
        idleItem.state = idleAnimationsEnabled ? .on : .off
        menu.addItem(idleItem)

        let nudgesItem = NSMenuItem(title: "Nudges",
                                    action: #selector(toggleNudges(_:)),
                                    keyEquivalent: "")
        nudgesItem.target = self
        nudgesItem.state = nudgesEnabled ? .on : .off
        menu.addItem(nudgesItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About",
                                   action: #selector(doAbout),
                                   keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(doQuit),
                                  keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        let screenMouse = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: screenMouse, in: nil)
    }

    private func wireMouseHandlers() {
        stage.character.onRightClick = { [weak self] in
            self?.showMenu()
        }
        stage.character.onDragDelta = { [weak self] dx, dy in
            guard let self = self, let w = self.window else { return }
            let proposed = CGPoint(x: w.frame.origin.x + dx, y: w.frame.origin.y + dy)
            w.setFrameOrigin(self.clampOriginToScreen(proposed, size: w.frame.size))
            self.savePositionDebounced()
        }
        stage.character.onLeftClick = { [weak self] in
            guard let self = self else { return }
            if self.stage.history.isVisible { self.stage.history.hide(); return }
            if self.isNapping { self.endNap(); return }
            // Cycle through recent actionable alerts if any; otherwise quip.
            let actionable = self.alertStore.entries.filter { $0.action != nil }
            if !actionable.isEmpty {
                let entry = actionable[self.historyCycleIndex % actionable.count]
                self.historyCycleIndex = (self.historyCycleIndex + 1) % actionable.count
                self.replay(entry: entry)
            } else {
                self.doSpeak()
            }
        }
        stage.character.onDragStart = { [weak self] in
            if self?.isNapping == true { self?.endNap() }
        }
        stage.character.onDoubleClick = { [weak self] in
            self?.showHistory()
        }
        stage.character.onCmdClick = { [weak self] in
            self?.toggleCompact()
        }

        stage.bubble.onAction = { [weak self] action in
            guard let self = self else { return }
            self.runAction(action)
            if let last = self.alertStore.lastActionableAlert {
                self.alertStore.markSeen(id: last.id)
            }
            self.bumpWound(self.woundHandled)
            self.updateWorryBubbles()
        }
        stage.bubble.onShow = { [weak self] talkDuration in
            self?.stage.character.stopIdles()
            self?.stage.character.startTalking(durationSeconds: talkDuration)
            self?.updateWorryBubbles()
        }
        stage.bubble.onHide = { [weak self] in
            guard let self = self else { return }
            self.stage.character.stopTalking()
            self.updateWorryBubbles()
            self.drainPendingBubbles()
        }

        stage.history.onRowClick = { [weak self] entry in
            guard let self = self else { return }
            if let action = entry.action {
                self.runAction(action)
                self.bumpWound(self.woundHandled)
            }
            self.alertStore.markSeen(id: entry.id)
            self.updateWorryBubbles()
        }

        stage.compact.onTap = { [weak self] in
            self?.expandToFull()
        }
        stage.compact.onCmdClick = { [weak self] in
            self?.toggleCompact()
        }
        stage.compact.onDragDelta = { [weak self] dx, dy in
            guard let self = self, let w = self.window else { return }
            let proposed = CGPoint(x: w.frame.origin.x + dx, y: w.frame.origin.y + dy)
            w.setFrameOrigin(self.clampOriginToScreen(proposed, size: w.frame.size))
            self.savePositionDebounced()
        }
    }

    /// Replays an archived alert in the bubble.
    private func replay(entry: AlertEntry) {
        stage.bubble.present(title: entry.title, body: entry.body,
                             priority: entry.priority, icon: entry.icon, action: entry.action)
        alertStore.markSeen(id: entry.id)
        updateWorryBubbles()
    }

    // MARK: - Nap scheduler

    private var isNapping = false
    private var firstNap = true
    private let napTimer = Scheduled()
    private let wakeTimer = Scheduled()

    private func scheduleNap() {
        let delay: TimeInterval = firstNap
            ? (90 + Double.random(in: 0...150))      // 1.5 – 4 min for the first nap
            : (300 + Double.random(in: 0...600))     // 5 – 15 min thereafter
        firstNap = false
        napTimer.run(after: delay) { [weak self] in self?.tryStartNap() }
    }

    private func tryStartNap() {
        guard idleAnimationsEnabled else { return }
        if stage.bubble.isVisible
           || stage.history.isVisible
           || alertStore.hasUnseenAlerts
           || woundUp >= woundNapBlock {
            napTimer.run(after: 20) { [weak self] in self?.tryStartNap() }
            return
        }
        startNap()
    }

    private func startNap() {
        guard !isNapping else { return }
        isNapping = true
        stage.character.enterNap()
        stage.zs.start()
        let wakeDelay: TimeInterval = 20 + Double.random(in: 0...20)
        wakeTimer.run(after: wakeDelay) { [weak self] in self?.endNap() }
    }

    private func endNap() {
        guard isNapping else { return }
        isNapping = false
        stage.character.leaveNap()
        stage.zs.stop()
        wakeTimer.cancel()
        bumpWound(woundWake)
        scheduleNap()
    }

    // MARK: - Alert store & worry-bubble state

    let alertStore = AlertStore()
    private let historySweepTimer = Scheduled()
    private var historyCycleIndex: Int = 0

    // MARK: - Bubble throttling
    // Prevents new non-urgent alerts from clobbering a bubble that was just
    // shown. Queued alerts are still archived; they just wait their turn for
    // the bubble slot.
    private struct PendingBubble {
        let envelope: [String: Any]
        let attention: String?
    }
    private var pendingBubbles: [PendingBubble] = []
    private let pendingBubbleCap: Int = 4
    private var lastBubbleOpenedAt: Date?
    private let minBubbleDisplayTime: TimeInterval = 2.5

    private func drainPendingBubbles() {
        guard !pendingBubbles.isEmpty,
              !stage.history.isVisible,
              !stage.bubble.isVisible else { return }
        let next = pendingBubbles.removeFirst()
        presentBubbleFromEnvelope(next.envelope, attention: next.attention)
    }

    /// Single-use helper that turns a validated envelope into a bubble +
    /// attention one-shot. Used by forwardToUI and drainPendingBubbles so
    /// both paths go through the same presentation logic.
    private func presentBubbleFromEnvelope(_ envelope: [String: Any], attention: String?) {
        let title    = (envelope["title"] as? String) ?? ""
        let body     = envelope["body"] as? String
        let priority = (envelope["priority"] as? String) ?? "normal"
        let icon     = envelope["icon"] as? String
        let action   = (envelope["actions"] as? [[String: Any]])?.first
        stage.bubble.present(title: title, body: body, priority: priority, icon: icon, action: action)
        lastBubbleOpenedAt = Date()

        let effective: String = {
            if let a = attention, a == "wiggle" || a == "hop" || a == "none" { return a }
            return priority == "urgent" ? "wiggle" : "none"
        }()
        if effective == "wiggle" { stage.character.playIdle(.wiggle) }
        if effective == "hop"    { stage.character.playIdle(.hop) }
    }

    private func updateWorryBubbles() {
        let shouldRun = alertStore.hasUnseenAlerts
                        && !stage.bubble.isVisible
                        && !stage.history.isVisible
                        && !isCompact
        if shouldRun {
            stage.worryBubbles.start()
        } else {
            stage.worryBubbles.stop()
        }
        if isCompact {
            stage.compact.updateBadge(count: alertStore.unseenCount)
        }
    }

    // MARK: - Compact mode

    private var isCompact = false
    private var savedFullFrame: NSRect?

    private func toggleCompact() {
        if isCompact { expandToFull() } else { shrinkToCompact() }
    }

    private func shrinkToCompact() {
        guard !isCompact else { return }
        isCompact = true
        savedFullFrame = window.frame

        // Hide full-mode UI + any transient overlays
        stage.bubble.hide()
        stage.history.hide()
        stage.character.isHidden = true
        stage.worryBubbles.isHidden = true
        stage.zs.isHidden = true
        stage.worryBubbles.stop()
        stage.zs.stop()
        stage.character.stopAmbientAnimations()

        // Show compact view pinned inside the new small window bounds
        let s = CompactView.size
        stage.compact.frame = NSRect(x: 0, y: 0, width: s, height: s)
        stage.compact.isHidden = false
        stage.compact.updateBadge(count: alertStore.unseenCount)

        // Shrink window anchored at its bottom-right corner (keeps her in
        // the same visual spot; the window just contracts). Clamp to the
        // screen so she doesn't end up half off if the full window's right
        // edge was sitting right against the edge.
        let old = window.frame
        let proposed = CGPoint(x: old.maxX - s, y: old.minY)
        let clamped = clampOriginToScreen(proposed, size: NSSize(width: s, height: s))
        let newFrame = NSRect(origin: clamped, size: NSSize(width: s, height: s))
        window.setFrame(newFrame, display: true, animate: true)
    }

    private func expandToFull() {
        guard isCompact else { return }
        isCompact = false
        stage.compact.isHidden = true

        // Most recent actionable alert is replayed after the resize settles.
        let pending = alertStore.lastActionableAlert

        stage.character.isHidden = false
        stage.worryBubbles.isHidden = false
        stage.zs.isHidden = false
        stage.character.startAmbientAnimations()
        updateWorryBubbles()

        guard let saved = savedFullFrame else {
            if let p = pending { replay(entry: p) }
            return
        }

        // Animated resize via NSWindow's built-in animate:true path.
        // animator()-based completion doesn't reliably fire for window frame
        // changes, so schedule the bubble replay after a generous delay that
        // covers the actual animation (animationResizeTime under-reports).
        window.setFrame(saved, display: true, animate: true)
        if let p = pending {
            let delay = window.animationResizeTime(saved) + 0.35
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.replay(entry: p)
            }
        }
    }

    private func startHistorySweeper() {
        func tick() {
            let removed = self.alertStore.sweep()
            if removed > 0 {
                self.updateWorryBubbles()
                if self.stage.history.isVisible {
                    self.showHistory()  // re-render with updated entries
                }
            }
            self.historySweepTimer.run(after: 30) { tick() }
        }
        historySweepTimer.run(after: 30) { tick() }
    }

    private func showHistory() {
        if stage.bubble.isVisible && !stage.bubble.isUrgentlyPinned {
            stage.bubble.hide()
        }
        stage.character.stopIdles()
        if alertStore.entries.isEmpty {
            stage.history.presentEmpty(in: stage)
        } else {
            stage.history.present(in: stage, entries: alertStore.entries)
        }
        alertStore.markAllSeen()
        updateWorryBubbles()
    }

    // MARK: - Idle scheduler

    private let idleTimer = Scheduled()

    private func scheduleIdle(firstRun: Bool = false) {
        let delay: TimeInterval = firstRun
            ? (2.5 + Double.random(in: 0...1.5))
            : (10.0 + Double.random(in: 0...20.0))
        idleTimer.run(after: delay) { [weak self] in self?.tryIdle() }
    }

    private func tryIdle() {
        guard idleAnimationsEnabled else { return }
        if stage.bubble.isVisible || stage.history.isVisible || isNapping {
            idleTimer.run(after: 4) { [weak self] in self?.tryIdle() }
            return
        }
        let pool = moodIdlePool()
        let kind = pool.randomElement() ?? .tilt
        stage.character.playIdle(kind)
        scheduleIdle(firstRun: false)
    }

    // MARK: - Quip pool

    private let calmMessages = [
        "Oh. Hi.",
        "I can wait.",
        "Drag me wherever.",
        "Right-click for more.",
        "Still here.",
        "Been a while.",
        "My gills need a moment sometimes.",
        "Take your time.",
        "Quiet out here.",
        "Breathe with me.",
        "I'm around.",
    ]

    private let frazzledMessages = [
        "That's a lot.",
        "I'm right here.",
        "One at a time.",
        "Gills are flaring.",
        "Hey. Slow it down.",
    ]

    // MARK: - Mood (wound-up axis)

    /// Scalar mood value in [0, 1]. Not persisted.
    private var woundUp: Double = 0
    private let moodDecayTimer = Scheduled()

    // Bumps mirror the JS version's tuning
    private let woundBumps: [String: Double] = [
        "low": 0.0, "normal": 0.08, "high": 0.18, "urgent": 0.28
    ]
    private let woundStackBonus: Double = 0.08
    private let woundHandled:    Double = -0.15
    private let woundClearFactor: Double = 0.2
    private let woundWake:       Double = -0.30
    private let woundNapBlock:   Double = 0.55
    private let woundAgitated:   Double = 0.6
    private let woundCalmMax:    Double = 0.3
    private let woundDecayInterval: TimeInterval = 10
    private let woundDecayFactor: Double = 0.95

    private func bumpWound(_ delta: Double) {
        woundUp = max(0, min(1, woundUp + delta))
        if woundUp < 0.02 { woundUp = 0 }
    }

    private func startMoodDecay() {
        func tick() {
            if self.woundUp > 0 {
                self.woundUp *= self.woundDecayFactor
                if self.woundUp < 0.02 { self.woundUp = 0 }
            }
            self.moodDecayTimer.run(after: self.woundDecayInterval) { tick() }
        }
        moodDecayTimer.run(after: woundDecayInterval) { tick() }
    }

    /// Mood-filtered pool for the idle scheduler. Calm woundUp favors
    /// settling animations (tilt, stretch); agitated woundUp prefers
    /// twitchier ones (peek, wiggle); mid-range uses the full pool.
    private func moodIdlePool() -> [AxolCharacterView.IdleKind] {
        if woundUp < woundCalmMax  { return [.tilt, .stretch] }
        if woundUp >= woundAgitated { return [.peek, .wiggle] }
        return AxolCharacterView.idlePool
    }

    @objc func doSpeak() {
        guard nudgesEnabled else { return }
        let pool = woundUp >= woundAgitated ? frazzledMessages : calmMessages
        let msg = pool.randomElement() ?? "Hi."
        stage.bubble.present(title: msg, body: nil, priority: "normal", action: nil)
    }
    @objc func doWave() {
        stage.character.wave()
        stage.bubble.present(title: "👋 hi there!", body: nil, priority: "normal", action: nil)
    }
    @objc func doAbout() {
        stage.bubble.present(title: "Axol v0.1 — a desktop companion.", body: nil, priority: "normal", action: nil)
    }
    // Phase 8 will wire these to real native behavior
    @objc func doLastAlert() {
        if let entry = alertStore.lastActionableAlert {
            replay(entry: entry)
        } else {
            stage.bubble.present(title: "No alerts yet.", body: nil, priority: "normal", action: nil)
        }
    }
    @objc func doClearAlert() {
        alertStore.markAllSeen()
        woundUp *= woundClearFactor
        stage.bubble.hide()
        updateWorryBubbles()
    }
    @objc func doNap() {
        if isNapping { endNap() } else { startNap() }
    }
    @objc func doAnimate() {
        let kind = AxolCharacterView.idlePool.randomElement() ?? .tilt
        stage.character.playIdle(kind)
    }
    @objc func doHide() { toggleCompact() }

    /// Keeps the given window origin inside the active screen's visible frame
    /// (respecting the menu bar + Dock). Called from drag handlers.
    fileprivate func clampOriginToScreen(_ origin: CGPoint, size: NSSize) -> CGPoint {
        guard let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return origin
        }
        let margin: CGFloat = 4
        var o = origin
        o.x = max(screen.minX + margin, min(o.x, screen.maxX - size.width  - margin))
        o.y = max(screen.minY + margin, min(o.y, screen.maxY - size.height - margin))
        return o
    }
    @objc func doQuit()       { NSApplication.shared.terminate(nil) }

    func applicationWillTerminate(_ note: Notification) {
        saveWorkItem.cancel()
        savePosition()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
