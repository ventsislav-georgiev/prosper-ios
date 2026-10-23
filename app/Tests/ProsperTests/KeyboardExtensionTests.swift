import XCTest
import UIKit
@testable import Prosper

/// The compact keyboard as the system keyboard extension sees it: no `sendBytes`, a
/// host field's `UITextDocumentProxy` as the target, a globe key, a smaller bottom pad.
/// The extension's controller only wires these up, so the logic is tested here.
@MainActor
final class KeyboardExtensionTests: XCTestCase {

    /// A host text field as the extension sees it: the text before the cursor, and the
    /// field's traits. SuggestionsTests uses it too.
    final class FakeProxy: NSObject, UITextDocumentProxy {
        var text = ""
        var calls: [String] = []
        var autocapitalizationType: UITextAutocapitalizationType = .sentences
        var keyboardType: UIKeyboardType = .default
        var autocorrectionType: UITextAutocorrectionType = .default
        var spellCheckingType: UITextSpellCheckingType = .default
        var textContentType: UITextContentType! = nil
        var isSecureTextEntry = false
        var documentContextBeforeInput: String? { text }
        var after: String?
        var documentContextAfterInput: String? { after }
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        var documentIdentifier: UUID { UUID() }
        var hasText: Bool { !text.isEmpty }
        func insertText(_ s: String) { text += s; calls.append(s) }
        func deleteBackward() { _ = text.popLast(); calls.append("⌫") }
        /// Every caret move, as asked; the caret moves within `text` + `after`.
        var moves: [Int] = []
        func adjustTextPosition(byCharacterOffset offset: Int) {
            moves.append(offset)
            let all = text + (after ?? ""), at = min(max(text.count + offset, 0), all.count)
            text = String(all.prefix(at))
            after = String(all.dropFirst(at))
        }
        func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
        func unmarkText() {}
    }

    private final class SpyInput: NSObject, UIKeyInput {
        var calls: [String] = []
        var hasText: Bool { true }
        func insertText(_ text: String) { calls.append(text) }
        func deleteBackward() { calls.append("⌫") }
    }

