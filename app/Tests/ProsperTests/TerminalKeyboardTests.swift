import XCTest
import UIKit
@testable import Prosper

/// The compact iPhone keyboard: every printable ASCII character reachable, the shift
/// rules, what reaches the terminal's text input, and that the host installs it.
@MainActor
final class TerminalKeyboardTests: XCTestCase {

    private final class SpyInput: NSObject, UIKeyInput {
        var calls: [String] = []
        var hasText: Bool { true }
        func insertText(_ text: String) { calls.append(text) }
        func deleteBackward() { calls.append("⌫") }
    }

    // MARK: Layout coverage

    private func chars(_ keys: [TerminalKeyboard.Key]) -> [String] {
        keys.compactMap { if case .char(let c) = $0 { return c } else { return nil } }
    }

    /// Every printable ASCII character and space is a tap (letters uppercase through
    /// shift) or a hold. Taps never repeat; a hold may repeat a tap or another hold.
    func testEveryPrintableAsciiIsReachableByTapOrHold() {
        let taps = chars(Array(TerminalKeyboard.rows.joined()))
        XCTAssertEqual(taps.count, Set(taps).count, "a key appears twice")
        let letters = taps.filter { $0.first!.isLetter }
        XCTAssertEqual(Set(letters), Set("abcdefghijklmnopqrstuvwxyz".map(String.init)))
        XCTAssertTrue(TerminalKeyboard.rows.joined().contains(.space))
        let reachable = Set(taps + letters.map { $0.uppercased() } + TerminalKeyboard.holdSymbol.values + [" "])
        let printable = Set((0x20...0x7E).map { String(UnicodeScalar(UInt8($0))) })
        XCTAssertEqual(printable.subtracting(reachable).sorted(), [], "unreachable")
        XCTAssertEqual(reachable.subtracting(printable).sorted(), [], "not ASCII")
    }

    /// Every letter and digit has a symbol, and only they do: the bottom row's punctuation
    /// has no hint.
    func testHoldSymbolCoversEveryLetterAndDigit() {
        let hinted = Set(chars(Array(TerminalKeyboard.rows.joined())).filter { $0.first!.isLetter || $0.first!.isNumber })
        XCTAssertEqual(hinted.count, 36)
        XCTAssertEqual(Set(TerminalKeyboard.holdSymbol.keys), hinted)
        XCTAssertEqual(TerminalKeyboard.holdSymbol["q"], "`")
        XCTAssertEqual(TerminalKeyboard.holdSymbol["w"], "\\")
        XCTAssertEqual(TerminalKeyboard.holdSymbol["1"], "!")
        XCTAssertEqual(TerminalKeyboard.holdSymbol["m"], "/")
    }

    func testDigitsLeadAndShiftLeavesThem() throws {
        XCTAssertEqual(chars(TerminalKeyboard.rows[0]), "1234567890".map(String.init))
        let (kb, caps) = laidOut()
        let spy = SpyInput()
        kb.target = spy
        let five = try XCTUnwrap(caps["5"]).frame
        XCTAssertLessThan(five.maxY, try XCTUnwrap(caps["q"]).frame.minY, "digits sit above qwerty")
        kb.track(.began, id: 1, at: CGPoint(x: five.midX, y: five.midY))
        kb.track(.ended, id: 1, at: CGPoint(x: five.midX, y: five.midY))
        kb.press(.shift)
        kb.press(.char("5"))
        XCTAssertEqual(spy.calls, ["5", "5"], "shift doesn't change a digit")
        XCTAssertEqual(kb.shift.mode, .once, "nor does a digit spend it")
    }

    /// The digit row is dim like shift, delete and return; letters and punctuation aren't.
    func testDigitsUseTheSpecialColor() throws {
        let (_, caps) = laidOut()
        let special = try XCTUnwrap(caps["shift"]).backgroundColor
        let plain = try XCTUnwrap(caps["q"]).backgroundColor
        XCTAssertNotEqual(special, plain)
        for d in "1234567890" { XCTAssertEqual(caps[String(d)]?.backgroundColor, special, "\(d)") }
        for k in ["delete", "new line"] { XCTAssertEqual(caps[k]?.backgroundColor, special, k) }
        for k in ["a", "m", ".", ",", "?", "space"] { XCTAssertEqual(caps[k]?.backgroundColor, plain, k) }
        XCTAssertEqual(try XCTUnwrap(caps["5"]).title(for: .normal), "5")
        XCTAssertEqual(try XCTUnwrap(caps["5"]).titleColor(for: .normal), .white)
    }

    /// Each hinted cap draws its symbol small in its top-right quadrant, the letter still
    /// centered; at the narrowest iPhone the hint stays inside the cap.
    func testHintLabelsSitTopRight() throws {
        for width in [375, 402] as [CGFloat] {
            let (kb, caps) = laidOut(width: width)
            kb.press(.shift)   // uppercase caps keep their hints
            kb.layoutIfNeeded()
            for (key, symbol) in TerminalKeyboard.holdSymbol {
                let cap = try XCTUnwrap(caps[key], key)
                cap.layoutIfNeeded()
                let hint = try XCTUnwrap(cap.subviews.compactMap { $0 as? UILabel }
                    .first { $0 !== cap.titleLabel && $0.text == symbol }, "\(key) at \(width)")
                let b = cap.bounds, f = hint.frame
                XCTAssertGreaterThan(f.width, 0)
                XCTAssertGreaterThanOrEqual(f.minX, b.midX, "\(key) at \(width)")
                XCTAssertLessThanOrEqual(f.maxX, b.maxX, "\(key) at \(width)")
                XCTAssertGreaterThanOrEqual(f.minY, -1, "only the empty ascent rises past the cap: \(key) at \(width)")
                XCTAssertLessThanOrEqual(f.maxY, b.midY, "\(key) at \(width)")
                XCTAssertLessThanOrEqual(hint.font.pointSize, 11)
            }
            XCTAssertEqual(caps["q"]?.title(for: .normal), "Q", "keyed lowercase, shown shifted")
            for k in [".", ",", "/", "?"] {
                let cap = try XCTUnwrap(caps[k], k)
                XCTAssertTrue(cap.subviews.compactMap { $0 as? UILabel }.allSatisfy { $0 === cap.titleLabel || ($0.text ?? "").isEmpty },
                              "\(k) has no hint")
            }
        }
    }

