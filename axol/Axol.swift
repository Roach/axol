import Cocoa
import QuartzCore

// Scheduled, AxolServer, AxolWindow live in Scheduled.swift + Server.swift.
// Predicate, AlertAdapter, AdapterTemplate, AdapterRegistry in Adapters.swift.
// EnvelopeValidator in Envelope.swift. AlertEntry, AlertStore in AlertStore.swift.

/// Three window-size modes, cycled by cmd-click (full → mini → micro → full):
///   - full: default ~300×360 pane with the ambient character + bubble-above-head.
///   - mini: small ~60×48 character with an optional side bubble (~240×80 total).
///   - micro: 48×48 static icon + count badge; clicks expand back to full.
/// The enum is `String`-backed so it round-trips through `state.json` cleanly.
/// The legacy raw value `"compact"` (pre-rename) is migrated to `.micro` in
/// `loadSavedMode()` — existing users don't get dropped back to full mode.
enum AxolMode: String {
    case full
    case mini
    case micro

    var next: AxolMode {
        switch self {
        case .full:  return .mini
        case .mini:  return .micro
        case .micro: return .full
        }
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

    /// Color palette the character is drawn with. Defaults to the hardcoded
    /// pink palette so callers that don't care about theming get the
    /// original axolotl. StageView / MicroView instantiate with the
    /// app's currently-loaded theme at startup.
    private let theme: Theme

    init(frame: NSRect, theme: Theme = .builtin) {
        self.theme = theme
        super.init(frame: frame)
        wantsLayer = true
        let root = CALayer()
        layer = root

        // Layer-backed NSViews on macOS default root anchorPoint to (0,0), so
        // rotations and scales pivot at the bottom-left corner. Re-anchor to
        // the center and shift position by half-bounds to keep the view
        // visually in place. Every ambient/idle animation on this layer now
        // pivots on the center naturally — no per-animation compensation.
        root.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        root.position = CGPoint(x: frame.origin.x + frame.width / 2,
                                y: frame.origin.y + frame.height / 2)

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

        let c = theme.character

        // Left gills (3 ellipses) — gillTip is conventionally darker than gillBase.
        leftGillsLayer.addSublayer(ellipse(cx: 52,  cy: 70,  rx: 16, ry: 9,  hex: c.gillBase, rotateDeg: -35))
        leftGillsLayer.addSublayer(ellipse(cx: 42,  cy: 95,  rx: 18, ry: 10, hex: c.gillBase, rotateDeg: -8))
        leftGillsLayer.addSublayer(ellipse(cx: 50,  cy: 122, rx: 20, ry: 11, hex: c.gillTip,  rotateDeg: 22))
        contentLayer.addSublayer(leftGillsLayer)

        // Right gills (3 ellipses, mirrored)
        rightGillsLayer.addSublayer(ellipse(cx: 168, cy: 70,  rx: 16, ry: 9,  hex: c.gillBase, rotateDeg: 35))
        rightGillsLayer.addSublayer(ellipse(cx: 178, cy: 95,  rx: 18, ry: 10, hex: c.gillBase, rotateDeg: 8))
        rightGillsLayer.addSublayer(ellipse(cx: 170, cy: 122, rx: 20, ry: 11, hex: c.gillTip,  rotateDeg: -22))
        contentLayer.addSublayer(rightGillsLayer)

        // Body + belly.
        contentLayer.addSublayer(ellipse(cx: 110, cy: 110, rx: 72, ry: 62, hex: c.body))
        contentLayer.addSublayer(ellipse(cx: 110, cy: 125, rx: 50, ry: 38, hex: c.belly))

        // Arms — same tone as the body.
        armLeftLayer.addSublayer(ellipse(cx: 58,  cy: 155, rx: 10, ry: 14, hex: c.body, rotateDeg: -20))
        armRightLayer.addSublayer(ellipse(cx: 162, cy: 155, rx: 10, ry: 14, hex: c.body, rotateDeg: 20))
        contentLayer.addSublayer(armLeftLayer)
        contentLayer.addSublayer(armRightLayer)

        // Eyes — pupils + highlights, grouped for blink animation
        eyesLayer.addSublayer(circle(cx: 88,  cy: 105, r: 7,   hex: c.eye))
        eyesLayer.addSublayer(circle(cx: 132, cy: 105, r: 7,   hex: c.eye))
        eyesLayer.addSublayer(circle(cx: 90,  cy: 102, r: 2.2, hex: c.highlight))
        eyesLayer.addSublayer(circle(cx: 134, cy: 102, r: 2.2, hex: c.highlight))
        contentLayer.addSublayer(eyesLayer)

        // Cheeks — opacity 45% is baked in regardless of the theme color.
        contentLayer.addSublayer(circle(cx: 78,  cy: 125, r: 7, hex: c.cheek, opacity: 0.45))
        contentLayer.addSublayer(circle(cx: 142, cy: 125, r: 7, hex: c.cheek, opacity: 0.45))

        // Mouth — closed arc + hidden open ellipse for talking
        let closedPath = CGMutablePath()
        closedPath.move(to: CGPoint(x: 98, y: 130))
        closedPath.addQuadCurve(to: CGPoint(x: 122, y: 130), control: CGPoint(x: 110, y: 138))
        mouthClosedLayer.path = closedPath
        mouthClosedLayer.strokeColor = Self.hexColor(c.mouth)
        mouthClosedLayer.fillColor = NSColor.clear.cgColor
        mouthClosedLayer.lineWidth = 2.5
        mouthClosedLayer.lineCap = .round
        contentLayer.addSublayer(mouthClosedLayer)

        let openPath = CGPath(ellipseIn: CGRect(x: -6, y: -4, width: 12, height: 8), transform: nil)
        mouthOpenLayer.path = openPath
        mouthOpenLayer.fillColor = Self.hexColor(c.mouth)
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
    var onOptClick:    (() -> Void)?
    var onDragStart:   (() -> Void)?
    var onDragEnd:     (() -> Void)?
    var onDragDelta:   ((CGFloat, CGFloat) -> Void)?
    /// Absolute drag: receives the window origin (screen points) that
    /// makes the cursor's grab point align with its position at mouseDown.
    /// No accumulated delta → no drift. Preferred over onDragDelta.
    var onDragTo:      ((CGPoint) -> Void)?

    private var isDragging = false
    private var mouseDownLocation: CGPoint = .zero
    private var dragWindowOriginAtMouseDown: CGPoint = .zero
    private var lastMouseLocation: CGPoint = .zero
    private let pendingSingleClick = Scheduled()
    private let dragThreshold: CGFloat = 5.0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        mouseDownLocation = NSEvent.mouseLocation
        lastMouseLocation = mouseDownLocation
        dragWindowOriginAtMouseDown = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        // Absolute-position drag (preferred): compute where the window
        // origin *should* be given the cursor's current screen position
        // and its offset at mouseDown. No delta accumulation → no drift.
        // Falls back to step-delta for consumers still on onDragDelta.
        let current = NSEvent.mouseLocation
        let totalDx = current.x - mouseDownLocation.x
        let totalDy = current.y - mouseDownLocation.y
        if !isDragging {
            if abs(totalDx) + abs(totalDy) <= dragThreshold { return }
            isDragging = true
            onDragStart?()
        }
        if let cb = onDragTo {
            cb(CGPoint(x: dragWindowOriginAtMouseDown.x + totalDx,
                       y: dragWindowOriginAtMouseDown.y + totalDy))
        } else {
            let stepDx = current.x - lastMouseLocation.x
            let stepDy = current.y - lastMouseLocation.y
            onDragDelta?(stepDx, stepDy)
        }
        lastMouseLocation = current
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
        if event.modifierFlags.contains(.option) {
            pendingSingleClick.cancel()
            onOptClick?()
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
        layer?.removeAnimation(forKey: "tilt")
        // peek rotates the root layer with paired additive (tx, ty) keyframes
        // that compensate for the below-center pivot. All three must be
        // removed together or the character will stick mid-drift.
        for key in ["peek", "peek-px", "peek-py"] {
            layer?.removeAnimation(forKey: key)
        }
        armLeftLayer.removeAnimation(forKey: "stretch")
        armRightLayer.removeAnimation(forKey: "stretch")
        leftGillsLayer.removeAnimation(forKey: "wiggle")
        rightGillsLayer.removeAnimation(forKey: "wiggle")
        eyesLayer.removeAnimation(forKey: "double-blink")
        leftGillsLayer.removeAnimation(forKey: "gill-flick")
        rightGillsLayer.removeAnimation(forKey: "gill-flick")
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
        case peek, stretch, hop, tilt, wiggle, doubleBlink, gillFlickLeft, gillFlickRight, flip
    }

    /// Idle animations available to the scheduler. `hop` is intentionally
    /// reserved for urgent-alert attention and not in this pool. The subtle
    /// micro-animations (doubleBlink, gill flicks) are listed twice so the
    /// idle picker weights them higher than the larger-motion idles. `flip`
    /// is listed once — it's the most dramatic move, so a rare treat.
    static let idlePool: [IdleKind] = [
        .peek, .stretch, .tilt, .wiggle,
        .doubleBlink, .doubleBlink,
        .gillFlickLeft, .gillFlickRight,
        .flip,
    ]

    func playIdle(_ kind: IdleKind) {
        switch kind {
        case .peek:            playPeek()
        case .stretch:         playStretch()
        case .hop:             playHop()
        case .tilt:            playTilt()
        case .wiggle:          playWiggle()
        case .doubleBlink:     playDoubleBlink()
        case .gillFlickLeft:   playGillFlick(leftSide: true)
        case .gillFlickRight:  playGillFlick(leftSide: false)
        case .flip:            playFlip()
        }
    }

    private func playPeek() {
        // Head-cock + return — a curiosity glance. Pivots ~40px below the
        // view center so the swing reads as planted on her body instead
        // of spinning around her forehead.
        rotateWithGroundedPivot(key: "peek",
                                angleDeg: 4,
                                pivotBelow: rotationPivotBelow,
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

    /// Underwater 360° flip — she's in water, so no jumping; the motion
    /// is all rotation. Body winds up by leaning back a few degrees,
    /// spins a full turn, then overshoots slightly past zero and
    /// settles. Gills and arms "drag" behind the body (they're child
    /// layers, so applying rotation in the *opposite* direction of the
    /// body's spin makes them appear to lag through the water), then
    /// whip forward and catch up on the settle.
    private func playFlip() {
        let dur: Double = 1.6
        let deg = Double.pi / 180

        // Body: small wind-up back, full −360° spin, small overshoot
        // past zero, settle. Values are cumulative angles (radians).
        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = [
            0.0,
            0.20,                       // wind-up (lean back)
            0.15,                       // release
            -(2 * Double.pi - 0.15),    // near-full spin
            -(2 * Double.pi) - 0.12,    // overshoot past zero
            -(2 * Double.pi),           // settle back to start
        ]
        rotation.keyTimes = [0.0, 0.14, 0.22, 0.82, 0.92, 1.0]
        rotation.duration = dur
        // Slow wind-up, snappy spin, gentle settle.
        rotation.timingFunction = CAMediaTimingFunction(controlPoints: 0.35, 0.05, 0.35, 1)
        contentLayer.add(rotation, forKey: "flip-rotation")

        // Gill drag — OPPOSITE sign to the body's spin direction, so in
        // screen-space they look like they're being pulled through the
        // water. Ramps up during the fast spin, whips forward, then
        // overshoots and settles with a small counter-swing.
        let gillDrag: [Double] = [0, -2, 14, 22, -8, 0]
        let gillTimes: [NSNumber] = [0.0, 0.14, 0.45, 0.78, 0.92, 1.0].map { NSNumber(value: $0) }
        let leftGill = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        leftGill.values   = gillDrag.map { $0 * deg }
        leftGill.keyTimes = gillTimes
        leftGill.duration = dur
        leftGill.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        leftGill.isAdditive = true
        leftGillsLayer.add(leftGill, forKey: "flip-drag")

        // Right gill drags the opposite local direction for asymmetry
        // — a real creature's gills aren't a rigid pair, they flutter
        // independently. Slight time offset adds to the liveliness.
        let rightGillDrag: [Double] = [0, -1, 12, 24, -6, 0]
        let rightGillTimes: [NSNumber] = [0.0, 0.14, 0.48, 0.80, 0.93, 1.0].map { NSNumber(value: $0) }
        let rightGill = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rightGill.values   = rightGillDrag.map { $0 * deg }
        rightGill.keyTimes = rightGillTimes
        rightGill.duration = dur
        rightGill.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rightGill.isAdditive = true
        rightGillsLayer.add(rightGill, forKey: "flip-drag")

        // Arms (her visible feet/appendages) drag a touch more than
        // gills — more mass, later catch-up. Mirror-asymmetric so the
        // two sides don't move in lockstep.
        let leftArmDrag:  [Double] = [0, -4, 20, 28, -10, 0]
        let rightArmDrag: [Double] = [0, -3, 18, 30,  -8, 0]
        let armTimes: [NSNumber] = [0.0, 0.16, 0.48, 0.82, 0.94, 1.0].map { NSNumber(value: $0) }

        let leftArm = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        leftArm.values   = leftArmDrag.map { $0 * deg }
        leftArm.keyTimes = armTimes
        leftArm.duration = dur
        leftArm.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        leftArm.isAdditive = true
        armLeftLayer.add(leftArm, forKey: "flip-drag")

        let rightArm = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rightArm.values   = rightArmDrag.map { -$0 * deg }
        rightArm.keyTimes = armTimes
        rightArm.duration = dur
        rightArm.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rightArm.isAdditive = true
        armRightLayer.add(rightArm, forKey: "flip-drag")
    }

    /// Bigger-amplitude bounce for high-attention moments (permission
    /// prompts) — a deeper anticipation and ~2x the peak height of the
    /// regular hop so it reads as a "notice me!" beat rather than an
    /// ambient idle.
    func playAttentionHop() {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values   = [0.0, -4.0, 28.0, 0.0, 12.0, 0.0]
        a.keyTimes = [0.0, 0.08, 0.32, 0.58, 0.80, 1.0]
        a.duration = 1.1
        a.calculationMode = .cubic
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.28, 0.84, 0.42, 1)
        a.isAdditive = true
        layer?.add(a, forKey: "hop")
    }

    private func playTilt() {
        // Gentle breathe — a slow inhale/exhale scale around the view center.
        // Replaces the previous whole-body rotation, which read as an
        // off-kilter pendulum sway on a rounded character that has no neck
        // or feet to anchor the swing.
        let breathe = CAKeyframeAnimation(keyPath: "transform.scale")
        breathe.values   = [1.0, 1.025, 0.99, 1.0]
        breathe.keyTimes = [0.0, 0.42, 0.78, 1.0]
        breathe.duration = 2.0
        breathe.calculationMode = .cubic
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(breathe, forKey: "tilt")
    }

    /// Tiny double blink — two quick lid closures with a short hold between.
    /// Subtle; reads as a moment of thought.
    private func playDoubleBlink() {
        let b = CAKeyframeAnimation(keyPath: "transform.scale.y")
        b.values   = [1.0, 0.08, 1.0, 1.0, 0.08, 1.0]
        b.keyTimes = [0.0,  0.08, 0.16, 0.42, 0.50, 0.58]
        b.duration = 1.0
        b.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        eyesLayer.add(b, forKey: "double-blink")
    }

    /// Single-gill flick — one side's gill group scales up slightly then
    /// settles. Reads as a small involuntary flutter. Alternates sides.
    private func playGillFlick(leftSide: Bool) {
        let target = leftSide ? leftGillsLayer : rightGillsLayer
        let flick = CAKeyframeAnimation(keyPath: "transform.scale")
        flick.values   = [1.0, 1.10, 0.98, 1.0]
        flick.keyTimes = [0.0, 0.30, 0.70, 1.0]
        flick.duration = 0.8
        flick.calculationMode = .cubic
        flick.isAdditive = false
        target.add(flick, forKey: "gill-flick")
    }

    /// Distance below the view center (in root-layer pixel coords, y-up) to
    /// use as the rotation pivot for tilt/peek. ~40px lands near her hips on
    /// the default 150×136 character view, so rotations feel planted on the
    /// body rather than spinning around her head.
    private var rotationPivotBelow: CGFloat { bounds.height * 0.30 }

    /// Apply a constant-peak rotation whose effective pivot sits `h` pixels
    /// below the layer's anchor. The anchor is at the view's geometric center
    /// (set in `init`); additive (tx, ty) keyframes keep the point (0, -h)
    /// (i.e. h below center, root-layer y-up) stationary throughout the
    /// rotation. Used by peek-style in/hold/out/rest idles.
    private func rotateWithGroundedPivot(key: String,
                                         angleDeg: CGFloat,
                                         pivotBelow h: CGFloat,
                                         keyTimes: [NSNumber],
                                         duration: CFTimeInterval) {
        let theta = CGFloat.pi * angleDeg / 180
        let angles: [CGFloat] = [0, theta, theta, 0]
        let rot = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rot.values   = angles.map { Double($0) }
        rot.keyTimes = keyTimes
        rot.duration = duration
        rot.calculationMode = .cubic
        rot.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        rot.isAdditive = true
        layer?.add(rot, forKey: key)

        addPivotCompensation(key: key,
                             anglesRad: angles,
                             pivotBelow: h,
                             keyTimes: keyTimes,
                             duration: duration,
                             calculationMode: .cubic,
                             timingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    /// Additive translation keyframes that keep the point (0, -h) (h pixels
    /// below the anchor in root-layer y-up coords) stationary under a
    /// rotation keyframe. The rotation R(θ) carries that point to
    /// (h·sin θ, -h·cos θ) — a drift of (h·sin θ, h·(1−cos θ)) — so we
    /// apply the opposite.
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
    /// Carousel-style dots in the bubble's top-right corner, one per
    /// actionable alert in the rotation. The current dot is filled in the
    /// pink accent; the others are muted. Hidden for fresh alerts and
    /// single-entry replays (nothing to paginate through).
    private let indicatorDotsLayer = CALayer()

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
    private let maxBubbleWidth: CGFloat = 200
    private let minBubbleWidth: CGFloat = 120
    /// Per-present override that widens the bubble for content-heavy modes
    /// (currently: permission requests, which need room for a readable
    /// command preview alongside the Allow/Deny buttons).
    private var maxBubbleWidthOverride: CGFloat?

    private var action: [String: Any]?
    private var isUrgent: Bool = false
    private let autoDismissTimer = Scheduled()

    // Permission mode — when true, the whole-bubble click is disabled and
    // two buttons (Allow / Deny) handle resolution. No auto-dismiss.
    private var permissionMode: Bool = false
    private let allowButton = NSButton(title: "Allow", target: nil, action: nil)
    private let denyButton  = NSButton(title: "Deny",  target: nil, action: nil)
    private var onAllow: (() -> Void)?
    private var onDeny:  (() -> Void)?
    private let permissionButtonRowHeight: CGFloat = 22
    private let permissionButtonGap: CGFloat = 6

    /// Which edge the tail protrudes from. Set by `present()`; drives both
    /// the shape-path draw and the text-field positioning in `layoutContent`.
    private var tailSide: BubbleShape.Side = .bottom

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

        // Both fields are already configured as non-editable, non-bezeled
        // labels via `labelWithString:` / `wrappingLabelWithString:`; we only
        // need to wire the shared rendering knobs here.
        for f in [titleField, bodyField] {
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

        // Pagination dots container. Populated per-`present()` with one
        // child CAShapeLayer per actionable alert in the rotation. Sits in
        // the top-right of the bubble body.
        indicatorDotsLayer.masksToBounds = false
        indicatorDotsLayer.isHidden = true
        root.addSublayer(indicatorDotsLayer)

        // Custom pill buttons — NSButton's native bezel styles render as
        // near-invisible white-on-pink on the bubble's tinted background.
        // Explicit layer fills + attributed titles give us guaranteed
        // legible, on-theme pills.
        for (b, label, bgHex, fgHex) in [
            (allowButton, "Allow", "2E8B57", "FFFFFF"),
            (denyButton,  "Deny",  "FFFFFF", "2D2533"),
        ] {
            b.isBordered = false
            b.bezelStyle = .shadowlessSquare
            b.wantsLayer = true
            b.layer?.backgroundColor = AxolCharacterView.hexColor(bgHex)
            b.layer?.cornerRadius = 8
            b.layer?.masksToBounds = true
            if b === denyButton {
                b.layer?.borderWidth = 1
                b.layer?.borderColor = AxolCharacterView.hexColor("D6457A")
            }
            b.attributedTitle = NSAttributedString(
                string: label,
                attributes: [
                    .foregroundColor: NSColor.fromHex(fgHex),
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
                ])
            b.isHidden = true
            addSubview(b)
        }
        allowButton.target = self
        allowButton.action = #selector(handleAllow)
        denyButton.target  = self
        denyButton.action  = #selector(handleDeny)

        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleAllow() {
        let cb = onAllow
        onAllow = nil; onDeny = nil
        cb?()
        hide()
    }

    @objc private func handleDeny() {
        let cb = onDeny
        onAllow = nil; onDeny = nil
        cb?()
        hide()
    }

    /// Show a permission-request bubble with Allow/Deny buttons. No
    /// auto-dismiss — the user must answer, or the upstream connection
    /// has to close (handled externally via PendingPermissions.discard).
    func presentPermission(title: String, body: String?, icon: String? = nil,
                           tailSide: BubbleShape.Side = .bottom,
                           onAllow: @escaping () -> Void,
                           onDeny:  @escaping () -> Void) {
        self.action = nil
        self.isUrgent = true  // reuse urgent-pinned semantics: no auto-dismiss
        self.tailSide = tailSide
        self.permissionMode = true
        self.onAllow = onAllow
        self.onDeny  = onDeny

        indicatorDotsLayer.isHidden = true
        titleField.stringValue = title
        let bodyText = body?.trimmingCharacters(in: .whitespaces) ?? ""
        bodyField.stringValue = bodyText
        bodyField.isHidden = bodyText.isEmpty

        applyStyle(priority: "urgent", clickable: false)
        allowButton.isHidden = false
        denyButton.isHidden  = false

        // Icon prefix (same SF-Symbol / brand-glyph path the regular alert
        // bubble uses). Attach it inline with the title — keeps the visual
        // parity with Notification-style bubbles.
        if let iconName = icon?.trimmingCharacters(in: .whitespaces), !iconName.isEmpty {
            if let image = Self.iconImage(for: iconName) {
                let attachment = NSTextAttachment()
                attachment.image = image
                let attach = NSMutableAttributedString(attachment: attachment)
                attach.addAttribute(.baselineOffset, value: -1,
                                    range: NSRange(location: 0, length: attach.length))
                let para = NSMutableParagraphStyle()
                para.alignment = .center
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: titleField.font!,
                    .foregroundColor: titleField.textColor ?? NSColor.labelColor,
                    .paragraphStyle: para
                ]
                let full = NSMutableAttributedString()
                full.append(attach)
                full.append(NSAttributedString(string: "  " + title, attributes: attrs))
                full.addAttribute(.paragraphStyle, value: para,
                                  range: NSRange(location: 0, length: full.length))
                titleField.attributedStringValue = full
            } else {
                titleField.stringValue = "\(iconName) \(title)"
            }
        }

        // Permission bubbles get their own geometry: modestly wider than
        // alert bubbles with room for 2 wrapped lines so the Notification-
        // style body ("Claude needs your permission to use X") reads as a
        // full sentence instead of getting mid-word ellipsized.
        maxBubbleWidthOverride = 220
        bodyField.maximumNumberOfLines = 2
        bodyField.lineBreakMode = .byWordWrapping
        bodyField.usesSingleLineMode = false

        layoutContent()

        if let parent = superview {
            let idealX = (parent.frame.width - frame.width) / 2
            let adjustedX = Self.edgeAdjustedX(idealX: idealX, panelWidth: frame.width, in: parent)
            let adjustedY = Self.edgeAdjustedY(idealY: 128, panelHeight: frame.height, in: parent)
            frame.origin = CGPoint(x: adjustedX, y: adjustedY)
        }

        autoDismissTimer.cancel()
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            animator().alphaValue = 1.0
        }

        let fullText = title + " " + bodyText
        onShow?(Self.talkDurationFor(text: fullText))
    }

    /// Show the bubble with the given content + styling.
    ///
    /// `tailSide` picks which edge the bubble's pointer protrudes from:
    /// `.bottom` (default) is for full-mode bubbles that sit above the
    /// character; `.left` is for mini-mode bubbles that sit to her right.
    ///
    /// `cyclePosition` is `(current, total)` when the user is flipping
    /// through multiple pending alerts by clicking the character —
    /// renders as a small "N/M" in the top-right corner so the user knows
    /// where they are in the stack. Pass `nil` for fresh alerts and
    /// single-entry replays.
    func present(title: String, body: String?, priority: String, icon: String? = nil,
                 action: [String: Any]?, tailSide: BubbleShape.Side = .bottom,
                 cyclePosition: (Int, Int)? = nil) {
        self.action = action
        self.isUrgent = (priority == "urgent")
        self.tailSide = tailSide
        self.permissionMode = false
        self.allowButton.isHidden = true
        self.denyButton.isHidden = true
        self.maxBubbleWidthOverride = nil
        // Restore normal-alert body wrapping in case a prior permission
        // bubble narrowed it down.
        bodyField.maximumNumberOfLines = 4
        bodyField.lineBreakMode = .byWordWrapping
        bodyField.usesSingleLineMode = false
        let clickable = action != nil

        // Only surface the indicator when there's actually a stack to
        // page through — a single dot is noise.
        if let (current, total) = cyclePosition, total > 1 {
            buildIndicatorDots(current: current, total: total)
            indicatorDotsLayer.isHidden = false
        } else {
            indicatorDotsLayer.isHidden = true
        }

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
            let adjustedY = Self.edgeAdjustedY(idealY: 128, panelHeight: frame.height, in: parent)
            frame.origin = CGPoint(x: adjustedX, y: adjustedY)
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
        let talkDuration = Self.talkDurationFor(text: fullText)
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
            self.permissionMode = false
            self.allowButton.isHidden = true
            self.denyButton.isHidden = true
            self.onHide?()
        })
    }

    var isVisible: Bool { !isHidden && alphaValue > 0 }
    var isUrgentlyPinned: Bool { isVisible && isUrgent }
    var isPermissionMode: Bool { permissionMode }

    // MARK: - Click to run action

    override func hitTest(_ point: NSPoint) -> NSView? {
        // In permission mode, fall through to default hit-testing so the
        // Allow/Deny buttons receive clicks instead of the whole bubble.
        if permissionMode { return super.hitTest(point) }
        // Only accept clicks when visible and clickable (has an action)
        guard !isHidden, action != nil else { return nil }
        // The body field is a wrapping NSTextField — its default hit-testing
        // absorbs clicks on the wrapped glyphs and stops `mouseDown` from
        // propagating up to us. Claim the whole bubble rect so title, body,
        // icon, and padding alike all route to our click handler.
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
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
        let effectiveMaxBubbleWidth = maxBubbleWidthOverride ?? maxBubbleWidth
        let maxContentWidth = effectiveMaxBubbleWidth - 2 * horizPadding

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
            // wrapped height for up to 4 lines (1 line in permission mode).
            let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyField.font!]
            let bodyText = bodyField.stringValue as NSString
            let oneLineHeight = ceil(bodyText.size(withAttributes: bodyAttrs).height)
            let lineCap: CGFloat = permissionMode ? 2 : 4
            let maxBodyLines = oneLineHeight * lineCap
            let boundingRect = bodyText.boundingRect(
                with: CGSize(width: maxContentWidth, height: maxBodyLines),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: bodyAttrs
            )
            bodyWidth  = ceil(min(boundingRect.width, maxContentWidth))
            bodyHeight = ceil(min(boundingRect.height, maxBodyLines))
        }

        // Permission-mode button row: fit two buttons side-by-side with a
        // gap, plus a tight vertical gap above them. Ensure the bubble is
        // wide enough to hold both buttons comfortably.
        let permissionBodyButtonsGap: CGFloat = 4
        let buttonRowExtra: CGFloat = permissionMode
            ? (permissionButtonRowHeight + permissionBodyButtonsGap) : 0
        let buttonsMinContent: CGFloat = permissionMode ? 140 : 0

        let rawWidth = max(titleWidth, bodyWidth, buttonsMinContent)
        let contentWidth = max(min(rawWidth, maxContentWidth), minBubbleWidth - 2 * horizPadding)
        let bubbleWidth = contentWidth + 2 * horizPadding
        let gap: CGFloat = bodyField.isHidden ? 0 : 3
        let bodyAreaHeight = titleHeight + gap + bodyHeight + 2 * vertPadding + buttonRowExtra

        // A side tail pokes out of a vertical edge instead of the bottom, so
        // the overall bubble width grows by tailHeight while the height stays
        // flush with the text box — no extra vertical padding for a tail
        // stub that isn't there. Horizontal padding for the text shifts right
        // by the tail reserve too, so glyphs don't overlap the pointer.
        let totalWidth:   CGFloat
        let totalHeight:  CGFloat
        let xOffset:      CGFloat     // left-edge offset for text labels
        let yOffsetBase:  CGFloat     // bottom-edge offset for text labels
        switch tailSide {
        case .bottom:
            totalWidth = bubbleWidth
            totalHeight = bodyAreaHeight + tailHeight
            xOffset = 0
            yOffsetBase = tailHeight
        case .left:
            totalWidth = bubbleWidth + tailHeight
            totalHeight = bodyAreaHeight
            xOffset = tailHeight
            yOffsetBase = 0
        case .right:
            totalWidth = bubbleWidth + tailHeight
            totalHeight = bodyAreaHeight
            xOffset = 0
            yOffsetBase = 0
        }

        let origin = frame.origin
        frame = CGRect(x: origin.x, y: origin.y, width: totalWidth, height: totalHeight)

        // Labels — view origin is bottom-left, so measure Y from bottom.
        let titleY = yOffsetBase + bodyAreaHeight - vertPadding - titleHeight
        // Allow the title field to extend slightly into the horizontal padding
        // on each side — gives NSTextField extra rendering slack so the cell's
        // internal insets don't trigger truncation.
        let titleInset: CGFloat = 4
        titleField.frame = CGRect(
            x: xOffset + horizPadding - titleInset,
            y: titleY,
            width: contentWidth + 2 * titleInset,
            height: titleHeight
        )
        // When in permission mode the button row sits flush with the bottom
        // padding; body text (if any) stacks above it with a tight gap.
        let bodyBaseY = yOffsetBase + vertPadding
                      + (permissionMode ? permissionButtonRowHeight + permissionBodyButtonsGap : 0)
        if bodyField.isHidden {
            bodyField.frame = .zero
        } else {
            let bodyInset: CGFloat = 4
            bodyField.frame = CGRect(
                x: xOffset + horizPadding - bodyInset,
                y: bodyBaseY,
                width: contentWidth + 2 * bodyInset,
                height: bodyHeight
            )
        }

        if permissionMode {
            let buttonsY = yOffsetBase + vertPadding
            let available = contentWidth - permissionButtonGap
            let btnW = floor(available / 2)
            allowButton.frame = CGRect(
                x: xOffset + horizPadding,
                y: buttonsY,
                width: btnW,
                height: permissionButtonRowHeight
            )
            denyButton.frame = CGRect(
                x: xOffset + horizPadding + btnW + permissionButtonGap,
                y: buttonsY,
                width: btnW,
                height: permissionButtonRowHeight
            )
        }

        backgroundLayer.frame = bounds
        backgroundLayer.path = BubbleShape.path(
            bubbleRect: bounds,
            tailHeight: tailHeight,
            cornerRadius: cornerRadius,
            tailWidth: tailWidth,
            tailSide: tailSide
        )

        // Pagination dots centered along the top edge of the bubble body.
        // Computing bodyMinX accommodates the .left tail's body offset so
        // the row actually lines up under the visible center, not the
        // whole-frame center.
        if !indicatorDotsLayer.isHidden {
            let indW = indicatorDotsLayer.frame.width
            let indH = indicatorDotsLayer.frame.height
            let bodyMinX: CGFloat = (tailSide == .left) ? tailHeight : 0
            let bodyCenterX = bodyMinX + bubbleWidth / 2
            let bodyMaxY = yOffsetBase + bodyAreaHeight
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            indicatorDotsLayer.frame.origin = CGPoint(
                x: bodyCenterX - indW / 2,
                y: bodyMaxY - indH - 5
            )
            CATransaction.commit()
        }
    }

