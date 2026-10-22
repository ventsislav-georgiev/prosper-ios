import GameController
import UIKit

/// The shift key: a tap uppercases the next letter only, a quick second tap locks caps,
/// and a tap on either lit state turns it off. Pure, so the timing rules are testable.
/// The shortcut bar's sticky ctrl, alt and shift run on it too: once is spent by the
/// next key that takes it (`typedLetter`), locked stays.
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

    /// Auto-capitalization (the keyboard extension only): one-shot on at a sentence start,
    /// off elsewhere. Caps lock is the user's and stays.
    ///
    /// ponytail: off also clears a one-shot the user tapped, so shift then a digit then
    /// a letter types it lowercase. Track who set it if that ever matters.
    mutating func autoShift(_ on: Bool) { if mode != .locked { mode = on ? .once : .off } }
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
/// - A character touch still waiting after `holdDelay` (the view's timer calls `hold`)
///   becomes that key's `holdSymbol` and stays it: lifting types the symbol. A touch a
///   rollover already typed has nothing left to convert.
/// - A cancelled touch that was still a tap (it traveled at most `tapSlop`) still types:
///   the user pressed the key before a system gesture took it. One that traveled further
///   was a swipe (the home gesture starting in the strip under the space bar) and types
///   nothing.
/// - A cancelled touch that began below the bottom row's keys types nothing however
///   little it traveled: that strip is where the home gesture starts, and the system
///   cancels it inside `tapSlop`. One there that lifts normally still types.
///
/// Points are in the view's coordinates; the defaults suit callers that don't care
/// about travel.
struct KeyTouchTracker {
    typealias Key = TerminalKeyboard.Key
    enum Effect: Equatable { case press(Key), startRepeat, stopRepeat }

    /// How far a finger may travel and still count as a tap if it's cancelled.
    static let tapSlop: CGFloat = 10
    /// How long a character touch stays down before it types its symbol instead.
    static let holdDelay: TimeInterval = 0.35

    private struct Touch {
        let id: Int; var key: Key; var done: Bool
        let start: CGPoint; var travel: CGFloat = 0
        var belowKeys = false
        /// Set by a hold: what the touch types instead of `key`.
        var symbol: String?
        var output: Key { symbol.map(Key.char) ?? key }
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
    /// The symbol that touch will type, once a hold converted it: the preview shows it.
    var previewSymbol: String? { previewKey == nil ? nil : touches.last?.symbol }

    private static func actsOnDown(_ key: Key) -> Bool { key == .shift || key == .backspace }

    /// `belowKeys`: the touch began in the strip under the bottom row.
    mutating func began(_ id: Int, _ key: Key, at point: CGPoint = .zero, belowKeys: Bool = false) -> [Effect] {
        var out: [Effect] = []
        for i in touches.indices where !touches[i].done {
            out.append(.press(touches[i].output))
            touches[i].done = true
        }
        switch key {
        case .shift: out.append(.press(.shift))
        case .backspace: out += [.press(.backspace), .startRepeat]
        default: break
        }
        touches.append(Touch(id: id, key: key, done: Self.actsOnDown(key), start: point, belowKeys: belowKeys))
        return out
    }

    /// Shift and backspace stay what they were; a lift key follows the finger to any
    /// other lift key.
    mutating func moved(_ id: Int, _ key: Key, at point: CGPoint? = nil) {
        guard let i = touches.firstIndex(where: { $0.id == id }) else { return }
        if let point { touches[i].reach(point) }
        guard !touches[i].done, touches[i].symbol == nil, !Self.actsOnDown(key) else { return }
        touches[i].key = key
    }

    /// The touch has stayed down `holdDelay`, now over `key`: the nearest key, uncorrected,
    /// since a hold is deliberate. True if it now types that key's symbol.
    mutating func hold(_ id: Int, over key: Key) -> Bool {
        guard let i = touches.firstIndex(where: { $0.id == id }), !touches[i].done,
              touches[i].symbol == nil, case .char(let c) = key,
              let symbol = TerminalKeyboard.holdSymbol[c] else { return false }
        touches[i].key = key
        touches[i].symbol = symbol
        return true
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
        if cancelled, t.travel > Self.tapSlop || t.belowKeys { return [] }
        return [.press(t.output)]
    }

