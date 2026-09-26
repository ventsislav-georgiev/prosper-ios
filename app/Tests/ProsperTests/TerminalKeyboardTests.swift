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

    func testEveryPrintableAsciiIsReachableExactlyOnce() {
        let letters = chars(.letters)
        let symbols = chars(.numbers) + chars(.symbols)
        XCTAssertEqual(Set(symbols).count, symbols.count, "a symbol appears on both pages or twice on one")
        XCTAssertEqual(Set(letters).count, letters.count)
        XCTAssertEqual(Set(letters), Set("abcdefghijklmnopqrstuvwxyz".map(String.init)))
        // Letters reach uppercase through shift.
        let reachable = Set(letters + letters.map { $0.uppercased() } + symbols)
        let printable = Set((0x21...0x7E).map { String(UnicodeScalar(UInt8($0))) })
        XCTAssertEqual(reachable, printable, "missing \(printable.subtracting(reachable).sorted())")
        XCTAssertTrue(Set("0123456789".map(String.init)).isSubset(of: Set(symbols)))
    }

    func testShellSymbolsAreOnTheFirstSymbolsPage() {
        let first = Set(chars(.numbers))
        for c in "-/|~_$\\'\".,&*><;" { XCTAssertTrue(first.contains(String(c)), "\(c) not on the 123 page") }
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

    func testNoSystemKeyboardKeySpaceFillsTheBottomRow() {
        for page in [TerminalKeyboard.Page.letters, .numbers, .symbols] {
            let bottom = TerminalKeyboard.rows(for: page).last!
            XCTAssertEqual(bottom.count, 3, "bottom row is page · space · return, got \(bottom)")
            XCTAssertEqual(Array(bottom.dropFirst()), [.space, .ret])
        }
    }

    /// The home-indicator inset is no longer reserved under the keys: only a small pad.
    func testHeightDropsTheBottomSafeAreaInset() {
        XCTAssertEqual(TerminalKeyboard.height, TerminalKeyboard.keysHeight + TerminalKeyboard.bottomPadding)
        XCTAssertLessThan(TerminalKeyboard.bottomPadding, 12)
        XCTAssertEqual(TerminalKeyboard().frame.height, TerminalKeyboard.height)
    }

    // MARK: Press preview

    private func laidOut() -> (TerminalKeyboard, [String: UIButton]) {
        let kb = TerminalKeyboard()
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews {
            caps[b.title(for: .normal) ?? b.accessibilityLabel ?? ""] = b
        }
        return (kb, caps)
    }

    func testPreviewFollowsTheTouchOfCharacterKeysOnly() throws {
        let (kb, caps) = laidOut()
        let spy = SpyInput()
        kb.target = spy
        let q = try XCTUnwrap(caps["q"]), w = try XCTUnwrap(caps["w"]), p = try XCTUnwrap(caps["p"])

        q.sendActions(for: .touchDown)
        XCTAssertEqual(kb.previewText, "q")
        let qf = try XCTUnwrap(kb.previewFrame)
        XCTAssertLessThan(qf.minY, 0, "a top-row bubble rises above the keyboard")
        XCTAssertGreaterThanOrEqual(qf.minX, 0, "edge key keeps its bubble on screen")
        q.sendActions(for: .touchUpInside)
        XCTAssertNil(kb.previewText)
        XCTAssertEqual(spy.calls, ["q"])

        p.sendActions(for: .touchDown)
        XCTAssertLessThanOrEqual(try XCTUnwrap(kb.previewFrame).maxX, 402)
        p.sendActions(for: .touchCancel)
        XCTAssertNil(kb.previewText, "cancel must not leave the bubble stuck")

        q.sendActions(for: .touchDown)
        q.sendActions(for: .touchDragExit)
        XCTAssertNil(kb.previewText, "sliding off hides it")
        q.sendActions(for: .touchUpOutside)

        // Rolled typing: the first key's release keeps the second key's bubble.
        q.sendActions(for: .touchDown)
        w.sendActions(for: .touchDown)
        q.sendActions(for: .touchUpInside)
        XCTAssertEqual(kb.previewText, "w")
        w.sendActions(for: .touchUpInside)
        XCTAssertNil(kb.previewText)

        for label in ["shift", "delete", "space", "return", "123"] {
            let cap = try XCTUnwrap(caps[label], label)
            cap.sendActions(for: .touchDown)
            XCTAssertNil(kb.previewText, "\(label) shows no preview")
            cap.sendActions(for: .touchUpInside)
        }
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