    /// Build one small dot per alert in the rotation, with the current
    /// index filled in the pink accent and the rest muted. Called from
    /// `present()` whenever the caller passes a multi-item cyclePosition.
    private func buildIndicatorDots(current: Int, total: Int) {
        let dotSize: CGFloat = 4
        let dotSpacing: CGFloat = 4
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicatorDotsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for i in 0..<total {
            let dot = CAShapeLayer()
            let rect = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.path = CGPath(ellipseIn: rect, transform: nil)
            let isCurrent = (i + 1 == current)
            // Softer palette than the full pink accent — the dots are
            // metadata, not a call to action. The active dot still reads
            // as warmer pink, the inactive ones fade into the bubble's
            // own light-pink backdrop.
            dot.fillColor = isCurrent
                ? AxolCharacterView.hexColor("E8A4C2")     // soft pink
                : AxolCharacterView.hexColor("EADDE3")     // barely-there gray
            dot.frame = CGRect(
                x: CGFloat(i) * (dotSize + dotSpacing),
                y: 0,
                width: dotSize,
                height: dotSize
            )
            indicatorDotsLayer.addSublayer(dot)
        }
        let totalWidth = CGFloat(total) * dotSize + CGFloat(max(total - 1, 0)) * dotSpacing
        indicatorDotsLayer.frame.size = CGSize(width: totalWidth, height: dotSize)
        CATransaction.commit()
    }

