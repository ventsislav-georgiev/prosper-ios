import GameController
import UIKit

/// The shift key: a tap uppercases the next letter only, a quick second tap locks caps,
/// and a tap on either lit state turns it off. Pure, so the timing rules are testable.
struct ShiftState: Equatable {
    enum Mode: Equatable { case off, once, locked }
    static let doubleTapWindow: TimeInterval = 0.3
    private(set) var mode: Mode = .off
    private var lastTap: TimeInterval = -.greatestFiniteMagnitude

    var uppercase: Bool { mode != .off }

    mutating func tap(at time: TimeInterval) {
        switch mode {
        case .off: mode = .once
        case .once: mode = time - lastTap <= Self.doubleTapWindow ? .locked : .off
        case .locked: mode = .off
        }
        lastTap = time
    }

    /// A letter went out: a one-shot shift is spent, caps lock stays.
    mutating func typedLetter() { if mode == .once { mode = .off } }
}

/// Every finger on the compact keyboard, in press order, and what each one types. Pure,
/// so the multi-touch rules are testable; the view maps each UITouch to an id and the
/// key nearest it and feeds it here.
///
/// - Shift acts on touch-down; backspace deletes on touch-down, then repeats while held.
/// - Every other key types on lift, as whatever key is under the finger then, so sliding
///   to correct works.
/// - A new touch types any earlier one still waiting first, so rolled typing keeps its
///   order and a second tap on a key that's still held counts twice.
/// - A cancelled touch that was still a tap (it traveled at most `tapSlop`) still types:
///   the user pressed the key before a system gesture took it. One that traveled further
///   was a swipe (the home gesture starting in the strip under the space bar) and types
///   nothing. Page keys never type on cancel, as a cancel shouldn't flip the page.
///
/// Points are in the view's coordinates; the defaults suit callers that don't care
/// about travel.
struct KeyTouchTracker {
    typealias Key = TerminalKeyboard.Key
    enum Effect: Equatable { case press(Key), startRepeat, stopRepeat }

    /// How far a finger may travel and still count as a tap if it's cancelled.
    static let tapSlop: CGFloat = 10

    private struct Touch {
        let id: Int; var key: Key; var done: Bool
        let start: CGPoint; var travel: CGFloat = 0
        mutating func reach(_ p: CGPoint) { travel = max(travel, hypot(p.x - start.x, p.y - start.y)) }
    }
    private var touches: [Touch] = []

    /// Keys under a finger right now, for the pressed look.
    var held: [Key] { touches.map(\.key) }
    /// The key of the touch still waiting to type a character: it gets the preview.
    var previewKey: Key? {
        guard let t = touches.last, !t.done, case .char = t.key else { return nil }
        return t.key
    }

    private static func actsOnDown(_ key: Key) -> Bool { key == .shift || key == .backspace }

    mutating func began(_ id: Int, _ key: Key, at point: CGPoint = .zero) -> [Effect] {
        var out: [Effect] = []
        for i in touches.indices where !touches[i].done {
            out.append(.press(touches[i].key))
            touches[i].done = true
        }
        switch key {
        case .shift: out.append(.press(.shift))
        case .backspace: out += [.press(.backspace), .startRepeat]
        default: break
        }
        touches.append(Touch(id: id, key: key, done: Self.actsOnDown(key), start: point))
        return out
    }

    /// Shift and backspace stay what they were; a lift key follows the finger to any
    /// other lift key.
    mutating func moved(_ id: Int, _ key: Key, at point: CGPoint? = nil) {
        guard let i = touches.firstIndex(where: { $0.id == id }) else { return }
        if let point { touches[i].reach(point) }
        guard !touches[i].done, !Self.actsOnDown(key) else { return }
        touches[i].key = key
    }

    mutating func ended(_ id: Int) -> [Effect] { finish(id, cancelled: false) }
    mutating func cancelled(_ id: Int, at point: CGPoint? = nil) -> [Effect] {
        if let point, let i = touches.firstIndex(where: { $0.id == id }) { touches[i].reach(point) }
        return finish(id, cancelled: true)
    }

