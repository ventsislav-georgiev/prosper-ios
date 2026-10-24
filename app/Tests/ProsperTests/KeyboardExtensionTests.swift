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
        var text = "" { didSet { units = nil } }
        var calls: [String] = []
        var autocapitalizationType: UITextAutocapitalizationType = .sentences
        var keyboardType: UIKeyboardType = .default
        var autocorrectionType: UITextAutocorrectionType = .default
        var spellCheckingType: UITextSpellCheckingType = .default
        var textContentType: UITextContentType! = nil
        var isSecureTextEntry = false
        /// Both contexts are nil, as some hosts' fields show none.
        var hidesContext = false
        var documentContextBeforeInput: String? {
            if hidesContext { return nil }
            var u = Array(((guess ?? shown)?.before ?? text).utf16)
            if lineBefore, let i = u.lastIndex(of: 0x0A) { u = i == u.count - 1 ? [0x0A] : Array(u[(i + 1)...]) }
            return String(decoding: u.suffix(window ?? u.count), as: UTF16.self)
        }
        /// The before-context is the caret's line, and only its LF at a line's start, as a
        /// UITextView's is.
        var lineBefore = false
        /// Each context is this many units either side of the caret, sliding with it, as
        /// Safari's is.
        var window: Int?
        var after: String? { didSet { units = nil } }
        var documentContextAfterInput: String? {
            if hidesContext { return nil }
            let a = (guess ?? shown).map(\.after) ?? after
            let cut = stopsAtLineEnd ? a.map { String($0.utf16.prefix { $0 != 0x0A && $0 != 0x0D }) ?? "" } : a
            return window.flatMap { w in cut.map { String(decoding: Array($0.utf16.prefix(w)), as: UTF16.self) } } ?? cut
        }
        /// The after-context stops at the caret line's end, as a host's does.
        var stopsAtLineEnd = false
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        let documentIdentifier = UUID()
        var hasText: Bool { !text.isEmpty }
        func insertText(_ s: String) { text += s; calls.append(s) }
        func deleteBackward() { _ = text.popLast(); calls.append("⌫") }
        /// Every caret move, as asked; the caret moves within `text` + `after`.
        var moves: [Int] = []
        /// Where each move left the caret, in UTF-16 units from the start.
        var stops: [Int] = []
        /// Moves count UTF-16 units, as UIKit hosts do, not Characters, as WebKit does: they
        /// can stop inside a Character, whose halves then show as U+FFFD.
        var countsUTF16 = false
        /// The context shows each move only after `catchUp()`, or the next after
        /// `showNext()`, as a host's lags.
        var lags = false
        /// The context before each move not shown yet.
        private var unshown: [(before: String, after: String?)] = []
        private var shown: (before: String, after: String?)? { unshown.first }
        /// The text and the caret in units, which a split context can't keep.
        private var units: (all: [UInt16], at: Int)?
        /// Right after each move the context shows it taken as Characters until `answer()`
        /// or `catchUp()`, as UIKit's proxy guesses before the host answers.
        var guesses = false
        private var guess: (before: String, after: String?)?
        func answer() { guess = nil }
        func catchUp() { unshown = []; guess = nil }
        func showNext() { if !unshown.isEmpty { unshown.removeFirst() } }
        func adjustTextPosition(byCharacterOffset offset: Int) {
            moves.append(offset)
            if lags { unshown.append((text, after)) }
            if guesses {
                let all = text + (after ?? ""), at = min(max(text.count + offset, 0), all.count)
                guess = (String(all.prefix(at)), String(all.dropFirst(at)))
            }
            if countsUTF16 {
                let u = units ?? (Array((text + (after ?? "")).utf16), text.utf16.count)
                let at = min(max(u.at + offset, 0), u.all.count)
                text = String(decoding: u.all[..<at], as: UTF16.self)
                after = String(decoding: u.all[at...], as: UTF16.self)
                units = (u.all, at)
            } else {
                // WebKit ignores a move past either end of its text.
                let all = text + (after ?? ""), to = text.count + offset, at = (0...all.count).contains(to) ? to : text.count
                text = String(all.prefix(at))
                after = String(all.dropFirst(at))
            }
            stops.append(text.utf16.count)
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
        kb.settings.autoCapitalization = true
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
        none.settings.autoCapitalization = true
        none.autoCapitalize()
        none.press(.char("x"))
        XCTAssertEqual(plain.text, "x")

        let app = TerminalKeyboard(), spy = SpyInput()
        app.target = spy
        app.autoCapitalize()
        app.press(.char("x"))
        XCTAssertEqual(spy.calls, ["x"], "the terminal never auto-capitalizes")
    }

    /// Auto-Capitalization: off (the default), a sentences field types lowercase.
    func testAutoCapitalizationSwitch() {
        for on in [true, false] {
            let kb = TerminalKeyboard(), doc = FakeProxy()
            kb.target = doc
            kb.settings.autoCapitalization = on
            kb.autoCapitalize()
            XCTAssertEqual(kb.shift.mode, on ? .once : .off, "empty field")
            for k in ["h", "i", ".", " ", "y"] { kb.press(k == " " ? .space : .char(k)) }
            XCTAssertEqual(doc.text, on ? "Hi. Y" : "hi. y")
        }
        XCTAssertFalse(TerminalKeyboard().settings.autoCapitalization, "off by default")
    }

    /// Enable Caps Lock off: a quick second shift tap turns shift off, as a slow one does.
    func testCapsLockSwitch() {
        for on in [true, false] {
            let kb = TerminalKeyboard()
            kb.settings.capsLock = on
            kb.press(.shift); kb.press(.shift)
            XCTAssertEqual(kb.shift.mode, on ? .locked : .off)
        }
        var s = ShiftState()
        s.tap(at: 0, locks: false); s.tap(at: 0.1, locks: false)
        XCTAssertEqual(s.mode, .off)
        s.tap(at: 1); s.tap(at: 1.1)
        XCTAssertEqual(s.mode, .locked, "the shortcut bar's modifiers still lock")
    }

    // MARK: Keyboard settings

    func testKeyboardSettingsDefaults() {
        let d = KeyboardSettings()
        XCTAssertFalse(d.autoCapitalization)
        XCTAssertTrue(d.autoCorrection)
        XCTAssertTrue(d.capsLock)
        XCTAssertTrue(d.predictiveText)
        XCTAssertTrue(d.characterPreview)
        XCTAssertTrue(d.periodShortcut)
        XCTAssertEqual(KeyboardSettings(nil), d)
        XCTAssertEqual(TerminalKeyboard().settings, d)
        XCTAssertEqual(Suggestions().settings, d)
        XCTAssertEqual(KeyboardSettings.suiteName, "group.eu.illegible.prosperios", "the entitlements' App Group")
    }

    /// What the app wrote is read back; a key it never wrote keeps its default.
    func testKeyboardSettingsReadWhatTheAppWrote() throws {
        let suite = "KeyboardSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KeyboardSettings(defaults), KeyboardSettings(), "nothing written")
        typealias K = KeyboardSettings.Key
        for key in [K.autoCapitalization, K.autoCorrection, K.capsLock, K.predictiveText,
                    K.characterPreview, K.periodShortcut] {
            defaults.set(key == K.autoCapitalization, forKey: key)   // each flipped
        }
        var flipped = KeyboardSettings()
        flipped.autoCapitalization = true
        flipped.autoCorrection = false
        flipped.capsLock = false
        flipped.predictiveText = false
        flipped.characterPreview = false
        flipped.periodShortcut = false
        XCTAssertEqual(KeyboardSettings(defaults), flipped)
        defaults.removeObject(forKey: K.capsLock)
        XCTAssertTrue(KeyboardSettings(defaults).capsLock, "unwritten: the default")
    }

    /// No Full Access, or no suite: the defaults, whatever the app wrote.
    func testKeyboardSettingsFallBackToTheDefaults() throws {
        let saved = KeyboardSettings.store
        defer { KeyboardSettings.store = saved }
        let suite = "KeyboardSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeyboardSettings.Key.autoCapitalization)
        KeyboardSettings.store = { defaults }
        XCTAssertTrue(KeyboardSettings.current().autoCapitalization, "the app's value")
        XCTAssertTrue(KeyboardSettings.current(fullAccess: true).autoCapitalization)
        XCTAssertEqual(KeyboardSettings.current(fullAccess: false), KeyboardSettings(), "no Full Access")
        KeyboardSettings.store = { nil }
        XCTAssertEqual(KeyboardSettings.current(), KeyboardSettings(), "no suite")
    }

    // MARK: AutoFill hop

    /// The sibling hops on a fresh mark from the other Prosper keyboard, in a login field.
    func testHopsOnlyOnAFreshMarkFromTheSibling() {
        let en = "eu.illegible.prosperios.keyboard", bg = "eu.illegible.prosperios.keyboard-bg"
        let now = Date()
        func hops(_ from: String?, ago: TimeInterval = 0.06, login: Bool = true) -> Bool {
            KeyboardSettings.hops(from.map { ($0, now - ago) }, own: bg, now: now, login: login)
        }
        XCTAssertTrue(hops(en), "the sibling's fresh tap")
        XCTAssertTrue(hops(en, ago: 0.45))
        XCTAssertFalse(hops(bg), "its own mark")
        XCTAssertFalse(hops(en, ago: 0.5), "stale")
        XCTAssertFalse(hops(en, ago: 3))
        XCTAssertFalse(hops(en, ago: -1), "from the future")
        XCTAssertFalse(hops(en, login: false), "not a login field")
        XCTAssertFalse(hops(nil), "no mark")
    }

    /// The mark reads back once: reading removes it, so a hop can't loop.
    func testHopMarkIsTakenOnce() throws {
        let saved = KeyboardSettings.store
        defer { KeyboardSettings.store = saved }
        let suite = "KeyboardSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardSettings.store = { defaults }
        XCTAssertNil(KeyboardSettings.takeHop(), "nothing marked")
        let at = Date(timeIntervalSince1970: 1_000)
        KeyboardSettings.markHop(from: "a", at: at)
        let mark = try XCTUnwrap(KeyboardSettings.takeHop())
        XCTAssertEqual(mark.from, "a")
        XCTAssertEqual(mark.at, at)
        XCTAssertNil(KeyboardSettings.takeHop(), "cleared on read")
        KeyboardSettings.store = { nil }
        KeyboardSettings.markHop(from: "a")
        XCTAssertNil(KeyboardSettings.takeHop(), "no suite: nothing")
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
        kb.settings.autoCapitalization = true
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

    /// "." Shortcut off: the extension's keyboard types two spaces too.
    func testPeriodShortcutSwitch() {
        for on in [true, false] {
            let kb = TerminalKeyboard(), doc = FakeProxy()
            kb.target = doc
            kb.doubleSpacePeriod = true
            kb.settings.periodShortcut = on
            kb.press(.char("o")); kb.press(.space); kb.press(.space)
            XCTAssertEqual(doc.text, on ? "o. " : "o  ")
        }
    }

    // MARK: Trackpad in a host field

    /// Emoji, a ZWJ family, two flags, a CR LF, a combining accent, a keycap and a heart
    /// with its variation selector, between plain letters.
    private static let mixed = "a😀b👨‍👩‍👧c🇧🇬🇺🇸d\r\ne\u{301}1️⃣❤️f"
    /// QA's texts: two emoji; CR LF line breaks; a family, a flag, a keycap, an accent and a
    /// skin tone; one emoji over and over; and a line long enough for Safari's windows to slide.
    private static let texts = [
        mixed, "ab😀cd😀ef", "abcdef\r\nab\r\nabcdefgh", "a👨‍👩‍👧b🇧🇬c1️⃣de\u{301}f👍🏽g", "😀😀😀😀",
        String(repeating: "ab😀cd😀ef ", count: 30),
    ]

    /// Where the caret may stop in `s`, in UTF-16 units: between two Characters.
    private func boundaries(_ s: String) -> [Int] { s.indices.map { s[..<$0].utf16.count } + [s.utf16.count] }

    /// A UITextView's proxy (`kit`): moves count units, the before-context is the caret's
    /// line, the after-context stops at its end, and right after a move it shows its guess.
    /// Else Safari's: moves count Characters, each context 100 units either side.
    private func host(kit: Bool, _ before: String, _ after: String = "") -> FakeProxy {
        let doc = FakeProxy()
        doc.text = before; doc.after = after
        doc.countsUTF16 = kit; doc.lineBefore = kit; doc.stopsAtLineEnd = kit; doc.guesses = kit
        doc.window = kit ? nil : 100
        return doc
    }

    /// Steps through `walk` as the view sends them: the host catching up after every
    /// `perRefresh` of them (0: its context never lags), then polled until the walk is
    /// idle, the walk settled from the third poll after a move and timing out after 15.
    private func drive(_ walk: inout CaretWalk, _ doc: FakeProxy, _ steps: [Int], perRefresh: Int) {
        var polls = 0
        func step(_ n: Int) {
            let units = walk.step(n, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "",
                                  settled: polls >= 3)
            if units != 0 { doc.adjustTextPosition(byCharacterOffset: units); polls = 0 }
        }
        doc.lags = perRefresh > 0
        for (i, n) in steps.enumerated() {
            step(n)
            if perRefresh > 0, (i + 1) % perRefresh == 0 { doc.catchUp(); step(0) }
        }
        for _ in 0..<200 where !walk.idle {
            doc.catchUp()
            polls += 1
            if polls > 15 { walk.timedOut() }
            step(0)
        }
    }

    func testSplitsSeesEveryWayACharacterCanBeCut() {
        let cuts: [(String, String)] = [
            ("ab\u{FFFD}", "\u{FFFD}cd"), ("\r", "\n"), ("\r", ""), ("e", "\u{301}"), ("❤", "\u{FE0F}"),
            ("1", "\u{FE0F}\u{20E3}"), ("👨\u{200D}", "👩\u{200D}👧"), ("👨\u{200D}👩", "\u{200D}👧"),
        ]
        for (b, a) in cuts { XCTAssertTrue(CaretWalk.splits(before: b, after: a), "\(b.debugDescription) | \(a.debugDescription)") }
        let whole: [(String, String)] = [
            ("ab", "cd"), ("😀", "b"), ("a", "😀"), ("🇧🇬", "🇺🇸"), ("\r\n", "e"), ("d", "\r\n"), ("", "x"), ("x", ""),
            ("👨‍👩‍👧", "c"), ("e\u{301}", "1️⃣"), ("\n", ""),
        ]
        for (b, a) in whole { XCTAssertFalse(CaretWalk.splits(before: b, after: a), "\(b.debugDescription) | \(a.debugDescription)") }
    }

    /// Both hosts, every lag, each of `texts`: drags past either end stop there, and one
    /// step at a time, either way, stops on each Character boundary in turn, none skipped.
    /// A UITextView's caret never stops inside a Character, even before the walk knows the
    /// host, but for a moment between a CR and the LF its line-cut context hides; it's
    /// never taken for a host counting Characters. Safari's is learned and its overshoots
    /// come back.
    func testTheWalkStopsOnlyBetweenCharactersInEitherHost() {
        for text in Self.texts {
            let ends = boundaries(text), n = ends.count - 1, u = Array(text.utf16)
            let crlf = u.indices.dropFirst().filter { u[$0 - 1] == 0x0D && u[$0] == 0x0A }
            for kit in [true, false] {
                for perRefresh in [0, 1, 3, 100] {
                    let at = "\(text.prefix(12).debugDescription) kit \(kit) lag \(perRefresh)"
                    var docs: [FakeProxy] = [], walks: [CaretWalk] = []
                    let doc = host(kit: kit, text)
                    var walk = CaretWalk()
                    drive(&walk, doc, Array(repeating: -1, count: n + 2), perRefresh: perRefresh)
                    XCTAssertEqual(doc.text.utf16.count, 0, at)
                    drive(&walk, doc, Array(repeating: 1, count: n + 2), perRefresh: perRefresh)
                    XCTAssertEqual(doc.text.utf16.count, u.count, at)
                    docs.append(doc); walks.append(walk)
                    for dir in [1, -1] {
                        let doc = dir > 0 ? host(kit: kit, "", text) : host(kit: kit, text)
                        var walk = CaretWalk()
                        for k in 1...n {
                            drive(&walk, doc, [dir], perRefresh: perRefresh)
                            XCTAssertEqual(doc.text.utf16.count, ends[dir > 0 ? k : n - k], "\(at) dir \(dir) step \(k)")
                        }
                        docs.append(doc); walks.append(walk)
                    }
                    for (doc, walk) in zip(docs, walks) {
                        if kit {
                            XCTAssertNotEqual(walk.utf16, false, at)
                            let bad = doc.stops.filter { !ends.contains($0) && !crlf.contains($0) }
                            XCTAssertEqual(bad, [], "\(at): stopped inside a Character")
                        } else {
                            XCTAssertEqual(walk.utf16, false, at)
                        }
                    }
                }
            }
        }
    }

    /// QA's run in 400 x's from the middle, and one of emoji: Safari's windows read the
    /// same after every move, so the walk takes them as landed when it stops waiting, and
    /// an emoji's units, unseen, as WebKit going that many Characters.
    func testALongRunOfOneCharacterLosesNoSteps() {
        for (kit, run) in [true, false].flatMap({ k in ["x", "😀"].map { (k, String(repeating: $0, count: 200)) } }) {
            for perRefresh in [0, 1, 3, 100] {
                let doc = host(kit: kit, run, run)
                var walk = CaretWalk()
                drive(&walk, doc, Array(repeating: -1, count: 5), perRefresh: perRefresh)
                XCTAssertEqual(doc.text.count, 195, "\(run.prefix(1)) kit \(kit) lag \(perRefresh)")
                drive(&walk, doc, Array(repeating: 1, count: 3), perRefresh: perRefresh)
                XCTAssertEqual(doc.text.count, 198, "\(run.prefix(1)) kit \(kit) lag \(perRefresh)")
                drive(&walk, doc, Array(repeating: -1, count: 12), perRefresh: perRefresh)
                XCTAssertEqual(doc.text.count, 186, "\(run.prefix(1)) kit \(kit) lag \(perRefresh)")
            }
        }
    }

    /// Safari's overshoot at either end of the document comes back to where it was asked,
    /// and a move it ignores, past the end, goes again in Characters (QA's test58c). In a
    /// UITextView "right 3" over "a b 😀" lands past the emoji, never inside it (QA's
    /// M220). Left over a CR LF from a line's start, where the context shows only the LF,
    /// finishes the crossing (report-307's bug 2).
    func testOvershootsAndClampsAtTheEnds() {
        let cases: [(String, String, Int, Int, [Int], [Int])] = [
            // before, after, steps, where it ends in units, UITextView's moves, Safari's
            ("", "a😀b", 2, 3, [1, 2], [1, 2, -1]),
            ("a😀b", "", -2, 1, [-1, -2], [-1, -2, 1]),
            ("ab", "😀", 1, 4, [2], [2, 1]),
            ("😀", "cd", -1, 0, [-2], [-2, -1]),
            ("", "ab😀", 3, 4, [1, 1, 2], [1, 1, 2, 1]),
            ("abcdef\r\nab\r\na", "bcdefgh", -2, 10, [-1, -1, -1], [-1, -2, 1]),
            ("x", "😀😀😀y", 3, 7, [2, 4], [2, -1, 2]),
            ("y😀😀😀", "x", -3, 1, [-2, -4], [-2, 1, -2]),
            // Safari's windows slid, nothing after the overshoot: only the before side tells.
            (String(repeating: "x", count: 120), "😀😀", 1, 122, [2], [2, -1]),
            // QA's test58c: before the last of six "ab😀👍🏽" in a fresh field.
            (String(String(repeating: "ab😀👍🏽", count: 6).dropLast()), "👍🏽", 1, 48, [4], [4, 1]),
        ]
        for (before, after, steps, end, kitMoves, webMoves) in cases {
            for kit in [true, false] {
                let doc = host(kit: kit, before, after)
                var walk = CaretWalk()
                drive(&walk, doc, Array(repeating: steps.signum(), count: abs(steps)), perRefresh: 100)
                XCTAssertEqual(doc.text.utf16.count, end, "\(before.debugDescription) kit \(kit)")
                XCTAssertEqual(doc.moves, kit ? kitMoves : webMoves, "\(before.debugDescription) kit \(kit)")
            }
        }
        // A UITextView's line start shows only the LF before it: only the after side tells.
        let doc = host(kit: true, "ab\n", "😀😀x")
        var walk = CaretWalk()
        drive(&walk, doc, [1], perRefresh: 1)
        XCTAssertEqual(walk.utf16, true, "learned at a line's start")
    }

    /// Holds space and drags it by each of `offsets` caret steps in turn, the host never
    /// catching up mid-drag, then lifts and (`settle`) lets the host catch up as the poll
    /// timer does.
    private func drag(_ kb: TerminalKeyboard, _ doc: FakeProxy, _ offsets: [CGFloat], settle: Bool = true) throws {
        let space = try XCTUnwrap(laidOut(kb)["space"]).frame
        var p = CGPoint(x: space.midX, y: space.midY)
        doc.lags = true
        kb.track(.began, id: 1, at: p)
        kb.fireHold()
        for o in offsets {
            p.x += o * KeyTouchTracker.caretStep
            kb.track(.moved, id: 1, at: p)
        }
        kb.track(.ended, id: 1, at: p)
        for _ in 0..<(settle ? 20 : 0) { doc.catchUp(); kb.pollCaret() }
    }

    /// Types `key` with a tap.
    private func tap(_ kb: TerminalKeyboard, _ key: String) throws {
        let p = try XCTUnwrap(laidOut(kb)[key]).center
        kb.track(.began, id: 2, at: p)
        kb.track(.ended, id: 2, at: p)
    }

    /// QA's case through the keyboard: one step left over an emoji, a CR LF or a family,
    /// then a letter. A UIKit host takes it in one move of its units; a WebKit host goes
    /// that many Characters and comes back. The letter lands whole beside it either way.
    func testATrackpadStepThenALetterNeverBreaksAnEmojiOrACRLF() throws {
        for utf16 in [false, true] {
            for (before, after, typed, units) in [
                ("ab😀", "cd", "abz😀cd", -2), ("ab\r\n", "cd", "abz\r\ncd", -2), ("x👨‍👩‍👧", "", "xz👨‍👩‍👧", -8),
            ] {
                let back = typed.hasPrefix("x") ? -1 : 1
                let kb = TerminalKeyboard(), doc = FakeProxy()
                kb.target = doc
                doc.countsUTF16 = utf16
                doc.text = before; doc.after = after
                try drag(kb, doc, [-1.2])
                try tap(kb, "z")
                XCTAssertEqual(doc.text + (doc.after ?? ""), typed, "\(utf16)")
                XCTAssertEqual(doc.moves, utf16 ? [units] : [units, back], "\(utf16) \(typed.debugDescription)")
            }
        }
        let kb = TerminalKeyboard(), doc = FakeProxy()
        kb.target = doc
        doc.countsUTF16 = true
        doc.text = Self.mixed
        try drag(kb, doc, Array(repeating: -1, count: 5))
        XCTAssertEqual(doc.text, "a😀b👨‍👩‍👧c🇧🇬🇺🇸d", "five back, the drag never waiting for the host")
        XCTAssertTrue(doc.stops.allSatisfy(boundaries(Self.mixed).contains), "\(doc.stops)")
        try drag(kb, doc, [-1, -1, -1])
        XCTAssertEqual(doc.text, "a😀b👨‍👩‍👧c", "three back")
        try drag(kb, doc, [2])
        XCTAssertEqual(doc.text, "a😀b👨‍👩‍👧c🇧🇬🇺🇸", "and two on")
        XCTAssertEqual(doc.moves.suffix(3), [-1, -8, 8], "the flags in one move each way, sized in units")
    }

    /// What the walk learned in one field is forgotten in the next (QA's M217): Safari's
    /// Characters, then a UITextView's emoji crossed at its units, never one.
    func testANewFieldForgetsHowTheLastCounted() throws {
        let kb = TerminalKeyboard(), web = host(kit: false, "ab", "😀cd")
        kb.target = web
        try drag(kb, web, [1])
        XCTAssertEqual(web.moves, [2, -1], "learned: Safari counts Characters")
        let kit = host(kit: true, "ab", "😀cd")
        kb.target = kit
        try drag(kb, kit, [1])
        XCTAssertEqual(kit.moves, [2])
        XCTAssertEqual(kit.stops, [4])
    }

    /// A step past the document's end never shows, so the poll limit lets the steps after
    /// it through, in the same hold (QA's M219).
    func testThePollLimitLetsTheNextStepsThrough() throws {
        let kb = TerminalKeyboard(), doc = host(kit: true, "abc")
        kb.target = doc
        let space = try XCTUnwrap(laidOut(kb)["space"]).frame
        var p = CGPoint(x: space.midX, y: space.midY)
        kb.track(.began, id: 1, at: p)
        kb.fireHold()
        p.x += KeyTouchTracker.caretStep
        kb.track(.moved, id: 1, at: p)
        for _ in 0..<20 { kb.pollCaret() }
        p.x -= KeyTouchTracker.caretStep
        kb.track(.moved, id: 1, at: p)
        kb.track(.ended, id: 1, at: p)
        XCTAssertEqual(doc.moves, [1, -1])
        XCTAssertEqual(doc.text, "ab")
    }

    /// A key touched before the poll saw a CR LF split first finishes the crossing, so the
    /// letter goes after the line break, not inside it.
    func testATouchFinishesACrossingBeforeTyping() throws {
        let kb = TerminalKeyboard(), doc = host(kit: true, "ab", "\r\ncd")
        kb.target = doc
        try drag(kb, doc, [1], settle: false)
        doc.catchUp()
        try tap(kb, "z")
        XCTAssertEqual(doc.text + (doc.after ?? ""), "ab\r\nzcd")
    }

    /// A field that shows no context even after a move gets the steps queued behind it,
    /// and every later one in that hold, as asked, until it shows some.
    func testAFieldThatNeverShowsContextGetsStepsAsAsked() throws {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(-5, before: "", after: ""), -1)
        XCTAssertFalse(walk.idle)
        walk.timedOut()
        XCTAssertTrue(walk.blank)
        XCTAssertEqual(walk.step(0, before: "", after: ""), -4)
        XCTAssertTrue(walk.idle)
        XCTAssertEqual(walk.step(3, before: "", after: ""), 3)
        XCTAssertEqual(walk.step(1, before: "", after: "😀x"), 2, "context again: sized")
        XCTAssertFalse(walk.blank)
        let kb = TerminalKeyboard(), doc = FakeProxy()
        kb.target = doc
        doc.hidesContext = true
        doc.text = "abcdef"
        try drag(kb, doc, [-5])
        try drag(kb, doc, [2])
        XCTAssertEqual(doc.moves, [-1, -4, 1, 1], "each hold looks for context again")
        XCTAssertEqual(doc.text, "abc")
    }

    /// A UITextView's caret at an empty first line shows no context, and the emoji past
    /// the line break is never split: in one move, or two while the host lags, even
    /// straight after a field that shows none.
    func testAnEmptyLineBeforeAnEmojiIsNoFieldWithoutContext() throws {
        for lagged in [false, true] {
            let kb = TerminalKeyboard(), blank = FakeProxy()
            kb.target = blank
            blank.hidesContext = true
            blank.text = "ab"
            try drag(kb, blank, [-1])
            XCTAssertEqual(blank.moves, [-1])
            let doc = host(kit: true, "", "\n😀x")
            kb.target = doc
            doc.lags = lagged
            if lagged { kb.caret(1); kb.caret(1) } else { kb.caret(2) }
            for _ in 0..<20 { doc.catchUp(); kb.pollCaret() }
            XCTAssertEqual(doc.text.utf16.count, 3, "lagged \(lagged)")
            XCTAssertTrue(doc.stops.allSatisfy(boundaries("\n😀x").contains), "lagged \(lagged): \(doc.stops)")
        }
    }

    /// A field taken for one showing no context is looked at again at the next hold: a
    /// UITextView's empty document, then text typed and the caret back at its empty first
    /// line, where a fast drag right 2 still never splits the emoji after the line break.
    func testEachHoldLooksForContextAgain() throws {
        let kb = TerminalKeyboard(), doc = host(kit: true, "")
        kb.target = doc
        try drag(kb, doc, [1])
        doc.text = ""; doc.after = "\n😀x"
        try drag(kb, doc, [2])
        XCTAssertEqual(doc.text.utf16.count, 3)
        XCTAssertTrue(doc.stops.allSatisfy(boundaries("\n😀x").contains), "\(doc.stops)")
    }

    /// A move that never shows stops the polling after 2 s, still waited on: the next step
    /// polls again without sizing from the stale context.
    func testAMoveThatNeverShowsStopsThePolling() {
        let kb = TerminalKeyboard(), doc = host(kit: true, "", "ab😀x")
        kb.target = doc
        doc.lags = true
        doc.guesses = false
        kb.caret(1)
        for _ in 0..<99 { kb.pollCaret() }
        XCTAssertNotNil(kb.walkTimer)
        kb.pollCaret()
        XCTAssertNil(kb.walkTimer)
        kb.caret(1)
        XCTAssertNotNil(kb.walkTimer)
        XCTAssertEqual(doc.moves, [1], "still waiting on the first")
        for _ in 0..<5 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.moves, [1, 1])
        XCTAssertNil(kb.walkTimer)
    }

    /// A UITextView slower than the poll limit, its context showing one move at a time:
    /// a move that can show never counts as landed before it does, so the step behind it
    /// is never sized from the text before it and the emoji after the run stays whole.
    func testASlowHostNeverHasAnEmojiSplitBehindAPlainMove() {
        let doc = host(kit: true, "", "ab😀x")
        doc.lags = true
        doc.guesses = false
        var walk = CaretWalk()
        func step(_ n: Int) {
            let units = walk.step(n, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "")
            if units != 0 { doc.adjustTextPosition(byCharacterOffset: units) }
        }
        func poll(_ times: Int) { for p in 1...times { if p > 15 { walk.timedOut() }; step(0) } }
        step(1)
        poll(20)
        step(1)
        doc.showNext()
        poll(1)
        step(1)
        for _ in 0..<20 { doc.showNext(); poll(1) }
        XCTAssertEqual(doc.text.utf16.count, 4)
        XCTAssertTrue(doc.stops.allSatisfy(boundaries("ab😀x").contains), "\(doc.stops)")
    }

    /// QA's report-311: a UITextView whose proxy shows its guess, the move taken as
    /// Characters, for 10 polls after each move, longer than the walk's 40 ms. Fast right
    /// 2 from an empty first line, and fast left 3 over a skin-tone thumb, a space and a
    /// letter, while the walk doesn't know the host: the guess reads as WebKit going too
    /// far, and its step back would land inside the emoji. It never goes.
    func testUIKitsGuessIsNeverTakenForWebKit() {
        for (before, after, steps, end) in [("", "\n😀x", 2, 3), ("abcdef👍🏽 l", "", -3, 6)] {
            let kb = TerminalKeyboard(), doc = host(kit: true, before, after)
            kb.target = doc
            kb.caret(steps)
            for i in 1...60 { if i % 10 == 0 { doc.answer() }; kb.pollCaret() }
            XCTAssertEqual(doc.text.utf16.count, end, before + after)
            XCTAssertTrue(doc.stops.allSatisfy(boundaries(before + after).contains), "\(doc.stops)")
        }
    }

    /// A blind unit off a line's end before a CR LF: UIKit's guess shows it past the line
    /// break, the host between CR and LF. The view believes no context for 40 ms, so the
    /// emoji after is sized from the host's answer, never the guess.
    func testTheViewWaitsOutAGuessAtALineBreak() {
        let kb = TerminalKeyboard(), doc = host(kit: true, "ab", "\r\n😀x")
        kb.target = doc
        kb.caret(2)
        for i in 1...30 { if i % 2 == 0 { doc.answer() }; kb.pollCaret() }
        XCTAssertEqual(doc.text.utf16.count, 6)
        XCTAssertTrue(doc.stops.allSatisfy { boundaries("ab\r\n😀x").contains($0) || $0 == 3 }, "\(doc.stops)")
    }

    /// Once a host is known to count units, a context reading as the move taken in
    /// Characters is the proxy's guess: the steps behind wait for the host's answer rather
    /// than be sized from it.
    func testAKnownUIKitHostsGuessSizesNothing() {
        let doc = host(kit: true, "ab😀c😀")
        var walk = CaretWalk()
        walk.utf16 = true
        func step(_ n: Int) {
            let units = walk.step(n, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "")
            if units != 0 { doc.adjustTextPosition(byCharacterOffset: units) }
        }
        step(-1)
        step(-1)
        XCTAssertEqual(doc.moves, [-2], "the guess shows: wait")
        doc.answer()
        step(0)
        XCTAssertEqual(doc.stops, [5, 4])
    }

    /// A host wrongly taken for WebKit learns its units at the first split: one emoji is
    /// cut for a moment, then none.
    func testASplitTeachesUnits() {
        let doc = host(kit: true, "", "😀😀😀")
        var walk = CaretWalk()
        walk.utf16 = false
        drive(&walk, doc, [1, 1, 1], perRefresh: 1)
        XCTAssertEqual(walk.utf16, true)
        XCTAssertEqual(doc.stops.filter { !boundaries("😀😀😀").contains($0) }, [1])
        XCTAssertEqual(doc.text.utf16.count, 6)
    }

    /// A host that shows nothing until it answers, slower than the poll limit, over a run
    /// of x's whose line ends before an emoji: a move taken as landed where it reads the
    /// same is reckoned there, and the reckoning is dropped once the host shows a move,
    /// so no step behind is sized from where the caret was.
    func testAReckonedMoveSizesTheNextUntilTheHostShows() {
        for (after, first, second) in [("xxx\n😀y", 2, 3), ("xxxx\n😀y", 1, 2)] {
            let doc = host(kit: true, "", after)
            doc.lags = true
            doc.guesses = false
            var walk = CaretWalk()
            func step(_ n: Int) {
                let units = walk.step(n, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "")
                if units != 0 { doc.adjustTextPosition(byCharacterOffset: units) }
            }
            step(first)
            for _ in 0..<16 { walk.timedOut(); step(0) }
            step(second)
            if first == 1 { doc.catchUp(); step(0); step(3) }
            for _ in 0..<20 { doc.catchUp(); step(0) }
            XCTAssertTrue(doc.stops.allSatisfy(boundaries(after).contains), "\(after.debugDescription): \(doc.stops)")
        }
    }

    /// A context neither landing explains (the text changed under the move) teaches the
    /// walk nothing about the host.
    func testAContextNeitherLandingExplainsTeachesNothing() {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(1, before: "", after: "😀ab"), 2)
        XCTAssertEqual(walk.step(0, before: "q", after: "r"), 0)
        XCTAssertNil(walk.utf16)
        XCTAssertTrue(walk.idle)
    }
}