    static func durationFor(text: String, isAlert: Bool) -> TimeInterval {
        return isAlert ? 6.0 : 3.5
    }

    /// How long the mouth-flap animation should run. Scales with character
    /// count (~0.065s per char, ~15 chars/sec spoken pace) so short quips
    /// stop talking before the full bubble dismisses, and longer messages
    /// keep her mouth moving proportionally. Clamped 0.5–3.5s.
    static func talkDurationFor(text: String) -> TimeInterval {
        return max(0.5, min(3.5, Double(text.count) * 0.065))
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

    /// Clamp bubble origin-y so the bubble's top edge stays inside the
    /// parent (stage) view. Without this, a tall permission bubble with a
    /// long body and two-row layout can push its top off the top of the
    /// window — the title ends up clipped and invisible.
    ///
    /// We prefer the ideal y (so the tail keeps pointing at the character),
    /// but shift the bubble down if needed so `originY + panelHeight`
    /// doesn't exceed the parent height. A small margin keeps the shadow
    /// from flush-sitting on the window edge.
    static func edgeAdjustedY(idealY: CGFloat, panelHeight: CGFloat, in stage: NSView) -> CGFloat {
        let margin: CGFloat = 4
        let maxY = max(0, stage.frame.height - panelHeight - margin)
        return min(max(0, idealY), maxY)
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

// MARK: - History panel UI

/// Small pink-accent pill showing the alert's source field.
final class SourcePillView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, bgHex: String = "FFE8F2", fgHex: String = "D6457A") {
        super.init(frame: .zero)
        wantsLayer = true
        let bg = CALayer()
        layer = bg
        bg.cornerRadius = 8
        bg.backgroundColor = AxolCharacterView.hexColor(bgHex)

        label.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        label.textColor = NSColor.fromHex(fgHex)
        label.stringValue = text
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
        // For permission entries, the source pill doubles as a decision
        // chip: green "Allowed" / red "Denied" / muted "Pending". Saves
        // the duplicate "claude-code" pill (which the rest of the row
        // already signals via icon) and puts the decision at natural
        // reading position instead of floating in the right margin.
        if entry.isPermissionRequest {
            switch entry.permissionDecision {
            case "allow":
                self.sourcePill = SourcePillView(text: "Allowed", bgHex: "DDEFE3", fgHex: "2E8B57")
            case "deny":
                self.sourcePill = SourcePillView(text: "Denied",  bgHex: "F7DDDD", fgHex: "C0392B")
            default:
                self.sourcePill = SourcePillView(text: "Pending", bgHex: "EDE8EA", fgHex: "6E5F6B")
            }
        } else {
            self.sourcePill = SourcePillView(text: entry.source)
        }
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
        timeLabel.alignment = .right
        addSubview(timeLabel)

        addSubview(sourcePill)

        // Optional body line below
        if let bodyLabel = bodyLabel {
            bodyLabel.font = NSFont.systemFont(ofSize: 11)
            bodyLabel.textColor = NSColor.fromHex("998F96")
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

    /// Which edge the panel's tail protrudes from. `.bottom` is the default
    /// full-mode layout (panel above the character, tail down). `.right` is
    /// for mini mode where the panel sits to the left of the character and
    /// its tail points right at her. Set by the caller of `present(...)`.
    private var tailSide: BubbleShape.Side = .bottom

    var onRowClick: ((AlertEntry) -> Void)?
    var onHide: (() -> Void)?
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

    func present(in stage: NSView, entries: [AlertEntry],
                 tailSide: BubbleShape.Side = .bottom,
                 origin: NSPoint? = nil,
                 maxVisibleRows: Int? = nil) {
        self.tailSide = tailSide
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
        // In mini mode the caller caps visible rows to keep the panel
        // compact. Rows beyond that remain in the rowsContainer and are
        // reachable via the scroll view — the cap only shrinks the
        // visible viewport.
        let cappedHeight: CGFloat = {
            guard let n = maxVisibleRows, n > 0, n < rows.count else {
                return min(rowsTotalHeight, maxBodyHeight)
            }
            let firstN = rows.prefix(n).reduce(0) { $0 + $1.frame.height }
            return min(firstN, maxBodyHeight)
        }()
        let scrollHeight = cappedHeight

        // Dimensions differ depending on which edge carries the tail. A side
        // tail protrudes horizontally (adding tail reserve to width), a
        // bottom tail protrudes downward (adding to height).
        let panelHeight: CGFloat
        let panelTotalWidth: CGFloat
        let bodyXOffset: CGFloat    // shift content right when tail is on the left
        let bodyYOffset: CGFloat    // shift content up when tail is on the bottom
        switch tailSide {
        case .bottom:
            panelHeight = headerHeight + scrollHeight + tailHeight
            panelTotalWidth = panelWidth
            bodyXOffset = 0
            bodyYOffset = tailHeight
        case .left:
            panelHeight = headerHeight + scrollHeight
            panelTotalWidth = panelWidth + tailHeight
            bodyXOffset = tailHeight
            bodyYOffset = 0
        case .right:
            panelHeight = headerHeight + scrollHeight
            panelTotalWidth = panelWidth + tailHeight
            bodyXOffset = 0
            bodyYOffset = 0
        }

        let frameOrigin: NSPoint
        if let o = origin {
            frameOrigin = o
        } else {
            let idealX = (stage.frame.width - panelTotalWidth) / 2
            let adjustedX = BubbleView.edgeAdjustedX(idealX: idealX, panelWidth: panelTotalWidth, in: stage)
            frameOrigin = NSPoint(x: adjustedX, y: 128)
        }
        frame = CGRect(origin: frameOrigin,
                       size: NSSize(width: panelTotalWidth, height: panelHeight))
        backgroundLayer.frame = bounds
        backgroundLayer.path = BubbleShape.path(
            bubbleRect: bounds, tailHeight: tailHeight,
            cornerRadius: cornerRadius, tailWidth: tailWidth,
            tailSide: tailSide)

        // Header label sized to its text height (~14 for 10pt) and centered
        // vertically in the 30px header band.
        let labelH: CGFloat = 14
        let labelY = panelHeight - headerHeight + (headerHeight - labelH) / 2
        headerLabel.frame = CGRect(x: bodyXOffset + horizPadding + 2,
                                   y: labelY,
                                   width: panelWidth - 2 * horizPadding,
                                   height: labelH)
        dividerLayer.frame = CGRect(x: bodyXOffset, y: panelHeight - headerHeight,
                                    width: panelWidth, height: 1)

        // Scrollable rows area sits entirely below the header band.
        scrollView.frame = CGRect(x: bodyXOffset + horizPadding, y: bodyYOffset,
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

    func presentEmpty(in stage: NSView,
                      tailSide: BubbleShape.Side = .bottom,
                      origin: NSPoint? = nil) {
        self.tailSide = tailSide
        rowsContainer.subviews.forEach { $0.removeFromSuperview() }

        let empty = NSTextField(labelWithString: "No alerts yet.")
        empty.font = NSFont.systemFont(ofSize: 12)
        empty.textColor = NSColor.fromHex("A89CA3")
        empty.alignment = .left
        rowsContainer.addSubview(empty)

        let emptyBodyHeight: CGFloat = 28
        let panelHeight: CGFloat
        let panelTotalWidth: CGFloat
        let bodyXOffset: CGFloat
        let bodyYOffset: CGFloat
        switch tailSide {
        case .bottom:
            panelHeight = headerHeight + emptyBodyHeight + tailHeight
            panelTotalWidth = panelWidth
            bodyXOffset = 0
            bodyYOffset = tailHeight
        case .left:
            panelHeight = headerHeight + emptyBodyHeight
            panelTotalWidth = panelWidth + tailHeight
            bodyXOffset = tailHeight
            bodyYOffset = 0
        case .right:
            panelHeight = headerHeight + emptyBodyHeight
            panelTotalWidth = panelWidth + tailHeight
            bodyXOffset = 0
            bodyYOffset = 0
        }

        let frameOrigin: NSPoint
        if let o = origin {
            frameOrigin = o
        } else {
            let idealX = (stage.frame.width - panelTotalWidth) / 2
            let adjustedX = BubbleView.edgeAdjustedX(idealX: idealX, panelWidth: panelTotalWidth, in: stage)
            frameOrigin = NSPoint(x: adjustedX, y: 128)
        }
        frame = CGRect(origin: frameOrigin,
                       size: NSSize(width: panelTotalWidth, height: panelHeight))

        backgroundLayer.frame = bounds
        backgroundLayer.path = BubbleShape.path(
            bubbleRect: bounds, tailHeight: tailHeight,
            cornerRadius: cornerRadius, tailWidth: tailWidth,
            tailSide: tailSide)

        let labelH: CGFloat = 14
        headerLabel.frame = CGRect(x: bodyXOffset + horizPadding + 2,
                                   y: panelHeight - headerHeight + (headerHeight - labelH) / 2,
                                   width: panelWidth - 2 * horizPadding,
                                   height: labelH)
        dividerLayer.frame = CGRect(x: bodyXOffset, y: panelHeight - headerHeight,
                                    width: panelWidth, height: 1)

        let rowWidth = panelWidth - 2 * horizPadding
        scrollView.frame = CGRect(x: bodyXOffset + horizPadding, y: bodyYOffset,
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
            guard let self = self else { return }
            self.isHidden = true
            self.onHide?()
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
    /// Which edge the tail protrudes from. `.bottom` is the default (bubble
    /// above the character, tail pointing down). `.right` is for mini mode,
    /// where the bubble sits to the left of the character with its tail
    /// pointing right at her. `.left` exists for symmetry but isn't wired
    /// up anywhere today.
    enum Side { case bottom, left, right }

    static func path(bubbleRect: CGRect, tailHeight: CGFloat,
                     cornerRadius r: CGFloat, tailWidth: CGFloat,
                     tailSide: Side = .bottom) -> CGPath {
        let path = CGMutablePath()
        switch tailSide {
        case .bottom:
            let body = CGRect(x: bubbleRect.minX, y: bubbleRect.minY + tailHeight,
                              width: bubbleRect.width, height: bubbleRect.height - tailHeight)
            let tailCX = body.midX
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

        case .left:
            // Body is shifted right by the tail reserve; tail pokes out of
            // the body's left edge at mid-height.
            let body = CGRect(x: bubbleRect.minX + tailHeight, y: bubbleRect.minY,
                              width: bubbleRect.width - tailHeight, height: bubbleRect.height)
            let tailCY = body.midY
            path.move(to: CGPoint(x: body.minX + r, y: body.maxY))
            path.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                        tangent2End: CGPoint(x: body.maxX, y: body.maxY - r), radius: r)
            path.addLine(to: CGPoint(x: body.maxX, y: body.minY + r))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                        tangent2End: CGPoint(x: body.maxX - r, y: body.minY), radius: r)
            path.addLine(to: CGPoint(x: body.minX + r, y: body.minY))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                        tangent2End: CGPoint(x: body.minX, y: body.minY + r), radius: r)
            path.addLine(to: CGPoint(x: body.minX, y: tailCY - tailWidth / 2))
            path.addLine(to: CGPoint(x: bubbleRect.minX, y: tailCY))
            path.addLine(to: CGPoint(x: body.minX, y: tailCY + tailWidth / 2))
            path.addLine(to: CGPoint(x: body.minX, y: body.maxY - r))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                        tangent2End: CGPoint(x: body.minX + r, y: body.maxY), radius: r)

        case .right:
            // Body stays flush-left; tail pokes out of the body's right
            // edge at mid-height. Mirror of `.left`.
            let body = CGRect(x: bubbleRect.minX, y: bubbleRect.minY,
                              width: bubbleRect.width - tailHeight, height: bubbleRect.height)
            let tailCY = body.midY
            path.move(to: CGPoint(x: body.minX + r, y: body.maxY))
            path.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                        tangent2End: CGPoint(x: body.maxX, y: body.maxY - r), radius: r)
            path.addLine(to: CGPoint(x: body.maxX, y: tailCY + tailWidth / 2))
            path.addLine(to: CGPoint(x: bubbleRect.maxX, y: tailCY))
            path.addLine(to: CGPoint(x: body.maxX, y: tailCY - tailWidth / 2))
            path.addLine(to: CGPoint(x: body.maxX, y: body.minY + r))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                        tangent2End: CGPoint(x: body.maxX - r, y: body.minY), radius: r)
            path.addLine(to: CGPoint(x: body.minX + r, y: body.minY))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                        tangent2End: CGPoint(x: body.minX, y: body.minY + r), radius: r)
            path.addLine(to: CGPoint(x: body.minX, y: body.maxY - r))
            path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                        tangent2End: CGPoint(x: body.minX + r, y: body.maxY), radius: r)
        }
        path.closeSubpath()
        return path
    }
}