    private mutating func finish(_ id: Int, cancelled: Bool) -> [Effect] {
        guard let i = touches.firstIndex(where: { $0.id == id }) else { return [] }
        let t = touches.remove(at: i)
        if t.key == .backspace { return held.contains(.backspace) ? [] : [.stopRepeat] }
        if t.done { return [] }
        if cancelled, case .page = t.key { return [] }
        if cancelled, t.travel > Self.tapSlop { return [] }
        return [.press(t.key)]
    }

    mutating func reset() { touches.removeAll() }
}

/// Compact terminal keyboard for iPhone, installed as the terminal's `inputView`.
///
/// Why it exists: on Face ID iPhones the system keyboard reserves an empty ~73 pt strip
/// under its keys (globe/dictation) plus padding above them, and an app can't shrink
/// it. This one is four 40 pt rows with only `bottomPadding` under them, reaching into
/// the home-indicator strip instead of stopping above it: 206 pt against the system's
/// 308. The bottom row pulls in from the sides so its outer keys clear the display's
/// rounded corners, and carries `,` `/` `?` beside space on every page. Character keys
/// show a press preview above the key.
///
/// Touches are handled by this view, not per key: each finger goes to the nearest key
/// (no dead zones in the gaps or margins) and `KeyTouchTracker` decides what it types,
/// so fast repeats, rolled typing and system-cancelled taps aren't dropped (while a
/// cancelled swipe, like the home gesture, types nothing).
///
/// Output goes through the terminal's own `UIKeyInput` (`insertText` / `deleteBackward`),
/// so SwiftTerm's return mapping and the host's sticky ctrl behave exactly as they do
/// for the system keyboard.
final class TerminalKeyboard: UIInputView, UIInputViewAudioFeedback {
    enum Page { case letters, numbers, symbols }
    enum Key: Hashable {
        case char(String), shift, backspace, space, ret, page(Page)
    }

    static let rowHeight: CGFloat = 40
    static let rowGap: CGFloat = 8
    static let topPadding: CGFloat = 6
    static let keyGap: CGFloat = 6
    static let sideMargin: CGFloat = 3
    static let keysHeight = topPadding + 4 * rowHeight + 3 * rowGap
    /// Under the bottom row, in place of the 34 pt home-indicator inset: enough to keep
    /// the space bar off the very bottom edge, where the home gesture starts. The host
    /// also defers the bottom edge gesture while this keyboard is up.
    static let bottomPadding: CGFloat = 16
    /// How far from the screen edge the bottom row starts, so its outer keys sit inside
    /// the display's rounded corners: on the iPhone 17 Pro the edge is 20 pt in at 16 pt
    /// up. Landscape's side safe area already exceeds it.
    static let bottomRowInset: CGFloat = 24
    static let height = keysHeight + bottomPadding