    private func laidOut(_ kb: TerminalKeyboard = TerminalKeyboard(), width: CGFloat = 402) -> [String: UIButton] {
        kb.frame = CGRect(x: 0, y: 0, width: width, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews { caps[b.accessibilityLabel ?? ""] = b }
        return caps
    }

    // MARK: Return

    func testReturnTypesANewlineWithoutSendBytes() {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        kb.press(.ret)
        XCTAssertEqual(spy.calls, ["\n"], "the extension's return is a real newline")
        var sent: [[UInt8]] = []
        kb.sendBytes = { sent.append($0) }
        kb.press(.ret)
        XCTAssertEqual(spy.calls, ["\n"], "the app's return types no text")
        XCTAssertEqual(sent, [TerminalKeyboard.newlineBytes])
    }

    func testReturnIsTitledByTheFieldsReturnKey() throws {
        let expected: [(UIReturnKeyType, String?)] = [
            (.default, nil), (.go, "go"), (.google, "search"), (.yahoo, "search"), (.search, "search"),
            (.join, "join"), (.next, "next"), (.route, "route"), (.send, "send"), (.done, "done"),
            (.emergencyCall, "emergency"), (.continue, "continue"),
        ]
        for (type, title) in expected {
            XCTAssertEqual(TerminalKeyboard.returnTitle(for: type), title, "\(type.rawValue)")
        }
        let kb = TerminalKeyboard()
        kb.returnTitle = "send"
        var caps = laidOut(kb)
        let send = try XCTUnwrap(caps["send"], "the label follows the title")
        XCTAssertEqual(send.title(for: .normal), "send")
        XCTAssertNil(send.image(for: .normal))
        XCTAssertNil(caps["new line"])
        kb.returnTitle = nil
        caps = laidOut(kb)
        XCTAssertNotNil(try XCTUnwrap(caps["new line"]).image(for: .normal), "nil keeps the arrow")
    }

    // MARK: Globe

    func testGlobeOnlyWhenAskedAndTheBottomRowFits() throws {
        XCTAssertNil(laidOut()["next keyboard"], "the app never shows it")
        for width in [375, 430] as [CGFloat] {
            let kb = TerminalKeyboard()
            kb.showsGlobe = true
            let caps = laidOut(kb, width: width)
            let globe = try XCTUnwrap(caps["next keyboard"], "at \(width)")
            XCTAssertTrue(globe.isUserInteractionEnabled, "it takes its own touches")
            XCTAssertEqual(globe.actions(forTarget: nil, forControlEvent: .touchDown),
                           ["handleInputModeListFromView:withEvent:"])
            let row = kb.subviews.compactMap { $0 as? UIButton }
                .filter { $0.frame.midY == globe.frame.midY }.sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(row.map { $0.accessibilityLabel ?? "" },
                           ["next keyboard", ".", ",", "/", "space", "?", "new line"], "at \(width)")
            XCTAssertGreaterThanOrEqual(row.first!.frame.minX, 0)
            XCTAssertLessThanOrEqual(row.last!.frame.maxX, width)
            for (a, b) in zip(row, row.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.frame.minX - a.frame.maxX, TerminalKeyboard.keyGap - 0.001,
                                            "\(a.accessibilityLabel!) overlaps \(b.accessibilityLabel!) at \(width)")
            }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(caps["space"]).frame.width, 80, "space stays wide at \(width)")
            // A touch in the gap beside the globe goes to the next key over, never to the globe.
            let spy = SpyInput()
            kb.target = spy
            let p = CGPoint(x: globe.frame.maxX + 2, y: globe.frame.midY)   // nearer the globe than .
            kb.track(.began, id: 1, at: p)
            kb.track(.ended, id: 1, at: p)
            XCTAssertEqual(spy.calls, ["."], "at \(width)")
        }
    }

    // MARK: Hit-testing

    /// Where real hit-testing puts a touch on each cap: the tracker must get the keys'
    /// (UIKit's content views sit inside a UIInputView), never the globe's.
    private func assertKeysFeed(_ kb: TerminalKeyboard, _ context: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews { caps[b.accessibilityLabel ?? ""] = b }
        for label in ["q", "h", "l", "space", "1"] {
            let cap = try XCTUnwrap(caps[label] ?? caps[label.uppercased()], "\(label) in \(context)", file: file, line: line)
            XCTAssertTrue(TerminalKeyboard.feeds(kb.hitTest(CGPoint(x: cap.frame.midX, y: cap.frame.midY), with: nil)),
                          "\(label) in \(context)", file: file, line: line)
        }
        if let globe = caps["next keyboard"] {
            XCTAssertFalse(TerminalKeyboard.feeds(kb.hitTest(CGPoint(x: globe.frame.midX, y: globe.frame.midY), with: nil)),
                           "globe in \(context)", file: file, line: line)
        }
    }

    func testKeyTouchesReachTheTrackerInTheApp() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        let saved = TerminalKeyboard.hardwareKeyboardConnected   // a simulator reports one
        TerminalKeyboard.hardwareKeyboardConnected = { false }
        defer { TerminalKeyboard.hardwareKeyboardConnected = saved }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let vc = TerminalHostVC(conn: SessionConnection(transport: SpyTransport(),
                                                       session: DchSession(name: "t", alias: nil)),
                                handle: TermHandle())
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let frame = expectation(forNotification: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        vc.toggleKeyboard()
        wait(for: [frame], timeout: 3)
        defer { vc.toggleKeyboard() }
        try assertKeysFeed(try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard), "the app")
    }

    func testKeyTouchesReachTheTrackerInTheExtension() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let ivc = UIInputViewController()
        let kb = TerminalKeyboard()
        kb.showsGlobe = true
        kb.translatesAutoresizingMaskIntoConstraints = false
        ivc.view.addSubview(kb)
        NSLayoutConstraint.activate([
            kb.topAnchor.constraint(equalTo: ivc.view.topAnchor),
            kb.leadingAnchor.constraint(equalTo: ivc.view.leadingAnchor),
            kb.trailingAnchor.constraint(equalTo: ivc.view.trailingAnchor),
            kb.bottomAnchor.constraint(equalTo: ivc.view.bottomAnchor),
        ])
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 254)
        window.rootViewController = ivc
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        var labels = Set<String>()
        for case let b as UIButton in kb.subviews { labels.insert(b.accessibilityLabel ?? "") }
        XCTAssertTrue(labels.contains("next keyboard"), "the globe is checked")
        try assertKeysFeed(kb, "the extension")
    }

    // MARK: Bottom pad

    func testBottomInsetSetsTheHeight() throws {
        let kb = TerminalKeyboard()
        let height = try XCTUnwrap(kb.constraints.first { $0.firstItem === kb && $0.firstAttribute == .height })
        XCTAssertEqual(height.constant, TerminalKeyboard.height, "the app keeps its home-gesture pad")
        kb.bottomInset = 6
        XCTAssertEqual(height.constant, TerminalKeyboard.keysHeight + 6)
    }

    // MARK: Auto-capitalization

    func testShouldCapitalize() {
        let cap = TerminalKeyboard.shouldCapitalize
        XCTAssertTrue(cap(nil, .sentences), "start of the field")
        XCTAssertTrue(cap("", .sentences))
        XCTAssertTrue(cap("Hi. ", .sentences))
        XCTAssertTrue(cap("Really?  ", .sentences))
        XCTAssertTrue(cap("Go! ", .sentences))
        XCTAssertTrue(cap("line\n", .sentences))
        XCTAssertTrue(cap("He said \"hi.\" ", .sentences), "after a closing quote")
        XCTAssertTrue(cap("(done.) ", .sentences), "after a closing bracket")
        XCTAssertTrue(cap("“OK?” ", .sentences))
        XCTAssertFalse(cap("(hi) ", .sentences), "a bracket alone ends nothing")
        XCTAssertTrue(cap("  ", .sentences), "only spaces before it")
        XCTAssertFalse(cap("Hi.", .sentences), "not before the space")
        XCTAssertFalse(cap("Hello wor", .sentences), "mid-word")
        XCTAssertFalse(cap("Hello ", .sentences), "mid-sentence")
        XCTAssertFalse(cap("", .none))
        XCTAssertFalse(cap("Hi. ", .none))
        XCTAssertTrue(cap("hello ", .words))
        XCTAssertFalse(cap("hello", .words))
        XCTAssertTrue(cap("ab", .allCharacters))
    }

    func testAutoShiftLeavesCapsLockAlone() {
        var s = ShiftState()
        s.autoShift(true)
        XCTAssertEqual(s.mode, .once)
        s.autoShift(false)
        XCTAssertEqual(s.mode, .off)
        s.tap(at: 0); s.tap(at: 0.1)
        XCTAssertEqual(s.mode, .locked)
        s.autoShift(false)
        XCTAssertEqual(s.mode, .locked)
        s.autoShift(true)
        XCTAssertEqual(s.mode, .locked)
    }

    /// Through the keyboard: a document proxy that asks for sentences gets them; the app's
    /// target, not a proxy, never does.
    func testAutoCapitalizeThroughTheProxy() {
        let kb = TerminalKeyboard()
        let doc = FakeProxy()
        kb.target = doc
        kb.autoCapitalize()
        XCTAssertEqual(kb.shift.mode, .once, "empty field")
        for k in ["h", "i", ".", " ", "y", "o"] { kb.press(k == " " ? .space : .char(k)) }
        XCTAssertEqual(doc.text, "Hi. Yo")
        kb.press(.ret)
        kb.press(.char("a"))
        XCTAssertEqual(doc.text, "Hi. Yo\nA")
        kb.press(.shift); kb.press(.shift)   // caps lock survives mid-sentence
        kb.press(.space)
        kb.press(.char("b"))
        XCTAssertEqual(doc.text, "Hi. Yo\nA B")
        XCTAssertEqual(kb.shift.mode, .locked)

        let none = TerminalKeyboard(), plain = FakeProxy()
        plain.autocapitalizationType = .none
        none.target = plain
        none.autoCapitalize()
        none.press(.char("x"))
        XCTAssertEqual(plain.text, "x")

        let app = TerminalKeyboard(), spy = SpyInput()
        app.target = spy
        app.autoCapitalize()
        app.press(.char("x"))
        XCTAssertEqual(spy.calls, ["x"], "the terminal never auto-capitalizes")
    }

    // MARK: Double-space period

    func testPeriodReplacesSpace() {
        let period = TerminalKeyboard.periodReplacesSpace
        XCTAssertTrue(period("word ", .default), "word, space: the second space is a period")
        XCTAssertTrue(period("Up 5 ", .default), "after a digit")
        XCTAssertTrue(period("word ", .asciiCapable))
        XCTAssertFalse(period("word", .default), "the first space after a word is a space")
        XCTAssertFalse(period("word. ", .default), "a period already there")
        XCTAssertFalse(period("word, ", .default), "nor after other punctuation")
        XCTAssertFalse(period("word  ", .default), "only exactly one space")
        XCTAssertFalse(period(" ", .default))
        XCTAssertFalse(period(nil, .default))
        for type in [UIKeyboardType.URL, .emailAddress, .webSearch, .numberPad, .asciiCapableNumberPad,
                     .decimalPad, .phonePad, .namePhonePad] {
            XCTAssertFalse(period("word ", type), "\(type.rawValue)")
        }
    }

    /// Through the keyboard: with the flag, two spaces after a word give ". " and the next
    /// letter is capitalized; without it (the app's default), two spaces.
    func testDoubleSpacePeriodThroughTheProxy() {
        let kb = TerminalKeyboard()
        let doc = FakeProxy()
        kb.target = doc
        kb.doubleSpacePeriod = true
        for k in ["o", "k"] { kb.press(.char(k)) }
        kb.press(.space); kb.press(.space)
        kb.press(.char("s"))
        XCTAssertEqual(doc.text, "ok. S")
        XCTAssertEqual(doc.calls.suffix(4), [" ", "⌫", ". ", "S"], "through deleteBackward and insertText")
        doc.text = "a@b "; doc.keyboardType = .emailAddress
        kb.press(.space)
        XCTAssertEqual(doc.text, "a@b  ", "not in an email field")

        let off = TerminalKeyboard(), plain = FakeProxy()
        off.target = plain
        plain.text = "ok "
        off.press(.space)
        XCTAssertEqual(plain.text, "ok  ", "the flag is off by default")
    }
}