/// Three small blue bubbles that rise from above Axol's head when an
/// alert is unresolved, each with a slightly different horizontal drift.
final class WorryBubblesView: NSView {
    /// Hard cap on concurrent worry bubbles. Over ~6 it stops reading as
    /// "worried" and starts reading as a soda can.
    private let maxBubbles = 6
    private var bubbles: [CAShapeLayer] = []
    private var currentLevel: Int = 0
    private var currentTempo: Double = 1.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        // Three size/drift archetypes (left/right/waver) cycled across the
        // pool. Creating all maxBubbles layers upfront lets start(level:)
        // just activate a subset rather than allocate mid-animation.
        let sizes: [CGFloat] = [6, 5, 7]
        for i in 0..<maxBubbles {
            let size = sizes[i % sizes.count]
            let l = CAShapeLayer()
            let r = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
            l.path = CGPath(ellipseIn: r, transform: nil)
            l.fillColor   = AxolCharacterView.hexColor("B9E2F5")
            l.strokeColor = AxolCharacterView.hexColor("5EA6D0")
            l.lineWidth = 1
            l.bounds = r
            l.position = CGPoint(x: frame.width / 2, y: size / 2)
            l.opacity = 0
            bubbles.append(l)
            layer?.addSublayer(l)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Run worry bubbles with density = `level` (clamped 1..maxBubbles)
    /// and cycle duration scaled by `tempo` (1.0 = default, <1.0 =
    /// faster — used for urgent alerts). Idempotent when called with the
    /// same params.
    func start(level: Int, tempo: Double = 1.0) {
        let desired = max(1, min(level, maxBubbles))
        if currentLevel == desired && currentTempo == tempo { return }
        currentLevel = desired
        currentTempo = tempo

        // Left/right/waver rise paths. Y values in Cocoa coords (up
        // positive). Keyed to [0,1]; duration scales via `tempo`.
        let paths: [[(t: Double, dx: CGFloat, dy: CGFloat, scale: CGFloat, opacity: Float)]] = [
            [(0,  0, 0, 0.4, 0.0), (0.15, 0, 0, 0.4, 0.85),
             (0.5, 3, 18, 0.95, 0.85), (0.85, 5, 32, 1.05, 0.7), (1.0, 7, 40, 1.1, 0.0)],
            [(0,  0, 0, 0.4, 0.0), (0.15, 0, 0, 0.4, 0.85),
             (0.5, -2, 18, 0.95, 0.85), (0.85, -6, 32, 1.05, 0.7), (1.0, -8, 40, 1.1, 0.0)],
            [(0,  0, 0, 0.4, 0.0), (0.15, 0, 0, 0.4, 0.85),
             (0.5, 2, 19, 0.95, 0.85), (0.85, 1, 33, 1.05, 0.7), (1.0, 3, 40, 1.1, 0.0)],
        ]
        let duration = 2.6 * tempo
        let step = duration / Double(desired)
        let now = CACurrentMediaTime()

        for (i, bubble) in bubbles.enumerated() {
            bubble.removeAllAnimations()
            bubble.opacity = 0
            if i >= desired { continue }

            let frames = paths[i % paths.count]
            let transformAnim = CAKeyframeAnimation(keyPath: "transform")
            transformAnim.values = frames.map { frame -> CATransform3D in
                var t = CATransform3DIdentity
                t = CATransform3DTranslate(t, frame.dx, frame.dy, 0)
                t = CATransform3DScale(t, frame.scale, frame.scale, 1)
                return t
            }
            transformAnim.keyTimes = frames.map { NSNumber(value: $0.t) }
            transformAnim.duration = duration
            transformAnim.repeatCount = .infinity
            transformAnim.beginTime = now + Double(i) * step
            transformAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
            opacityAnim.values   = frames.map { NSNumber(value: $0.opacity) }
            opacityAnim.keyTimes = frames.map { NSNumber(value: $0.t) }
            opacityAnim.duration = duration
            opacityAnim.repeatCount = .infinity
            opacityAnim.beginTime = now + Double(i) * step
            opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            bubble.add(transformAnim, forKey: "rise-transform")
            bubble.add(opacityAnim,   forKey: "rise-opacity")
        }
    }

    func stop() {
        currentLevel = 0
        currentTempo = 1.0
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
/// when the user minimizes to micro mode via the right-click menu.
/// Smaller than mini mode — occupies a 48×48 footprint with the character
/// rendered at 40px wide. No ambient animations (she stays still here).
final class MicroView: NSView {
    static let size: CGFloat = 48
    let character: AxolCharacterView
    private let badgeLayer = CAShapeLayer()
    private let badgeLabel = NSTextField(labelWithString: "")

    var onTap: (() -> Void)?
    var onCmdClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDragDelta: ((CGFloat, CGFloat) -> Void)?
    var onDragTo: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    private var isDragging = false
    private var moveAccum: CGFloat = 0
    private var lastMouseLocation: CGPoint = .zero

    init(frame: NSRect, theme: Theme = .builtin) {
        // Reuse AxolCharacterView for visual consistency but keep it static
        // (no startAmbientAnimations call).
        let charWidth: CGFloat = 40
        let charHeight = charWidth * (AxolCharacterView.svgHeight / AxolCharacterView.svgWidth)
        let charX = (frame.width - charWidth) / 2
        let charY = (frame.height - charHeight) / 2
        character = AxolCharacterView(
            frame: NSRect(x: charX, y: charY, width: charWidth, height: charHeight),
            theme: theme
        )

        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        addSubview(character)

        // The inner AxolCharacterView handles its own mouse events; forward
        // them up to the micro view so taps/drags reach the app delegate.
        // Double-click also triggers onTap so rapid clicks don't feel inert
        // — micro has nothing meaningful to do with a double-click that
        // differs from a single-click (both mean "expand").
        character.onLeftClick   = { [weak self] in self?.onTap?() }
        character.onDoubleClick = { [weak self] in self?.onTap?() }
        character.onCmdClick    = { [weak self] in self?.onCmdClick?() }
        character.onRightClick  = { [weak self] in self?.onRightClick?() }
        character.onDragDelta   = { [weak self] dx, dy in self?.onDragDelta?(dx, dy) }
        character.onDragTo      = { [weak self] origin in self?.onDragTo?(origin) }
        character.onDragEnd     = { [weak self] in self?.onDragEnd?() }

        badgeLayer.fillColor = AxolCharacterView.hexColor("4A90E2")
        badgeLayer.isHidden = true
        badgeLayer.shadowColor = NSColor.black.cgColor
        badgeLayer.shadowOpacity = 0.2
        badgeLayer.shadowRadius = 2
        badgeLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(badgeLayer)

        badgeLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = .white
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
        let badgeH: CGFloat = 14
        let badgeW = max(badgeH, ceil(textSize.width) + 8)
        let rect = CGRect(x: 1,
                          y: bounds.height - badgeH - 3,
                          width: badgeW, height: badgeH)
        badgeLayer.frame = rect
        badgeLayer.path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size),
                                 cornerWidth: badgeH / 2, cornerHeight: badgeH / 2, transform: nil)
        badgeLabel.frame = rect.insetBy(dx: 0, dy: 0)
    }

    override func layout() {
        super.layout()
        if !badgeLayer.isHidden { layoutBadge() }
    }

    // Mouse events are handled by the inner AxolCharacterView whose callbacks
    // we wire to our own onTap / onDragDelta / onDragEnd in init.
}

/// Tiny blue alert-count pill shown in mini mode. Non-interactive — the
/// character underneath still handles clicks/drags through it. Unlike the
/// micro-mode badge, this one is laid out in isolation (no character) and
/// only appears when unseen alerts are stacked up.
final class MiniBadgeView: NSView {
    private let badgeLayer = CAShapeLayer()
    private let badgeLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        badgeLayer.fillColor = AxolCharacterView.hexColor("4A90E2")
        badgeLayer.shadowColor = NSColor.black.cgColor
        badgeLayer.shadowOpacity = 0.18
        badgeLayer.shadowRadius = 2
        badgeLayer.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(badgeLayer)

        badgeLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        addSubview(badgeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Passes all clicks through — the character view sits below and should
    // receive drag/click events even when the badge overlaps its head.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(count: Int) {
        if count <= 0 {
            isHidden = true
            return
        }
        isHidden = false
        badgeLabel.stringValue = count > 99 ? "99+" : "\(count)"
        let text = badgeLabel.stringValue
        let textSize = (text as NSString).size(withAttributes: [.font: badgeLabel.font!])
        let h: CGFloat = 14
        let w = max(h, ceil(textSize.width) + 8)
        frame.size = CGSize(width: w, height: h)
        badgeLayer.frame = bounds
        badgeLayer.path = CGPath(roundedRect: bounds, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        badgeLabel.frame = bounds.insetBy(dx: 0, dy: 0)
    }
}

/// Container view that composes the character + overlays + bubble + micro.
/// Subview order matters for z-order: later subviews paint on top.
final class StageView: NSView {
    let character: AxolCharacterView
    /// Dedicated small-render character used while in mini mode. Rendered
    /// at ~60×54 so it doesn't need a runtime scale transform — the
    /// AxolCharacterView init already sets the CALayer content scale from
    /// the frame width, and transform-based scaling interacts unreliably
    /// with layout when the view stays on screen long-term (unlike the
    /// 300ms micro-mode animation).
    let miniCharacter: AxolCharacterView
    let worryBubbles: WorryBubblesView
    let zs: ZsView
    let bubble: BubbleView
    let history: HistoryView
    let micro: MicroView
    let miniBadge: MiniBadgeView

    /// Render size used for the mini-mode character instance. Small enough to
    /// tuck into the 62×56 mini window with ~1–2 px of margin.
    static let miniCharacterRenderWidth: CGFloat = 58

    init(frame: NSRect, theme: Theme = .builtin) {
        let charSize = NSSize(width: AxolCharacterView.renderWidth,
                              height: AxolCharacterView.renderWidth * (AxolCharacterView.svgHeight / AxolCharacterView.svgWidth))
        let charX = (frame.width - charSize.width) / 2
        let charY: CGFloat = 4
        character = AxolCharacterView(
            frame: NSRect(origin: CGPoint(x: charX, y: charY), size: charSize),
            theme: theme
        )

        let miniCharW = Self.miniCharacterRenderWidth
        let miniCharH = miniCharW * (AxolCharacterView.svgHeight / AxolCharacterView.svgWidth)
        miniCharacter = AxolCharacterView(
            frame: NSRect(x: 0, y: 0, width: miniCharW, height: miniCharH),
            theme: theme
        )
        miniCharacter.isHidden = true

        let overlayWidth: CGFloat = 40
        let overlayHeight: CGFloat = 80
        let overlayX = (frame.width - overlayWidth) / 2
        let overlayFrame = NSRect(x: overlayX, y: 118, width: overlayWidth, height: overlayHeight)
        worryBubbles = WorryBubblesView(frame: overlayFrame)
        zs           = ZsView(frame: overlayFrame)

        bubble = BubbleView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        history = HistoryView(frame: NSRect(x: 0, y: 0, width: 236, height: 100))
        micro = MicroView(frame: NSRect(x: 0, y: 0, width: MicroView.size, height: MicroView.size),
                          theme: theme)
        micro.isHidden = true
        miniBadge = MiniBadgeView(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
        miniBadge.isHidden = true

        super.init(frame: frame)
        wantsLayer = true
        addSubview(character)
        addSubview(miniCharacter)
        addSubview(worryBubbles)
        addSubview(zs)
        addSubview(bubble)
        addSubview(history)
        addSubview(micro)
        // The mini badge is a child of the mini character (not stage) so it
        // follows her through drags and ambient animations automatically,
        // without a per-frame reposition dance. `layoutMiniBadge` still runs
        // once on show/update to size the pill to its numeric content.
        miniCharacter.addSubview(miniBadge)
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

    func loadSavedMode() -> AxolMode {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["mode"] as? String else { return .full }
        // `"compact"` was the pre-rename name for `.micro`; migrate silently
        // so users who saved their state before the rename aren't dropped
        // back to full on first launch after upgrading.
        if raw == "compact" { return .micro }
        return AxolMode(rawValue: raw) ?? .full
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
        let dict: [String: Any] = ["x": o.x, "y": o.y, "mode": mode.rawValue]
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
            let size = NSSize(width: w, height: h)
            guard let saved = loadSavedOrigin(),
                  originFitsOnAScreen(saved, size: size) else {
                return defaultOrigin
            }
            // Saved origin may have been recorded at a smaller (micro)
            // size. Clamp inline (self.window isn't assigned yet here, so
            // we can't call clampOriginToScreen which dereferences it).
            let margin: CGFloat = 4
            var o = saved
            o.x = max(visible.minX + margin, min(o.x, visible.maxX - size.width  - margin))
            o.y = max(visible.minY + margin, min(o.y, visible.maxY - size.height - margin))
            return o
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

        let theme = ThemeLoader.loadAtStartup()
        stage = StageView(frame: NSRect(x: 0, y: 0, width: w, height: h), theme: theme)
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

        server = AxolServer(
            onEvent: { [weak self] data in
                self?.forwardToUI(data)
            },
            onPermission: { [weak self] requestId, payload, conn in
                guard let self = self else { return }
                PendingPermissions.shared.register(requestId: requestId, connection: conn)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .failed, .cancelled:
                        PendingPermissions.shared.discard(requestId: requestId)
                        DispatchQueue.main.async { [weak self] in
                            self?.dismissPermissionBubble(requestId: requestId)
                        }
                    default: break
                    }
                }
                self.presentPermissionBubble(requestId: requestId, payload: payload)
            })
        server?.start(port: 47329)

        // Restore saved mode from last run. Skip for .full since we already
        // initialized the window at full size above — setting it to .full
        // would be a no-op cycle.
        let saved = loadSavedMode()
        if saved != .full {
            setMode(saved)
        }
    }