    /// Whether this device gets the compact keyboard: iPhone with no hardware keyboard.
    /// iPad, the Mac and a connected keyboard keep system behavior.
    static var appliesHere: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone && !hardwareKeyboardConnected()
        #endif
    }
    /// Seam for tests: the simulator may have its hardware keyboard connected.
    static var hardwareKeyboardConnected: () -> Bool = { GCKeyboard.coalesced != nil }

    private static func chars(_ s: String) -> [Key] { s.map { .char(String($0)) } }

    /// The bottom row is the same on every page but for its page key: `, / ?` beside
    /// space, for prose and paths. The two symbol pages hold every other printable ASCII
    /// character that isn't a letter, once each; the common ones are on the first page.
    static func rows(for page: Page) -> [[Key]] {
        func bottom(_ other: Page) -> [Key] {
            [.page(other), .char(","), .char("/"), .space, .char("?"), .ret]
        }
        switch page {
        case .letters: return [
            chars("qwertyuiop"),
            chars("asdfghjkl"),
            [.shift] + chars("zxcvbnm") + [.backspace],
            bottom(.numbers),
        ]
        case .numbers: return [
            chars("1234567890"),
            chars("-#()_$='\"&"),
            [.page(.symbols)] + chars(".@*`+;:") + [.backspace],
            bottom(.letters),
        ]
        case .symbols: return [
            chars("[]{}|<>%^~"),
            chars("!\\"),
            [.page(.numbers), .backspace],
            bottom(.letters),
        ]
        }
    }

    weak var target: UIKeyInput?
    private(set) var page: Page = .letters
    private(set) var shift = ShiftState()

    private var caps: [[Cap]] = []
    private let keysArea = UILayoutGuide()
    /// One generator, kept warm — same pattern as `ShortcutBar`.
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private var repeatTimer: Timer?
    private let preview = KeyPreview()
    private weak var previewCap: Cap?
    private var tracker = KeyTouchTracker()

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        isMultipleTouchEnabled = true
        overrideUserInterfaceStyle = .dark
        addLayoutGuide(keysArea)
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        height.priority = .required - 1
        NSLayoutConstraint.activate([
            keysArea.topAnchor.constraint(equalTo: topAnchor),
            keysArea.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            keysArea.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            keysArea.heightAnchor.constraint(equalToConstant: Self.keysHeight),
            height,
        ])
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var enableInputClicksWhenVisible: Bool { true }

    /// What a key does. The touch tracker's presses land here; so do the tests'.
    func press(_ key: Key) {
        switch key {
        case .char(let c):
            let letter = c.first?.isLetter == true
            target?.insertText(letter && shift.uppercase ? c.uppercased() : c)
            if letter, shift.mode == .once { shift.typedLetter(); refreshLabels() }
        case .space: target?.insertText(" ")
        case .ret: target?.insertText("\n")   // SwiftTerm sends `returnByteSequence` (CR)
        case .backspace: target?.deleteBackward()
        case .shift:
            shift.tap(at: CACurrentMediaTime())
            refreshLabels()
        case .page(let p):
            page = p
            build()
        }
    }

    // MARK: - Caps

    private enum Style {
        static let key = UIColor(white: 0.42, alpha: 1)          // ~#6B6B6B
        static let keyPressed = UIColor(white: 0.58, alpha: 1)
        static let special = UIColor(white: 0.27, alpha: 1)      // ~#454545
        static let specialPressed = UIColor(white: 0.42, alpha: 1)
        static let letterFont = UIFont.systemFont(ofSize: 22)
        static let wordFont = UIFont.systemFont(ofSize: 16)
        static let symbol = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    }

    private func build() {
        hidePreview()
        caps.joined().forEach { $0.removeFromSuperview() }
        caps = Self.rows(for: page).map { $0.map(makeCap) }
        refreshLabels()
        setNeedsLayout()
    }

    private func makeCap(_ key: Key) -> Cap {
        let cap = Cap(key: key)
        let plain: Bool
        switch key { case .char, .space: plain = true; default: plain = false }
        cap.fill = plain ? Style.key : Style.special
        cap.pressedFill = plain ? Style.keyPressed : Style.specialPressed
        cap.accessibilityTraits = .keyboardKey
        cap.activate = { [weak self] in self?.press(key) }
        addSubview(cap)
        return cap
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .cancelled) }

    private func feed(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
        for t in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            track(phase, id: Int(bitPattern: ObjectIdentifier(t)), at: t.location(in: self))
        }
    }

    /// One touch event, `at` in this view's coordinates. The UIKit overrides call it;
    /// so do the tests, which can't make UITouches.
    func track(_ phase: UITouch.Phase, id: Int, at point: CGPoint) {
        switch phase {
        case .began:
            feedback()
            let before = page
            perform(tracker.began(id, key(at: point), at: point))
            // A rolled-over page key just switched the page under this finger.
            if page != before { tracker.moved(id, key(at: point)) }
        case .moved:
            tracker.moved(id, key(at: point), at: point)
        case .ended:
            tracker.moved(id, key(at: point), at: point)
            perform(tracker.ended(id))
        case .cancelled:
            perform(tracker.cancelled(id, at: point))   // only how far it traveled matters
        default:
            return
        }
        refreshPressed()
    }

    /// The key nearest `point`, so the gaps, margins and the strip under the bottom row
    /// all belong to a key.
    private func key(at point: CGPoint) -> Key {
        func distance(_ r: CGRect) -> CGFloat {
            hypot(max(r.minX - point.x, 0, point.x - r.maxX), max(r.minY - point.y, 0, point.y - r.maxY))
        }
        return caps.joined().min { distance($0.frame) < distance($1.frame) }?.key ?? .space
    }

    private func perform(_ effects: [KeyTouchTracker.Effect]) {
        for e in effects {
            switch e {
            case .press(let k): press(k)
            case .startRepeat: startRepeat()
            case .stopRepeat: stopRepeat()
            }
        }
    }

    /// The pressed look and the preview follow the tracker, not the caps' own tracking.
    private func refreshPressed() {
        let held = tracker.held
        for cap in caps.joined() { cap.isHighlighted = held.contains(cap.key) }
        let cap = tracker.previewKey.flatMap { k in caps.joined().first { $0.key == k } }
        if let cap { showPreview(cap) } else { hidePreview() }
    }

    private func refreshLabels() {
        for cap in caps.joined() {
            var title: String?, image: String?, label: String
            switch cap.key {
            case .char(let c):
                let s = c.first?.isLetter == true && shift.uppercase ? c.uppercased() : c
                title = s; label = s
            case .shift:
                switch shift.mode {
                case .off: image = "shift"; label = "shift"
                case .once: image = "shift.fill"; label = "shift on"
                case .locked: image = "capslock.fill"; label = "caps lock"
                }
                cap.fill = shift.uppercase ? Style.key : Style.special
            case .backspace: image = "delete.left"; label = "delete"
            case .space: title = "space"; label = "space"
            case .ret: title = "return"; label = "return"
            case .page(let p):
                switch p {
                case .letters: title = "ABC"; label = "letters"
                case .numbers: title = "123"; label = "numbers"
                case .symbols: title = "#+="; label = "more symbols"
                }
            }
            cap.titleLabel?.font = title?.count == 1 ? Style.letterFont : Style.wordFont
            cap.setTitle(title, for: .normal)
            let img = image.flatMap { UIImage(systemName: $0, withConfiguration: Style.symbol) }
            cap.setImage(img, for: .normal)
            cap.setImage(img, for: .highlighted)   // no default dimming; the fill shows the press
            cap.accessibilityLabel = label
        }
    }

    // MARK: - Press preview

    /// The preview goes in the keyboard's window, not this view, so a top-row bubble can
    /// rise over the shortcut bar whatever the input host's ancestors clip.
    private func showPreview(_ cap: Cap) {
        guard let text = cap.title(for: .normal) else { return }
        guard cap !== previewCap || preview.label.text != text || preview.superview == nil else { return }
        layoutIfNeeded()   // a key pressed right after a page switch has no frame yet
        let host: UIView = window ?? self
        host.addSubview(preview)   // also brings it to the front
        preview.show(text, over: convert(cap.frame, to: host), within: host.bounds)
        previewCap = cap
    }

    private func hidePreview() {
        preview.removeFromSuperview()
        previewCap = nil
    }

    /// Test seams: the character in the visible preview, and its frame in its host.
    var previewText: String? { preview.superview == nil ? nil : preview.label.text }
    var previewFrame: CGRect? { preview.superview == nil ? nil : preview.frame }

    private func feedback() {
        UIDevice.current.playInputClick()
        haptics.impactOccurred(intensity: 0.7)
        haptics.prepare()
    }

    // Backspace: the tracker deletes once on touch-down; this repeats after a pause while held.
    private func startRepeat() {
        stopRepeat()
        let delay = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            let tick = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                UIDevice.current.playInputClick()
                self?.press(.backspace)
            }
            RunLoop.main.add(tick, forMode: .common)
            self.repeatTimer = tick
        }
        RunLoop.main.add(delay, forMode: .common)
        repeatTimer = delay
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopRepeat(); tracker.reset(); refreshPressed() }   // dismissed mid-hold
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = keysArea.layoutFrame.insetBy(dx: Self.sideMargin, dy: 0)
        for (r, row) in caps.enumerated() {
            let y = area.minY + Self.topPadding + CGFloat(r) * (Self.rowHeight + Self.rowGap)
            // The bottom row clears the screen's rounded corners (a no-op in landscape).
            let pull = r == caps.count - 1 ? max(0, Self.bottomRowInset - area.minX) : 0
            let rowArea = area.insetBy(dx: pull, dy: 0)
            for (cap, f) in zip(row, Self.place(row.map(\.key), width: rowArea.width)) {
                cap.frame = CGRect(x: rowArea.minX + f.x, y: y, width: f.w, height: Self.rowHeight)
            }
        }
    }

    /// Horizontal slots for one row, in a row `width` wide. A letter is one unit (ten
    /// units and nine gaps fill the width). A row of nine or more characters stretches
    /// them to fill it. A row with space gives space the rest; a row led by a special key
    /// (shift / page) pins it and the last key to the edges and centers the letters
    /// between; anything else is centered.
    static func place(_ keys: [Key], width: CGFloat) -> [(x: CGFloat, w: CGFloat)] {
        let g = keyGap, u = (width - 9 * g) / 10
        if keys.count >= 9, keys.allSatisfy({ if case .char = $0 { return true } else { return false } }) {
            let kw = (width - g * CGFloat(keys.count - 1)) / CGFloat(keys.count)
            return keys.indices.map { (CGFloat($0) * (kw + g), kw) }
        }
        func w(_ k: Key) -> CGFloat {
            switch k {
            case .char: return u
            case .ret: return 2.25 * u
            default: return 1.5 * u
            }
        }
        if keys.contains(.space) {
            let fixed = keys.filter { $0 != .space }.map(w).reduce(0, +)
            let spaceW = width - fixed - g * CGFloat(keys.count - 1)
            var x: CGFloat = 0
            return keys.map { k in
                let kw = k == .space ? spaceW : w(k)
                defer { x += kw + g }
                return (x, kw)
            }
        }
        let edged: Bool
        if keys.count >= 2, case .char = keys[0] { edged = false } else { edged = keys.count >= 2 }
        let middle = edged ? Array(keys.dropFirst().dropLast()) : keys
        let span = middle.map(w).reduce(0, +) + g * CGFloat(max(0, middle.count - 1))
        var x = (width - span) / 2
        let mids: [(x: CGFloat, w: CGFloat)] = middle.map { k in
            defer { x += w(k) + g }
            return (x, w(k))
        }
        guard edged, let first = keys.first, let last = keys.last else { return mids }
        return [(0, w(first))] + mids + [(width - w(last), w(last))]
    }
}