    /// Five rows, the keys ending at `keysHeight`.
    func testFiveRowsAndTheHeight() {
        let kb = TerminalKeyboard()
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        XCTAssertEqual(TerminalKeyboard.rows.count, 5)
        let caps = kb.subviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(Set(caps.map(\.frame.minY)).count, 5)
        XCTAssertEqual(caps.map(\.frame.maxY).max(), TerminalKeyboard.keysHeight)
    }

    /// Landscape (a compact vertical size class): 149 pt of keys in five 26 pt rows that
    /// don't overlap, the height following the traits both ways, hints still top-right,
    /// touches still on the key drawn there, and a top-row bubble rising 35 pt.
    func testLandscapeRowsAreShorterAndFollowTheTraits() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.traitOverrides.verticalSizeClass = .compact
        let kb = TerminalKeyboard()
        kb.frame = CGRect(x: 0, y: 0, width: 874, height: TerminalKeyboard.height)
        window.addSubview(kb)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let height = try XCTUnwrap(kb.constraints.first { $0.firstItem === kb && $0.firstAttribute == .height })
        XCTAssertEqual(TerminalKeyboard.keysHeight(compact: true), 149)
        XCTAssertEqual(height.constant, TerminalKeyboard.keysHeight(compact: true) + TerminalKeyboard.bottomPadding)
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews { caps[b.accessibilityLabel ?? ""] = b }
        let tops = Set(caps.values.map(\.frame.minY)).sorted()
        XCTAssertEqual(tops.count, 5)
        XCTAssertTrue(caps.values.allSatisfy { $0.frame.height == 26 })
        for (a, b) in zip(tops, tops.dropFirst()) { XCTAssertLessThan(a + 26, b, "rows overlap") }
        XCTAssertEqual(caps.values.map(\.frame.maxY).max(), TerminalKeyboard.keysHeight(compact: true))
        let g = try XCTUnwrap(caps["g"])
        g.layoutIfNeeded()
        let hint = try XCTUnwrap(g.subviews.compactMap { $0 as? UILabel }.first { $0.text == "-" })
        XCTAssertGreaterThanOrEqual(hint.frame.minX, g.bounds.midX)
        XCTAssertLessThanOrEqual(hint.frame.maxY, g.bounds.midY)
        for label in ["1", "q", "g", "space"] {
            let f = try XCTUnwrap(caps[label]).frame
            XCTAssertEqual(kb.key(at: CGPoint(x: f.midX, y: f.midY)), label == "space" ? .space : .char(label))
            XCTAssertEqual(kb.key(at: CGPoint(x: f.midX, y: f.maxY + 2)), label == "space" ? .space : .char(label),
                           "just under \(label): still its row")
        }
        let one = try XCTUnwrap(caps["1"]).frame
        kb.track(.began, id: 1, at: CGPoint(x: one.midX, y: one.midY))
        XCTAssertEqual(try XCTUnwrap(kb.previewFrame).minY, one.minY - 35)
        kb.track(.cancelled, id: 1, at: CGPoint(x: one.midX, y: one.midY))