    /// Routes an incoming server payload through the adapter pipeline and
    /// dispatches the resulting envelope to the native bubble on the main queue.
    func forwardToUI(_ data: [String: Any]) {
        var candidate: [String: Any]?
        if data["title"] is String {
            candidate = data
        } else {
            switch adapters.route(data) {
            case .rendered(let env, _):
                candidate = env
            case .skipped(let name):
                NSLog("axol: skipped by adapter \(name)")
                return
            case .noMatch:
                break
            }
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
            let entryId = priority != "low" ? self.alertStore.push(envelope: envelope).id : nil
            self.updateWorryBubbles()

            // If the history panel is open, update it in place and skip the
            // bubble — matches the "appended to the list" flow.
            if self.stage.history.isVisible {
                if priority != "low" {
                    self.stage.history.present(in: self.stage, entries: self.alertStore.entries)
                }
                return
            }

            // Permission bubbles are fully modal — nothing (not even another
            // urgent alert) replaces them. CC is literally blocked waiting
            // on the user's click. Queue the new alert so it surfaces after
            // the permission resolves.
            if self.stage.bubble.isPermissionMode {
                if priority != "low"
                   && self.pendingBubbles.count < self.pendingBubbleCap {
                    self.pendingBubbles.append(PendingBubble(envelope: envelope, attention: attention, entryId: entryId))
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
                    self.pendingBubbles.append(PendingBubble(envelope: envelope, attention: attention, entryId: entryId))
                }
                return
            }

            if self.isNapping { self.endNap() }
            self.presentBubbleFromEnvelope(envelope, attention: attention, entryId: entryId)
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
                // Resolve tilde and any `..` segments, then follow symlinks, so
                // a path like `~/../../etc/passwd` or a user-placed symlink
                // to outside $HOME can't escape the home prefix. `hasPrefix`
                // on the pre-canonicalized string is not enough.
                let expanded = (path as NSString).expandingTildeInPath
                let canonical = URL(fileURLWithPath: expanded)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                let home = URL(fileURLWithPath: NSHomeDirectory())
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                    .path
                if canonical.hasPrefix(home + "/") && FileManager.default.fileExists(atPath: canonical) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: canonical)])
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

    // MARK: - Load at startup (LaunchAgent)

    private static let launchAgentLabel = "com.axol.agent"
    private static var launchAgentPlistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private var loadAtStartupEnabled: Bool {
        FileManager.default.fileExists(atPath: Self.launchAgentPlistURL.path)
    }

