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

    /// `locks` false: a quick second tap turns it off like a slow one (Enable Caps Lock off).
    mutating func tap(at time: TimeInterval, locks: Bool = true) {
        switch mode {
        case .off: mode = .once
        case .once: mode = locks && time - lastTap <= Self.doubleTapWindow ? .locked : .off
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

/// The Keyboard section of the app's Settings: Apple's Settings › General › Keyboard
/// switches, for the features this keyboard has. iOS tells a custom keyboard none of its
/// own. The app writes them to the App Group's defaults (`store`); the extensions read
/// them each time they appear, the app's keyboard each time it rises.
struct KeyboardSettings: Equatable {
    static let suiteName = "group.eu.illegible.prosperios"
    /// The shared defaults, nil if unavailable. Settable for tests.
    static var store: () -> UserDefaults? = { UserDefaults(suiteName: suiteName) }

    enum Key {
        static let autoCapitalization = "keyboard.autoCapitalization"
        static let autoCorrection = "keyboard.autoCorrection"
        static let capsLock = "keyboard.capsLock"
        static let predictiveText = "keyboard.predictiveText"
        static let characterPreview = "keyboard.characterPreview"
        static let periodShortcut = "keyboard.periodShortcut"
    }

    /// Shift on at a sentence start (`TerminalKeyboard.autoCapitalize`). Off by default.
    var autoCapitalization = false
    /// A separator replaces a misspelled word (`Suggestions.correction`).
    var autoCorrection = true
    /// A quick second shift tap locks caps (`ShiftState.tap`).
    var capsLock = true
    /// The bar's words; Paste and AutoFill stay (`Suggestions.state`).
    var predictiveText = true
    /// The bubble over a pressed key; a hold's symbol still shows (`refreshPressed`).
    var characterPreview = true
    /// A double space types ". " (`TerminalKeyboard.doubleSpacePeriod`).
    var periodShortcut = true

    init() {}
    /// What `defaults` holds, the default for anything it doesn't; nil is all defaults.
    init(_ defaults: UserDefaults?) {
        func read(_ key: String, _ value: inout Bool) {
            if let v = defaults?.object(forKey: key) as? Bool { value = v }
        }
        read(Key.autoCapitalization, &autoCapitalization)
        read(Key.autoCorrection, &autoCorrection)
        read(Key.capsLock, &capsLock)
        read(Key.predictiveText, &predictiveText)
        read(Key.characterPreview, &characterPreview)
        read(Key.periodShortcut, &periodShortcut)
    }

    /// The shared values. Without Full Access an extension can't reach the group: defaults.
    static func current(fullAccess: Bool = true) -> KeyboardSettings {
        KeyboardSettings(fullAccess ? store() : nil)
    }

    // MARK: AutoFill hop

    /// The globe's advance toggles between the two most recent keyboards, so with both
    /// Prosper keyboards there it never reaches Apple's. AutoFill marks the tap here; the
    /// sibling, appearing, advances once more (`hops`), to the next keyboard in Settings
    /// order. Not gated on Full Access: without it the group isn't shared and the mark
    /// expires unread.
    static let hopKey = "keyboard.autofillHop"
    /// How long a mark stays fresh: the sibling appears 50–60 ms after the tap.
    static let hopWindow: TimeInterval = 0.5

    static func markHop(from bundle: String, at date: Date = Date()) {
        store()?.set(["from": bundle, "at": date.timeIntervalSince1970], forKey: hopKey)
    }

    /// The mark, removed as it's read, so a hop never repeats.
    static func takeHop() -> (from: String, at: Date)? {
        guard let defaults = store(), let mark = defaults.dictionary(forKey: hopKey) else {
            return nil
        }
        defaults.removeObject(forKey: hopKey)
        guard let from = mark["from"] as? String, let at = mark["at"] as? TimeInterval else {
            return nil
        }
        return (from, Date(timeIntervalSince1970: at))
    }

    /// Hop on: a fresh mark from the other Prosper keyboard, in a login field.
    static func hops(_ mark: (from: String, at: Date)?, own: String, now: Date,
                     login: Bool) -> Bool {
        guard let mark, login, mark.from != own else { return false }
        let age = now.timeIntervalSince(mark.at)
        return age >= 0 && age < hopWindow
    }
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
/// - A space touch still waiting after `holdDelay` (`startTrackpad`) is a trackpad, as on
///   Apple's keyboard: every `caretStep` its finger travels sideways moves the caret one
///   character, and lifting it types nothing. Other fingers are ignored until it lifts.
///   Never one begun under the keys: that strip is the home gesture's.
///
/// Points are in the view's coordinates; the defaults suit callers that don't care
/// about travel.
struct KeyTouchTracker {
    typealias Key = TerminalKeyboard.Key
    /// `caret`: trackpad steps, negative left.
    enum Effect: Equatable { case press(Key), startRepeat, stopRepeat, caret(Int) }

    /// How far a finger may travel and still count as a tap if it's cancelled.
    static let tapSlop: CGFloat = 10
    /// How long a character touch stays down before it types its symbol instead.
    static let holdDelay: TimeInterval = 0.35
    /// How far a trackpad finger travels sideways per character the caret moves.
    ///
    /// ponytail: a fixed step, no acceleration, and sideways only: the host field's proxy
    /// has no line geometry and the terminal's up/down is shell history. Tune it on device;
    /// add a speed curve if long moves feel slow.
    static let caretStep: CGFloat = 9

    private struct Touch {
        let id: Int; var key: Key; var done: Bool
        let start: CGPoint; var travel: CGFloat = 0
        var belowKeys = false
        /// Set by a hold: what the touch types instead of `key`.
        var symbol: String?
        /// Set by a space hold: trackpad mode, the x its caret steps count from.
        var anchor: CGFloat?
        var output: Key { symbol.map(Key.char) ?? key }
        mutating func reach(_ p: CGPoint) { travel = max(travel, hypot(p.x - start.x, p.y - start.y)) }
    }
    private var touches: [Touch] = []

    /// A space hold is moving the caret: the keyboard blanks its labels until it lifts.
    var isTrackpad: Bool { touches.contains { $0.anchor != nil } }
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
        if isTrackpad { return [] }   // a second finger on the trackpad: never tracked
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
    /// other lift key. A trackpad touch steps the caret instead, whatever key it's over.
    @discardableResult
    mutating func moved(_ id: Int, _ key: Key, at point: CGPoint? = nil) -> [Effect] {
        guard let i = touches.firstIndex(where: { $0.id == id }) else { return [] }
        if let point { touches[i].reach(point) }
        if let anchor = touches[i].anchor {
            guard let point else { return [] }
            let steps = Int((point.x - anchor) / Self.caretStep)
            if steps == 0 { return [] }
            touches[i].anchor = anchor + CGFloat(steps) * Self.caretStep
            return [.caret(steps)]
        }
        guard !touches[i].done, touches[i].symbol == nil, !Self.actsOnDown(key) else { return [] }
        touches[i].key = key
        return []
    }

    /// The touch has stayed down `holdDelay`, now at `x`: a space touch becomes a trackpad
    /// until it lifts, and lifting types nothing (Apple's types no space either). True if
    /// it did.
    mutating func startTrackpad(_ id: Int, at x: CGFloat) -> Bool {
        guard let i = touches.firstIndex(where: { $0.id == id }), !touches[i].done,
              touches[i].key == .space, !touches[i].belowKeys else { return false }
        touches[i].done = true
        touches[i].anchor = x
        return true
    }

    /// The touch has stayed down `holdDelay`, now over `key`: the nearest key, uncorrected,
    /// since a hold is deliberate. True if it now types that key's symbol in `symbols`.
    mutating func hold(_ id: Int, over key: Key,
                       symbols: [String: String] = TerminalKeyboard.holdSymbol) -> Bool {
        guard let i = touches.firstIndex(where: { $0.id == id }), !touches[i].done,
              touches[i].symbol == nil, case .char(let c) = key,
              let symbol = symbols[c] else { return false }
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

/// Trackpad steps through a host field's document proxy, whose `adjustTextPosition` counts
/// Characters (WebKit) or UTF-16 units (UIKit), and whose context lags each move until the
/// host round-trips. The host isn't named, and UIKit's keyboard daemon can crash when the
/// caret lands inside a surrogate pair, so below the poll limit (`poll`) no move is sized
/// to land inside one:
/// - One move is in flight at a time: steps queue until the context changes from the one
///   the move left to one its landing explains, and the next move is sized from the
///   context then. Until the next move any other context is an older answer from a host
///   that's behind (`believed`), and the steps wait for the latest.
/// - A Character goes at its UTF-16 length unless the host is known to count Characters
///   (`utf16` false): UIKit lands exactly, WebKit goes further, by whole Characters.
/// - Until the host is known, a move is no longer in units than the Characters in sight,
///   and the context after it tells which happened (`landings`): WebKit's overshoot
///   goes back, and the host is known from then on.
/// - Right after a move UIKit's proxy shows its own guess, the move taken as Characters,
///   until the host answers with its units. A context after a move that isn't plain is
///   believed only 40 ms on (`settled`), unless it splits a Character, which no guess
///   does; a WebKit landing only once the view stops waiting (`timedOut`), and once the
///   host is known to count units, never.
/// - Past the end of the context (a line's or the document's) one unit goes blind, and
///   any move that lands inside a Character (a CR LF) gets one more code point the same
///   way, so below the poll limit it never stops between a surrogate pair's halves. The
///   host counts units then, so a context reading as that code point taken as a Character
///   is the guess.
/// - The view stops waiting 0.3 s after the move or after the last new context the host
///   showed (`poll`): a host still answering older moves is working, not ignoring this one.
/// - A move that can't show (a long run of one character in WebKit's fixed windows) is
///   taken as landed when the view stops waiting (`timedOut`).
/// - A field whose context stays empty after a move gets every step as asked (`blank`).
struct CaretWalk {
    /// The host counts UTF-16 units; nil until a move shows which.
    var utf16: Bool?
    /// Steps asked for and not sent yet, negative left.
    private(set) var queued = 0
    /// The move in flight: the proxy's context it left (`seen`), the context it was sized
    /// from, its direction, the Characters it crossed and the units it sent, and whether
    /// they were all single units and no line break, or the move was blind, and whether
    /// the view stopped waiting for it (`late`).
    private var sent: (seen: (String, String), before: String, after: String,
                       dir: Int, chars: Int, units: Int, plain: Bool, blind: Bool, late: Bool)?
    /// The field showed no context even after a move (`timedOut`): nothing to size by or
    /// see a split in, so steps go as asked until it shows some.
    var blank = false
    /// The context the last move was taken to land in, until a touch or the poll limit.
    private var believed: (String, String)?
    /// Where the walk reckons the caret is while the proxy still shows `seen`.
    private var reckoned: (seen: (String, String), before: String, after: String)?
    /// The context the last step saw, and the polls since a move or since it last changed.
    private var shown: (String, String)?
    private var quiet = 0
    var idle: Bool { sent == nil && queued == 0 }

    /// `steps` more Characters, negative left (0 checks the move in flight), given the
    /// proxy's context now, and whether 40 ms have passed since the last move (`settled`):
    /// the units to move it now.
    mutating func step(_ steps: Int, before b: String, after a: String, settled: Bool = true) -> Int {
        if !b.isEmpty || !a.isEmpty { blank = false }
        if let w = shown, !Self.same(w, b, a) { quiet = 0 }
        shown = (b, a)
        if blank { defer { queued = 0 }; return queued + steps }
        queued += steps
        if let r = reckoned, !Self.same(r.seen, b, a) { reckoned = nil }
        if let s = sent {
            if Self.same(s.seen, b, a) {
                // Nothing shown when the view stopped waiting: UIKit's proxy shows at least its
                // guess, so WebKit, which ignored a move past the end of its text (again, in
                // Characters) or went its units in Characters where its windows read the same.
                guard s.late, utf16 == nil, s.units != s.chars else { return 0 }
                utf16 = false
                queued += s.dir * (s.units > (s.dir < 0 ? s.before : s.after).count ? s.chars : s.chars - s.units)
            } else if Self.splits(before: b, after: a) {
                utf16 = true
                return send(s.dir * Self.codePoint(before: b, after: a, dir: s.dir), (b, a), b, a, dir: s.dir, chars: 1, blind: true)
            } else if !s.plain, !settled {
                return 0   // UIKit's guess, maybe: a line break crossed in Characters
            } else if s.blind {
                // A known UIKit host's extra lands exactly its units on: the Character's landing
                // instead is its guess. One that neither explains crossed out of sight.
                if utf16 == true, !(s.dir < 0 ? s.before : s.after).isEmpty {
                    let fit = Self.landings(before: s.before, after: s.after, dir: s.dir, chars: s.chars, units: s.units,
                                            nowBefore: b, nowAfter: a)
                    if fit.units == 0, fit.chars != 0 { return 0 }
                }
            } else {
                let fit = Self.landings(before: s.before, after: s.after, dir: s.dir, chars: s.chars, units: s.units,
                                        nowBefore: b, nowAfter: a)
                if fit.units == 0, fit.chars == 0 {
                    guard s.late else { return 0 }   // an older answer: the host is behind
                } else if fit.chars > fit.units, fit.back > 0 {
                    guard utf16 == nil, s.late else { return 0 }   // UIKit's guess, maybe
                    utf16 = false
                    return send(-s.dir * fit.back, (b, a), b, a, dir: -s.dir, chars: fit.back)
                } else if fit.units > fit.chars {
                    utf16 = true
                }
            }
            sent = nil
            believed = (b, a)
        }
        // Nothing sent since the walk believed a landing: any other context is an older answer.
        if sent == nil, let w = believed, !Self.same(w, b, a), queued != 0 { return 0 }
        guard queued != 0 else { return 0 }
        let (before, after) = reckoned.map { ($0.before, $0.after) } ?? (b, a)
        let d = queued.signum(), ahead = d < 0 ? Array(before.reversed()) : Array(after)
        var units = 0, n = 0, plain = true
        for c in ahead.prefix(abs(queued)) {
            let w = utf16 == false ? 1 : c.utf16.count
            if utf16 == nil, n > 0, units + w > ahead.count { break }   // WebKit's overshoot stays in sight
            units += w
            n += 1
            plain = plain && c.utf16.count == 1 && !c.isNewline
        }
        if n == 0 { queued -= d; return send(d, (b, a), before, after, dir: d, chars: 1, blind: true) }
        queued -= d * n
        return send(d * units, (b, a), before, after, dir: d, chars: n, plain: plain)
    }

    /// The view stopped waiting for the move in flight to show, its context still `seen`,
    /// or with none in flight, for the context `believed` to come back (forgotten now):
    /// - A blind move from no context at all: the field shows none (`blank`).
    /// - Any other blind move (past the document's end): forgotten, with the steps behind.
    ///   ponytail: a host only stalled at a line's end looks the same, and a step stacked
    ///   on the forgotten move can split an emoji starting the next line; tell them apart
    ///   when a device shows how.
    /// - One over as many units as Characters whose landing reads as `seen` does, as far as
    ///   `seen` reaches (a long run of one character): taken as landed there.
    /// - Any other keeps waiting, now `late`: a next move sized from a context that hasn't
    ///   shown this one could land inside a Character once the host applies both. A WebKit
    ///   landing it shows is believed now, and so are one that shows nothing and one its
    ///   landing doesn't explain (`step`). ponytail: 0.3 s with nothing new shown (`poll`),
    ///   so a UIKit host taking longer than that over one move is taken for WebKit if the
    ///   walk doesn't know it yet, and its older answers for the latest; wait on the host's
    ///   own signal if a device shows one.
    mutating func timedOut() {
        guard let s = sent else { believed = nil; return }
        if s.blind {
            if s.seen.0.isEmpty, s.seen.1.isEmpty { blank = true; sent = nil } else { drop() }
            return
        }
        sent?.late = true
        let n = s.chars
        let landed = s.dir > 0 ? (s.before + s.after.prefix(n), String(s.after.dropFirst(n)))
                               : (String(s.before.dropLast(n)), s.before.suffix(n) + s.after)
        guard s.units == s.chars, Self.agree(Array(landed.0.utf16)[...], Array(landed.1.utf16)[...],
                                  Array(s.seen.0.utf16), Array(s.seen.1.utf16)) else { return }
        reckoned = (s.seen, landed.0, landed.1)
        sent = nil
    }

    /// One tick of the view's 20 ms poll: past 15 since the move or since the host last
    /// showed a new context (it's still answering older moves), the view stops waiting.
    mutating func poll() {
        quiet += 1
        if quiet > 15 { timedOut() }
    }

    /// Forget the move in flight, the steps behind it and what the field showed: a touch
    /// starts afresh, looking for context again.
    mutating func drop() { sent = nil; reckoned = nil; believed = nil; queued = 0; blank = false }

    private mutating func send(_ units: Int, _ seen: (String, String), _ before: String, _ after: String,
                               dir: Int, chars: Int, plain: Bool = false, blind: Bool = false) -> Int {
        sent = (seen, before, after, dir, chars, abs(units), plain, blind, false)
        quiet = 0
        return units
    }

    private static func same(_ seen: (String, String), _ before: String, _ after: String) -> Bool {
        seen.0.utf16.elementsEqual(before.utf16) && seen.1.utf16.elementsEqual(after.utf16)
    }

    /// How well the context a host shows now fits a move of `units` (sign `dir`) over
    /// `chars` Characters from between `before` and `after` landing in UTF-16 units, and in
    /// Characters, n of them too far (`back`). Each landing is checked in the text the walk
    /// saw, Characters clamped to its end: 0 if it doesn't fit, 1 if both sides agree as far
    /// as both reach (WebKit's windows slide, UIKit's stop at the line), 2 if both reach
    /// exactly as far. Where both landings are one, they fit alike.
    static func landings(before: String, after: String, dir: Int, chars: Int, units: Int,
                         nowBefore: String, nowAfter: String) -> (units: Int, chars: Int, back: Int) {
        let head = uncut(Array(before.utf16), start: true), text = head + uncut(Array(after.utf16), start: false)
        let at = head.count, widths = (dir < 0 ? Array(before.reversed()) : Array(after)).map(\.utf16.count)
        let crossed = min(units, widths.count)
        let b = uncut(Array(nowBefore.utf16), start: true), a = uncut(Array(nowAfter.utf16), start: false)
        func fit(_ q: Int) -> Int {
            guard text.indices.contains(q) || q == text.count else { return 0 }
            let tb = text[..<q], ta = text[q...]
            guard agree(tb, ta, b, a) else { return 0 }
            return tb.count == b.count && ta.count == a.count ? 2 : 1
        }
        return (fit(at + dir * units), fit(at + dir * widths.prefix(crossed).reduce(0, +)), crossed - chars)
    }

    /// The units of the code point next to a caret inside a Character, toward `dir`: 2 for
    /// a whole surrogate pair, else 1 (a lone half, or U+FFFD in its place).
    private static func codePoint(before: String, after: String, dir: Int) -> Int {
        let u = dir < 0 ? Array(before.utf16.suffix(2).reversed()) : Array(after.utf16.prefix(2))
        guard u.count == 2 else { return 1 }
        return dir < 0 ? (UTF16.isTrailSurrogate(u[0]) && UTF16.isLeadSurrogate(u[1]) ? 2 : 1)
                       : (UTF16.isLeadSurrogate(u[0]) && UTF16.isTrailSurrogate(u[1]) ? 2 : 1)
    }

    /// Two contexts around one caret read the same as far as both reach.
    private static func agree(_ tb: ArraySlice<UInt16>, _ ta: ArraySlice<UInt16>, _ b: [UInt16], _ a: [UInt16]) -> Bool {
        tb.suffix(b.count).elementsEqual(b.suffix(tb.count)) && ta.prefix(a.count).elementsEqual(a.prefix(ta.count))
    }

    /// `units` without the surrogate half (or U+FFFD) a context's window may have cut off
    /// at its far end, its `start` for a before-context.
    private static func uncut(_ units: [UInt16], start: Bool) -> [UInt16] {
        guard let x = start ? units.first : units.last,
              x == 0xFFFD || (start ? UTF16.isTrailSurrogate(x) : UTF16.isLeadSurrogate(x)) else { return units }
        return start ? Array(units.dropFirst()) : Array(units.dropLast())
    }

    /// The caret between `before` and `after` is inside one Character: between a surrogate
    /// pair's halves (lone, or each shown as U+FFFD), or between pieces that join into one
    /// (CR LF, a combining mark, a ZWJ sequence, a keycap). A CR with nothing after it is
    /// a CR LF's half too: the after-context stops at the line's end.
    static func splits(before: String, after: String) -> Bool {
        guard let l = before.utf16.last else { return false }
        guard let r = after.utf16.first else { return l == 0x0D }
        if UTF16.isLeadSurrogate(l) || l == 0xFFFD, UTF16.isTrailSurrogate(r) || r == 0xFFFD { return true }
        guard let x = before.last, let y = after.first else { return false }
        return (String(x) + String(y)).count == 1
    }
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
/// Holding space turns the keys into a trackpad, as on Apple's keyboard: the labels blank
/// out and a sideways drag moves the caret (`caret`), through `moveCaret` in the app (arrow
/// keys) and the field's document proxy in the extension.
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
/// (`doubleSpacePeriod`). The Bulgarian extension's has Bulgarian letters (`Layout`); the
/// app's is always English.
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
    static let keysHeight = keysHeight(compact: false)
    /// Rows, gaps and the top pad: the above, or in a compact vertical size class (iPhone
    /// landscape) shorter ones. The portrait keys on a 402 pt tall landscape screen took
    /// 63% of it and hid the focused field; these come to 149 pt, so the extension
    /// (32 pt bar + 149 + 6) is about the Apple keyboard's landscape height (QA measured
    /// the old 36 + 174 + 6 ~30 pt taller). The bar + the 3 pt top pad is the bubble's
    /// compact rise (`KeyPreview.rise(compact:)`).
    static func metrics(compact: Bool) -> (row: CGFloat, gap: CGFloat, top: CGFloat) {
        compact ? (26, 4, 3) : (rowHeight, rowGap, topPadding)
    }
    /// The host window's system gesture gate holds a touch near the left or right edge
    /// until the lift, so an edge key shows no pressed look and its hold fails: let it
    /// through. `delaysTouchesEnded` stays.
    static func undelayEdges(_ window: UIWindow?) {
        window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
    }
    static func keysHeight(compact: Bool) -> CGFloat {
        let m = metrics(compact: compact)
        return m.top + 5 * m.row + 4 * m.gap
    }
    /// Under the bottom row, in place of the 34 pt home-indicator inset: enough to keep
    /// the space bar off the bottom edge, where the home gesture starts. (Deferring that
    /// gesture does nothing on iPhone; a cancelled touch begun here types nothing, see
    /// the tracker.)
    static let bottomPadding: CGFloat = 28
    /// This keyboard's pad under the bottom row: `bottomPadding` in the app. The extension
    /// sets a few points, since iOS already keeps its own strip under a custom keyboard.
    var bottomInset = TerminalKeyboard.bottomPadding {
        didSet { fitHeight() }
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

    /// Apple's "Bulgarian – QWERTY" (phonetic) letters, 11 / 11 / 8, between the same
    /// digits and bottom row.
    static let bulgarianRows: [[Key]] = [
        rows[0],
        chars("явертъуиопю"),
        chars("асдфгхйклшщ"),
        [.shift] + chars("зьцжбнмч") + [.backspace],
        rows[4],
    ]

    /// English's holds on the same physical keys, so all 32 ASCII symbols stay where they
    /// were, except that и holds ѝ, as Apple's does, and its > moves to ю. ш, щ and ч
    /// have none.
    static let bulgarianHoldSymbol: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "я": "`", "в": "\\", "е": "~", "р": "|", "т": "[", "ъ": "]", "у": "<", "и": "ѝ", "о": "{", "п": "}",
        "ю": ">",
        "а": "@", "с": "#", "д": "&", "ф": "*", "г": "-", "х": "+", "й": "=", "к": "(", "л": ")",
        "з": "_", "ь": "$", "ц": "\"", "ж": "'", "б": ":", "н": ";", "м": "/",
    ]

    /// A keyboard's letters and their dictionary, picked once at init: English for the
    /// app's terminal and the Prosper extension, Bulgarian for the Bulgarian extension
    /// (`init(extension:)`).
    ///
    /// ponytail: two hand-written layouts. A third language means a table per layout
    /// (rows, holds, checker language) rather than another case in each switch.
    enum Layout: Equatable {
        case english, bulgarian

        /// An extension's `PrimaryLanguage` ("bg-BG"); anything else is English.
        init(primaryLanguage: String?) {
            self = primaryLanguage?.hasPrefix("bg") == true ? .bulgarian : .english
        }
        /// The one a keyboard extension's Info.plist names (`NSExtensionAttributes`).
        init(extension bundle: Bundle) {
            let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any]
            let attributes = ext?["NSExtensionAttributes"] as? [String: Any]
            self.init(primaryLanguage: attributes?["PrimaryLanguage"] as? String)
        }

        var rows: [[Key]] { self == .english ? TerminalKeyboard.rows : TerminalKeyboard.bulgarianRows }
        var holdSymbol: [String: String] {
            self == .english ? TerminalKeyboard.holdSymbol : TerminalKeyboard.bulgarianHoldSymbol
        }
        /// The three letter rows, for `Suggestions.neighbors`.
        var letterRows: [[Character]] {
            rows[1...3].map { row in
                row.compactMap { if case .char(let c) = $0 { return Character(c) } else { return nil } }
            }
        }
        /// The longest letter row: `place` sizes the shift row's keys to match it.
        var columns: Int { rows[1].count }

        /// The checker language for what this layout types. Nil is no dictionary: no
        /// completions, guesses or autocorrect, and never English's in its place.
        var language: String? {
            switch self {
            case .english: return TerminalKeyboard.language
            case .bulgarian: return TerminalKeyboard.bulgarianSpells ? "bg_BG" : nil
            }
        }
    }

    weak var target: UIKeyInput?
    /// The responder this view is the `inputView` of: the app's terminal. Its input host
    /// pins a required height of its own, measured once at install, unless this view's
    /// height is required; and it posts the new frame (the shortcut bar rides that) only
    /// on `reloadInputViews`. So with a host the height is required and a change reloads.
    /// Nil in the extension, where the keys sit under the bar in the controller's view
    /// and `.required - 1` gives way to the system's transient sizes without a conflict.
    weak var inputHost: UIResponder? {
        didSet {
            heightConstraint.isActive = false   // required ⇄ not can't change while active
            heightConstraint.priority = inputHost == nil ? .required - 1 : .required
            heightConstraint.isActive = true
        }
    }
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
    /// keyboard, while `settings` allow it. The extension sets it; the terminal never
    /// wants it.
    var doubleSpacePeriod = false
    /// The app's Keyboard settings: the extension's controller sets them when it appears,
    /// the terminal when it takes focus.
    var settings = KeyboardSettings()
    /// The extension's suggestions (`SuggestionBar.attach`): asked before every key, it
    /// can autocorrect the word a separator ends, or take the key itself (true: backspace
    /// undoing an autocorrect) and the keyboard types nothing. Nil in the app.
    var willPress: ((Key) -> Bool)?
    /// After every key, shift included: the extension's bar recomputes. Nil in the app.
    var didPress: (() -> Void)?
    /// Where trackpad steps go, negative left: the app sends arrow keys. Nil moves the
    /// host field's caret through its document proxy (the extension).
    var moveCaret: ((Int) -> Void)?
    /// After each trackpad step: the extension's suggestions forget the word they were
    /// following, and the bar recomputes. Nil in the app.
    var didMoveCaret: (() -> Void)?
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
    /// The labels are blank: a trackpad touch is down (`refreshLabels`).
    private var blanked = false
    /// The extension's trackpad moves, and the field whose way of counting `walk` learned.
    private var walk = CaretWalk()
    private var walkField: UUID?
    private(set) var walkTimer: Timer?
    private var walkPolls = 0
    private var heightConstraint: NSLayoutConstraint!
    private var keysHeightConstraint: NSLayoutConstraint!
    private var compact: Bool { traitCollection.verticalSizeClass == .compact }

    let layout: Layout

    init(layout: Layout = .english) {
        self.layout = layout
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: Self.height), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        isMultipleTouchEnabled = true
        overrideUserInterfaceStyle = .dark
        addLayoutGuide(keysArea)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        heightConstraint.priority = .required - 1
        keysHeightConstraint = keysArea.heightAnchor.constraint(equalToConstant: Self.keysHeight)
        NSLayoutConstraint.activate([
            keysArea.topAnchor.constraint(equalTo: topAnchor),
            keysArea.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            keysArea.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            keysHeightConstraint,
            heightConstraint,
        ])
        fitHeight()
        build()
        _ = Self.dictionaryKnows("te", language: layout.language)   // loads the lexicon now
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var enableInputClicksWhenVisible: Bool { true }

    /// The height follows the size class: rotation, or the extension's traits arriving.
    /// (`traitCollectionDidChange`: `registerForTraitChanges` is iOS 17.)
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.verticalSizeClass != traitCollection.verticalSizeClass { fitHeight(); setNeedsLayout() }
    }

    private func fitHeight() {
        keysHeightConstraint.constant = Self.keysHeight(compact: compact)
        let height = keysHeightConstraint.constant + bottomInset
        guard height != heightConstraint.constant else { return }
        heightConstraint.constant = height
        // Deferred, out of the layout pass that changed the traits.
        // ponytail: the host drops a reload while the keyboard still animates (rising,
        // rotating). Rotation is covered by the app's `kbChange`; a pad change mid-rise
        // isn't, and nothing makes one today. Reload again after the animation if it does.
        if inputHost?.isFirstResponder == true {
            DispatchQueue.main.async { [weak self] in self?.inputHost?.reloadInputViews() }
        }
    }

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
            target?.insertText(shifted(c))
            if letter, shift.mode == .once { shift.typedLetter(); refreshLabels() }
        case .space:
            if doubleSpacePeriod, settings.periodShortcut, let doc = target as? UITextDocumentProxy,
               Self.periodReplacesSpace(before: doc.documentContextBeforeInput, keyboardType: doc.keyboardType ?? .default) {
                doc.deleteBackward()
                doc.insertText(". ")
            } else {
                target?.insertText(" ")
            }
        case .ret: if let sendBytes { sendBytes(Self.newlineBytes) } else { target?.insertText("\n") }
        case .backspace: target?.deleteBackward()
        case .shift:
            shift.tap(at: CACurrentMediaTime(), locks: settings.capsLock)
            refreshLabels()
            return   // the user's shift: auto-capitalization doesn't undo it
        case .globe: return   // its cap acts on its own; the tracker never yields it (`nearest`)
        }
        autoCapitalize()
    }

    /// A trackpad step of `offset` characters, negative left: in a host field, through
    /// `walk`, so it never stops inside one. The word touch correction continues ends here,
    /// as it does at an arrow key (`resetWord`).
    func caret(_ offset: Int) {
        if let moveCaret {
            moveCaret(offset)
        } else if let doc = target as? UITextDocumentProxy {
            if doc.documentIdentifier != walkField {
                walkField = doc.documentIdentifier
                walk = CaretWalk()
            }
            walkOn(offset)
        }
        word = ""
        autoCapitalize()
        didMoveCaret?()
    }

    /// `steps` more for `walk`, and what it can send now; polls the host's context until
    /// the walk is idle, or 0.3 s pass without a move landing.
    private func walkOn(_ steps: Int = 0) {
        guard let doc = target as? UITextDocumentProxy else { return }
        let units = walk.step(steps, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "",
                              settled: walkPolls >= 3)
        if units != 0 { doc.adjustTextPosition(byCharacterOffset: units); walkPolls = 0 }
        if walk.idle {
            walkTimer?.invalidate()
            walkTimer = nil
        } else if walkTimer == nil {
            let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] t in
                if let self { self.pollCaret() } else { t.invalidate() }
            }
            RunLoop.main.add(t, forMode: .common)
            walkTimer = t
        }
    }

    /// The poll timer's tick; tests call it in place of waiting.
    ///
    /// ponytail: polling, not the controller's `textDidChange`, since Safari may send
    /// none; 0.3 s of nothing new is a guess at the slowest host (`CaretWalk.poll`). A
    /// drag past the document's end waits that long before steps back count. A move that
    /// never shows stops the polling after 2 s, still waited on: the next `caret` polls
    /// again, the next touch drops it.
    func pollCaret() {
        walkPolls += 1
        walk.poll()   // the host clamped at the document's end, or never showed it
        walkOn()
        guard walkPolls >= 100 else { return }   // 2 s: a move that never shows waits for the next `caret`
        walkPolls = 0
        walkTimer?.invalidate()
        walkTimer = nil
    }

    /// Shift on at a sentence start, off elsewhere, when the target is a host app's text
    /// field that asks for it, and only with Auto-Capitalization on: the extension's. The
    /// app's target, the terminal, isn't a document proxy, so it never auto-capitalizes.
    /// `press` calls it after every key; the extension's controller also does when the
    /// field or the selection changes.
    func autoCapitalize() {
        guard let doc = target as? UITextDocumentProxy else { return }
        let on = settings.autoCapitalization
            && Self.shouldCapitalize(before: doc.documentContextBeforeInput, type: doc.autocapitalizationType ?? .none)
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
        var rows = layout.rows
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
        if case .char(let c) = key, let symbol = layout.holdSymbol[c] {
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
            if tracker.isTrackpad { return }   // a second finger on the trackpad: ignored
            if !walk.idle { walkOn() }   // a last look for a split before typing
            walk.drop()
            knownCache = [:]; screenCache = nil
            feedback()
            let bottomRow = caps.last?.map(\.frame.maxY).max() ?? .infinity
            perform(tracker.began(id, key(at: point), at: point, belowKeys: point.y > bottomRow))
            stopHold()
            if tracker.previewKey != nil || tracker.held.last == .space { startHold(id, at: point) }
        case .moved:
            perform(tracker.moved(id, key(at: point), at: point))
            if holdTouch?.id == id { holdTouch?.at = point }
        case .ended:
            perform(tracker.moved(id, key(at: point), at: point))
            perform(tracker.ended(id))
            if holdTouch?.id == id { stopHold() }
        case .cancelled:
            perform(tracker.cancelled(id, at: point))   // only how far it traveled matters
            if holdTouch?.id == id { stopHold() }
        default:
            return
        }
        if blanked, !tracker.isTrackpad { trackpadEnded() }
        refreshPressed()
    }

    /// The trackpad finger lifted: the labels come back as they were, shift's included.
    /// The extension's bar and shift read the moved caret's text again a moment later.
    ///
    /// ponytail: a proxy may still report the text around the old caret right after
    /// `adjustTextPosition`, and Safari sends no `selectionDidChange`; one re-read 0.1 s
    /// on is a guess at the host's lag. Re-read on the next `textDidChange` if it lags more.
    private func trackpadEnded() {
        refreshLabels()
        guard target is UITextDocumentProxy else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.autoCapitalize()
            self?.didPress?()
        }
    }

    /// The key nearest `point`, so the gaps, margins and the strip under the bottom row
    /// all belong to a key, unless `corrected` moves it to a neighbor that continues the
    /// word. Began, moved and the preview all ask here, so they agree.
    func key(at point: CGPoint) -> Key {
        let keys = caps.joined().map { ($0.key, $0.frame) }
        return Self.corrected(nearest(at: point), at: point, keys: keys, prefix: word) { s in
            if let known = knownCache[s] { return known }
            var known = Self.dictionaryKnows(s, language: layout.language)
                || ShellWords.all.contains { $0.hasPrefix(s) }
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
            case .caret(let n): caret(n)
            }
        }
    }

    /// The pressed look and the preview follow the tracker, not the caps' own tracking.
    private func refreshPressed() {
        let held = tracker.held
        for cap in caps.joined() { cap.isHighlighted = held.contains(cap.key) }
        let cap = tracker.previewKey.flatMap { k in caps.joined().first { $0.key == k } }
        let symbol = tracker.previewSymbol.map(shifted)
        // Character Preview off still shows a hold's symbol, as Apple's still shows its accents.
        if let cap, settings.characterPreview || symbol != nil { showPreview(cap, symbol) } else { hidePreview() }
    }

    /// `c` as shift types it: a letter uppercased, anything else as is.
    private func shifted(_ c: String) -> String {
        c.first?.isLetter == true && shift.uppercase ? c.uppercased() : c
    }

    /// What every cap shows: blank while a trackpad touch is down, as on Apple's keyboard.
    private func refreshLabels() {
        blanked = tracker.isTrackpad
        for cap in caps.joined() {
            var title: String?, image: String?, label: String
            switch cap.key {
            case .char(let c):
                let s = shifted(c)
                title = s; label = s
            case .shift:
                switch shift.mode {
                case .off: image = "shift"; label = "shift"
                case .once: image = "shift.fill"; label = "shift on"
                case .locked: image = "capslock.fill"; label = "caps lock"
                }
                cap.fill = shift.uppercase ? Style.key : Style.special
            case .backspace: image = "delete.left"; label = "delete"
            case .space: title = layout == .english ? "space" : "БГ"; label = "space"
            case .ret:
                if let returnTitle { title = returnTitle; label = returnTitle } else { image = "return.left"; label = "new line" }
            case .globe: image = "globe"; label = "next keyboard"
            }
            if blanked { title = nil; image = nil }
            cap.hint.isHidden = blanked
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
        preview.show(text, over: convert(cap.frame, to: host), within: host.bounds,
                     rise: KeyPreview.rise(compact: compact))
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

    // Hold: a character touch still waiting after `holdDelay` types its symbol on lift;
    // a space touch becomes the trackpad.
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

    /// The hold timer's end; tests call it in place of waiting. Space becomes the trackpad;
    /// any other key converts on the key under the finger now, without correction: a hold
    /// is deliberate.
    func fireHold() {
        guard let h = holdTouch else { return }
        stopHold()
        if tracker.startTrackpad(h.id, at: h.at.x) {
            haptics.impactOccurred()
            haptics.prepare()
            refreshLabels()
            refreshPressed()
            return
        }
        guard tracker.hold(h.id, over: nearest(at: h.at), symbols: layout.holdSymbol) else { return }
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
        if window == nil {   // dismissed mid-hold
            stopRepeat(); stopHold(); tracker.reset(); refreshPressed()
            if blanked { refreshLabels() }
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = keysArea.layoutFrame.insetBy(dx: Self.sideMargin, dy: 0)
        let m = Self.metrics(compact: compact)
        for (r, row) in caps.enumerated() {
            let y = area.minY + m.top + CGFloat(r) * (m.row + m.gap)
            // The bottom row clears the screen's rounded corners (a no-op in landscape).
            let pull = r == caps.count - 1 ? max(0, Self.bottomRowInset - area.minX) : 0
            let rowArea = area.insetBy(dx: pull, dy: 0)
            // Shift's row keeps its letters as wide as the longest row's (Bulgarian's 11).
            let columns = row.first?.key == .shift ? layout.columns : 10
            for (cap, f) in zip(row, Self.place(row.map(\.key), width: rowArea.width, columns: columns)) {
                cap.frame = CGRect(x: rowArea.minX + f.x, y: y, width: f.w, height: m.row)
            }
        }
    }

    /// Horizontal slots for one row, in a row `width` wide. A letter is one unit
    /// (`columns` units and their gaps fill the width). A row of nine or more characters
    /// stretches them to fill it. A row with space gives space the rest; a row led by a
    /// special key (shift) pins it and the last key to the edges and centers the letters
    /// between; anything else is centered.
    static func place(_ keys: [Key], width: CGFloat, columns: Int = 10) -> [(x: CGFloat, w: CGFloat)] {
        let g = keyGap, u = (width - CGFloat(columns - 1) * g) / CGFloat(columns)
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

    /// English's checker language. Also the extension's suggestions' (`Suggestions`).
    static let language: String? = {
        let all = UITextChecker.availableLanguages
        return all.contains("en_US") ? "en_US" : all.first { $0.hasPrefix("en") }
    }()
    /// One checker for every keyboard and language (each lookup names its language).
    /// `init` makes a lookup in its layout's language, so that lexicon loads with the
    /// keyboard, not on the first ambiguous touch.
    ///
    /// ponytail: that load is ~130 ms on the main thread, once per process, paid when the
    /// session screen builds the keyboard (UITextChecker is main-actor only). Warm it
    /// after the screen settles if that open ever feels slow.
    static let checker = UITextChecker()

    /// Whether the checker really spells Bulgarian. Listed isn't enough: the simulator
    /// lists bg_BG with no lexicon behind it, where every word passes and nothing is
    /// guessed. So a typo it neither flags nor fixes means none. Settable for tests.
    static var bulgarianSpells: Bool = {
        let typo = "къша", range = NSRange(location: 0, length: 4)
        return spells(
            listed: UITextChecker.availableLanguages.contains("bg_BG"),
            flags: { checker.rangeOfMisspelledWord(in: typo, range: range, startingAt: 0, wrap: false,
                                                   language: "bg_BG").location != NSNotFound },
            guesses: { checker.guesses(forWordRange: range, in: typo, language: "bg_BG") ?? [] })
    }()

    /// The probe's verdict from the checker's answers on a typo: listed, the typo flagged,
    /// and something guessed for it. The checker is asked only as far as it has to be.
    static func spells(listed: Bool, flags: () -> Bool, guesses: () -> [String]) -> Bool {
        listed && flags() && !guesses().isEmpty
    }

    /// `s` is a word in `language` (English by default) or the start of one.
    ///
    /// ponytail: the dictionary sees a shell token as a misspelling; `ShellWords` and the
    /// screen cover those.
    static func dictionaryKnows(_ s: String, language: String? = language) -> Bool {
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
        /// Landscape's shorter bar and top pad leave the extension 35 pt over the digits.
        static func rise(compact: Bool) -> CGFloat { compact ? 35 : rise }
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
        func show(_ text: String, over key: CGRect, within limit: CGRect, rise: CGFloat) {
            let w = key.width + 2 * Self.extra
            let x = min(max(key.midX - w / 2, limit.minX + 2), limit.maxX - 2 - w)
            let bubble = CGRect(x: x, y: key.minY - rise, width: w, height: rise + 8)
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
