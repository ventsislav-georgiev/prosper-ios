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
    /// The one-shot is auto-capitalization's (`autoShift`), not the user's tap.
    private(set) var auto = false
    private var lastTap: TimeInterval = -.greatestFiniteMagnitude

    var uppercase: Bool { mode != .off }

    /// `locks` false: a quick second tap turns it off like a slow one (Enable Caps Lock off).
    mutating func tap(at time: TimeInterval, locks: Bool = true) {
        auto = false
        switch mode {
        case .off: mode = .once
        case .once: mode = locks && time - lastTap <= Self.doubleTapWindow ? .locked : .off
        case .locked: mode = .off
        }
        lastTap = time
    }

    /// A letter went out: a one-shot shift is spent, caps lock stays.
    mutating func typedLetter() { if mode == .once { mode = .off; auto = false } }

    /// Auto-capitalization (the keyboard extension only): one-shot on at a sentence start,
    /// off elsewhere. Caps lock is the user's and stays.
    ///
    /// ponytail: off also clears a one-shot the user tapped, so shift then a digit then
    /// a letter types it lowercase. Track who set it if that ever matters.
    mutating func autoShift(_ on: Bool) { if mode != .locked { mode = on ? .once : .off; auto = on } }
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
        static let bottomOrder = "keyboard.bottomOrder"
        static let bottomHidden = "keyboard.bottomHidden"
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
    /// The keys beside space, space itself as " ", in the bottom row's order (`bottomRow`).
    var bottomOrder = KeyboardSettings.bottomKeys
    /// Those of them that don't show; space always does, and takes their room (`place`).
    var bottomHidden = ""
    static let bottomKeys = ".,/ ?" + String(emojiKey)
    /// The emoji key's stand-in in `bottomOrder` and `bottomHidden` (#515). An order or a
    /// hidden set stored before it existed lacks it, so it shows, last before return (`order`).
    static let emojiKey: Character = "😀"

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
        bottomOrder = defaults?.string(forKey: Key.bottomOrder) ?? bottomOrder
        bottomHidden = defaults?.string(forKey: Key.bottomHidden) ?? bottomHidden
    }

    /// Every key of `bottomKeys` once, in `stored`'s order: unknown ones dropped, missing
    /// ones (a key added since) at the end.
    static func order(_ stored: String) -> [Character] {
        var seen = Set<Character>()
        return (stored + bottomKeys).filter { bottomKeys.contains($0) && seen.insert($0).inserted }
    }

    /// Both keyboards' bottom row, before the extension's globe: the shown keys, then return.
    var bottomRow: [TerminalKeyboard.Key] {
        Self.order(bottomOrder).filter { $0 == " " || !bottomHidden.contains($0) }
            .map { $0 == " " ? .space : $0 == Self.emojiKey ? .emoji : .char(String($0)) } + [.ret]
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
///   to correct works; until the finger has traveled `tapSlop`, the key it landed on.
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
///   character, and every `lineStep` up or down one line; each axis carries its own
///   remainder, so a diagonal drag moves both. Lifting it types nothing. Other fingers are
///   ignored until it lifts.
///   Never one begun under the keys: that strip is the home gesture's.
///
/// Points are in the view's coordinates; the defaults suit callers that don't care
/// about travel.
struct KeyTouchTracker {
    typealias Key = TerminalKeyboard.Key
    /// `caret`: trackpad steps, negative left. `line`: trackpad lines, negative up; one move
    /// yields its `caret` before its `line`.
    enum Effect: Equatable { case press(Key), startRepeat, stopRepeat, caret(Int), line(Int) }

    /// How far a finger may travel and still count as a tap if it's cancelled.
    static let tapSlop: CGFloat = 10
    /// How long a character touch stays down before it types its symbol instead.
    static let holdDelay: TimeInterval = 0.35
    /// How far a trackpad finger travels sideways per character the caret moves.
    ///
    /// ponytail: fixed steps, no acceleration. Tune them on device; add a speed curve if
    /// long moves feel slow.
    static let caretStep: CGFloat = 9
    /// How far a trackpad finger travels up or down per line: a key row, four times
    /// `caretStep`, so a sideways drag's wobble, under a row, never changes line and a drag goes
    /// a line per row it crosses.
    ///
    /// ponytail: the space bar sits about 100 pt over the screen's bottom (874 pt tall), so a
    /// hold goes at most 2 lines down; a second hold goes on. Kept a row, not shorter, since
    /// shorter steps read as jumps.
    static let lineStep: CGFloat = TerminalKeyboard.rowHeight

    private struct Touch {
        let id: Int; var key: Key; var done: Bool
        let start: CGPoint; var travel: CGFloat = 0
        var belowKeys = false
        /// Set by a hold: what the touch types instead of `key`.
        var symbol: String?
        /// Set by a space hold: trackpad mode, the point its caret and line steps count from.
        var anchor: CGPoint?
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

    /// `belowKeys`: the touch began in the app's strip under the bottom row, over the home gesture.
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
            let steps = Int((point.x - anchor.x) / Self.caretStep)
            let lines = Int((point.y - anchor.y) / Self.lineStep)
            touches[i].anchor = CGPoint(x: anchor.x + CGFloat(steps) * Self.caretStep,
                                        y: anchor.y + CGFloat(lines) * Self.lineStep)
            return (steps == 0 ? [] : [.caret(steps)]) + (lines == 0 ? [] : [.line(lines)])
        }
        guard !touches[i].done, touches[i].symbol == nil, !Self.actsOnDown(key) else { return [] }
        // A thumb's lift rolls a few points off where it landed: a tap keeps the key it
        // landed on till the finger has slid past `tapSlop`.
        if point != nil, touches[i].travel <= Self.tapSlop { return [] }
        touches[i].key = key
        return []
    }

    /// The touch has stayed down `holdDelay`, now at `point`: a space touch becomes a
    /// trackpad until it lifts, and lifting types nothing (Apple's types no space either).
    /// True if it did.
    mutating func startTrackpad(_ id: Int, at point: CGPoint) -> Bool {
        guard let i = touches.firstIndex(where: { $0.id == id }), !touches[i].done,
              touches[i].key == .space, !touches[i].belowKeys else { return false }
        touches[i].done = true
        touches[i].anchor = point
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
/// - Line moves (`lines`) go as legs of such steps (`lineLeg`), each sized from the context
///   the last one landed in, so they keep all of the above.
/// - A keyboard sees only the text, never the host's layout: its lines are the text's, and
///   a paragraph the host wraps is one of them. With `wrap` set, a line move inside one goes
///   a row of that many Characters instead.
struct CaretWalk {
    /// The host counts UTF-16 units; nil until a move shows which.
    var utf16: Bool?
    /// The Characters a host's row is guessed to hold (the view's `wrapGuess`): a line longer
    /// than that is rows of it, and a line move goes a row. nil: lines are the text's.
    var wrap: Int?
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
    /// Polls since the last move, and the most polls after a move the host has been seen
    /// to change its context (`step`), 0 while it answers by the next poll, at most 40 (0.8 s)
    /// so the walk stops waiting (`poll`) well inside the view's 2 s.
    private var age = 0, lag = 0
    /// Line moves asked for and not crossed yet, negative up.
    private(set) var lines = 0
    /// The column line moves aim for, in Characters from the line's start: kept from line
    /// to line, so a short one on the way doesn't shorten the next, until a sideways step
    /// goes. Kept past a touch (`drop`) and an idle walk too, as iOS keeps it from arrow to
    /// arrow, while the context still reads as where the walk left the caret (`kept`, `kin`):
    /// any other (typing, an edit, a tap in the host field) means the caret moved without it.
    ///
    /// ponytail: a letter typed and deleted again reads as where the walk left it, and keeps the
    /// goal; so does typing a run's own Character where the context showed only that run.
    private var goal: Int?
    private var kept: (String, String)?
    /// The line move under way: the Characters it walked on the line it started on, nil
    /// once it crossed a break, 0 once it landed; whether the leg in flight crosses one;
    /// and once the last is crossed (with `wrap`, each), its landing: to the line's start
    /// while that's out of sight, counting the Characters walked there, then right.
    private var walked: Int? = 0, crossing = false
    private var landing: Landing?
    private enum Landing { case start(Int, Int), right(Int) }
    /// Sideways steps asked for during a line move: they go once it has landed.
    private var held = 0
    var idle: Bool { sent == nil && queued == 0 && lines == 0 && landing == nil && held == 0 }

    /// `steps` more Characters, negative left (0 checks the move in flight), and `lines`
    /// more lines, negative up, given the proxy's context now, and whether 40 ms have
    /// passed since the last move (`settled`): the units to move it now.
    mutating func step(_ steps: Int, lines n: Int = 0, before raw: String, after a: String,
                       settled: Bool = true) -> Int {
        // ponytail: WebKit's before-context opening on a line's break shows a space after it
        // that isn't in the text (Safari, a paragraph's start); a line that does start with
        // a space reads a Character short there.
        let b = utf16 != true && raw.hasPrefix("\n ") ? "\n" + raw.dropFirst(2) : raw
        if !b.isEmpty || !a.isEmpty { blank = false }
        let changed = shown.map { !Self.same($0, b, a) } ?? false
        if changed { quiet = 0 }
        shown = (b, a)
        if n != 0, idle, goal != nil, !(kept.map { Self.kin($0, b, a) } ?? false) { goal = nil }
        defer { kept = idle && goal != nil ? (b, a) : nil }
        if blank { defer { queued = 0 }; return queued + steps }   // no lines: nothing to see them by
        if lines != 0 || landing != nil { held += steps } else { queued += steps; if steps != 0 { goal = nil } }
        lines += n
        if let r = reckoned, !Self.same(r.seen, b, a) { reckoned = nil }
        if let s = sent {
            // The host answers this late: a guess shows at once, so a context changing later
            // is the host's own. During a line move, no landing is believed before that, so no
            // leg is sized from UIKit's guess, whose emptied side is no line's start or end.
            // ponytail: the lag is learned, not known: a field's first line move on a host slower
            // than the view's settle can still size a leg from a guess, and one host stall sets
            // the most for the field (a backlog of guessed legs answered one by one sets more).
            // Time the host's answers if that shows.
            if changed, age > 1 { lag = min(max(lag, age), 40) }
            if lines != 0 || landing != nil, lag > 0, age <= lag, !s.late { return 0 }
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
                // Past a line's end a blind unit lands after its break: any other context is the
                // host's answer to a move before it, in a new window.
                if crossing, s.dir > 0, b.last?.isNewline != true { return 0 }
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
                // So does a plain leg, its Characters beside it: a context showing none there,
                // and still reading as where the leg left, is that answer too.
                let stayed = s.plain && (s.dir < 0 ? a : b).isEmpty && !(s.dir < 0 ? b : a).isEmpty
                    && Self.agree(Array(s.before.utf16)[...], Array(s.after.utf16)[...], Array(b.utf16), Array(a.utf16))
                if stayed || fit.units == 0 && fit.chars == 0 {
                    guard s.late else { return 0 }   // an older answer: the host is behind
                } else if fit.chars > fit.units, fit.back > 0 {
                    guard utf16 == nil, s.late else { return 0 }   // UIKit's guess, maybe
                    utf16 = false
                    return send(-s.dir * fit.back, (b, a), b, a, dir: -s.dir, chars: fit.back)
                } else if fit.units > fit.chars {
                    utf16 = true
                }
                // A leg that took all of one side lands, in UIKit's guess, in the window it was
                // sized in, that side empty: no line's end or start where UIKit cut the window
                // there (after a sentence's space, before at a break). Believed once the host
                // shows another window, or at the poll limit. ponytail: a line that does end in a
                // space waits out the poll limit; a cut elsewhere (a sentence's start before the
                // caret) still reads as the line's start.
                if lines != 0 || landing != nil, fit.units == 2, !s.late,
                   s.dir > 0 ? a.isEmpty && s.after.last?.isWhitespace == true
                             : b.isEmpty && s.before.first?.isNewline == true { return 0 }
            }
            sent = nil
            believed = (b, a)
        }
        if sent == nil, queued == 0, believed.map({ Self.same($0, b, a) }) ?? true {
            let (before, after) = reckoned.map { ($0.before, $0.after) } ?? (b, a)
            lineLeg(before: Array(before), after: Array(after))
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
        if s.blind, crossing { crossing = false; sent = nil; edge(); return }   // no break past it: the text's end
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

    /// `ticks` of the view's 20 ms poll, one a poll on time: past 15 since the move or since
    /// the host last showed a new context (it's still answering older moves), or past the
    /// host's `lag` if it has shown more, the view stops waiting.
    ///
    /// ponytail: a host answering later than that (a stall past 0.3 s it hasn't shown yet) has
    /// UIKit's guess believed, whose emptied side reads as a line's start or the text's: the
    /// move ends a line or a column short. Wait on the host's own signal if a device shows one.
    mutating func poll(_ ticks: Int = 1) {
        quiet += ticks
        age += ticks
        if quiet > max(15, lag) { timedOut() }
    }

    /// Forget the move in flight, the steps behind it and what the field showed: a touch
    /// starts afresh, looking for context again. The goal column stays, as long as the
    /// context still reads as `kept`.
    mutating func drop() {
        sent = nil; reckoned = nil; believed = nil; queued = 0; blank = false
        lines = 0; walked = 0; crossing = false; landing = nil; held = 0
    }

    /// The next leg of a line move, in Characters, from the context the last one landed in:
    /// down, to the caret line's end and over its break; up, to its start and over the break
    /// before it. A leg stops where the context does, to be read again, so none lands in
    /// text the host hasn't shown. Hosts show no break past a line's end, so that crossing
    /// goes blind, and one that never shows was the text's end (`timedOut`); no context
    /// before the caret is the text's start. The goal column is counted from the start line's
    /// start, walked to first if the context doesn't reach it. After the last break, that
    /// column, or the line's end if it's shorter. Then the sideways steps held behind it.
    /// A landing the context already shows goes in one move (`reach`).
    ///
    /// With `wrap`, one line at a time: a row inside the caret's line if it has one that
    /// way, at the goal's place in the row (`goal` mod `wrap`), else over the break to the
    /// next line's first row or the last line's last.
    ///
    /// ponytail: a host that hides the line's break shows no edge either, so a line move
    /// from the first line (UIKit) or the last (every host) walks to the edge, and stays
    /// there as iOS's own arrows do. A wrapped line's rows are cut every `wrap` Characters,
    /// not at words as the host wraps, so the column drifts a word's width; one whose start
    /// is out of sight has it guessed at the context's start, not walked to (a visible jump),
    /// so a cut context puts the rows elsewhere. A row move with no line's start in sight at all
    /// (UIKit's context, cut at the line) goes `wrap` Characters, keeping the caret's place in
    /// the row, not the goal's, once a short row clamped it.
    private mutating func lineLeg(before: [Character], after: [Character]) {
        if crossing { crossing = false; walked = nil }
        let br = before.lastIndex(where: \.isNewline), col = br.map { before.count - $0 - 1 }
        while queued == 0 {
            if lines != 0, wrap == nil || landing == nil {
                landing = nil
                let down = lines > 0, rest = after.prefix { !$0.isNewline }.count
                // A wrapped line's row that way, its start out of sight: `wrap` on.
                if let w = wrap, walked == 0, col == nil, (down ? rest - 1 : before.count) >= w {
                    queued = down ? w : -w; lines -= lines.signum()
                    return
                }
                // The column from the line's start, which a host can cut off (a sentence, a
                // window): walked to it first, counting, if it's out of sight. A wrapped line's,
                // with a row or more in sight, is guessed at the context's start instead.
                if goal == nil, col == nil, !before.isEmpty, wrap.map({ before.count < $0 }) ?? true {
                    queued = -before.count
                    walked = walked.map { $0 + queued }
                    return
                }
                let c = col ?? before.count, g = goal ?? c - (walked ?? 0)
                goal = g
                // Its start in sight or guessed: the goal's place in the row that way, or the
                // line's end.
                if let w = wrap, let k = walked, col != nil || before.count >= w || before.isEmpty {
                    let from = c - k, end = c + rest, at = from == end ? max(from - 1, 0) : from
                    let row = at - at % w + (down ? w : -w)
                    if down ? end > row : row >= 0 {
                        queued = min(row + g % w, end) - c; lines -= lines.signum(); walked = 0
                        return
                    }
                }
                // The line it goes to in sight: there in one move, no stop at a line's end.
                if let to = Self.reach(wrap == nil ? lines : lines.signum(), column: g, wrap: wrap, before: before, after: after) {
                    queued = to; lines = wrap == nil ? 0 : lines - lines.signum(); walked = 0
                    return
                }
                if down, let k = after.firstIndex(where: \.isNewline) {
                    queued = k + 1
                } else if !down, let br {
                    queued = br - before.count
                } else if !(down ? after : before).isEmpty {
                    queued = down ? after.count : -before.count   // to the edge of what's shown
                    walked = walked.map { $0 + queued }
                    return
                } else if down {
                    queued = 1   // blind
                } else {
                    edge()
                    continue
                }
                crossing = true
                lines -= lines.signum()
                if lines == 0 || wrap != nil { landing = .start(g, 0) }
                return
            }
            switch landing {
            case .start(let g, let n)?:
                if col == nil, !before.isEmpty, wrap.map({ before.count < $0 }) ?? true {
                    queued = -before.count; landing = .start(g, n + before.count); return
                }
                let c = col ?? before.count   // a wrapped line's start, guessed as above
                // Wrapped: the goal's place in the line's last row (up, landed at its end and `n`
                // back from there), or its first (down, landed at its start).
                let g = wrap.map { w in max(c + n - 1, 0) / w * w + g % w } ?? g
                queued = min(g - c, 0)
                landing = g > c ? .right(g - c) : nil
                if landing == nil { walked = 0 }
            case .right(let n)?:
                let line = after.prefix { !$0.isNewline }
                queued = min(n, line.count)
                landing = queued < n && queued == after.count && queued > 0 ? .right(n - queued) : nil
                if landing == nil { walked = 0 }
            case nil:
                if walked != 0 { edge(back: true); continue }   // up and down cancelled out before it landed
                if held != 0 { goal = nil }
                queued = held
                held = 0
                return
            }
        }
    }

    /// The line move met the text's edge: it stays there, as iOS's own ↑ on the first line
    /// and ↓ on the last do, however many lines were left. Its lines cancelling out (`back`)
    /// goes back where it started instead, or if it crossed a line on the way, lands on the
    /// one it reached.
    private mutating func edge(back: Bool = false) {
        lines = 0
        if back, walked == nil { landing = .start(goal ?? 0, 0); return }
        queued = back ? -(walked ?? 0) : 0
        walked = 0
        landing = nil
    }

    /// Where a move of `n` lines (negative up) lands, in Characters from the caret, if the
    /// context shows it: the line from its start to column `g`, or to its end if shorter.
    /// Up needs the break before that line in sight, as a host can cut a line's start; down,
    /// the line's end or the column, as a host can cut the after-context anywhere. Safari's
    /// textarea shows lines above; a UITextView's context, cut at a line or a sentence it
    /// can't be told from, and every after-context, stopping at the line's end, never do.
    /// With `wrap`, the column is `g`'s place in the line's first row (down) or last (up).
    static func reach(_ n: Int, column g: Int, wrap: Int? = nil, before: [Character], after: [Character]) -> Int? {
        let side = n > 0 ? after : before, brs = side.indices.filter { side[$0].isNewline }
        if n > 0 {
            guard brs.count >= n else { return nil }
            let start = brs[n - 1] + 1, line = after[start...].prefix { !$0.isNewline }, g = wrap.map { g % $0 } ?? g
            guard line.count >= g || start + line.count < after.count else { return nil }
            return start + min(g, line.count)
        }
        guard brs.count > -n else { return nil }
        let start = brs[brs.count + n - 1] + 1, end = brs[brs.count + n]
        let g = wrap.map { w in max(end - start - 1, 0) / w * w + g % w } ?? g
        return start + min(g, end - start) - before.count
    }

    private mutating func send(_ units: Int, _ seen: (String, String), _ before: String, _ after: String,
                               dir: Int, chars: Int, plain: Bool = false, blind: Bool = false) -> Int {
        sent = (seen, before, after, dir, chars, abs(units), plain, blind, false)
        quiet = 0
        age = 0
        return units
    }

    private static func same(_ seen: (String, String), _ before: String, _ after: String) -> Bool {
        seen.0.utf16.elementsEqual(before.utf16) && seen.1.utf16.elementsEqual(after.utf16)
    }

    /// The caret `kept` read at, as a host can show it later: UIKit's guess when the walk went
    /// idle and the host's late answer cut their windows apart (a UITextView's after-context
    /// at a line's end is empty), so both sides agree as far as both reach, and the before,
    /// which typing changes, is empty in both or neither.
    private static func kin(_ kept: (String, String), _ before: String, _ after: String) -> Bool {
        kept.0.isEmpty == before.isEmpty
            && agree(Array(kept.0.utf16)[...], Array(kept.1.utf16)[...], Array(before.utf16), Array(after.utf16))
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
/// out and a drag moves the caret (`caret`), through `moveCaret` in the app (arrow keys)
/// and the field's document proxy in the extension, where up and down move it by line
/// (`line`).
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
/// auto-capitalization (`autoCapitalize`). The Bulgarian extension's has
/// Bulgarian letters (`Layout`); the app's is always English.
final class TerminalKeyboard: UIInputView, UIInputViewAudioFeedback {
    enum Key: Hashable {
        case char(String), shift, backspace, space, ret
        /// Next keyboard; the extension's only. Its cap takes its own touches (`makeCap`).
        case globe
        /// Opens the emoji picker in place of the caps (`EmojiPicker`).
        case emoji
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
    /// (32 pt bar + 149 + 6) was about the Apple keyboard's landscape height (QA measured
    /// the old 36 + 174 + 6 ~30 pt taller); `extensionBottomInset` has since added 10.
    /// The bar + the 3 pt top pad is the bubble's compact rise (`KeyPreview.rise(compact:)`).
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
    /// The extension's `bottomInset`. A touch under it lands on iOS's own strip and never
    /// reaches the keyboard, and thumbs land low: at 6 pt about one space tap in 25 was
    /// lost there (`TypoRateTests`).
    ///
    /// ponytail: sized on the typo harness's assumed thumb (11 pt spread, 6 pt low), not
    /// measured. Tune it on a device.
    static let extensionBottomInset: CGFloat = 16
    /// This keyboard's pad under the bottom row: `bottomPadding` in the app. The extension
    /// sets a few points, since iOS already keeps its own strip under a custom keyboard, so
    /// a touch on its pad is an ordinary key touch, never the home gesture's.
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

    /// Digits lead (shift doesn't change them), then qwerty, then `. , / ?` and the emoji
    /// key beside space for prose and paths, as Settings arranges them
    /// (`KeyboardSettings.bottomRow`). Every other symbol is a hold (`holdSymbol`).
    static let rows: [[Key]] = [
        chars("1234567890"),
        chars("qwertyuiop"),
        chars("asdfghjkl"),
        [.shift] + chars("zxcvbnm") + [.backspace],
        [.char("."), .char(","), .char("/"), .space, .char("?"), .emoji, .ret],
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
    /// The emoji key, where `settings.bottomRow` has it: the app's keyboard only. The
    /// extension clears it: its picker's glyphs outgrew an extension's memory (#515), and
    /// a system keyboard reaches iOS's own emoji through the globe or iOS's switcher.
    var offersEmoji = true { didSet { if offersEmoji != oldValue { build() } } }
    /// The app's Keyboard settings: the extension's controller sets them when it appears,
    /// the terminal when it takes focus. A new bottom row rebuilds the caps.
    var settings = KeyboardSettings() {
        didSet { if settings.bottomRow != oldValue.bottomRow { build() } }
    }
    /// The extension's suggestions (`SuggestionBar.attach`): asked before every key, it
    /// can autocorrect the word a separator ends, or take the key itself (true: backspace
    /// undoing an autocorrect) and the keyboard types nothing. Nil in the app.
    var willPress: ((Key) -> Bool)?
    /// After every key, shift included: the extension's bar recomputes. Nil in the app.
    var didPress: (() -> Void)?
    /// Where trackpad steps go, negative left: the app sends arrow keys. Nil moves the
    /// host field's caret through its document proxy (the extension).
    var moveCaret: ((Int) -> Void)?
    /// After each trackpad step, or a line move's first: the extension's suggestions forget
    /// the word they were following, and the bar recomputes. Nil in the app.
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
    /// Cleared when a touch begins; the completions, when the word changes.
    private var knownCache: [String: Bool] = [:]
    private var screenCache: Set<String>?
    private var completionsCache: (prefix: String, words: [String])?

    private var caps: [[Cap]] = []
    private let keysArea = UILayoutGuide()
    /// Built the first time the emoji key opens it; showing, it hides the caps.
    private(set) var emojiPicker: EmojiPicker?
    var showsEmoji: Bool { emojiPicker?.isHidden == false }
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
    /// The 20 ms ticks so far, by `clock`: a toolbar edit times a host's answer from its step
    /// by them, and the walk its wait for one.
    private(set) var ticks = 0
    /// The time, in seconds, for `ticks`: a poll on a busy main thread comes late and counts
    /// the ticks it missed (#553 QA: after a long edit the kit polled 3-4 times slower than
    /// the timer, and waits counted in polls held the toolbar 3-6 s). nil: a tick a poll.
    var clock: (() -> TimeInterval)?
    private var polled: TimeInterval?
    /// A line move asked for hasn't sent anything yet (`line`).
    private var lineAsked = false
    /// What runs on each poll once the walk is idle, till it returns true: the rest of a toolbar
    /// edit (`caret(_:then:)`, `wait`). A key, a touch, a move or the poll limit drops it.
    private var landed: (() -> Bool)?
    /// A toolbar edit's step pair under way (`caret(away:back:then:)`), till its step back
    /// lands: the step away, the units the two have sent, and a toolbar press held till then.
    private var pair: (steps: Int, units: Int, next: (() -> Void)?)?
    /// What runs on each poll (`landed`) holds a toolbar press, kept till then (`holding`).
    private var holds = false, heldPress: (() -> Void)?
    /// The field a toolbar press found (`finish`, `field`): its edit, and every press held
    /// behind it, writes there only (`writable`).
    private var editField: UUID?
    /// A toolbar edit's code is running: a press's, a held one's, or what runs on a poll.
    private var acting = 0
    /// The context a poll last read, the tick it or the edit's own writes last showed a new
    /// one at, the tick a poll last read a new one at, the ticks a toolbar edit last wrote at
    /// and first wrote at since that read (`wrote`), and the tick a new one ended a silence at
    /// (`pollCaret`).
    private var hostShows: [String?] = [], shownAt = 0, answeredAt = 0, wroteAt = 0, owedAt: Int?, woke = Int.min / 2
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
        settle()
        landed = nil
        if willPress?(key) == true {
            // ponytail: the text is no longer what the keys typed (an undone autocorrect),
            // so touch correction starts afresh rather than guess it back.
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
        case .space: target?.insertText(" ")
        case .ret: if let sendBytes { sendBytes(Self.newlineBytes) } else { target?.insertText("\n") }
        case .backspace: target?.deleteBackward()
        case .shift:
            shift.tap(at: CACurrentMediaTime(), locks: settings.capsLock)
            refreshLabels()
            return   // the user's shift: auto-capitalization doesn't undo it
        case .globe: return   // its cap acts on its own; the tracker never yields it (`nearest`)
        case .emoji: showEmoji(true)
        }
        autoCapitalize()
    }

    /// The picker in place of the caps, or the caps back. Whatever touch the caps were
    /// tracking is dropped, so none types after the swap.
    func showEmoji(_ on: Bool) {
        if on, emojiPicker == nil {
            let picker = EmojiPicker()
            picker.pick = { [weak self] e in self?.typeEmoji(e) }
            picker.delete = { [weak self] in self?.feedback(); self?.press(.backspace) }
            picker.letters = { [weak self] in self?.feedback(); self?.showEmoji(false) }
            addSubview(picker)
            emojiPicker = picker
        }
        if on { emojiPicker?.reload() }
        stopRepeat(); stopHold(); tracker.reset(); refreshPressed()
        if blanked { refreshLabels() }
        emojiPicker?.isHidden = !on
        caps.joined().forEach { $0.isHidden = on }
        setNeedsLayout()
    }

    /// A picker cell: typed the way a `.char` key types, then the word and the double
    /// space's history start afresh, so no emoji ever counts as a letter or a digit
    /// (Swift calls Ⓜ️ a letter and 1️⃣ a number).
    private func typeEmoji(_ e: String) {
        feedback()
        press(.char(e))
        resetWord()
    }

    /// A trackpad step of `offset` characters, negative left: in a host field, through
    /// `walk`, so it never stops inside one. The word touch correction continues ends here,
    /// as it does at an arrow key (`resetWord`).
    func caret(_ offset: Int) {
        settle()
        send(offset)
    }

    private func send(_ offset: Int) {
        landed = nil
        if let moveCaret {
            moveCaret(offset)
        } else {
            walkOn(offset)
        }
        caretMoved()
    }

    /// A step of `offset`, then `then` once the walk has landed it: a toolbar edit's deletes
    /// after its move (`SuggestionBar.edit`). The edit changes the text the walk last saw, so
    /// the walk starts afresh after it. A toolbar press till then is held (`holding`).
    func caret(_ offset: Int, then: @escaping () -> Void) {
        caret(offset)
        landed = holding { [weak self] in self?.walk.drop(); then(); return true }
        if walk.idle { runLanded() }
    }

    /// `check`, a toolbar press held till it passes and going then (`finish`), after what
    /// `check` sent, so a toolbar edit's walk, steps and deletes all go before the next press's
    /// (#553 QA: a quick second dd, reading the context mid-way, dropped the first's deletes
    /// and took the line it left the caret on).
    private func holding(_ check: @escaping () -> Bool) -> () -> Bool {
        holds = true
        return { [weak self] in
            guard let self else { return true }
            let next = self.heldPress
            self.holds = false
            self.heldPress = nil
            guard check() else { self.holds = true; self.heldPress = next; return false }
            self.then({}, next)
            return true
        }
    }

    /// A step of `offset` and, once it lands, back unless `back` says no, then `then` once
    /// that lands: a toolbar edit looking for a fresh context (`SuggestionBar.rewindow`).
    /// Till then the caret is off where the edit left it, so nothing else may act on it: a
    /// key, a touch or a move first sends back the units the pair sent (`settle`), which the
    /// host applies before what follows; a toolbar press, which reads the context, waits for
    /// the pair to land back and goes after `then` (`finish`). (#553 QA: a second ctrl-u in
    /// Safari dropped the step back and took the space after the caret.)
    func caret(away offset: Int, back: @escaping () -> Bool?, then: @escaping () -> Void) {
        pair = (offset, 0, nil)   // none under way: an edit's steps go from what runs on a poll
        send(offset)
        landed = { [weak self] in
            guard let self, let p = self.pair else { return true }
            self.walk.drop()
            guard let b = back() else { return false }   // asked again on the next poll
            guard b else { self.pair = nil; self.then(then, p.next); return true }
            self.send(-p.steps)
            self.landed = { [weak self] in
                let next = self?.pair?.next
                self?.pair = nil
                self?.walk.drop()
                self?.then(then, next)
                return true
            }
            return true
        }
        if walk.idle { runLanded() }
    }

    /// `then`, and a toolbar press held till then after it, held again by what `then` started.
    private func then(_ then: () -> Void, _ next: (() -> Void)?) {
        then()
        if let next { finish(next) }
    }

    /// `act` now, or once a step pair under way has landed back (`caret(away:back:then:)`), or
    /// what holds it has (`holding`).
    /// A press records its field (`editField`); one held goes only in that field.
    func finish(_ act: @escaping () -> Void) {
        if pair != nil { pair?.next = act; return }
        if holds { heldPress = act; return }
        if acting == 0 {
            editField = (target as? UITextDocumentProxy).flatMap(Self.field)
            shownAt = ticks; wroteAt = ticks; owedAt = nil
        } else if !writable() { return }
        acting += 1
        act()
        acting -= 1
    }

    /// The field's `documentIdentifier`, nil where the host has none, as mid-way through a
    /// focus change: read through KVC, since UIKit declares it a UUID and Swift traps on the
    /// nil it then returns (#569 QA: Safari, a tap into another field during delete all).
    static func field(_ doc: UITextDocumentProxy) -> UUID? {
        (doc as? NSObject)?.value(forKey: "documentIdentifier") as? UUID
    }

    /// A step pair under way is dropped: the units it sent go back first, unseen. So is a
    /// press held.
    private func settle() {
        if fieldLeft { leave() }
        holds = false
        heldPress = nil
        guard let p = pair else { return }
        pair = nil
        if p.units != 0 { (target as? UITextDocumentProxy)?.adjustTextPosition(byCharacterOffset: -p.units) }
        walk.drop()
    }

    /// A toolbar edit under way, or a press held, in a field the host no longer serves: another,
    /// or none, since the press (`editField`; #569 QA: after a tap into another field mid-edit,
    /// delete all's and dd's deletes, steps and held presses went on there). A poll checks it
    /// first (`pollCaret`), a key or a move too (`settle`), and each write an edit makes again
    /// (`writable`).
    private var fieldLeft: Bool {
        (acting > 0 || landed != nil || pair != nil || holds)
            && (target as? UITextDocumentProxy).flatMap(Self.field) != editField
    }

    /// A toolbar edit's write (a delete, an insert, a move) may go: the host still serves the
    /// press's field. Else the edit and every press it holds are dropped, and so is every
    /// write the rest of its code tries, the field being the press's no more.
    func writable() -> Bool {
        guard fieldLeft else { return true }
        leave()
        return false
    }

    /// The edit and every press it holds are dropped, nothing sent back: the units a step pair
    /// sent went to the field the host no longer serves.
    private func leave() {
        holds = false
        heldPress = nil
        pair = nil
        landed = nil
        walk = CaretWalk()
        walkField = nil
        walkTimer?.invalidate()
        walkTimer = nil
    }

    /// `check` on each poll from the next, while the walk is idle, till it returns true: a
    /// toolbar edit waiting for the host to show its deletes (`SuggestionBar.deleteBack`), a
    /// toolbar press held till then (`holding`). Dropped as `landed` is; the poll limit
    /// counts from here.
    func wait(_ check: @escaping () -> Bool) {
        landed = holding(check)   // in place of what ran: no step pair under way
        walkPolls = 0
        pollOn()
    }

    /// `landed`, now the walk is idle, kept while it returns false; the timer polls while
    /// anything waits.
    private func runLanded() {
        if let f = landed {
            landed = nil
            acting += 1
            if !f() { landed = f }
            acting -= 1
        }
        if landed == nil, walk.idle {
            walkTimer?.invalidate()
            walkTimer = nil
        } else {
            pollOn()
        }
    }

    private func pollOn() {
        guard walkTimer == nil else { return }
        polled = clock?()
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] t in
            if let self { self.pollCaret() } else { t.invalidate() }
        }
        RunLoop.main.add(t, forMode: .common)
        walkTimer = t
    }

    /// A trackpad move of `lines` lines, negative up: in a host field only, through `walk`.
    /// The app ignores it, since a shell's up and down are history, not lines. The word
    /// ends once the move sends something, so one with nowhere to go ends nothing.
    func line(_ lines: Int) {
        guard moveCaret == nil, target is UITextDocumentProxy else { return }
        settle()
        landed = nil
        lineAsked = true
        walkOn(lines: lines)
    }

    private func caretMoved() {
        word = ""
        autoCapitalize()
        didMoveCaret?()
    }

    /// `steps` and `lines` more for `walk`, and what it can send now; polls the host's
    /// context until the walk is idle, or 0.3 s pass without a move landing.
    private func walkOn(_ steps: Int = 0, lines: Int = 0) {
        guard let doc = target as? UITextDocumentProxy, writable() else { return }
        // Another field, on a poll too, drops the walk: nothing more of it goes there (#569: a
        // trackpad drag's rest moved the caret from where a tap into the next field put it).
        if Self.field(doc) != walkField {
            walkField = Self.field(doc)
            walk = CaretWalk()
        }
        walk.wrap = wrapGuess
        let units = walk.step(steps, lines: lines, before: doc.documentContextBeforeInput ?? "",
                              after: doc.documentContextAfterInput ?? "", settled: walkPolls >= 3)
        if units != 0 {
            doc.adjustTextPosition(byCharacterOffset: units)
            wrote()
            pair?.units += units
            walkPolls = 0
            if lineAsked { lineAsked = false; caretMoved() }
        }
        if walk.idle { runLanded() } else { pollOn() }
    }

    /// A host field's row in Characters, guessed for `walk`, which sees no host layout: the
    /// keyboard's width less a field's usual margins (`fieldInset`), over the mean Character
    /// width of body text at the user's text size but never one under the default (`.large`),
    /// a tenth less since word wrap leaves rows short. nil while too narrow to mean anything.
    ///
    /// ponytail: unsure, it guesses short, as a move staying on its row beats one skipping a
    /// row: a field whose rows hold more (Dynamic Type under large, a fixed font under a size
    /// above it) keeps a move from a row's near end on its row. One holding fewer gets rows too
    /// long, so a move from a row's far end can go two: a font smaller than body, or a field
    /// narrower than the screen less `fieldInset`, as a chat composer with buttons beside it
    /// (Messages' 262 pt, rows of ~31 against 41; the operator's chat app's held 41 and 49).
    /// `fieldInset` and the tenth are the knobs; tune them on device.
    var wrapGuess: Int? {
        let size = traitCollection.preferredContentSizeCategory
        let at = UITraitCollection(traitsFrom: [traitCollection, UITraitCollection(
            preferredContentSizeCategory: size == .unspecified ? .large : max(size, .large))])
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: at)
        let sample = "the quick brown fox jumps over the lazy dog" as NSString
        let mean = sample.size(withAttributes: [.font: font]).width / CGFloat(sample.length)
        let n = Int((bounds.width - Self.fieldInset) / mean * 0.9)
        return n > 8 ? n : nil
    }
    /// What a host's text field leaves of the screen's width: about 20 pt a side.
    static let fieldInset: CGFloat = 40
    /// Ticks, 200 ms, a poll may read no new context for, or a toolbar edit's write go
    /// unanswered, before the next is a host's answer after a stall (QA's STALL host: 300 ms;
    /// a blocking one answered 150 ms a move behind); and the most an edit holds after one.
    static let stallTicks = 10
    /// Ticks, 100 ms, a toolbar edit holds after it, and after each answer that follows (#575
    /// QA: the field showed the switch 27 ms after the last); and how long before an answer
    /// that ends a stall the edit's last write must have gone (`pollCaret`).
    /// ponytail: a host showing the switch later than that may still take one batch.
    static let wakeTicks = 5

    /// A toolbar edit wrote to the host just now: an answer `stallTicks` past the first write
    /// it owes ends a stall, unless it comes within `wakeTicks` of the last (`pollCaret`).
    func wrote() { wroteAt = ticks; owedAt = owedAt ?? ticks }

    /// The poll timer's tick; tests call it in place of waiting.
    ///
    /// ponytail: polling, not the controller's `textDidChange`, since Safari may send
    /// none; 0.3 s of nothing new is a guess at the slowest host (`CaretWalk.poll`). A
    /// drag past the document's end waits that long before steps back count. A move that
    /// never shows stops the polling after 2 s, still waited on: the next `caret` polls
    /// again, the next touch drops it. An edit dropped there goes no further, but a toolbar
    /// press it held goes then, after the step pair's units came back (#553 QA: a held press
    /// was dropped with the edit).
    func pollCaret() {
        guard !fieldLeft else { return leave() }
        let now = clock?()
        // ponytail: a poll counts 5 ticks at most, so a stalled main thread's first poll after
        // it can't time out a wait before the host's queued answer is read; a host slower
        // than 100 ms a poll still waits longer than its time.
        let n = now.flatMap { now in polled.map { max(1, min(5, Int(((now - $0) / 0.02).rounded()))) } } ?? 1
        polled = now
        walkPolls += 1
        ticks += n
        let doc = target as? UITextDocumentProxy
        let shows = { [doc?.documentContextBeforeInput, doc?.documentContextAfterInput] }
        if shows() != hostShows {
            // A stall's end: the first new context after `stallTicks` of none, the edit's own
            // writes' counted, or after the edit's first write since the last went unanswered
            // `stallTicks`, its last `wakeTicks` or more before (#575 QA r2: ctrl-u's step pair,
            // sent mid-stall 125 ms before its end, showed UIKit's guess as a new context, and
            // the next 300-Character batch went 41 ms after the host's answer, unheld). A host
            // blocking 150 ms a move answers within `stallTicks` of the write it owes; Safari,
            // its step's guess for an answer, within `wakeTicks` of the step back after it.
            if ticks - shownAt > Self.stallTicks
                || owedAt.map({ ticks - $0 > Self.stallTicks }) == true && ticks - wroteAt >= Self.wakeTicks { woke = ticks }
            hostShows = shows(); shownAt = ticks; answeredAt = ticks; owedAt = nil
        }
        // A host answering after a stall may yet take a tap queued in it, after the answers it
        // owed and ahead of what the edit sends next, before the keyboard sees the field change:
        // the edit holds till `wakeTicks` pass without another answer, `stallTicks` at most, so
        // a poll's field check sees it first (#575 QA: STALL, delete all's batch, sized from the
        // host's answer 8 ms before, went to the field a tap 1.1 s before had switched to).
        // ponytail: a host taking such a tap at a stall's end owing no answer shows nothing
        // first, and a write the edit sends right then, on a timeout or after its own last one,
        // still goes there; so may one after a stall that ends within `wakeTicks` of the
        // edit's last write, or `stallTicks` of both its first unanswered one and the last
        // context shown, its own writes' too: a press or a step mid-stall, near its end.
        // One batch at most: up to a context window, QA's ~300 Characters on a long line. A cap
        // on batch size is the lever if that's too much.
        if landed != nil || pair != nil, ticks - woke <= Self.stallTicks, ticks - answeredAt < Self.wakeTicks { return }
        if walk.idle, landed != nil {
            runLanded()   // an edit waiting on the host (`wait`): no move to step
        } else {
            walk.poll(n)   // the host clamped at the document's end, or never showed it
            walkOn()
        }
        if shows() != hostShows { hostShows = shows(); shownAt = ticks }   // its own writes': no answer
        guard walkPolls >= 100 else { return }   // 2 s: a move that never shows waits for the next `caret`
        walkPolls = 0
        let next = pair?.next ?? heldPress
        settle()
        landed = nil
        walkTimer?.invalidate()
        walkTimer = nil
        acting += 1
        next?()
        acting -= 1
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

    /// A field whose value isn't prose, so nothing may rewrite what's typed (no
    /// autocorrect): URLs, email, web search, number and phone pads.
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
        rows[rows.count - 1] = settings.bottomRow.filter { offersEmoji || $0 != .emoji }
        if showsGlobe { rows[rows.count - 1].insert(.globe, at: 0) }
        caps = rows.map { $0.map(makeCap) }
        caps.joined().forEach { $0.isHidden = showsEmoji }
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
        // The picker's touches are its own; the hidden caps under them type nothing.
        if showsEmoji { return }
        switch phase {
        case .began:
            if tracker.isTrackpad { return }   // a second finger on the trackpad: ignored
            settle()
            landed = nil
            if !walk.idle { walkOn() }   // a last look for a split before typing
            walk.drop()
            lineAsked = false
            knownCache = [:]; screenCache = nil
            feedback()
            // Only the app's pad lies over the home gesture; the extension's is plain keyboard.
            let bottomRow = bottomInset == Self.bottomPadding ? caps.last?.map(\.frame.maxY).max() ?? .infinity : .infinity
            perform(tracker.began(id, key(at: point), at: point, belowKeys: point.y > bottomRow))
            stopHold()
            if tracker.previewKey != nil || tracker.held.last == .space { startHold(id, at: point) }
        case .moved:
            perform(tracker.moved(id, key(at: point), at: point))
            if holdTouch?.id == id { holdTouch?.at = point }
        case .ended:
            perform(tracker.moved(id, key(at: point), at: point))
            // Lifted on the globe, which takes its own touches: the key it slid from types nothing.
            let onOwnCap = caps.joined().contains { $0.key == .globe && $0.frame.contains(point) }
            perform(tracker.ended(id).filter { if case .press = $0 { !onOwnCap } else { true } })
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

    /// The key nearest where `point` aims (`aimed`), so the gaps, margins and the strip
    /// under the bottom row all belong to a key, unless `corrected` moves it to a neighbor
    /// that continues the word. Began, moved and the preview all ask here, so they agree.
    func key(at point: CGPoint) -> Key {
        let keys = caps.joined().map { ($0.key, $0.frame) }
        let point = aimed(point)
        func known(_ s: String) -> Bool {
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
        // The dictionary's completions of the word, most likely first (it lists 20): each one
        // `s` starts counts 1 / its rank. One past those, or only the shell or screen's, a little.
        func likely(_ s: String) -> Double {
            if completionsCache?.prefix != word {
                completionsCache = (word, Suggestions.completions(word, language: layout.language).map { $0.lowercased() })
            }
            let w = completionsCache!.words.enumerated().filter { $0.element.hasPrefix(s) }
                .map { 1 / Double($0.offset + 1) }.reduce(0, +)
            return w > 0 ? w : known(s) ? 0.025 : 0
        }
        return Self.corrected(nearest(at: point), at: point, keys: keys, prefix: word, known: known, likely: likely)
    }

    /// The key nearest `point`, uncorrected: what a hold converts. Never the globe: a
    /// touch beside its cap goes to the next key over, since only the cap can open the
    /// keyboard list.
    private func nearest(at point: CGPoint) -> Key {
        caps.joined().filter { $0.key != .globe }.min { Self.distance(point, $0.frame) < Self.distance(point, $1.frame) }?.key ?? .space
    }

    /// How far above a touch on the letter rows it aims: thumbs land low.
    ///
    /// ponytail: one fixed lift, not per side or per size class, no Settings slider; 4 pt
    /// because the typo harness (`TypoRateTests`) assumes taps land 4 pt low, so it's an
    /// assumption, not a measurement. Tune it on a device. Settable for tests.
    static var tapLift: CGFloat = 4

    /// Where a touch aims: `tapLift` higher, when both the touch and the lifted point are
    /// nearest a character key on the letter rows. The digit row, the bottom row, shift,
    /// backspace and the strip under the bottom row keep the touch where it is, so a lift
    /// never turns space, shift or backspace into a letter (in landscape the 4 pt row gap
    /// is under the lift), nor a digit into a letter or a letter into a digit.
    private func aimed(_ point: CGPoint) -> CGPoint {
        let letters = Set(caps.dropFirst().dropLast().joined().map(\.key).filter { if case .char = $0 { true } else { false } })
        let lifted = CGPoint(x: point.x, y: point.y - Self.tapLift)
        return letters.contains(nearest(at: point)) && letters.contains(nearest(at: lifted)) ? lifted : point
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
            case .line(let n): line(n)
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
            case .emoji: image = "face.smiling"; label = "emoji"
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
    /// any other key converts on the key the finger aims at now, without correction: a
    /// hold is deliberate.
    func fireHold() {
        guard let h = holdTouch else { return }
        stopHold()
        if tracker.startTrackpad(h.id, at: h.at) {
            haptics.impactOccurred()
            haptics.prepare()
            refreshLabels()
            refreshPressed()
            return
        }
        guard tracker.hold(h.id, over: nearest(at: aimed(h.at)), symbols: layout.holdSymbol) else { return }
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
        } else {
            Self.undelayEdges(window)   // a no-op in the app's keyboard window (no gate); reaches the extension's before viewDidAppear
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = keysArea.layoutFrame.insetBy(dx: Self.sideMargin, dy: 0)
        let m = Self.metrics(compact: compact)
        emojiPicker?.frame = area
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
            case .char, .globe, .emoji: return u
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
    /// on r's right edge types t. One that does start a word still goes to a neighbor in
    /// reach the word is that much likelier to go on with (`likely`, its weight against
    /// the touch's distance from each key's center): after "th", a touch on r's left edge
    /// types e, "the" far likelier than "three". A centered hit, an empty prefix or no
    /// neighbor known or likely enough keeps `nearest`, so only an already ambiguous touch
    /// ever moves. Only letters are corrected: digits and symbols never. A hold isn't
    /// corrected at all (`fireHold`). Lowercase in and out; `press` applies shift.
    ///
    /// The center is checked first, so `known` (and the screen it may read) is asked only
    /// for an ambiguous touch.
    ///
    /// ponytail: the touch's spread is a quarter key, one Gaussian for both axes, tuned on
    /// the typo harness: a third gained the common words less than it cost the rarer ones.
    ///
    /// ponytail: a password typed at a prompt is corrected too, at a key's edge, like the
    /// system keyboard's own dynamic hit areas. A secure-entry signal could switch it off.
    static func corrected(_ nearest: Key, at point: CGPoint, keys: [(Key, CGRect)],
                          prefix: String, known: (String) -> Bool, likely: (String) -> Double = { _ in 0 }) -> Key {
        func letter(_ k: Key) -> String? {
            if case .char(let c) = k, c.first?.isLetter == true { return c }
            return nil
        }
        guard !prefix.isEmpty, let c = letter(nearest),
              let frame = keys.first(where: { $0.0 == nearest })?.1 else { return nearest }
        let center = frame.insetBy(dx: frame.width / 4, dy: frame.height / 4)
        if center.contains(point) { return nearest }
        let reach = frame.width / 2
        let candidates = keys
            .filter { $0.0 != nearest && letter($0.0) != nil && distance(point, $0.1) <= reach }
            .sorted { distance(point, $0.1) < distance(point, $1.1) }
        guard known(prefix + c) else { return candidates.first { known(prefix + letter($0.0)!) }?.0 ?? nearest }
        let sigma = frame.width / 4
        func score(_ k: (Key, CGRect)) -> Double {
            let d = hypot(point.x - k.1.midX, point.y - k.1.midY)
            return likely(prefix + letter(k.0)!) * exp(-Double(d * d / (2 * sigma * sigma)))
        }
        let mine = score((nearest, frame))
        return candidates.filter { score($0) > mine }.max { score($0) < score($1) }?.0 ?? nearest
    }

    /// English's checker language. Also the extension's suggestions' (`Suggestions`).
    static let language: String? = {
        let all = UITextChecker.availableLanguages
        return all.contains("en_US") ? "en_US" : all.first { $0.hasPrefix("en") }
    }()
    /// One checker for every keyboard and language (each lookup names its language).
    /// `init` makes a lookup in its layout's language, so that lexicon loads with the
    /// keyboard, not on the first ambiguous touch. It also starts the checker's warm-up: for
    /// ~0.3 s after its first use in a process, guesses come from a cold list ("hese" →
    /// "hess" before "here"), so the first word the bar corrects would get those.
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