extension TerminalKeyboard {
    /// The enlarged character above a pressed key, joined to the key like the system
    /// keyboard's: one shape, the bubble on top and the key below as its stem. The bubble
    /// slides sideways to stay inside `limit`, so edge keys keep it on screen.
    fileprivate final class KeyPreview: UIView {
        static let extra: CGFloat = 10    // bubble overhang past each side of the key
        static let rise: CGFloat = 48     // bubble height above the key's top
        let label = UILabel()
        private let shape = CAShapeLayer()

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            shape.fillColor = Style.key.cgColor
            shape.shadowColor = UIColor.black.cgColor
            shape.shadowOpacity = 0.45
            shape.shadowRadius = 3
            shape.shadowOffset = CGSize(width: 0, height: 1)
            layer.addSublayer(shape)
            label.font = .systemFont(ofSize: 32)
            label.textColor = .white
            label.textAlignment = .center
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        /// `key` and `limit` in the superview's coordinates.
        func show(_ text: String, over key: CGRect, within limit: CGRect) {
            let w = key.width + 2 * Self.extra
            let x = min(max(key.midX - w / 2, limit.minX + 2), limit.maxX - 2 - w)
            let bubble = CGRect(x: x, y: key.minY - Self.rise, width: w, height: Self.rise + 8)
            frame = bubble.union(key)
            let local = { (r: CGRect) in r.offsetBy(dx: -self.frame.minX, dy: -self.frame.minY) }
            let path = UIBezierPath(roundedRect: local(bubble), cornerRadius: 9)
            path.append(UIBezierPath(roundedRect: local(key), cornerRadius: 6))
            shape.path = path.cgPath
            shape.shadowPath = path.cgPath
            label.text = text
            label.frame = local(bubble).insetBy(dx: 0, dy: 4).offsetBy(dx: 0, dy: -4)
        }
    }
}

/// One key, drawn only: flat fill that lightens while `isHighlighted` (set by the
/// keyboard's touch tracking) and a hairline bottom shadow like the system keys.
/// Touches go through to the keyboard view.
private final class Cap: UIButton {
    let key: TerminalKeyboard.Key
    var fill: UIColor = .gray { didSet { refill() } }
    var pressedFill: UIColor = .lightGray

    init(key: TerminalKeyboard.Key) {
        self.key = key
        super.init(frame: .zero)
        layer.cornerRadius = 6
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        setTitleColor(.white, for: .normal)
        tintColor = .white
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isHighlighted: Bool { didSet { refill() } }
    private func refill() { backgroundColor = isHighlighted ? pressedFill : fill }

    /// VoiceOver's double-tap: the cap has no actions of its own to fire.
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}