        window.traitOverrides.verticalSizeClass = .regular
        window.layoutIfNeeded()
        XCTAssertEqual(height.constant, TerminalKeyboard.height, "back to portrait")
        XCTAssertEqual(kb.subviews.compactMap { $0 as? UIButton }.map(\.frame.maxY).max(), TerminalKeyboard.keysHeight)
    }

    /// Render check, run by hand: `TK_SNAPSHOT_DIR=<dir>` saves the keyboard at 375 and
    /// 402 pt, lowercase, shifted, and with `s` held (its bubble showing #).
    func testSnapshotPages() throws {
        guard let dir = ProcessInfo.processInfo.environment["TK_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TK_SNAPSHOT_DIR to render")
        }
        for width in [375, 402] as [CGFloat] {
            let (kb, caps) = laidOut(width: width)
            kb.backgroundColor = .black
            func save(_ name: String) throws {
                kb.layoutIfNeeded()
                let png = UIGraphicsImageRenderer(bounds: kb.bounds).pngData { kb.layer.render(in: $0.cgContext) }
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("463-\(name)-\(Int(width)).png"))
            }
            try save("letters")
            let s = try XCTUnwrap(caps["s"]).frame
            kb.track(.began, id: 1, at: CGPoint(x: s.midX, y: s.midY))
            kb.fireHold()
            try save("held")
            kb.track(.cancelled, id: 1, at: CGPoint(x: s.midX, y: s.midY - 40))
            kb.press(.shift)
            try save("shifted")
        }
    }

    func testRowsFitTheWidth() {
        for width in [375, 393, 402, 440] as [CGFloat] {
            for row in TerminalKeyboard.rows {
                let slots = TerminalKeyboard.place(row, width: width)
                XCTAssertEqual(slots.count, row.count)
                XCTAssertGreaterThanOrEqual(slots.first!.x, -0.001)
                XCTAssertLessThanOrEqual(slots.last!.x + slots.last!.w, width + 0.001)
                for (a, b) in zip(slots, slots.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b.x - (a.x + a.w), TerminalKeyboard.keyGap - 0.001, "keys overlap in \(row)")
                }
            }
        }
    }

    func testARowFillsTheWidth() {
        let row = TerminalKeyboard.rows[2]
        XCTAssertEqual(row.count, 9)
        let slots = TerminalKeyboard.place(row, width: 393)
        XCTAssertEqual(slots.first!.x, 0, accuracy: 0.001)
        XCTAssertEqual(slots.last!.x + slots.last!.w, 393, accuracy: 0.001)
        let top = TerminalKeyboard.place(TerminalKeyboard.rows[1], width: 393)
        XCTAssertGreaterThan(slots[0].w, top[0].w, "nine keys in the width of ten are wider")
        // Short character rows stay one unit wide, centered.
        let short = TerminalKeyboard.place([.char("!"), .char("\\")], width: 393)
        XCTAssertEqual(short.count, 2)
        XCTAssertEqual(short[0].w, top[0].w, accuracy: 0.001)
        XCTAssertEqual(short[1].w, top[0].w, accuracy: 0.001)
        XCTAssertEqual(short[0].x, 393 - (short[1].x + short[1].w), accuracy: 0.001)
    }

    func testBottomRow() {
        XCTAssertEqual(TerminalKeyboard.rows.last!,
                       [.char("."), .char(","), .char("/"), .space, .char("?"), .ret])
    }

    /// The home-indicator inset is not reserved under the keys, only a pad that keeps
    /// the space bar off the bottom edge.
    func testHeight() {
        XCTAssertEqual(TerminalKeyboard.height, TerminalKeyboard.keysHeight + TerminalKeyboard.bottomPadding)
        XCTAssertEqual(TerminalKeyboard.height, 276)
        XCTAssertTrue((26...28).contains(TerminalKeyboard.bottomPadding))
        XCTAssertEqual(TerminalKeyboard().frame.height, TerminalKeyboard.height)
    }

    func testBottomRowClearsTheCornersAndSpaceStaysWide() throws {
        for width in [375, 393, 402, 440] as [CGFloat] {
            let (_, caps) = laidOut(width: width)
            let space = try XCTUnwrap(caps["space"]), ret = try XCTUnwrap(caps["new line"])
            let dot = try XCTUnwrap(caps["."])
            XCTAssertGreaterThanOrEqual(space.frame.width, 110, "at \(width)")
            XCTAssertEqual(dot.frame.minX, TerminalKeyboard.bottomRowInset, accuracy: 0.001)
            XCTAssertEqual(ret.frame.maxX, width - TerminalKeyboard.bottomRowInset, accuracy: 0.001)
            XCTAssertEqual(space.frame.maxY, TerminalKeyboard.height - TerminalKeyboard.bottomPadding,
                           accuracy: 0.001)
        }
    }

    // MARK: Touch tracking

    private func presses(_ effects: [KeyTouchTracker.Effect]) -> [TerminalKeyboard.Key] {
        effects.compactMap { if case .press(let k) = $0 { return k } else { return nil } }
    }

    func testTrackerSameKeyTwiceWhileHeldTypesTwice() {
        var t = KeyTouchTracker()
        var out: [TerminalKeyboard.Key] = []
        out += presses(t.began(1, .char("l")))
        out += presses(t.began(2, .char("l")))   // second finger while the first is down
        out += presses(t.ended(1))
        out += presses(t.ended(2))
        XCTAssertEqual(out, [.char("l"), .char("l")])
        out = presses(t.began(3, .space)) + presses(t.ended(3)) + presses(t.began(4, .space)) + presses(t.ended(4))
        XCTAssertEqual(out, [.space, .space])
    }

    func testTrackerRolloverKeepsPressOrder() {
        var t = KeyTouchTracker()
        XCTAssertEqual(presses(t.began(1, .char("a"))), [])
        XCTAssertEqual(presses(t.began(2, .char("b"))), [.char("a")], "a types as soon as b goes down")
        XCTAssertEqual(presses(t.ended(2)), [.char("b")], "b released first still comes after a")
        XCTAssertEqual(presses(t.ended(1)), [], "a isn't typed twice")
        XCTAssertEqual(t.held, [])
    }

    func testTrackerCancelStillTypesOnce() {
        var t = KeyTouchTracker()
        _ = t.began(1, .space)
        XCTAssertEqual(presses(t.cancelled(1)), [.space])
        XCTAssertEqual(presses(t.cancelled(1)), [])
        XCTAssertEqual(presses(t.ended(1)), [])
        _ = t.began(2, .char("x")); _ = t.began(3, .char("y"))   // x typed by the rollover
        XCTAssertEqual(presses(t.cancelled(2)), [])
        XCTAssertEqual(presses(t.cancelled(3)), [.char("y")])
    }

    /// The home gesture starting in the strip under space: a cancelled swipe types nothing.
    func testTrackerCancelledSwipeTypesNothing() {
        var t = KeyTouchTracker()
        _ = t.began(1, .space, at: CGPoint(x: 200, y: 200))
        t.moved(1, .space, at: CGPoint(x: 200, y: 170))
        XCTAssertEqual(t.cancelled(1, at: CGPoint(x: 200, y: 170)), [], "moved 30 pt up")
        // Travel seen only at the cancel counts too.
        _ = t.began(2, .space, at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(t.cancelled(2, at: CGPoint(x: 200, y: 170)), [])
        // Travel that came back still counts: it was a swipe.
        _ = t.began(3, .char("a"), at: CGPoint(x: 20, y: 70))
        t.moved(3, .char("a"), at: CGPoint(x: 20, y: 40))
        XCTAssertEqual(t.cancelled(3, at: CGPoint(x: 20, y: 70)), [])
        // Still a tap under the slop: types once.
        _ = t.began(4, .space, at: CGPoint(x: 200, y: 200))
        t.moved(4, .space, at: CGPoint(x: 203, y: 194))
        XCTAssertEqual(t.cancelled(4, at: CGPoint(x: 203, y: 194)), [.press(.space)])
        XCTAssertEqual(t.cancelled(4, at: CGPoint(x: 203, y: 194)), [])
        // Backspace still stops its repeat; a normal lift after a slide still types.
        _ = t.began(5, .backspace, at: CGPoint(x: 380, y: 120))
        XCTAssertEqual(t.cancelled(5, at: CGPoint(x: 380, y: 60)), [.stopRepeat])
        _ = t.began(6, .char("q"), at: CGPoint(x: 20, y: 25))
        t.moved(6, .char("w"), at: CGPoint(x: 60, y: 25))
        XCTAssertEqual(t.ended(6), [.press(.char("w"))])
    }

    /// The home gesture is cancelled inside the slop: a cancelled touch that began under
    /// the bottom row types nothing, however little it moved. Lifted normally, it types.
    func testTrackerCancelBegunBelowTheKeysTypesNothing() {
        var t = KeyTouchTracker()
        _ = t.began(1, .space, at: CGPoint(x: 200, y: 215), belowKeys: true)
        XCTAssertEqual(t.cancelled(1, at: CGPoint(x: 200, y: 213)), [], "moved 2 pt")
        _ = t.began(2, .space, at: CGPoint(x: 200, y: 215), belowKeys: true)
        XCTAssertEqual(t.cancelled(2, at: CGPoint(x: 200, y: 215)), [], "didn't move")
        _ = t.began(3, .space, at: CGPoint(x: 200, y: 215), belowKeys: true)
        XCTAssertEqual(t.ended(3), [.press(.space)], "a tap there still types")
        _ = t.began(4, .space, at: CGPoint(x: 200, y: 180))
        XCTAssertEqual(t.cancelled(4, at: CGPoint(x: 200, y: 180)), [.press(.space)], "on the key: types")
    }

    func testTrackerSlideTypesTheKeyUnderTheFingerAtLift() {
        var t = KeyTouchTracker()
        _ = t.began(1, .char("q"))
        XCTAssertEqual(t.previewKey, .char("q"))
        t.moved(1, .char("w"))
        XCTAssertEqual(t.previewKey, .char("w"))
        XCTAssertEqual(t.held, [.char("w")])
        t.moved(1, .shift)   // sliding over a key that acts on down doesn't become it
        XCTAssertEqual(presses(t.ended(1)), [.char("w")])
        XCTAssertNil(t.previewKey)
    }

    func testTrackerShiftAndBackspaceActOnDown() {
        var t = KeyTouchTracker()
        XCTAssertEqual(t.began(1, .shift), [.press(.shift)])
        XCTAssertEqual(t.ended(1), [])
        XCTAssertEqual(t.began(2, .backspace), [.press(.backspace), .startRepeat])
        t.moved(2, .char("a"))
        XCTAssertEqual(t.cancelled(2), [.stopRepeat], "no delete beyond the first on cancel")
        XCTAssertEqual(t.began(3, .char("a")), [])
        XCTAssertEqual(t.began(4, .backspace), [.press(.char("a")), .press(.backspace), .startRepeat],
                       "a held letter types before the delete")
        XCTAssertEqual(t.ended(4), [.stopRepeat])
        XCTAssertEqual(t.ended(3), [])
    }

    // MARK: Hold

    func testTrackerHoldTypesTheSymbol() {
        var t = KeyTouchTracker()
        XCTAssertEqual(t.began(1, .char("s")), [])
        XCTAssertNil(t.previewSymbol)
        XCTAssertTrue(t.hold(1, over: .char("s")))
        XCTAssertEqual(t.previewKey, .char("s"), "the bubble stays over s")
        XCTAssertEqual(t.previewSymbol, "#")
        t.moved(1, .char("d"))
        XCTAssertEqual(t.held, [.char("s")], "a held touch stays its symbol")
        XCTAssertFalse(t.hold(1, over: .char("s")), "converts once")
        XCTAssertEqual(t.ended(1), [.press(.char("#"))])
        XCTAssertNil(t.previewSymbol)
        // The hold takes the key it is given, a digit too.
        _ = t.began(2, .char("r"))
        XCTAssertTrue(t.hold(2, over: .char("1")))
        XCTAssertEqual(t.ended(2), [.press(.char("!"))])
    }

    func testTrackerQuickTapTypesTheChar() {
        var t = KeyTouchTracker()
        _ = t.began(1, .char("s"))
        XCTAssertEqual(t.ended(1), [.press(.char("s"))])
        XCTAssertFalse(t.hold(1, over: .char("s")), "a hold after the lift does nothing")
        // Keys with no symbol don't convert.
        for key in [TerminalKeyboard.Key.char("."), .space, .ret] {
            _ = t.began(2, key)
            XCTAssertFalse(t.hold(2, over: key), "\(key)")
            XCTAssertEqual(t.ended(2), [.press(key)])
        }
        // Backspace keeps its repeat: a hold timer is not its business.
        XCTAssertEqual(t.began(3, .backspace), [.press(.backspace), .startRepeat])
        XCTAssertFalse(t.hold(3, over: .backspace))
        XCTAssertEqual(t.ended(3), [.stopRepeat])
    }

    /// A second finger before the threshold types the first as its char; the hold that
    /// fires afterwards has nothing left to convert. The newest touch still can.
    func testTrackerRolledTypingBeforeTheHoldTypesChars() {
        var t = KeyTouchTracker()
        _ = t.began(1, .char("a"))
        XCTAssertEqual(presses(t.began(2, .char("b"))), [.char("a")])
        XCTAssertFalse(t.hold(1, over: .char("a")))
        XCTAssertEqual(presses(t.ended(1)), [])
        XCTAssertEqual(presses(t.ended(2)), [.char("b")])
        // A held touch rolled over types its symbol, in order.
        _ = t.began(3, .char("a"))
        XCTAssertTrue(t.hold(3, over: .char("a")))
        XCTAssertEqual(presses(t.began(4, .char("b"))), [.char("@")])
        XCTAssertEqual(presses(t.ended(3)), [])
        XCTAssertEqual(presses(t.ended(4)), [.char("b")])
        // A held touch the system cancels follows the cancel rules: a swipe types nothing.
        _ = t.began(5, .char("a"), at: CGPoint(x: 20, y: 70))
        XCTAssertTrue(t.hold(5, over: .char("a")))
        XCTAssertEqual(t.cancelled(5, at: CGPoint(x: 20, y: 30)), [])
    }

    /// Through the view: the real timer converts after `holdDelay`, the bubble shows the
    /// symbol, and the lift types it; a symbol ends the word and keeps a one-shot shift.
    func testHoldThroughTheKeyboard() throws {
        let (kb, caps) = laidOut()
        let spy = SpyInput()
        kb.target = spy
        let s = try XCTUnwrap(caps["s"]).frame, p = CGPoint(x: s.midX, y: s.midY)
        kb.press(.char("a"))
        kb.press(.shift)
        kb.track(.began, id: 1, at: p)
        XCTAssertEqual(kb.previewText, "S")
        RunLoop.main.run(until: Date().addingTimeInterval(KeyTouchTracker.holdDelay + 0.15))
        XCTAssertEqual(kb.previewText, "#", "the hold timer fired")
        kb.track(.ended, id: 1, at: p)
        XCTAssertNil(kb.previewText)
        XCTAssertEqual(spy.calls, ["a", "#"])
        XCTAssertEqual(kb.word, "", "a symbol ends the word")
        XCTAssertEqual(kb.shift.mode, .once, "and doesn't spend the one-shot shift")
        // A quick tap: the char, shifted; the timer that would have fired is gone.
        kb.track(.began, id: 2, at: p)
        kb.track(.ended, id: 2, at: p)
        RunLoop.main.run(until: Date().addingTimeInterval(KeyTouchTracker.holdDelay + 0.1))
        XCTAssertEqual(spy.calls, ["a", "#", "S"])
        // Rolled typing: the first finger is typed by the second, so its hold is void.
        kb.track(.began, id: 3, at: p)
        let d = try XCTUnwrap(caps["d"]).frame, q = CGPoint(x: d.midX, y: d.midY)
        kb.track(.began, id: 4, at: q)
        kb.fireHold()
        XCTAssertEqual(kb.previewText, "&", "the newest touch is the one held")
        kb.track(.ended, id: 3, at: p)
        kb.track(.ended, id: 4, at: q)
        XCTAssertEqual(spy.calls, ["a", "#", "S", "s", "&"])
    }

    /// "tes" and a touch on r's right edge: a tap is corrected to t, a hold is not, so it
    /// types r's symbol, |, not t's [.
    func testHoldIgnoresCorrection() throws {
        let (kb, caps) = laidOut()
        let spy = SpyInput()
        kb.target = spy
        let r = try XCTUnwrap(caps["r"]).frame, edge = CGPoint(x: r.maxX - 1, y: r.midY)
        for c in "tes" { kb.press(.char(String(c))) }
        kb.track(.began, id: 1, at: edge)
        kb.track(.ended, id: 1, at: edge)
        XCTAssertEqual(spy.calls.last, "t", "precondition: the tap is corrected")
        kb.resetWord()
        for c in "tes" { kb.press(.char(String(c))) }
        kb.track(.began, id: 2, at: edge)
        kb.fireHold()
        XCTAssertEqual(kb.previewText, "|")
        kb.track(.ended, id: 2, at: edge)
        XCTAssertEqual(spy.calls.last, "|")
    }

    /// A finger that slides from s to d before the timer holds d, the key under it when
    /// the hold fires: d's &, not s's #.
    func testAHoldConvertsTheKeyUnderTheFingerWhenItFires() throws {
        let (kb, caps) = laidOut()
        let spy = SpyInput()
        kb.target = spy
        let s = try XCTUnwrap(caps["s"]).frame, d = try XCTUnwrap(caps["d"]).frame
        kb.track(.began, id: 1, at: CGPoint(x: s.midX, y: s.midY))
        kb.track(.moved, id: 1, at: CGPoint(x: d.midX, y: d.midY))
        kb.fireHold()
        XCTAssertEqual(kb.previewText, "&")
        kb.track(.ended, id: 1, at: CGPoint(x: d.midX, y: d.midY))
        XCTAssertEqual(spy.calls, ["&"])
    }

    /// The hold threshold is the spec, not whatever the constant says: the other hold
    /// tests wait `holdDelay`, so they pass at any value.
    func testHoldDelayIsTheSpec() {
        XCTAssertEqual(KeyTouchTracker.holdDelay, 0.35)
    }

    // MARK: Trackpad

    /// A space hold is a trackpad: one caret step per `caretStep` sideways, signed, the
    /// remainder carried; up and down move nothing; lifting types nothing; other fingers
    /// are ignored while it's down. A tap still types space.
    func testTrackerSpaceHoldMovesTheCaret() {
        var t = KeyTouchTracker()
        let step = KeyTouchTracker.caretStep, y: CGFloat = 200
        _ = t.began(1, .space, at: CGPoint(x: 200, y: y))
        XCTAssertTrue(t.startTrackpad(1, at: 200))
        XCTAssertTrue(t.isTrackpad)
        XCTAssertEqual(t.moved(1, .space, at: CGPoint(x: 200 + 2.5 * step, y: y)), [.caret(2)])
        XCTAssertEqual(t.moved(1, .space, at: CGPoint(x: 200 + 2.9 * step, y: y - 40)), [],
                       "under a step from the last one, and vertical travel moves nothing")
        XCTAssertEqual(t.moved(1, .char("q"), at: CGPoint(x: 200 - 1.2 * step, y: 20)), [.caret(-3)],
                       "back from 2 steps right to past 1 left, over any key")
        XCTAssertEqual(t.began(2, .char("a")), [], "a second finger types nothing")
        XCTAssertEqual(t.moved(2, .char("a"), at: CGPoint(x: 0, y: 0)), [])
        XCTAssertEqual(t.ended(2), [])
        XCTAssertEqual(t.held, [.space], "and isn't tracked")
        XCTAssertEqual(t.ended(1), [], "lifting types no space")
        XCTAssertFalse(t.isTrackpad)

        _ = t.began(3, .space, at: CGPoint(x: 200, y: y))
        XCTAssertTrue(t.startTrackpad(3, at: 200))
        XCTAssertEqual(t.ended(3), [], "a hold and lift with no drag types nothing")
        _ = t.began(4, .space, at: CGPoint(x: 200, y: y))
        XCTAssertTrue(t.startTrackpad(4, at: 200))
        XCTAssertEqual(t.cancelled(4, at: CGPoint(x: 200, y: y)), [], "nor does a cancel")

        XCTAssertEqual(t.began(5, .space), [])
        XCTAssertEqual(t.ended(5), [.press(.space)], "a tap is space")
        XCTAssertFalse(t.startTrackpad(5, at: 0), "a hold after the lift does nothing")
        _ = t.began(6, .char("s"))
        XCTAssertFalse(t.startTrackpad(6, at: 0), "only space")
        _ = t.ended(6)
        _ = t.began(7, .space, at: CGPoint(x: 200, y: 215), belowKeys: true)
        XCTAssertFalse(t.startTrackpad(7, at: 200), "never from the home gesture's strip")
        XCTAssertEqual(t.ended(7), [.press(.space)])
    }

    /// Text a cap shows: its title, image or hint.
    private func shown(_ cap: UIButton) -> [String] {
        [cap.title(for: .normal), cap.image(for: .normal).map { _ in "image" }].compactMap { $0 }
            + cap.subviews.compactMap { v in
                guard let l = v as? UILabel, l !== cap.titleLabel, !l.isHidden else { return nil }
                return l.text
            }
    }

    /// Through the view: the hold blanks every cap with a haptic, a drag on it moves the
    /// caret through `moveCaret`, and the lift types nothing and brings the labels back
    /// with the one-shot shift still showing.
    func testSpaceHoldBlanksTheKeysAndMovesTheCaret() throws {
        let (kb, caps) = laidOut()
        let spy = SpyInput()
        kb.target = spy
        var steps: [Int] = []
        kb.moveCaret = { steps.append($0) }
        kb.press(.shift)
        let before = caps.mapValues(shown)
        XCTAssertEqual(before["q"], ["Q", "`"], "precondition: shifted letters with hints")
        let space = try XCTUnwrap(caps["space"]).frame, p = CGPoint(x: space.midX, y: space.midY)
        kb.track(.began, id: 1, at: p)
        RunLoop.main.run(until: Date().addingTimeInterval(KeyTouchTracker.holdDelay + 0.15))
        for (name, cap) in caps { XCTAssertEqual(shown(cap), [], "\(name) blanks") }
        kb.track(.began, id: 2, at: try XCTUnwrap(caps["q"]).center)   // ignored
        kb.track(.ended, id: 2, at: try XCTUnwrap(caps["q"]).center)
        kb.track(.moved, id: 1, at: CGPoint(x: p.x - 3.5 * KeyTouchTracker.caretStep, y: p.y))
        kb.track(.moved, id: 1, at: CGPoint(x: p.x - 1.9 * KeyTouchTracker.caretStep, y: p.y - 30))
        kb.track(.ended, id: 1, at: CGPoint(x: p.x - 1.9 * KeyTouchTracker.caretStep, y: p.y - 30))
        XCTAssertEqual(steps, [-3, 1])
        XCTAssertEqual(spy.calls, [], "no space, and the second finger typed nothing")
        XCTAssertEqual(caps.mapValues(shown), before, "every label back, shift's included")
        XCTAssertEqual(kb.shift.mode, .once)
    }

    /// Character Preview off: a press shows no bubble, a hold still shows its symbol.
    func testCharacterPreviewSwitch() throws {
        for on in [true, false] {
            let (kb, caps) = laidOut()
            let spy = SpyInput()
            kb.target = spy
            kb.settings.characterPreview = on
            let s = try XCTUnwrap(caps["s"]).frame, p = CGPoint(x: s.midX, y: s.midY)
            kb.track(.began, id: 1, at: p)
            XCTAssertEqual(kb.previewText, on ? "s" : nil)
            kb.fireHold()
            XCTAssertEqual(kb.previewText, "#", "the hold's symbol either way")
            kb.track(.ended, id: 1, at: p)
            XCTAssertNil(kb.previewText)
            kb.track(.began, id: 2, at: p)
            XCTAssertEqual(kb.previewText, on ? "s" : nil)
            kb.track(.ended, id: 2, at: p)
            XCTAssertEqual(spy.calls, ["#", "s"])
        }
    }

    // MARK: Press preview

    private func laidOut(width: CGFloat = 402) -> (TerminalKeyboard, [String: UIButton]) {
        let kb = TerminalKeyboard()
        kb.frame = CGRect(x: 0, y: 0, width: width, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews {
            caps[b.title(for: .normal) ?? b.accessibilityLabel ?? ""] = b
        }
        return (kb, caps)
    }

    func testTouchesPreviewAndPressedLookFollowTheFinger() throws {
        let (kb, caps) = laidOut()
        let spy = SpyInput()
        kb.target = spy
        var sent: [[UInt8]] = []
        kb.sendBytes = { sent.append($0) }
        func at(_ label: String) throws -> CGPoint {
            let f = try XCTUnwrap(caps[label], label).frame
            return CGPoint(x: f.midX, y: f.midY)
        }
        let q = try XCTUnwrap(caps["q"]), w = try XCTUnwrap(caps["w"])

        kb.track(.began, id: 1, at: try at("q"))
        XCTAssertEqual(kb.previewText, "q")
        XCTAssertTrue(q.isHighlighted)
        let qf = try XCTUnwrap(kb.previewFrame)
        XCTAssertGreaterThanOrEqual(qf.minX, 0, "edge key keeps its bubble on screen")
        kb.track(.moved, id: 1, at: try at("w"))
        XCTAssertEqual(kb.previewText, "w", "the preview follows the finger")
        XCTAssertFalse(q.isHighlighted)
        XCTAssertTrue(w.isHighlighted)
        kb.track(.ended, id: 1, at: try at("w"))
        XCTAssertNil(kb.previewText)
        XCTAssertFalse(w.isHighlighted)
        XCTAssertEqual(spy.calls, ["w"])
        kb.track(.began, id: 11, at: try at("1"))
        XCTAssertLessThan(try XCTUnwrap(kb.previewFrame).minY, 0, "a top-row bubble rises above the keyboard")
        kb.track(.ended, id: 11, at: try at("1"))
        XCTAssertEqual(spy.calls, ["w", "1"])
        spy.calls.removeLast()

        kb.track(.began, id: 2, at: try at("p"))
        XCTAssertLessThanOrEqual(try XCTUnwrap(kb.previewFrame).maxX, 402)
        kb.track(.cancelled, id: 2, at: try at("p"))
        XCTAssertNil(kb.previewText, "cancel must not leave the bubble stuck")
        XCTAssertEqual(spy.calls, ["w", "p"], "a cancelled tap still types")

        // A home swipe starting in the strip under space: cancelled after 30 pt, types nothing.
        let strip = CGPoint(x: try at("space").x, y: kb.bounds.maxY - 4)
        kb.track(.began, id: 20, at: strip)
        kb.track(.moved, id: 20, at: CGPoint(x: strip.x, y: strip.y - 30))
        kb.track(.cancelled, id: 20, at: CGPoint(x: strip.x, y: strip.y - 30))
        XCTAssertEqual(spy.calls, ["w", "p"], "a home swipe must not type a space")
        XCTAssertFalse(try XCTUnwrap(caps["space"]).isHighlighted)
        // The system cancels the home gesture inside the slop: still nothing.
        kb.track(.began, id: 21, at: strip)
        kb.track(.cancelled, id: 21, at: CGPoint(x: strip.x, y: strip.y - 3))
        XCTAssertEqual(spy.calls, ["w", "p"], "a short home swipe must not type a space")
        // Just under the space bar's frame counts as the strip too.
        let under = CGPoint(x: strip.x, y: try XCTUnwrap(caps["space"]).frame.maxY + 1)
        kb.track(.began, id: 22, at: under)
        kb.track(.cancelled, id: 22, at: under)
        XCTAssertEqual(spy.calls, ["w", "p"])
        // A cancelled tap on the space bar itself still types.
        kb.track(.began, id: 23, at: try at("space"))
        kb.track(.cancelled, id: 23, at: try at("space"))
        XCTAssertEqual(spy.calls, ["w", "p", " "])
        spy.calls.removeLast()

        // Rolled typing: q types when w goes down, and w's bubble takes over.
        kb.track(.began, id: 3, at: try at("q"))
        kb.track(.began, id: 4, at: try at("w"))
        XCTAssertEqual(spy.calls.last, "q")
        XCTAssertEqual(kb.previewText, "w")
        kb.track(.ended, id: 3, at: try at("q"))
        XCTAssertEqual(kb.previewText, "w")
        kb.track(.ended, id: 4, at: try at("w"))
        XCTAssertEqual(spy.calls, ["w", "p", "q", "w"])

        // No dead zones: the strip under the bottom row and the corner margins map to keys.
        let bottom = kb.bounds.maxY - 1
        kb.track(.began, id: 5, at: CGPoint(x: try at("space").x, y: bottom))
        kb.track(.ended, id: 5, at: CGPoint(x: try at("space").x, y: bottom))
        kb.track(.began, id: 6, at: CGPoint(x: kb.bounds.maxX - 1, y: bottom))
        kb.track(.ended, id: 6, at: CGPoint(x: kb.bounds.maxX - 1, y: bottom))
        XCTAssertEqual(spy.calls.last, " ")
        XCTAssertEqual(sent, [TerminalKeyboard.newlineBytes], "the corner maps to return")
        kb.track(.began, id: 7, at: try at(","))
        XCTAssertEqual(kb.previewText, ",")
        kb.track(.ended, id: 7, at: try at(","))
        kb.track(.began, id: 8, at: try at("?"))
        kb.track(.ended, id: 8, at: try at("?"))
        kb.track(.began, id: 10, at: try at("/"))
        kb.track(.ended, id: 10, at: try at("/"))
        XCTAssertEqual(spy.calls.suffix(3), [",", "?", "/"])

        kb.track(.began, id: 12, at: try at("."))
        kb.track(.ended, id: 12, at: try at("."))
        XCTAssertEqual(spy.calls.last, ".")

        for label in ["shift", "delete", "space", "new line"] {
            kb.track(.began, id: 9, at: try at(label))
            XCTAssertNil(kb.previewText, "\(label) shows no preview")
            XCTAssertTrue(try XCTUnwrap(caps[label]).isHighlighted, "\(label) looks pressed")
            kb.track(.ended, id: 9, at: try at(label))
        }
    }

    func testShiftDoesNotCapitalizeThePunctuationKeys() {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        kb.press(.shift)
        kb.press(.char(","))
        kb.press(.char("a"))
        XCTAssertEqual(spy.calls, [",", "A"], "punctuation doesn't spend the one-shot shift")
    }

    // MARK: Shift

    func testShiftStateMachine() {
        var s = ShiftState()
        s.tap(at: 0)
        XCTAssertEqual(s.mode, .once)
        s.typedLetter()
        XCTAssertEqual(s.mode, .off, "one-shot must clear after a letter")

        s.tap(at: 10)
        s.tap(at: 10.2)
        XCTAssertEqual(s.mode, .locked, "double tap within the window locks caps")
        s.typedLetter()
        XCTAssertEqual(s.mode, .locked, "caps lock survives a letter")
        s.tap(at: 11)
        XCTAssertEqual(s.mode, .off, "tap turns caps lock off")

        s.tap(at: 20)
        s.tap(at: 20.5)
        XCTAssertEqual(s.mode, .off, "a slow second tap is just off, not caps lock")
    }

    // MARK: Routing

    func testKeysReachTheTextInput() {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        var sent: [[UInt8]] = []
        kb.sendBytes = { sent.append($0) }
        kb.press(.char("h"))
        kb.press(.shift)
        kb.press(.char("i"))
        kb.press(.char("x"))            // one-shot spent
        kb.press(.space)
        kb.press(.ret)
        kb.press(.backspace)
        kb.press(.shift); kb.press(.shift)   // quick double tap → caps lock
        kb.press(.char("a")); kb.press(.char("b"))
        kb.press(.char("|"))
        XCTAssertEqual(spy.calls, ["h", "I", "x", " ", "⌫", "A", "B", "|"], "return types no text")
        XCTAssertEqual(sent, [[0x1b, 0x0d]], "return is meta-enter, a newline that doesn't submit")
    }

    func testCapsCarryAccessibility() throws {
        let kb = TerminalKeyboard()
        let caps = kb.subviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(caps.count, TerminalKeyboard.rows.joined().count)
        for cap in caps {
            XCTAssertFalse(cap.accessibilityLabel?.isEmpty ?? true)
            XCTAssertTrue(cap.accessibilityTraits.contains(.keyboardKey))
        }
        // VoiceOver can't hold: a hinted cap offers its symbol as an action.
        let spy = SpyInput()
        kb.target = spy
        let a = try XCTUnwrap(caps.first { $0.accessibilityLabel == "a" })
        let action = try XCTUnwrap(a.accessibilityCustomActions?.first)
        XCTAssertEqual(action.name, "@")
        _ = action.actionHandler?(action)
        XCTAssertEqual(spy.calls, ["@"])
    }

    /// Touches from one event tie on timestamp; the order must not depend on how the Set
    /// happens to iterate, or a two-thumb rollover can swap letters.
    func testSameEventTouchesHaveAStableOrder() {
        let touches: [(id: Int, timestamp: TimeInterval)] = [(7, 1), (3, 1), (9, 0.5), (5, 1)]
        XCTAssertEqual(TerminalKeyboard.inputOrder(touches), [9, 3, 5, 7])
        XCTAssertEqual(TerminalKeyboard.inputOrder(touches.reversed()), [9, 3, 5, 7])
    }

    // MARK: Hookup

    private var savedProbe: (() -> Bool)!
    override func setUp() {
        super.setUp()
        savedProbe = TerminalKeyboard.hardwareKeyboardConnected
        TerminalKeyboard.hardwareKeyboardConnected = { false }
    }
    override func tearDown() {
        TerminalKeyboard.hardwareKeyboardConnected = savedProbe
        super.tearDown()
    }

    /// iPhone simulator: the terminal types through the compact keyboard, sized without
    /// the home-indicator inset. On screen, so the keyboard-frame notification the
    /// avoidance path relies on is the real one.
    func testHostInstallsCompactKeyboard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let handle = TermHandle()
        let vc = TerminalHostVC(conn: SessionConnection(transport: SpyTransport(),
                                                       session: DchSession(name: "t", alias: nil)),
                                handle: handle)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        XCTAssertTrue(vc.keyboardInputView is TerminalKeyboard)

        let frame = expectation(forNotification: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        var end = CGRect.null
        let token = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: nil) { n in
            end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .null
        }
        defer { NotificationCenter.default.removeObserver(token) }
        vc.toggleKeyboard()
        wait(for: [frame], timeout: 3)
        XCTAssertTrue(handle.keyboardShown, "the custom inputView must drive the same avoidance path")
        XCTAssertEqual(end.height, TerminalKeyboard.height, accuracy: 1)
        XCTAssertLessThan(end.height, TerminalKeyboard.keysHeight + window.safeAreaInsets.bottom,
                          "the home-indicator inset is not reserved under the keys")
        XCTAssertEqual(end.maxY, window.bounds.maxY, accuracy: 1)
        print("compact keyboard frame: \(end) window: \(window.bounds.size) safe bottom: \(window.safeAreaInsets.bottom)")

        vc.toggleKeyboard()   // dismiss
        XCTAssertTrue(vc.keyboardInputView is TerminalKeyboard)
    }

    /// The input host takes the keyboard's height once, at install, unless that height is
    /// required, and rotation's frame notifications carry a height taken mid-transition:
    /// the view, and the shortcut bar on top of it, must still follow. A pad change while
    /// it's up, rotating there and back, and the keyboard first rising in landscape.
    func testHostedKeyboardFollowsItsHeight() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        guard #available(iOS 16, *) else { throw XCTSkip("requestGeometryUpdate is iOS 16") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let vc = TerminalHostVC(conn: SessionConnection(transport: SpyTransport(),
                                                       session: DchSession(name: "t", alias: nil)),
                                handle: TermHandle())
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let kb = try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard)
        let bar = try XCTUnwrap(vc.view.subviews.first { $0 is ShortcutBar })
        let screen = scene.screen.coordinateSpace
        func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func rotate(_ o: UIInterfaceOrientationMask) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: o)) { XCTFail("rotation: \($0)") }
            spin(1.5)
        }
        /// Waits for the keyboard to settle at `height`, then checks it and the bar on it.
        func expect(_ height: CGFloat, _ what: String, line: UInt = #line) {
            func top() -> CGFloat { kb.convert(kb.bounds, to: screen).minY }
            func barBottom() -> CGFloat { bar.convert(bar.bounds, to: screen).maxY }
            let settled = Date().addingTimeInterval(2)
            while kb.frame.height != height || abs(barBottom() - top()) > 0.5, Date() < settled { spin(0.05) }
            XCTAssertEqual(kb.frame.height, height, "\(what): the keyboard", line: line)
            XCTAssertEqual(barBottom(), top(), accuracy: 0.5, "\(what): the bar on the keyboard", line: line)
            XCTAssertEqual(kb.convert(kb.bounds, to: screen).maxY, screen.bounds.maxY, accuracy: 0.5,
                           "\(what): the keyboard at the bottom", line: line)
        }
        let portrait = TerminalKeyboard.height
        let landscape = TerminalKeyboard.keysHeight(compact: true) + TerminalKeyboard.bottomPadding
        defer { rotate(.portrait) }

        vc.toggleKeyboard()
        expect(portrait, "shown")
        spin(0.5)   // a reload while the keyboard still rises is dropped
        kb.bottomInset = 6
        expect(TerminalKeyboard.keysHeight + 6, "pad change")
        kb.bottomInset = TerminalKeyboard.bottomPadding
        expect(portrait, "pad back")
        rotate(.landscapeRight)
        expect(landscape, "to landscape")
        rotate(.portrait)
        expect(portrait, "back to portrait")

        vc.toggleKeyboard()   // dismiss, turn, and rise in landscape
        rotate(.landscapeRight)
        vc.toggleKeyboard()
        expect(landscape, "first shown in landscape")
        vc.toggleKeyboard()
        spin(0.5)
    }

}
