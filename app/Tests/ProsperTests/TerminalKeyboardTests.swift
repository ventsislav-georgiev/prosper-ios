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

    private func chars(_ page: TerminalKeyboard.Page) -> [String] {
        TerminalKeyboard.rows(for: page).joined().compactMap {
            if case .char(let c) = $0 { return c } else { return nil }
        }
    }

    // MARK: Layout coverage

    private func chars(_ keys: [TerminalKeyboard.Key]) -> [String] {
        keys.compactMap { if case .char(let c) = $0 { return c } else { return nil } }
    }

    /// The shared bottom row counts once; every other key on every page counts as is, so a
    /// character on two pages, or twice on one, fails as surely as a missing one.
    func testEveryPrintableAsciiIsReachableExactlyOnce() {
        let pages: [TerminalKeyboard.Page] = [.letters, .numbers, .symbols]
        let shared = chars(TerminalKeyboard.rows(for: .letters).last!)
        XCTAssertEqual(shared, [",", "/", "?"])
        let upper = pages.flatMap { chars(Array(TerminalKeyboard.rows(for: $0).dropLast().joined())) }
        let all = upper + shared
        let dupes = Dictionary(grouping: all, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(dupes, [], "reachable more than once")
        let letters = chars(.letters).filter { $0.first!.isLetter }
        XCTAssertEqual(Set(letters), Set("abcdefghijklmnopqrstuvwxyz".map(String.init)))
        // Letters reach uppercase through shift.
        let reachable = all + letters.map { $0.uppercased() }
        let printable = (0x21...0x7E).map { String(UnicodeScalar(UInt8($0))) }
        XCTAssertEqual(reachable.sorted(), printable.sorted(),
                       "missing \(Set(printable).subtracting(reachable).sorted())")
        XCTAssertEqual(chars(Array(TerminalKeyboard.rows(for: .numbers).dropLast().joined())).count, 27)
        XCTAssertEqual(chars(Array(TerminalKeyboard.rows(for: .symbols).dropLast().joined())).count, 12)
    }

    func testSymbolPageRows() {
        typealias K = TerminalKeyboard
        func row(_ page: K.Page, _ i: Int) -> [String] { chars(K.rows(for: page)[i]) }
        XCTAssertEqual(row(.numbers, 0), "1234567890".map(String.init))
        XCTAssertEqual(row(.numbers, 1), ["-", "#", "(", ")", "_", "$", "=", "'", "\"", "&"])
        XCTAssertEqual(K.rows(for: .numbers)[2],
                       [.page(.symbols)] + ".@*`+;:".map { .char(String($0)) } + [.backspace])
        XCTAssertEqual(row(.symbols, 0), ["[", "]", "{", "}", "|", "<", ">", "%", "^", "~"])
        XCTAssertEqual(row(.symbols, 1), ["!", "\\"])
        XCTAssertEqual(K.rows(for: .symbols)[2], [.page(.numbers), .backspace])
    }

    func testCommonSymbolsAreOnTheFirstSymbolsPage() {
        let first = Set(chars(.numbers))
        for c in "-#()_$='\"&.@*`+;:" { XCTAssertTrue(first.contains(String(c)), "\(c) not on the 123 page") }
    }

    func testRowsFitTheWidth() {
        for page in [TerminalKeyboard.Page.letters, .numbers, .symbols] {
            for row in TerminalKeyboard.rows(for: page) {
                let slots = TerminalKeyboard.place(row, width: 396)
                XCTAssertEqual(slots.count, row.count)
                XCTAssertGreaterThanOrEqual(slots.first!.x, -0.001)
                XCTAssertLessThanOrEqual(slots.last!.x + slots.last!.w, 396.001)
                for (a, b) in zip(slots, slots.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b.x - (a.x + a.w), TerminalKeyboard.keyGap - 0.001, "keys overlap in \(row)")
                }
            }
        }
    }

    func testARowFillsTheWidth() {
        let row = TerminalKeyboard.rows(for: .letters)[1]
        XCTAssertEqual(row.count, 9)
        let slots = TerminalKeyboard.place(row, width: 393)
        XCTAssertEqual(slots.first!.x, 0, accuracy: 0.001)
        XCTAssertEqual(slots.last!.x + slots.last!.w, 393, accuracy: 0.001)
        let top = TerminalKeyboard.place(TerminalKeyboard.rows(for: .letters)[0], width: 393)
        XCTAssertGreaterThan(slots[0].w, top[0].w, "nine keys in the width of ten are wider")
        // Short character rows stay one unit wide, centered.
        let short = TerminalKeyboard.place(TerminalKeyboard.rows(for: .symbols)[1], width: 393)
        XCTAssertEqual(short.count, 2)
        XCTAssertEqual(short[0].w, top[0].w, accuracy: 0.001)
        XCTAssertEqual(short[1].w, top[0].w, accuracy: 0.001)
        XCTAssertEqual(short[0].x, 393 - (short[1].x + short[1].w), accuracy: 0.001)
    }

    func testBottomRowIsSharedByEveryPage() {
        let pages: [(TerminalKeyboard.Page, TerminalKeyboard.Page)] =
            [(.letters, .numbers), (.numbers, .letters), (.symbols, .letters)]
        for (page, other) in pages {
            XCTAssertEqual(TerminalKeyboard.rows(for: page).last!,
                           [.page(other), .char(","), .char("/"), .space, .char("?"), .ret], "\(page)")
        }
    }

    /// The home-indicator inset is not reserved under the keys, only a pad that keeps
    /// the space bar off the bottom edge.
    func testHeight() {
        XCTAssertEqual(TerminalKeyboard.height, TerminalKeyboard.keysHeight + TerminalKeyboard.bottomPadding)
        XCTAssertEqual(TerminalKeyboard.height, 206)
        XCTAssertTrue((14...16).contains(TerminalKeyboard.bottomPadding))
        XCTAssertEqual(TerminalKeyboard().frame.height, TerminalKeyboard.height)
    }

    func testBottomRowClearsTheCornersAndSpaceStaysWide() throws {
        for width in [393, 402] as [CGFloat] {
            let (kb, _) = laidOut(width: width)
            for page in [TerminalKeyboard.Page.letters, .numbers, .symbols] {
                kb.press(.page(page))
                kb.layoutIfNeeded()
                let caps = Dictionary(kb.subviews.compactMap { $0 as? UIButton }
                    .map { ($0.title(for: .normal) ?? $0.accessibilityLabel ?? "", $0) }) { a, _ in a }
                let space = try XCTUnwrap(caps["space"]), ret = try XCTUnwrap(caps["return"])
                let pageKey = try XCTUnwrap(caps[page == .letters ? "123" : "ABC"])
                XCTAssertGreaterThanOrEqual(space.frame.width, 110, "\(page) at \(width)")
                XCTAssertEqual(pageKey.frame.minX, TerminalKeyboard.bottomRowInset, accuracy: 0.001)
                XCTAssertEqual(ret.frame.maxX, width - TerminalKeyboard.bottomRowInset, accuracy: 0.001)
                XCTAssertEqual(space.frame.maxY, TerminalKeyboard.height - TerminalKeyboard.bottomPadding,
                               accuracy: 0.001)
            }
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
        _ = t.began(4, .page(.numbers))
        XCTAssertEqual(presses(t.cancelled(4)), [], "a cancel doesn't flip the page")
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
        func at(_ label: String) throws -> CGPoint {
            let f = try XCTUnwrap(caps[label], label).frame
            return CGPoint(x: f.midX, y: f.midY)
        }
        let q = try XCTUnwrap(caps["q"]), w = try XCTUnwrap(caps["w"])

        kb.track(.began, id: 1, at: try at("q"))
        XCTAssertEqual(kb.previewText, "q")
        XCTAssertTrue(q.isHighlighted)
        let qf = try XCTUnwrap(kb.previewFrame)
        XCTAssertLessThan(qf.minY, 0, "a top-row bubble rises above the keyboard")
        XCTAssertGreaterThanOrEqual(qf.minX, 0, "edge key keeps its bubble on screen")
        kb.track(.moved, id: 1, at: try at("w"))
        XCTAssertEqual(kb.previewText, "w", "the preview follows the finger")
        XCTAssertFalse(q.isHighlighted)
        XCTAssertTrue(w.isHighlighted)
        kb.track(.ended, id: 1, at: try at("w"))
        XCTAssertNil(kb.previewText)
        XCTAssertFalse(w.isHighlighted)
        XCTAssertEqual(spy.calls, ["w"])

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
        XCTAssertEqual(spy.calls.suffix(2), [" ", "\n"])
        kb.track(.began, id: 7, at: try at(","))
        XCTAssertEqual(kb.previewText, ",")
        kb.track(.ended, id: 7, at: try at(","))
        kb.track(.began, id: 8, at: try at("?"))
        kb.track(.ended, id: 8, at: try at("?"))
        kb.track(.began, id: 10, at: try at("/"))
        kb.track(.ended, id: 10, at: try at("/"))
        XCTAssertEqual(spy.calls.suffix(3), [",", "?", "/"])

        for label in ["shift", "delete", "space", "return", "123"] {
            kb.track(.began, id: 9, at: try at(label))
            XCTAssertNil(kb.previewText, "\(label) shows no preview")
            XCTAssertTrue(try XCTUnwrap(caps[label]).isHighlighted, "\(label) looks pressed")
            kb.track(.ended, id: 9, at: try at(label))
        }
        XCTAssertEqual(kb.page, .numbers, "page keys switch on lift")
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
        kb.press(.char("h"))
        kb.press(.shift)
        kb.press(.char("i"))
        kb.press(.char("x"))            // one-shot spent
        kb.press(.space)
        kb.press(.ret)
        kb.press(.backspace)
        kb.press(.shift); kb.press(.shift)   // quick double tap → caps lock
        kb.press(.char("a")); kb.press(.char("b"))
        kb.press(.page(.numbers))
        kb.press(.char("|"))
        XCTAssertEqual(spy.calls, ["h", "I", "x", " ", "\n", "⌫", "A", "B", "|"])
        XCTAssertEqual(kb.page, .numbers)
    }

    func testCapsCarryAccessibility() {
        let kb = TerminalKeyboard()
        let caps = kb.subviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(caps.count, TerminalKeyboard.rows(for: .letters).joined().count)
        for cap in caps {
            XCTAssertFalse(cap.accessibilityLabel?.isEmpty ?? true)
            XCTAssertTrue(cap.accessibilityTraits.contains(.keyboardKey))
        }
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
    /// the home-indicator inset, and defers the bottom edge gesture while it is up. On
    /// screen, so the keyboard-frame notification the avoidance path relies on is the
    /// real one.
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
        XCTAssertEqual(vc.preferredScreenEdgesDeferringSystemGestures, [], "no deferral with the keyboard down")

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
        XCTAssertEqual(vc.preferredScreenEdgesDeferringSystemGestures, .bottom)

        vc.toggleKeyboard()   // dismiss
        XCTAssertEqual(vc.preferredScreenEdgesDeferringSystemGestures, [])
        XCTAssertTrue(vc.keyboardInputView is TerminalKeyboard)
    }
}