    mutating func reset() { touches.removeAll() }
}

/// Compact terminal keyboard for iPhone, installed as the terminal's `inputView`.
///
/// Why it exists: on Face ID iPhones the system keyboard reserves an empty ~73 pt strip
/// under its keys (globe/dictation) plus padding above them, and an app can't shrink
/// it. This one is five 38 pt rows with only `bottomPadding` under them, reaching into
/// the home-indicator strip instead of stopping above it: 276 pt against the system's
/// 308, with a digit row the system keyboard doesn't have. The bottom row pulls in from
/// the sides so its outer keys clear the display's rounded corners, and carries `.` `,`
/// `/` `?` beside space. Character keys show a press preview above the key.
///
/// There is one page, no symbols page: like Gboard, each letter and digit shows a small
/// symbol in its corner (`holdSymbol`) and holding the key types it, so every printable
/// ASCII character is a tap or a hold away and none costs a page switch and back.
///
/// Touches are handled by this view, not per key: each finger goes to the nearest key
/// (no dead zones in the gaps or margins) and `KeyTouchTracker` decides what it types,
/// so fast repeats, rolled typing and system-cancelled taps aren't dropped (while a
/// cancelled swipe, like the home gesture, types nothing). A touch between two letters
/// goes to the one that continues the word being typed (`corrected`).
///
/// Output goes through the terminal's own `UIKeyInput` (`insertText` / `deleteBackward`),
/// so the host's sticky ctrl behaves exactly as it does for the system keyboard. Return
/// is the exception: like Slack's it types a newline, `newlineBytes` (meta-enter) sent
/// raw through `sendBytes`; submitting is the shortcut bar's enter. The system keyboard
/// keeps return = submit.
///
/// The same view is the Prosper keyboard extension's, for every other app (Sources/Keys
/// is compiled by both targets; nothing here may reach into Sources/App or SwiftTerm).
/// There `target` is the host's `UITextDocumentProxy` and `sendBytes` is nil, so return
/// types a real "\n", titled by the field's return key (`returnTitle`); the globe key
/// shows when iOS asks for one (`showsGlobe`), shift follows the field's
/// auto-capitalization (`autoCapitalize`) and a second space after a word types ". "
/// (`doubleSpacePeriod`).
final class TerminalKeyboard: UIInputView, UIInputViewAudioFeedback {
    enum Key: Hashable {
        case char(String), shift, backspace, space, ret
        /// Next keyboard; the extension's only. Its cap takes its own touches (`makeCap`).
        case globe
    }

    static let rowHeight: CGFloat = 38
    static let rowGap: CGFloat = 13
    static let topPadding: CGFloat = 6
    static let keyGap: CGFloat = 9
    static let sideMargin: CGFloat = 3
    static let keysHeight = topPadding + 5 * rowHeight + 4 * rowGap
    /// Under the bottom row, in place of the 34 pt home-indicator inset: enough to keep
    /// the space bar off the bottom edge, where the home gesture starts. (Deferring that
    /// gesture does nothing on iPhone; a cancelled touch begun here types nothing, see
    /// the tracker.)
    static let bottomPadding: CGFloat = 28
    /// This keyboard's pad under the bottom row: `bottomPadding` in the app. The extension
    /// sets a few points, since iOS already keeps its own strip under a custom keyboard.
    var bottomInset = TerminalKeyboard.bottomPadding {
        didSet { heightConstraint.constant = Self.keysHeight + bottomInset }
    }
    /// How far from the screen edge the bottom row starts, so its outer keys sit inside
    /// the display's rounded corners: on the iPhone 17 Pro the edge is 20 pt in at 16 pt
    /// up. Landscape's side safe area already exceeds it.
    static let bottomRowInset: CGFloat = 24
    static let height = keysHeight + bottomPadding
    /// ESC CR, meta-enter: Claude Code's "insert newline, don't submit". Return sends it;
    /// so does the shortcut bar's `snl` key.
    static let newlineBytes: [UInt8] = [0x1b, 0x0d]

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

    /// Digits lead (shift doesn't change them), then qwerty, then `. , / ?` beside space
    /// for prose and paths. Every other symbol is a hold (`holdSymbol`).
    static let rows: [[Key]] = [
        chars("1234567890"),
        chars("qwertyuiop"),
        chars("asdfghjkl"),
        [.shift] + chars("zxcvbnm") + [.backspace],
        [.char("."), .char(","), .char("/"), .space, .char("?"), .ret],
    ]

