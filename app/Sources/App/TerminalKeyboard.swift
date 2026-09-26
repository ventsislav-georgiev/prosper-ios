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

/// Compact terminal keyboard for iPhone, installed as the terminal's `inputView`.
///
/// Why it exists: on Face ID iPhones the system keyboard reserves an empty ~73 pt strip
/// under its keys (globe/dictation) plus padding above them, and an app can't shrink
/// it. This one is four 40 pt rows ending at the safe-area bottom, which hands roughly
/// 85 pt back to the terminal. The ⌨︎ key hands off to the system keyboard for
/// dictation and swipe until the keyboard is next dismissed.
///
/// Output goes through the terminal's own `UIKeyInput` (`insertText` / `deleteBackward`),
/// so SwiftTerm's return mapping and the host's sticky ctrl behave exactly as they do
/// for the system keyboard.
final class TerminalKeyboard: UIInputView, UIInputViewAudioFeedback {
    enum Page { case letters, numbers, symbols }
    enum Key: Hashable {
        case char(String), shift, backspace, space, ret, page(Page), system
    }

    static let rowHeight: CGFloat = 40
    static let rowGap: CGFloat = 8
    static let topPadding: CGFloat = 6
    static let keyGap: CGFloat = 6
    static let sideMargin: CGFloat = 3
    /// Keys only; the view adds the bottom safe-area inset below this.
    static let keysHeight = topPadding + 4 * rowHeight + 3 * rowGap

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

    /// The two symbol pages together hold every printable ASCII character that isn't a
    /// letter, once each; the shell-heavy ones are on the first page.
    static func rows(for page: Page) -> [[Key]] {
        switch page {
        case .letters: return [
            chars("qwertyuiop"),
            chars("asdfghjkl"),
            [.shift] + chars("zxcvbnm") + [.backspace],
            [.page(.numbers), .system, .space, .ret],
        ]
        case .numbers: return [
            chars("1234567890"),
            chars("-/|~_$\\'\"&"),
            [.page(.symbols)] + chars(".,*><;:") + [.backspace],
            [.page(.letters), .system, .space, .ret],
        ]
        case .symbols: return [
            chars("[]{}()#%^="),
            chars("+?!@`"),
            [.page(.numbers), .backspace],
            [.page(.letters), .system, .space, .ret],
        ]
        }
    }

    weak var target: UIKeyInput?
    /// The ⌨︎ key: the owner swaps this view out for the system keyboard.
    var onSystemKeyboard: (() -> Void)?
    private(set) var page: Page = .letters
    private(set) var shift = ShiftState()

    private var caps: [[Cap]] = []
    private let keysArea = UILayoutGuide()
    /// One generator, kept warm — same pattern as `ShortcutBar`.
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private var repeatTimer: Timer?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.keysHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        overrideUserInterfaceStyle = .dark
        addLayoutGuide(keysArea)
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

    /// The screen's bottom safe-area inset, set by the owner before the keyboard shows.
    /// Height = keys + this, so the last row ends where the home indicator's gesture
    /// zone begins. Not a constraint to our own safe-area guide: the keyboard host takes
    /// the view's height when it attaches it — before it is in a window, inset 0 — and
    /// pins it (`_UIKBAutolayoutHeightConstraint`), so the frame must already be right.
    var bottomInset: CGFloat = 0 {
        didSet {
            height.constant = Self.keysHeight + bottomInset
            frame.size.height = height.constant
        }
    }
    private lazy var height = heightAnchor.constraint(equalToConstant: Self.keysHeight)

    var enableInputClicksWhenVisible: Bool { true }

    /// What a key does. The caps call this; so do the tests.
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
        case .system: onSystemKeyboard?()
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
        cap.addAction(UIAction { [weak self] _ in self?.feedback() }, for: .touchDown)
        switch key {
        case .backspace:
            cap.addAction(UIAction { [weak self] _ in self?.startRepeat() }, for: .touchDown)
            cap.addAction(UIAction { [weak self] _ in self?.stopRepeat() },
                          for: [.touchUpInside, .touchUpOutside, .touchCancel])
        case .shift:
            // On touch-down, like the system shift: the double-tap window is measured
            // between presses, not releases.
            cap.addAction(UIAction { [weak self] _ in self?.press(.shift) }, for: .touchDown)
        default:
            cap.addAction(UIAction { [weak self] _ in self?.press(key) }, for: .touchUpInside)
        }
        addSubview(cap)
        return cap
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
            case .system: image = "keyboard"; label = "system keyboard"
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

    private func feedback() {
        UIDevice.current.playInputClick()
        haptics.impactOccurred(intensity: 0.7)
        haptics.prepare()
    }

    // Backspace: once on touch-down, then repeat after a pause while held.
    private func startRepeat() {
        press(.backspace)
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
        if window == nil { stopRepeat() }   // dismissed mid-hold
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = keysArea.layoutFrame.insetBy(dx: Self.sideMargin, dy: 0)
        for (r, row) in caps.enumerated() {
            let y = area.minY + Self.topPadding + CGFloat(r) * (Self.rowHeight + Self.rowGap)
            for (cap, f) in zip(row, Self.place(row.map(\.key), width: area.width)) {
                cap.frame = CGRect(x: area.minX + f.x, y: y, width: f.w, height: Self.rowHeight)
            }
        }
    }

    /// Horizontal slots for one row, in a row `width` wide. A letter is one unit (ten
    /// units and nine gaps fill the width). A row with space gives space the rest; a row
    /// led by a special key (shift / page) pins it and the last key to the edges and
    /// centers the letters between; anything else is centered.
    static func place(_ keys: [Key], width: CGFloat) -> [(x: CGFloat, w: CGFloat)] {
        let g = keyGap, u = (width - 9 * g) / 10
        func w(_ k: Key) -> CGFloat {
            switch k {
            case .char: return u
            case .ret: return 2.25 * u
            case .system: return 1.25 * u
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

/// One key: flat fill that lightens under the finger, a hairline bottom shadow like the
/// system keys, and a touch area that reaches halfway into the gaps so there are no
/// dead spots between keys.
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
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isHighlighted: Bool { didSet { refill() } }
    private func refill() { backgroundColor = isHighlighted ? pressedFill : fill }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -TerminalKeyboard.keyGap / 2, dy: -TerminalKeyboard.rowGap / 2).contains(point)
    }
}