    @objc private func toggleLoadAtStartup(_ sender: NSMenuItem) {
        let url = Self.launchAgentPlistURL
        let label = Self.launchAgentLabel
        let uid = getuid()
        if loadAtStartupEnabled {
            // bootout first so the running job doesn't linger after the
            // plist is gone. Failures are non-fatal — `launchctl` prints
            // its own error; we still remove the file.
            _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
            try? FileManager.default.removeItem(at: url)
        } else {
            guard let exe = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0) else { return }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            do {
                try data.write(to: url)
                _ = runLaunchctl(["bootstrap", "gui/\(uid)", url.path])
            } catch {
                NSLog("axol: could not write LaunchAgent plist: \(error)")
            }
        }
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError  = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            NSLog("axol: launchctl \(args.joined(separator: " ")) failed: \(error)")
            return -1
        }
    }

    func showMenu() {
        let menu = NSMenu()

        // Three explicit size options — radio-style checkmark on the
        // current mode. Users can also cmd-click the character to cycle
        // through these without opening the menu.
        for (title, target, selector) in [
            ("Full",    AxolMode.full,    #selector(setModeFull)),
            ("Mini",    AxolMode.mini,    #selector(setModeMini)),
            ("Micro", AxolMode.micro, #selector(setModeMicroAction)),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.state = (mode == target) ? .on : .off
            menu.addItem(item)
        }

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

        let startupItem = NSMenuItem(title: "Load at Startup",
                                     action: #selector(toggleLoadAtStartup(_:)),
                                     keyEquivalent: "")
        startupItem.target = self
        startupItem.state = loadAtStartupEnabled ? .on : .off
        menu.addItem(startupItem)

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
        stage.character.onDragTo = { [weak self] origin in
            guard let self = self, let w = self.window else { return }
            w.setFrameOrigin(self.clampOriginToScreen(origin, size: w.frame.size))
            self.savePositionDebounced()
        }
        stage.character.onLeftClick = { [weak self] in
            guard let self = self else { return }
            if self.stage.history.isVisible { self.stage.history.hide(); return }
            if self.isNapping { self.endNap(); return }
            // Cycle through recent actionable alerts if any; otherwise quip.
            // Clicked-through entries stay in history but drop out of the
            // bubble rotation here.
            let actionable = self.alertStore.entries.filter { $0.action != nil && $0.actionedAt == nil }
            if !actionable.isEmpty {
                let idx = self.historyCycleIndex % actionable.count
                let entry = actionable[idx]
                self.historyCycleIndex = (self.historyCycleIndex + 1) % actionable.count
                // Pass (1-based position, total) so the bubble can render a
                // subtle "2/3" indicator while the user flips through.
                self.replay(entry: entry, cyclePosition: (idx + 1, actionable.count))
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
            self?.cycleMode()
        }
        stage.character.onOptClick = { [weak self] in
            self?.playRandomIdleForUser()
        }

        // miniCharacter mirrors the same handlers so mini mode supports the
        // same drag / click / cmd-click / double-click interactions.
        stage.miniCharacter.onLeftClick   = { [weak self] in self?.stage.character.onLeftClick?() }
        stage.miniCharacter.onCmdClick    = { [weak self] in self?.cycleMode() }
        stage.miniCharacter.onOptClick    = { [weak self] in self?.playRandomIdleForUser() }
        stage.miniCharacter.onRightClick  = { [weak self] in self?.showMenu() }
        stage.miniCharacter.onDoubleClick = { [weak self] in self?.showHistory() }
        stage.miniCharacter.onDragStart   = { [weak self] in
            if self?.isNapping == true { self?.endNap() }
        }
        stage.miniCharacter.onDragTo = { [weak self] origin in
            guard let self = self, let w = self.window else { return }
            w.setFrameOrigin(self.clampOriginToScreen(origin, size: w.frame.size))
            self.savePositionDebounced()
        }

        stage.bubble.onAction = { [weak self] action in
            guard let self = self else { return }
            self.runAction(action)
            if let id = self.currentBubbleEntryId {
                self.alertStore.markActioned(id: id)
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
            self.currentBubbleEntryId = nil
            self.stage.character.stopTalking()
            self.updateWorryBubbles()
            // Empty-collapse the mini window back to character-only when
            // nothing else is currently taking up the side-panel slot. Use
            // `isHidden` rather than the `isVisible` computed property —
            // `isVisible` gates on `alphaValue > 0`, and that's briefly
            // false during the history panel's fade-in. showHistory() hides
            // an open bubble, which fires this onHide ~220 ms later, so
            // the history fade can still be mid-ramp when we read it.
            if self.mode == .mini
                && self.pendingBubbles.isEmpty
                && self.stage.history.isHidden {
                self.collapseMiniToEmpty()
            }
            self.drainPendingBubbles()
        }

        stage.history.onRowClick = { [weak self] entry in
            guard let self = self else { return }
            if let action = entry.action {
                self.runAction(action)
                self.bumpWound(self.woundHandled)
                self.alertStore.markActioned(id: entry.id)
            } else {
                self.alertStore.markSeen(id: entry.id)
            }
            self.updateWorryBubbles()
        }

        stage.micro.onTap = { [weak self] in
            self?.setMode(.full)
        }
        stage.micro.onCmdClick = { [weak self] in
            self?.cycleMode()
        }
        stage.micro.onRightClick = { [weak self] in
            self?.showMenu()
        }
        stage.micro.onDragTo = { [weak self] origin in
            guard let self = self, let w = self.window else { return }
            w.setFrameOrigin(self.clampOriginToScreen(origin, size: w.frame.size))
            self.savePositionDebounced()
        }
    }

    /// Replays an archived alert in the bubble.
    private func replay(entry: AlertEntry, cyclePosition: (Int, Int)? = nil) {
        presentBubbleInCurrentMode(title: entry.title, body: entry.body,
                                   priority: entry.priority, icon: entry.icon,
                                   action: entry.action,
                                   cyclePosition: cyclePosition)
        currentBubbleEntryId = entry.id
        alertStore.markSeen(id: entry.id)
        updateWorryBubbles()
    }

    /// Every bubble-entry code path (fresh alert, replay, quip, wave, about)
    /// goes through this helper so the mini-mode side-tail + reposition is
    /// applied consistently. Without it, a direct `stage.bubble.present(...)`
    /// paints a tail-below-character bubble over top of mini-mode's
    /// character-on-the-right layout.
    private func presentBubbleInCurrentMode(title: String, body: String?,
                                            priority: String, icon: String? = nil,
                                            action: [String: Any]?,
                                            cyclePosition: (Int, Int)? = nil) {
        let side: BubbleShape.Side = (mode == .mini) ? .right : .bottom
        stage.bubble.present(title: title, body: body, priority: priority,
                             icon: icon, action: action, tailSide: side,
                             cyclePosition: cyclePosition)
        if mode == .mini {
            placeMiniBubble()
        }
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
        let entryId: Int?
    }
    private var pendingBubbles: [PendingBubble] = []
    private let pendingBubbleCap: Int = 4
    private var lastBubbleOpenedAt: Date?
    private let minBubbleDisplayTime: TimeInterval = 2.5

    /// ID of the archived alert currently shown in the bubble, if any.
    /// Set in the present paths; cleared on hide. Used to mark the exact
    /// entry as actioned when the user clicks the bubble — the bubble itself
    /// only carries the action payload, not the entry identity.
    private var currentBubbleEntryId: Int?

    /// request_id of the permission request currently displayed in the
    /// bubble, if any. Lets an upstream client-disconnect (handled in
    /// Server.swift via connection stateUpdateHandler) auto-dismiss the
    /// bubble in the MVP — without this, a killed Claude Code session
    /// would leave a stale permission bubble on screen.
    private var currentPermissionId: String?

    /// Repeating nudge timer — keeps Axol animating while a permission
    /// bubble is open so the user notices even if they looked away.
    /// Alternates wave → wiggle each tick for variety.
    private let permissionNudgeTimer = Scheduled()
    private let permissionNudgeInterval: TimeInterval = 5.0
    private var permissionNudgeToggle: Bool = false

    /// Pull a minimal title/body out of a Claude Code PermissionRequest
    /// payload. MVP: don't attempt suggestion rendering or argument pretty-
    /// printing — just show the tool name and let the user decide.
    /// Build a permission bubble in the same visual shape as a CC
    /// Notification-style alert: project-folder as title, a short
    /// "Claude needs your permission to use X" body, Claude icon.
    private static func permissionTitleBody(from payload: [String: Any]) -> (title: String, body: String, icon: String) {
        let tool = (payload["tool_name"] as? String) ?? "tool"
        var title = "Claude"
        if let cwd = payload["cwd"] as? String,
           let leaf = (cwd as NSString).pathComponents.last,
           !leaf.isEmpty, leaf != "/" {
            title = leaf
        } else if let sid = payload["session_id"] as? String, sid.count >= 4 {
            title = "Claude · \(String(sid.suffix(4)))"
        }
        let body = "Claude needs your permission to use \(tool)"
        return (title, body, "claude")
    }

    func presentPermissionBubble(requestId: String, payload: [String: Any]) {
        let built = Self.permissionTitleBody(from: payload)

        // If something else is on screen, drop it — permission requests are
        // modal-intent: Claude Code's tool call is blocked waiting on this.
        if stage.bubble.isVisible { stage.bubble.hide() }

        // Archive the permission request in the alert history so it shows
        // up in the recent-alerts panel with a decision dot once answered.
        // `kind: "permission"` tags it for the row renderer; we stamp the
        // decision later via setPermissionDecision.
        let archiveEnvelope: [String: Any] = [
            "title": built.title,
            "body": built.body,
            "icon": built.icon,
            "priority": "normal",
            "source": "claude-code",
            "kind": "permission"
        ]
        let archived = alertStore.push(envelope: archiveEnvelope)
        let entryId = archived.id
        updateWorryBubbles()

        currentPermissionId = requestId
        currentBubbleEntryId = entryId
        let side: BubbleShape.Side = (mode == .mini) ? .right : .bottom
        stage.bubble.presentPermission(
            title: built.title, body: built.body, icon: built.icon, tailSide: side,
            onAllow: { [weak self] in
                PendingPermissions.shared.resolve(requestId: requestId, behavior: "allow")
                self?.alertStore.setPermissionDecision(id: entryId, decision: "allow")
                self?.currentPermissionId = nil
                self?.permissionNudgeTimer.cancel()
                self?.updateWorryBubbles()
            },
            onDeny: { [weak self] in
                PendingPermissions.shared.resolve(requestId: requestId, behavior: "deny")
                self?.alertStore.setPermissionDecision(id: entryId, decision: "deny")
                self?.currentPermissionId = nil
                self?.permissionNudgeTimer.cancel()
                self?.updateWorryBubbles()
            }
        )
        if mode == .mini { placeMiniBubble() }

        // Initial big bounce + schedule recurring wave/wiggle nudges
        // until answered.
        if isNapping { endNap() }
        permissionNudgeToggle = false
        stage.character.playAttentionHop()
        scheduleNextPermissionNudge()
    }

    private func scheduleNextPermissionNudge() {
        permissionNudgeTimer.run(after: permissionNudgeInterval) { [weak self] in
            guard let self = self else { return }
            guard self.stage.bubble.isPermissionMode,
                  self.stage.bubble.isVisible else { return }
            if self.permissionNudgeToggle {
                self.stage.character.playIdle(.wiggle)
            } else {
                self.stage.character.wave()
            }
            self.permissionNudgeToggle.toggle()
            self.scheduleNextPermissionNudge()
        }
    }

    /// Called when the upstream connection dies before the user answered.
    /// If the on-screen bubble is for this requestId, hide it.
    func dismissPermissionBubble(requestId: String) {
        if currentPermissionId == requestId {
            currentPermissionId = nil
            permissionNudgeTimer.cancel()
            if stage.bubble.isVisible && stage.bubble.isPermissionMode {
                stage.bubble.hide()
            }
        }
    }

    private func drainPendingBubbles() {
        guard !pendingBubbles.isEmpty,
              !stage.history.isVisible,
              !stage.bubble.isVisible else { return }
        let next = pendingBubbles.removeFirst()
        presentBubbleFromEnvelope(next.envelope, attention: next.attention, entryId: next.entryId)
    }

    /// Single-use helper that turns a validated envelope into a bubble +
    /// attention one-shot. Used by forwardToUI and drainPendingBubbles so
    /// both paths go through the same presentation logic.
    private func presentBubbleFromEnvelope(_ envelope: [String: Any], attention: String?, entryId: Int?) {
        let title    = (envelope["title"] as? String) ?? ""
        let body     = envelope["body"] as? String
        let priority = (envelope["priority"] as? String) ?? "normal"
        let icon     = envelope["icon"] as? String
        let action   = (envelope["actions"] as? [[String: Any]])?.first
        presentBubbleInCurrentMode(title: title, body: body, priority: priority,
                                   icon: icon, action: action)
        currentBubbleEntryId = entryId
        lastBubbleOpenedAt = Date()

        let effective: String = {
            if let a = attention, a == "wiggle" || a == "hop" || a == "none" { return a }
            return priority == "urgent" ? "wiggle" : "none"
        }()
        if effective == "wiggle" { stage.character.playIdle(.wiggle) }
        if effective == "hop"    { stage.character.playIdle(.hop) }
    }

    private func updateWorryBubbles() {
        // Worry bubbles only make sense in full mode. Mini and micro both
        // show a numeric badge instead; worry dots would collide visually
        // with the side bubble / micro icon.
        let shouldRun = alertStore.hasUnseenAlerts
                        && !stage.bubble.isVisible
                        && !stage.history.isVisible
                        && mode == .full
        if shouldRun {
            // Density scales with backlog; urgent entries accelerate the
            // cycle so a single urgent alert still feels more insistent
            // than a pile of normal ones.
            let level = alertStore.unseenActionableCount
            let tempo = alertStore.hasUrgentUnseenAlert ? 0.65 : 1.0
            stage.worryBubbles.start(level: level, tempo: tempo)
        } else {
            stage.worryBubbles.stop()
        }
        switch mode {
        case .micro:
            stage.micro.updateBadge(count: alertStore.unseenCount)
        case .mini:
            stage.miniBadge.update(count: alertStore.unseenCount)
            layoutMiniBadge()
        case .full:
            break
        }
    }

    // MARK: - Mode transitions (full / mini / micro)

    /// Current size-mode. Source of truth for which of the three layout
    /// branches is active; persisted via `savePosition()` so a quit+relaunch
    /// restores whichever mode the user was in.
    private var mode: AxolMode = .full
    private var savedFullFrame: NSRect?

    /// Target window size for mini mode in its two sub-states. The
    /// with-bubble size must fit `BubbleView.maxBubbleWidth` (200) plus the
    /// tail reserve (6) plus the character slot (~60) plus a little margin.
    private static let miniEmptySize = NSSize(width: 62, height: 56)
    private static let miniWithBubbleSize = NSSize(width: 290, height: 80)
    /// Transform scale applied to `stage.character` when in mini mode. The
    /// full character is rendered at `renderWidth=150` and we want her to
    /// fill ~50px of the 62px mini footprint, so 50/150 ≈ 0.33.
    private static let miniCharacterScale: CGFloat = 0.33
    /// Transform scale used by the micro animation. Used here too when
    /// transitioning mini → micro so the character doesn't pop larger
    /// before the swap to MicroView.
    private static let microCharacterScale: CGFloat = 0.38

    private func cycleMode() {
        setMode(mode.next)
    }

    private func setMode(_ target: AxolMode) {
        guard target != mode else { return }
        let previous = mode
        // Use the polished animated transitions for direct full ↔ micro.
        // Mini transitions are instant — cheap enough to not warrant the
        // choreography apparatus, and the mini footprint is small enough
        // that a scale-animation doesn't read as much more than a blink.
        switch (previous, target) {
        case (.full, .micro):
            mode = .micro
            shrinkToMicro()
        case (.micro, .full):
            mode = .full
            expandToFull()
        case (.full, .mini):
            mode = .mini
            enterMini(from: .full)
        case (.mini, .full):
            mode = .full
            exitMini(to: .full)
        case (.mini, .micro):
            mode = .micro
            exitMini(to: .micro)
        case (.micro, .mini):
            mode = .mini
            enterMini(from: .micro)
        default:
            break
        }
        savePositionDebounced()
    }

    /// CATransform3D that scales a view around its own geometric center —
    /// works for any anchor point (layer-backed NSViews default to (0,0)
    /// on macOS, so `transform.scale` alone would pivot at the bottom-left).
    fileprivate static func centeredScale(_ s: CGFloat, for view: NSView) -> CATransform3D {
        let cx = view.bounds.width  / 2
        let cy = view.bounds.height / 2
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t,  cx,  cy, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    private func shrinkToMicro() {
        savedFullFrame = window.frame

        // Hide transient overlays but leave the character visible for phase 1.
        stage.bubble.hide()
        stage.history.hide()
        stage.worryBubbles.isHidden = true
        stage.zs.isHidden = true
        stage.worryBubbles.stop()
        stage.zs.stop()
        stage.character.stopAmbientAnimations()
        // Kill any in-flight idle (peek/tilt add additive translation
        // keyframes for their lowered pivot — if they're still playing when
        // we start the scale animation, the residual translation reads as a
        // diagonal drift on top of the pure shrink.
        stage.character.stopIdles()

        let s = MicroView.size
        let old = window.frame
        let targetScale: CGFloat = 0.38

        // Phase 1 — scale the full-mode character down in place. Reads as
        // "getting smaller" rather than just vanishing. Layer-backed NSViews
        // default anchorPoint to (0, 0) on macOS, so we can't just animate
        // transform.scale (would pivot at the bottom-left). Use an explicit
        // transform keyframe that translates to the view's center, scales,
        // and translates back — pure center scale regardless of anchor.
        let scaleDown = CABasicAnimation(keyPath: "transform")
        scaleDown.fromValue = NSValue(caTransform3D: Self.centeredScale(1.0, for: stage.character))
        scaleDown.toValue   = NSValue(caTransform3D: Self.centeredScale(targetScale, for: stage.character))
        scaleDown.duration  = 0.28
        scaleDown.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scaleDown.fillMode = .forwards
        scaleDown.isRemovedOnCompletion = false
        stage.character.layer?.add(scaleDown, forKey: "micro-shrink")

        // Phase 2 — hand off to the micro view and slide the window to
        // its micro footprint. NSWindow.setFrame(animate:true) does the
        // actual slide; anchoring at the right edge keeps her visually
        // tucked into the same corner throughout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self = self else { return }

            // Center the micro window on where the (scaled) character
            // currently sits, so the snap-to-micro-size doesn't appear
            // to slide — she just stays in place and the window contracts
            // to fit her.
            let charFrame = self.stage.character.frame
            let charCenterX = old.minX + charFrame.midX
            let charCenterY = old.minY + charFrame.midY
            let proposed = CGPoint(x: charCenterX - s / 2, y: charCenterY - s / 2)
            let clamped = self.clampOriginToScreen(proposed, size: NSSize(width: s, height: s))
            let newFrame = NSRect(origin: clamped, size: NSSize(width: s, height: s))

            // Hide character BEFORE clearing the scale animation so the
            // identity-transform snap-back can't flash a full-size frame.
            self.stage.character.isHidden = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.stage.character.layer?.removeAnimation(forKey: "micro-shrink")
            self.stage.character.layer?.transform = CATransform3DIdentity
            CATransaction.commit()

            self.stage.micro.frame = NSRect(x: 0, y: 0, width: s, height: s)
            self.stage.micro.isHidden = false
            self.stage.micro.updateBadge(count: self.alertStore.unseenCount)

            // Instant resize — no slide animation.
            self.window.setFrame(newFrame, display: true, animate: false)
        }
    }

    private func expandToFull() {
        let pending = alertStore.lastActionableAlert
        let savedSize = savedFullFrame?.size ?? NSSize(width: 300, height: 360)
        let microFrame = window.frame

        // Target full frame — size from savedFullFrame but positioned so the
        // character's layer center lands where the micro center currently
        // is. Mirrors the shrink math so the transition reads as a pure
        // scale at the same on-screen point (no slide).
        let charCenterInStage = CGPoint(x: stage.character.frame.midX,
                                        y: stage.character.frame.midY)
        let fullCenterScreen  = CGPoint(x: microFrame.midX,
                                        y: microFrame.midY)
        let proposedOrigin = CGPoint(x: fullCenterScreen.x - charCenterInStage.x,
                                     y: fullCenterScreen.y - charCenterInStage.y)
        let clamped = clampOriginToScreen(proposedOrigin, size: savedSize)
        let newFrame = NSRect(origin: clamped, size: savedSize)

        // Snap the window to full size (no slide), then reveal the
        // character pre-scaled to the micro size and grow her back up
        // from her own visual center (see centeredScale rationale above).
        let targetScale: CGFloat = 0.38
        window.setFrame(newFrame, display: true, animate: false)
        stage.micro.isHidden = true
        stage.worryBubbles.isHidden = false
        stage.zs.isHidden = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.character.layer?.transform = Self.centeredScale(targetScale, for: stage.character)
        CATransaction.commit()
        stage.character.isHidden = false

        let scaleUp = CABasicAnimation(keyPath: "transform")
        scaleUp.fromValue = NSValue(caTransform3D: Self.centeredScale(targetScale, for: stage.character))
        scaleUp.toValue   = NSValue(caTransform3D: Self.centeredScale(1.0, for: stage.character))
        scaleUp.duration  = 0.28
        scaleUp.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scaleUp.fillMode = .forwards
        scaleUp.isRemovedOnCompletion = false
        stage.character.layer?.add(scaleUp, forKey: "micro-expand")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self = self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.stage.character.layer?.removeAnimation(forKey: "micro-expand")
            self.stage.character.layer?.transform = CATransform3DIdentity
            CATransaction.commit()

            self.stage.character.startAmbientAnimations()
            self.updateWorryBubbles()

            if let p = pending { self.replay(entry: p) }
        }
    }

    /// Enter mini mode from either full or micro. Swaps the visible
    /// character from the full-size `stage.character` to the mini-sized
    /// `stage.miniCharacter`, resizes the window around the character's
    /// on-screen center, and replays any pending actionable alert.
    private func enterMini(from previous: AxolMode) {
        if previous == .full { savedFullFrame = window.frame }

        // Anchor the new window so the visible character's on-screen center
        // stays put. In full mode that's `stage.character.frame.midX/Y`; in
        // micro it's the center of the micro view.
        let currentFrame = window.frame
        let screenAnchor: CGPoint = {
            switch previous {
            case .full:
                return CGPoint(x: currentFrame.minX + stage.character.frame.midX,
                               y: currentFrame.minY + stage.character.frame.midY)
            case .micro:
                return CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            case .mini:
                return CGPoint(x: currentFrame.midX, y: currentFrame.midY)
            }
        }()
        let targetSize = Self.miniEmptySize
        let proposed = CGPoint(x: screenAnchor.x - targetSize.width / 2,
                               y: screenAnchor.y - targetSize.height / 2)
        let origin = clampOriginToScreen(proposed, size: targetSize)

        // Tear down full-mode overlays and hide the full character.
        stage.bubble.hide()
        stage.history.hide()
        stage.worryBubbles.isHidden = true
        stage.zs.isHidden = true
        stage.worryBubbles.stop()
        stage.zs.stop()
        stage.character.stopIdles()
        stage.character.stopAmbientAnimations()
        stage.character.isHidden = true
        stage.micro.isHidden = true

        window.setFrame(NSRect(origin: origin, size: targetSize), display: true, animate: false)

        // Show + start the mini character. It renders at its own natural
        // render size (see StageView.miniCharacterRenderWidth), no transform.
        stage.miniCharacter.isHidden = false
        stage.miniCharacter.startAmbientAnimations()
        positionCharacterForMini()

        updateWorryBubbles()

        if let pending = alertStore.lastActionableAlert {
            replay(entry: pending)
        }
    }

    /// Exit mini mode, either back to full or forward to micro.
    private func exitMini(to target: AxolMode) {
        stage.bubble.hide()
        stage.miniBadge.isHidden = true
        stage.miniCharacter.stopIdles()
        stage.miniCharacter.stopAmbientAnimations()

        switch target {
        case .full:
            // Expand window back to savedFullFrame, re-anchored on the
            // mini character's current screen center so she stays put.
            let miniFrame = window.frame
            let miniCharScreenX = miniFrame.minX + stage.miniCharacter.frame.midX
            let miniCharScreenY = miniFrame.minY + stage.miniCharacter.frame.midY
            let size = savedFullFrame?.size ?? NSSize(width: 300, height: 360)
            // Full-mode character sits near the top-center of the stage
            // (see StageView init: charX = centered, charY = 4). Anchor so
            // her full-mode visual center lands where she is now.
            let fullCharCenterInStage = CGPoint(
                x: size.width / 2,
                y: 4 + stage.character.bounds.height / 2
            )
            let proposed = CGPoint(x: miniCharScreenX - fullCharCenterInStage.x,
                                   y: miniCharScreenY - fullCharCenterInStage.y)
            let origin = clampOriginToScreen(proposed, size: size)
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)

            restoreCharacterFullLayout()
            stage.miniCharacter.isHidden = true
            stage.worryBubbles.isHidden = false
            stage.zs.isHidden = false
            stage.character.isHidden = false
            stage.character.startAmbientAnimations()
            updateWorryBubbles()
        case .micro:
            // Swap to micro, anchored on mini character's current center.
            let miniFrame = window.frame
            let s = MicroView.size
            let miniCharScreenX = miniFrame.minX + stage.miniCharacter.frame.midX
            let miniCharScreenY = miniFrame.minY + stage.miniCharacter.frame.midY
            let proposed = CGPoint(x: miniCharScreenX - s / 2, y: miniCharScreenY - s / 2)
            let origin = clampOriginToScreen(proposed, size: NSSize(width: s, height: s))
            window.setFrame(NSRect(origin: origin, size: NSSize(width: s, height: s)),
                            display: true, animate: false)

            stage.miniCharacter.isHidden = true
            stage.micro.frame = NSRect(x: 0, y: 0, width: s, height: s)
            stage.micro.isHidden = false
            stage.micro.updateBadge(count: alertStore.unseenCount)
        case .mini:
            break // unreachable
        }
    }

    /// Restore the character to its full-mode frame position (centered near
    /// the top of the stage, same as StageView's init).
    private func restoreCharacterFullLayout() {
        let charSize = stage.character.bounds.size
        let charX = (stage.bounds.width - charSize.width) / 2
        stage.character.frame.origin = CGPoint(x: charX, y: 4)
    }

    /// Position the mini character within the current stage bounds. In empty
    /// mini she's centered; in with-bubble mini she's right-aligned so the
    /// bubble has room on the left.
    private func positionCharacterForMini() {
        let mc = stage.miniCharacter
        let isEmpty = stage.bounds.width <= Self.miniEmptySize.width + 10
        let centerX = isEmpty
            ? stage.bounds.width / 2
            : stage.bounds.width - Self.miniEmptySize.width / 2
        let centerY = stage.bounds.height / 2
        mc.frame.origin = CGPoint(
            x: centerX - mc.bounds.width / 2,
            y: centerY - mc.bounds.height / 2
        )
    }

    /// Grow the mini window leftward to fit a speech bubble on the left and
    /// position the bubble so its right-pointing tail meets the character's
    /// cheek. The character's on-screen position stays fixed — only the
    /// window's origin.x shifts left to make room.
    private func placeMiniBubble() {
        let currentFrame = window.frame
        // Grow the mini stage vertically to fit the bubble — a regular
        // one-liner still lands in the compact 80pt window, but a taller
        // permission bubble (title + 2-line body + buttons) pushes the
        // stage up to its own height + a small margin. Without this the
        // bubble is centered in a stage shorter than itself and the top
        // and bottom rounded corners clip against the window edges.
        let bubbleH = stage.bubble.frame.height
        let minH = Self.miniWithBubbleSize.height
        let neededH = max(minH, ceil(bubbleH) + 16)
        let grown = NSSize(width: Self.miniWithBubbleSize.width, height: neededH)

        let charScreenX = currentFrame.minX + stage.miniCharacter.frame.midX
        let charScreenY = currentFrame.minY + stage.miniCharacter.frame.midY
        // In the grown window the character's center lands at
        // (grown.width - miniEmptySize.width/2, grown.height/2).
        let newOriginX = charScreenX - (grown.width - Self.miniEmptySize.width / 2)
        let newOriginY = charScreenY - grown.height / 2
        let origin = clampOriginToScreen(CGPoint(x: newOriginX, y: newOriginY), size: grown)

        if currentFrame.size != grown {
            window.setFrame(NSRect(origin: origin, size: grown), display: true, animate: false)
        }
        positionCharacterForMini()

        // Bubble on the left of the mini character. Its frame includes the
        // tail reserve on the right; place so the tail tip meets her cheek.
        let b = stage.bubble
        let charVisualLeft = stage.miniCharacter.frame.minX
        b.frame.origin = CGPoint(
            x: charVisualLeft - b.frame.width + 4,
            y: stage.miniCharacter.frame.midY - b.frame.height / 2
        )

        layoutMiniBadge()
    }

    /// Shrink the mini-mode window back to character-only once the bubble
    /// dismisses. Keeps the mini character's on-screen position fixed by
    /// retracting origin.x rightward.
    private func collapseMiniToEmpty() {
        guard mode == .mini else { return }
        let currentFrame = window.frame
        let shrunk = Self.miniEmptySize

        let charScreenX = currentFrame.minX + stage.miniCharacter.frame.midX
        let charScreenY = currentFrame.minY + stage.miniCharacter.frame.midY
        let newOriginX = charScreenX - shrunk.width / 2
        let newOriginY = charScreenY - shrunk.height / 2
        let origin = clampOriginToScreen(CGPoint(x: newOriginX, y: newOriginY), size: shrunk)

        window.setFrame(NSRect(origin: origin, size: shrunk), display: true, animate: false)
        positionCharacterForMini()
        layoutMiniBadge()
    }

    /// Pin the mini badge over the character's upper-right gill. The badge
    /// is a subview of the character (not stage), so these coordinates are
    /// in the character's local space — the badge moves with her for free
    /// during drags / ambient animations. The ~13 px inset compensates for
    /// the AxolCharacterView frame's padding around the visible gills AND
    /// leaves a few pixels of headroom for her bob animation — without it,
    /// the top of the badge gets clipped by the window on the up-beat.
    private func layoutMiniBadge() {
        guard mode == .mini, !stage.miniBadge.isHidden else { return }
        let mc = stage.miniCharacter
        let badge = stage.miniBadge
        let visualInset: CGFloat = 13
        badge.frame.origin = CGPoint(
            x: mc.bounds.maxX - visualInset - badge.frame.width / 2,
            y: mc.bounds.maxY - visualInset - badge.frame.height / 2
        )
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

        if mode == .mini {
            presentHistoryInMini()
        } else {
            if alertStore.entries.isEmpty {
                stage.history.presentEmpty(in: stage)
            } else {
                stage.history.present(in: stage, entries: alertStore.entries)
            }
        }
        alertStore.markAllSeen()
        updateWorryBubbles()
    }

    /// Grow the mini window to fit the history panel on the left of the
    /// character, present the panel with a right-pointing tail so it reads
    /// like an oversized side bubble, and shrink back when it dismisses.
    private func presentHistoryInMini() {
        let currentFrame = window.frame
        let charScreenX = currentFrame.minX + stage.miniCharacter.frame.midX
        let charScreenY = currentFrame.minY + stage.miniCharacter.frame.midY

        // Target window: history-panel width + tail + character slot + a
        // breath of margin. History panel is 276 wide + 6px tail = 282;
        // plus 58 for the mini character footprint = 340. Height is sized
        // to the panel's tallest state (~216 with maxBodyHeight 180 +
        // header 30 + some margin).
        let historyAreaW: CGFloat = 282
        let charSlotW: CGFloat = Self.miniEmptySize.width
        let targetW: CGFloat = historyAreaW + charSlotW
        let targetH: CGFloat = 216
        let grown = NSSize(width: targetW, height: targetH)

        // Anchor so the character's on-screen center stays put.
        let newOriginX = charScreenX - (targetW - charSlotW / 2)
        let newOriginY = charScreenY - targetH / 2
        let origin = clampOriginToScreen(CGPoint(x: newOriginX, y: newOriginY), size: grown)

        window.setFrame(NSRect(origin: origin, size: grown), display: true, animate: false)
        positionCharacterForMini()

        // Present the history panel flush-left first (its actual height
        // depends on row count), then immediately reposition so it's
        // vertically centered on the character — the panel's right-pointing
        // tail emerges from its vertical midpoint, so centering here makes
        // the tail tip meet the character's cheek.
        if alertStore.entries.isEmpty {
            stage.history.presentEmpty(in: stage, tailSide: .right, origin: .zero)
        } else {
            stage.history.present(in: stage, entries: alertStore.entries,
                                  tailSide: .right, origin: .zero,
                                  maxVisibleRows: 2)
        }
        let panelH = stage.history.frame.height
        let charMidY = stage.miniCharacter.frame.midY
        stage.history.frame.origin = NSPoint(x: 0, y: charMidY - panelH / 2)

        // Collapse the window back to empty-mini when the history dismisses.
        stage.history.onHide = { [weak self] in
            guard let self = self, self.mode == .mini else { return }
            self.collapseMiniToEmpty()
        }

        layoutMiniBadge()
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

    /// User-triggered idle (option+click): pick a random move from the
    /// full idle pool and play it on whichever character is currently
    /// visible. Wakes her from a nap first so she can actually perform.
    func playRandomIdleForUser() {
        if isNapping { endNap() }
        let kind = AxolCharacterView.idlePool.randomElement() ?? .hop
        let target: AxolCharacterView = (mode == .mini)
            ? stage.miniCharacter : stage.character
        target.playIdle(kind)
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
        presentBubbleInCurrentMode(title: msg, body: nil, priority: "normal", action: nil)
    }
    @objc func doWave() {
        stage.character.wave()
        presentBubbleInCurrentMode(title: "👋 hi there!", body: nil, priority: "normal", action: nil)
    }
    @objc func doAbout() {
        let openRepo: [String: Any] = [
            "type": "open-url",
            "url": "https://github.com/Roach/axol",
            "label": "Open GitHub repo"
        ]
        stage.bubble.present(
            title: "Axol v2.0 — a desktop companion.",
            body: "github.com/Roach/axol",
            priority: "normal",
            action: openRepo
        )
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
        alertStore.markAllActioned()
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
    @objc func setModeFull()           { setMode(.full) }
    @objc func setModeMini()           { setMode(.mini) }
    @objc func setModeMicroAction()  { setMode(.micro) }

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

// Entry point lives in main.swift so swiftc can distinguish the driver file
// from the library files when compiling the multi-file target.