    /// What holding a letter or digit types, shown in its corner: the digits' US shift
    /// symbols, the letters' Gboard ones, with q and w carrying ` and \. With the taps
    /// that covers all 32 printable ASCII symbols; a few appear twice (@ # $ & * ( ) /),
    /// where both spots are familiar. Keyed by the lowercase key, whatever shift shows.
    static let holdSymbol: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "q": "`", "w": "\\", "e": "~", "r": "|", "t": "[", "y": "]", "u": "<", "i": ">", "o": "{", "p": "}",
        "a": "@", "s": "#", "d": "&", "f": "*", "g": "-", "h": "+", "j": "=", "k": "(", "l": ")",
        "z": "_", "x": "$", "c": "\"", "v": "'", "b": ":", "n": ";", "m": "/",
    ]

    weak var target: UIKeyInput?
    /// Raw bytes to the terminal, past `insertText` (which makes multi-byte control text
    /// a paste). Nil in the extension: return then types "\n".
    var sendBytes: (([UInt8]) -> Void)?
    /// Return's title, from the field's return key (`returnTitle(for:)`); nil draws the
    /// `return.left` arrow. The extension sets it, the app never does.
    var returnTitle: String? { didSet { refreshLabels() } }
    /// A globe key before `.`, for the extension when iOS asks for one
    /// (`needsInputModeSwitchKey`: Touch ID iPhones and iPad; Face ID iPhones draw their
    /// own under the keyboard). The app never shows it.
    var showsGlobe = false { didSet { if showsGlobe != oldValue { build() } } }
    /// A second space after a word types ". " (`periodReplacesSpace`), like the system
    /// keyboard. The extension sets it; the terminal never wants it.
    var doubleSpacePeriod = false
    /// The extension's suggestions (`SuggestionBar.attach`): asked before every key, it
    /// can autocorrect the word a separator ends, or take the key itself (true: backspace
    /// undoing an autocorrect) and the keyboard types nothing. Nil in the app.
    var willPress: ((Key) -> Bool)?
    /// After every key, shift included: the extension's bar recomputes. Nil in the app.
    var didPress: (() -> Void)?
    private(set) var shift = ShiftState()
    /// The letters typed since the last non-letter, lowercase: the prefix touch correction
    /// continues. Backspace drops one, shift keeps it, any other key clears it. Keys from
    /// the shortcut bar bypass this keyboard, so the host calls `resetWord` for them.
    private(set) var word = ""
    /// The words on the terminal now (`screenWords(in:)`), for touch correction: names no
    /// dictionary knows, like hosts, services and branches. In the extension, the user's
    /// learned words and contact names instead (`Suggestions.personalWords`). Read only
    /// for an ambiguous touch, and held only until the next one begins.
    var screenWords: (() -> Set<String>)?
    /// What correction looked up for the current touch, so a finger sliding over an
    /// ambiguous spot doesn't repeat the lookups or the screen read: one is a few ms.
    /// Cleared when a touch begins.
    private var knownCache: [String: Bool] = [:]
    private var screenCache: Set<String>?

    private var caps: [[Cap]] = []
    private let keysArea = UILayoutGuide()
    /// One generator, kept warm — same pattern as `ShortcutBar`.
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private var repeatTimer: Timer?
    private let preview = KeyPreview()
    private weak var previewCap: Cap?
    private var tracker = KeyTouchTracker()
    /// The touch the hold timer is waiting on, and where it is now: only the newest touch
    /// can still be waiting (a new one types the others), so one timer is enough.
    private var holdTimer: Timer?
    private var holdTouch: (id: Int, at: CGPoint)?
    private var heightConstraint: NSLayoutConstraint!

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        isMultipleTouchEnabled = true
        overrideUserInterfaceStyle = .dark
        addLayoutGuide(keysArea)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        heightConstraint.priority = .required - 1
        NSLayoutConstraint.activate([
            keysArea.topAnchor.constraint(equalTo: topAnchor),
            keysArea.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            keysArea.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            keysArea.heightAnchor.constraint(equalToConstant: Self.keysHeight),
            heightConstraint,
        ])
        build()
        _ = Self.checker   // loads the lexicon now, not on the first ambiguous touch
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var enableInputClicksWhenVisible: Bool { true }

