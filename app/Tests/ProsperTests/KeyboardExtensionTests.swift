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
        /// Both contexts are nil, as a password field's are.
        var hidesContext = false
        var documentContextBeforeInput: String? { hidesContext ? nil : shown?.before ?? text }
        var after: String? { didSet { units = nil } }
        var documentContextAfterInput: String? {
            if hidesContext { return nil }
            let a = shown == nil ? after : shown?.after
            return stopsAtLineEnd ? a.map { String($0.utf16.prefix { $0 != 0x0A && $0 != 0x0D }) ?? "" } : a
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
        /// The context shows each move only after `catchUp()`, as a host's lags.
        var lags = false
        private var shown: (before: String, after: String?)?
        /// The text and the caret in units, which a split context can't keep.
        private var units: (all: [UInt16], at: Int)?
        func catchUp() { shown = nil }
        func adjustTextPosition(byCharacterOffset offset: Int) {
            moves.append(offset)
            if lags, shown == nil { shown = (text, after) }
            if countsUTF16 {
                let u = units ?? (Array((text + (after ?? "")).utf16), text.utf16.count)
                let at = min(max(u.at + offset, 0), u.all.count)
                text = String(decoding: u.all[..<at], as: UTF16.self)
                after = String(decoding: u.all[at...], as: UTF16.self)
                units = (u.all, at)
            } else {
                let all = text + (after ?? ""), at = min(max(text.count + offset, 0), all.count)
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

    /// Where the caret may stop in `s`, in UTF-16 units: between two Characters.
    private func boundaries(_ s: String) -> [Int] { s.indices.map { s[..<$0].utf16.count } + [s.utf16.count] }

    /// A host field holding `mixed`, the caret at its end.
    private func field(utf16: Bool, lineEnds: Bool) -> FakeProxy {
        let doc = FakeProxy()
        doc.text = Self.mixed
        doc.countsUTF16 = utf16
        doc.stopsAtLineEnd = lineEnds
        return doc
    }

    /// Single steps through `walk`, the host catching up after every `perRefresh` of them
    /// (0: its context never lags), then until the walk is idle, or gives up as the view does.
    private func drive(_ walk: inout CaretWalk, _ doc: FakeProxy, _ steps: [Int], perRefresh: Int) {
        func step(_ n: Int) {
            let units = walk.step(n, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "")
            if units != 0 { doc.adjustTextPosition(byCharacterOffset: units) }
        }
        doc.lags = perRefresh > 0
        for (i, n) in steps.enumerated() {
            step(n)
            if perRefresh > 0, (i + 1) % perRefresh == 0 { doc.catchUp(); step(0) }
        }
        for _ in 0..<40 where !walk.idle { doc.catchUp(); step(0) }
        if !walk.idle { walk.drop() }
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

    /// In both kinds of host, however many steps go between the host's catching up: a
    /// drag past either end stops there, and one step at a time stops on every Character
    /// boundary in turn, none skipped. Once the walk has learned the host, no move ever
    /// stops inside a Character, not even for a moment.
    func testTheWalkStopsOnlyBetweenCharactersInEitherHost() {
        let ends = boundaries(Self.mixed), n = ends.count - 1
        for utf16 in [false, true] {
            for lineEnds in [false, true] {
                for perRefresh in [0, 1, 3, 100] {
                    let doc = field(utf16: utf16, lineEnds: lineEnds), at = "\(utf16) \(lineEnds) \(perRefresh)"
                    var walk = CaretWalk()
                    drive(&walk, doc, Array(repeating: -1, count: n + 2), perRefresh: perRefresh)
                    XCTAssertEqual(doc.text, "", at)
                    XCTAssertEqual(walk.utf16, utf16, at)
                    let learned = doc.stops.count
                    drive(&walk, doc, Array(repeating: 1, count: n + 2), perRefresh: perRefresh)
                    XCTAssertEqual(doc.text.utf16.count, Self.mixed.utf16.count, at)
                    // The one blind step: off a line's end into a CR LF the context cut.
                    let crlf = lineEnds && utf16 ? ["a😀b👨‍👩‍👧c🇧🇬🇺🇸d\r".utf16.count] : []
                    XCTAssertTrue(doc.stops[learned...].allSatisfy((ends + crlf).contains), "\(at): \(doc.stops[learned...])")

                    let fresh = field(utf16: utf16, lineEnds: lineEnds)
                    fresh.text = ""; fresh.after = Self.mixed
                    walk = CaretWalk()
                    for k in 1...n {
                        drive(&walk, fresh, [1], perRefresh: perRefresh)
                        XCTAssertEqual(fresh.text.utf16.count, ends[k], "\(at) step \(k)")
                    }
                }
            }
        }
    }

    /// Holds space and drags it by each of `offsets` caret steps in turn, the host never
    /// catching up mid-drag, then lifts and lets the host catch up as the poll timer does.
    private func drag(_ kb: TerminalKeyboard, _ doc: FakeProxy, _ offsets: [CGFloat]) throws {
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
        for _ in 0..<20 { doc.catchUp(); kb.pollCaret() }
    }

    /// QA's case through the keyboard: one step left over an emoji, or a CR LF, then a
    /// letter. A UIKit host takes a probe and a nudge, and so a fast drag over the family;
    /// a WebKit host the one move. The letter lands whole beside it either way.
    func testATrackpadStepThenALetterNeverBreaksAnEmojiOrACRLF() throws {
        for utf16 in [false, true] {
            for (before, after, typed, moves) in [
                ("ab😀", "cd", "abz😀cd", [-1, -1]), ("ab\r\n", "cd", "abz\r\ncd", [-1, -1]),
                ("x👨‍👩‍👧", "", "xz👨‍👩‍👧", [-1, -7]),
            ] {
                let kb = TerminalKeyboard(), doc = FakeProxy()
                kb.target = doc
                doc.countsUTF16 = utf16
                doc.text = before; doc.after = after
                try drag(kb, doc, [-1.2])
                let z = try XCTUnwrap(laidOut(kb)["z"]).center
                kb.track(.began, id: 2, at: z)
                kb.track(.ended, id: 2, at: z)
                XCTAssertEqual(doc.text + (doc.after ?? ""), typed, "\(utf16)")
                XCTAssertEqual(doc.moves, utf16 ? moves : [-1], "\(utf16) \(typed.debugDescription)")
            }
        }
        let kb = TerminalKeyboard(), doc = FakeProxy()
        kb.target = doc
        doc.countsUTF16 = true
        doc.text = Self.mixed
        try drag(kb, doc, Array(repeating: -1, count: 5))
        XCTAssertEqual(doc.text, "a😀b👨‍👩‍👧c🇧🇬🇺🇸d", "five back, the drag never waiting for the host")
        try drag(kb, doc, [-1, -1, -1])
        XCTAssertEqual(doc.text, "a😀b👨‍👩‍👧c", "learned: three back")
        try drag(kb, doc, [2])
        XCTAssertEqual(doc.text, "a😀b👨‍👩‍👧c🇧🇬🇺🇸", "and two on")
        XCTAssertEqual(doc.moves.suffix(3), [-1, -8, 8], "the flags in one move each way, sized in units")
    }

    /// A field that shows no context, like a password's: a drag moves the caret at once,
    /// one unit a step as asked, with nothing left waiting on the host.
    func testAFieldWithNoContextMovesAtOnce() throws {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(-5, before: "", after: ""), -5)
        XCTAssertTrue(walk.idle)
        let kb = TerminalKeyboard(), doc = FakeProxy()
        kb.target = doc
        doc.hidesContext = true
        doc.text = "abcdef"
        try drag(kb, doc, [-5])
        try drag(kb, doc, [2])
        XCTAssertEqual(doc.moves, [-5, 2])
        XCTAssertEqual(doc.text, "abc")
    }
}