    /// What a key does. The touch tracker's presses land here; so do the tests'.
    func press(_ key: Key) {
        defer { didPress?() }
        if willPress?(key) == true {
            // ponytail: the text is no longer what the keys typed (an undone autocorrect),
            // so touch correction starts afresh rather than guess the word back.
            word = ""
            autoCapitalize()
            return
        }
        switch key {
        case .char(let c) where c.first?.isLetter == true: word += c.lowercased()
        case .backspace: _ = word.popLast()
        case .shift: break
        default: word = ""
        }
        switch key {
        case .char(let c):
            let letter = c.first?.isLetter == true
            target?.insertText(letter && shift.uppercase ? c.uppercased() : c)
            if letter, shift.mode == .once { shift.typedLetter(); refreshLabels() }
        case .space:
            if doubleSpacePeriod, let doc = target as? UITextDocumentProxy,
               Self.periodReplacesSpace(before: doc.documentContextBeforeInput, keyboardType: doc.keyboardType ?? .default) {
                doc.deleteBackward()
                doc.insertText(". ")
            } else {
                target?.insertText(" ")
            }
        case .ret: if let sendBytes { sendBytes(Self.newlineBytes) } else { target?.insertText("\n") }
        case .backspace: target?.deleteBackward()
        case .shift:
            shift.tap(at: CACurrentMediaTime())
            refreshLabels()
            return   // the user's shift: auto-capitalization doesn't undo it
        case .globe: return   // its cap acts on its own; the tracker never yields it (`nearest`)
        }
        autoCapitalize()
    }

    /// Shift on at a sentence start, off elsewhere, when the target is a host app's text
    /// field that asks for it: the extension's. The app's target, the terminal, isn't a
    /// document proxy, so it never auto-capitalizes. `press` calls it after every key;
    /// the extension's controller also does when the field or the selection changes.
    func autoCapitalize() {
        guard let doc = target as? UITextDocumentProxy else { return }
        let on = Self.shouldCapitalize(before: doc.documentContextBeforeInput,
                                       type: doc.autocapitalizationType ?? .none)
        let before = shift
        shift.autoShift(on)
        if shift != before { refreshLabels() }
    }

    /// Whether the next letter starts capitalized, given the text before the cursor and
    /// the field's autocapitalization: at the start of the field, after a newline, and
    /// (sentences) after `. ` `? ` `! ` (closing quotes and brackets
    /// between them allowed) or (words) after any space. Nil text is the start.
    static func shouldCapitalize(before text: String?, type: UITextAutocapitalizationType) -> Bool {
        let text = text ?? ""
        switch type {
        case .allCharacters: return true
        case .words: return text.last.map { $0.isWhitespace } ?? true
        case .sentences:
            guard let last = text.last else { return true }
            if last.isNewline { return true }
            guard last == " " else { return false }
            // A closing quote or bracket after the stop still ends the sentence: `"hi." `.
            let rest = text.reversed().drop { $0 == " " }.drop { "\"')]”’".contains($0) }
            guard let end = rest.first else { return true }   // only spaces before it
            return end.isNewline || ".?!".contains(end)
        default: return false
        }
    }

    /// Whether a space typed now replaces the space before the cursor with ". ": the text
    /// ends in a letter or digit and exactly one space. Never in a field where a period
    /// would break the value: URLs, email, web search, number and phone pads.
    static func periodReplacesSpace(before text: String?, keyboardType: UIKeyboardType) -> Bool {
        if isValueField(keyboardType) { return false }
        let tail = Array((text ?? "").suffix(2))
        return tail.count == 2 && tail[1] == " " && (tail[0].isLetter || tail[0].isNumber)
    }

    /// A field whose value isn't prose, so nothing may rewrite what's typed (no period for
    /// a double space, no autocorrect): URLs, email, web search, number and phone pads.
    static func isValueField(_ type: UIKeyboardType) -> Bool {
        switch type {
        case .URL, .emailAddress, .webSearch, .numberPad, .asciiCapableNumberPad, .decimalPad,
             .phonePad, .namePhonePad: return true
        default: return false
        }
    }

    /// Return's title for a host field's return key type; nil keeps the arrow.
    static func returnTitle(for type: UIReturnKeyType) -> String? {
        switch type {
        case .go: return "go"
        case .google, .yahoo, .search: return "search"
        case .join: return "join"
        case .next: return "next"
        case .route: return "route"
        case .send: return "send"
        case .done: return "done"
        case .emergencyCall: return "emergency"
        case .continue: return "continue"
        default: return nil
        }
    }

    // MARK: - Caps

    /// Shared with the extension's `SuggestionBar`, so the bar matches the keys.
    enum Style {
        static let key = UIColor(white: 0.42, alpha: 1)          // ~#6B6B6B
        static let keyPressed = UIColor(white: 0.58, alpha: 1)
        static let special = UIColor(white: 0.27, alpha: 1)      // ~#454545
        static let specialPressed = UIColor(white: 0.42, alpha: 1)
        /// Behind the extension's bar and keys (`SuggestionBar.host`): dark in light apps too.
        static let backdrop = UIColor(white: 0.13, alpha: 1)
        static let hint = UIColor(white: 1, alpha: 0.6)           // secondary label
        static let hintFont = UIFont.systemFont(ofSize: 10)
        static let letterFont = UIFont.systemFont(ofSize: 22)
        static let wordFont = UIFont.systemFont(ofSize: 16)
        static let symbol = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    }

    private func build() {
        hidePreview()
        caps.joined().forEach { $0.removeFromSuperview() }
        var rows = Self.rows
        if showsGlobe { rows[rows.count - 1].insert(.globe, at: 0) }
        caps = rows.map { $0.map(makeCap) }
        refreshLabels()
        setNeedsLayout()
    }

    private func makeCap(_ key: Key) -> Cap {
        let cap = Cap(key: key)
        // Digits take the special keys' dimmer fill, setting the row off from the letters.
        let plain: Bool
        switch key {
        case .char(let c): plain = c.first?.isNumber != true
        case .space: plain = true
        default: plain = false
        }
        cap.fill = plain ? Style.key : Style.special
        cap.pressedFill = plain ? Style.keyPressed : Style.specialPressed
        cap.accessibilityTraits = .keyboardKey
        if key == .globe {
            // The one cap that takes its own touches: `handleInputModeList` wants a
            // control's touch events, to switch on a tap and list keyboards on a hold.
            // A nil target sends it up the responder chain to the extension's
            // UIInputViewController. VoiceOver's activate falls back to a real tap.
            cap.isUserInteractionEnabled = true
            cap.addTarget(nil, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                          for: .allTouchEvents)
        } else {
            cap.activate = { [weak self] in self?.press(key) }
        }
        if case .char(let c) = key, let symbol = Self.holdSymbol[c] {
            cap.hint.text = symbol
            cap.hint.font = Style.hintFont
            cap.hint.textColor = Style.hint
            // VoiceOver can't hold a key: the symbol is the cap's action instead.
            cap.accessibilityCustomActions = [UIAccessibilityCustomAction(name: symbol) { [weak self] _ in
                self?.press(.char(symbol)); return true
            }]
        }
        addSubview(cap)
        return cap
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { feed(touches, .cancelled) }

    /// Whether a touch that hit-tested to `view` is the tracker's. Not `=== self`: UIKit
    /// puts its own content views inside a UIInputView, so key touches land on those. Only
    /// a control (the globe cap) takes its own touches.
    static func feeds(_ view: UIView?) -> Bool { !(view is UIControl) }

    private func feed(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
        let byID = Dictionary(uniqueKeysWithValues: touches.filter { Self.feeds($0.view) }.map { (Int(bitPattern: ObjectIdentifier($0)), $0) })
        for id in Self.inputOrder(byID.map { ($0.key, $0.value.timestamp) }) {
            track(phase, id: id, at: byID[id]!.location(in: self))
        }
    }

    /// Oldest first. Touches from one event share a timestamp and a Set has no order, so
    /// ties break on the touch id: the same touches always go in the same order.
    static func inputOrder(_ touches: [(id: Int, timestamp: TimeInterval)]) -> [Int] {
        touches.sorted { ($0.timestamp, $0.id) < ($1.timestamp, $1.id) }.map(\.id)
    }

    /// One touch event, `at` in this view's coordinates. The UIKit overrides call it;
    /// so do the tests, which can't make UITouches.
    func track(_ phase: UITouch.Phase, id: Int, at point: CGPoint) {
        switch phase {
        case .began:
            knownCache = [:]; screenCache = nil
            feedback()
            let bottomRow = caps.last?.map(\.frame.maxY).max() ?? .infinity
            perform(tracker.began(id, key(at: point), at: point, belowKeys: point.y > bottomRow))
            stopHold()
            if tracker.previewKey != nil { startHold(id, at: point) }
        case .moved:
            tracker.moved(id, key(at: point), at: point)
            if holdTouch?.id == id { holdTouch?.at = point }
        case .ended:
            tracker.moved(id, key(at: point), at: point)
            perform(tracker.ended(id))
            if holdTouch?.id == id { stopHold() }
        case .cancelled:
            perform(tracker.cancelled(id, at: point))   // only how far it traveled matters
            if holdTouch?.id == id { stopHold() }
        default:
            return
        }
        refreshPressed()
    }

    /// The key nearest `point`, so the gaps, margins and the strip under the bottom row
    /// all belong to a key, unless `corrected` moves it to a neighbor that continues the
    /// word. Began, moved and the preview all ask here, so they agree.
    func key(at point: CGPoint) -> Key {
        let keys = caps.joined().map { ($0.key, $0.frame) }
        return Self.corrected(nearest(at: point), at: point, keys: keys, prefix: word) { s in
            if let known = knownCache[s] { return known }
            var known = Self.dictionaryKnows(s) || ShellWords.all.contains { $0.hasPrefix(s) }
            if !known {   // the screen last, and only if the dictionaries don't settle it
                if screenCache == nil { screenCache = screenWords?() ?? [] }
                known = screenCache!.contains { $0.hasPrefix(s) }
            }
            knownCache[s] = known
            return known
        }
    }

    /// The key nearest `point`, uncorrected: what a hold converts. Never the globe: a
    /// touch beside its cap goes to the next key over, since only the cap can open the
    /// keyboard list.
    private func nearest(at point: CGPoint) -> Key {
        caps.joined().filter { $0.key != .globe }.min { Self.distance(point, $0.frame) < Self.distance(point, $1.frame) }?.key ?? .space
    }

    /// Start the next word afresh: a key went to the terminal some other way.
    func resetWord() { word = "" }

    /// 0 inside `r`.
    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
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
        if let cap { showPreview(cap, tracker.previewSymbol) } else { hidePreview() }
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
            case .ret:
                if let returnTitle { title = returnTitle; label = returnTitle } else { image = "return.left"; label = "new line" }
            case .globe: image = "globe"; label = "next keyboard"
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
    /// rise over the shortcut bar whatever the input host's ancestors clip. A held key's
    /// bubble shows the `symbol` it will type.
    private func showPreview(_ cap: Cap, _ symbol: String?) {
        guard let text = symbol ?? cap.title(for: .normal) else { return }
        guard cap !== previewCap || preview.label.text != text || preview.superview == nil else { return }
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

    // Hold: a character touch still waiting after `holdDelay` types its symbol on lift.
    private func startHold(_ id: Int, at point: CGPoint) {
        holdTouch = (id, point)
        let t = Timer(timeInterval: KeyTouchTracker.holdDelay, repeats: false) { [weak self] _ in self?.fireHold() }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
    }

    private func stopHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdTouch = nil
    }

    /// The hold timer's end; tests call it in place of waiting. Converts on the key under
    /// the finger now, without correction: a hold is deliberate.
    func fireHold() {
        guard let h = holdTouch else { return }
        stopHold()
        guard tracker.hold(h.id, over: nearest(at: h.at)) else { return }
        haptics.impactOccurred()
        haptics.prepare()
        refreshPressed()
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
        if window == nil { stopRepeat(); stopHold(); tracker.reset(); refreshPressed() }   // dismissed mid-hold
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
    /// (shift) pins it and the last key to the edges and centers the letters between;
    /// anything else is centered.
    static func place(_ keys: [Key], width: CGFloat) -> [(x: CGFloat, w: CGFloat)] {
        let g = keyGap, u = (width - 9 * g) / 10
        let n = keys.prefix { if case .char = $0 { return true } else { return false } }.count
        if n >= 9, n == keys.count {
            let kw = (width - g * CGFloat(n - 1)) / CGFloat(n)
            return keys.indices.map { (CGFloat($0) * (kw + g), kw) }
        }
        func w(_ k: Key) -> CGFloat {
            switch k {
            case .char, .globe: return u
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

// MARK: - Touch correction

extension TerminalKeyboard {
    /// What a touch types once the word typed so far is taken into account. With a
    /// `prefix`, a touch off the center of a letter that starts no `known` word after it
    /// goes to the closest letter within half a key width that does: "tes" and a touch
    /// on r's right edge types t. A centered hit, an empty prefix, a known continuation
    /// or no known neighbor keeps `nearest`, so only an already ambiguous touch ever
    /// moves. Only letters are corrected: digits and symbols never. A hold isn't corrected
    /// at all (`fireHold`). Lowercase in and out; `press` applies shift.
    ///
    /// The center is checked first, so `known` (and the screen it may read) is asked only
    /// for an ambiguous touch.
    ///
    /// ponytail: a password typed at a prompt is corrected too, at a key's edge, like the
    /// system keyboard's own dynamic hit areas. A secure-entry signal could switch it off.
    static func corrected(_ nearest: Key, at point: CGPoint, keys: [(Key, CGRect)],
                          prefix: String, known: (String) -> Bool) -> Key {
        func letter(_ k: Key) -> String? {
            if case .char(let c) = k, c.first?.isLetter == true { return c }
            return nil
        }
        guard !prefix.isEmpty, let c = letter(nearest),
              let frame = keys.first(where: { $0.0 == nearest })?.1 else { return nearest }
        let center = frame.insetBy(dx: frame.width / 4, dy: frame.height / 4)
        if center.contains(point) || known(prefix + c) { return nearest }
        let reach = frame.width / 2
        let candidates = keys
            .filter { $0.0 != nearest && letter($0.0) != nil && distance(point, $0.1) <= reach }
            .sorted { distance(point, $0.1) < distance(point, $1.1) }
        return candidates.first { known(prefix + letter($0.0)!) }?.0 ?? nearest
    }

    /// Also the extension's suggestions' (`Suggestions`): one checker per process.
    static let language: String? = {
        let all = UITextChecker.availableLanguages
        return all.contains("en_US") ? "en_US" : all.first { $0.hasPrefix("en") }
    }()
    /// One checker for every keyboard, warmed by its first lookups here; `init` touches
    /// it, so the lexicon loads with the keyboard, not on the first ambiguous touch.
    ///
    /// ponytail: that load is ~130 ms on the main thread, once per process, paid when the
    /// session screen builds the keyboard (UITextChecker is main-actor only). Warm it
    /// after the screen settles if that open ever feels slow.
    static let checker: UITextChecker = {
        let c = UITextChecker()
        if let language {
            let r = NSRange(location: 0, length: 2)
            _ = c.completions(forPartialWordRange: r, in: "te", language: language)
            _ = c.rangeOfMisspelledWord(in: "te", range: r, startingAt: 0, wrap: false, language: language)
        }
        return c
    }()

    /// `s` is an English word or the start of one.
    ///
    /// ponytail: English only, and the dictionary sees a shell token as a misspelling;
    /// `ShellWords` and the screen cover those. Another language means a second checker.
    static func dictionaryKnows(_ s: String) -> Bool {
        guard let language else { return false }
        let range = NSRange(location: 0, length: (s as NSString).length)
        if !(checker.completions(forPartialWordRange: range, in: s, language: language) ?? []).isEmpty { return true }
        return checker.rangeOfMisspelledWord(in: s, range: range, startingAt: 0, wrap: false,
                                             language: language).location == NSNotFound
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
/// keyboard's touch tracking), a hairline bottom shadow like the system keys, and the
/// hold symbol's `hint` in the top-right corner. Touches go through to the keyboard view.
private final class Cap: UIButton {
    let key: TerminalKeyboard.Key
    var fill: UIColor = .gray { didSet { refill() } }
    var pressedFill: UIColor = .lightGray
    let hint = UILabel()

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
        titleLabel?.adjustsFontSizeToFitWidth = true   // a long return title ("emergency")
        titleLabel?.minimumScaleFactor = 0.5
        isUserInteractionEnabled = false
        addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        hint.sizeToFit()
        // Tucked into the corner: at 375 pt a 22 pt M or Z reaches within 3 pt of it.
        hint.frame.origin = CGPoint(x: bounds.maxX - hint.frame.width - 2.5, y: 0)
    }

    override var isHighlighted: Bool { didSet { refill() } }
    private func refill() { backgroundColor = isHighlighted ? pressedFill : fill }

    /// VoiceOver's double-tap: the cap has no actions of its own to fire.
    var activate: (() -> Void)?
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}
