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
        var text = "" { didSet { units = nil; rest = nil } }
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
            let s = guess ?? shown
            if let r = s.map({ $0.rest }) ?? rest { return r }
            return context(before: s?.before ?? text)
        }
        private func context(before x: String) -> String {
            var u = Array(x.utf16)
            if lineBefore, let i = u.lastIndex(of: 0x0A) { u = i == u.count - 1 ? [0x0A] : Array(u[(i + 1)...]) }
            if sentenceBefore, let i = u.indices.dropLast(2).last(where: { u[$0] == 0x2E && u[$0 + 1] == 0x20 }) {
                u = Array(u[(i + 2)...])
            }
            if breakSpace, let i = u.lastIndex(of: 0x0A), i < u.count - 1 { u = [0x0A, 0x20] + Array(u[(i + 1)...]) }
            return String(decoding: u.suffix(window ?? u.count), as: UTF16.self)
        }
        /// The before-context is the caret's line, and only its LF at a line's start, as a
        /// UITextView's is.
        var lineBefore = false
        /// The before-context starts at the caret's sentence, as some UIKit hosts' does.
        var sentenceBefore = false
        /// The before-context stops at the caret line's break and shows a space after it that
        /// isn't in the text, as Safari's does at a paragraph's start.
        var breakSpace = false
        /// Each context is this many units either side of the caret, sliding with it, as
        /// Safari's is.
        var window: Int?
        /// After a delete the before-context is what's left of the one shown when the deletes
        /// began, "" at its start, till a caret move shows a fresh one, as a UITextView's and
        /// Safari's are (#553 QA): the host keeps the window it cut the context at.
        var cutsEdits = false
        private var rest: String?
        var after: String? { didSet { units = nil } }
        var documentContextAfterInput: String? {
            if hidesContext { return nil }
            let a = (guess ?? shown).map(\.after) ?? after
            let cut = stopsAtLineEnd && !(guessesPastLineEnd && guess != nil) ? a.map { String($0.utf16.prefix { $0 != 0x0A && $0 != 0x0D }) ?? "" } : a
            return window.flatMap { w in cut.map { String(decoding: Array($0.utf16.prefix(w)), as: UTF16.self) } } ?? cut
        }
        /// The after-context stops at the caret line's end, as a host's does.
        var stopsAtLineEnd = false
        /// UIKit's guess (`guesses`) shows the after-context on past the line's end where the
        /// host's own answer stops (`stopsAtLineEnd`), as QA's UITextView's did.
        var guessesPastLineEnd = false
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        let documentIdentifier = UUID()
        var hasText: Bool { !text.isEmpty }
        /// Edits lag as moves do (`lags`): the context shows them only after `catchUp()`, as
        /// real hosts show none in the runloop turn that sent them.
        var lagsEdits = false
        /// The context shows all but the last edit until `catchUp()`: a host one edit behind,
        /// whose context changes but still shows the last Character deleted.
        var behind = false
        func insertText(_ s: String) { if lagsEdits || behind { unshown.append((text, after, rest)) }; text += s; calls.append(s) }
        func deleteBackward() {
            let left = cutsEdits ? String((rest ?? context(before: text)).dropLast()) : nil
            if lagsEdits || behind { unshown.append((text, after, rest)) }
            _ = text.popLast()
            rest = left
            calls.append("⌫")
        }
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
        private var unshown: [(before: String, after: String?, rest: String?)] = []
        private var shown: (before: String, after: String?, rest: String?)? { behind ? unshown.last : unshown.first }
        /// The text and the caret in units, which a split context can't keep.
        private var units: (all: [UInt16], at: Int)?
        /// Right after each move the context shows it taken as Characters until `answer()`
        /// or `catchUp()`, as UIKit's proxy guesses before the host answers: counted in the
        /// text on the move's side of the caret alone, so from inside a Character a lone
        /// surrogate half is one, and the rest of a family before a ZWJ another.
        var guesses = false
        private var guess: (before: String, after: String?, rest: String?)?
        func answer() { guess = nil }
        func catchUp() { unshown = []; guess = nil }
        func showNext() { if !unshown.isEmpty { unshown.removeFirst() } }
        func adjustTextPosition(byCharacterOffset offset: Int) {
            moves.append(offset)
            if lags { unshown.append((text, after, rest)) }
            if guesses {
                let u = units ?? (Array((text + (after ?? "")).utf16), text.utf16.count)
                let side = String(decoding: offset < 0 ? u.all[..<u.at] : u.all[u.at...], as: UTF16.self)
                let at = offset < 0 ? side.dropLast(-offset).utf16.count : u.at + side.prefix(offset).utf16.count
                guess = (String(decoding: u.all[..<at], as: UTF16.self), String(decoding: u.all[at...], as: UTF16.self), nil)
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
            kb.offersEmoji = false
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
                    K.characterPreview] {
            defaults.set(key == K.autoCapitalization, forKey: key)   // each flipped
        }
        var flipped = KeyboardSettings()
        flipped.autoCapitalization = true
        flipped.autoCorrection = false
        flipped.capsLock = false
        flipped.predictiveText = false
        flipped.characterPreview = false
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

    // MARK: Keys beside space

    /// Settings' order and hidden keys make the bottom row: every key once, unknown ones
    /// dropped, missing ones at the end, space never hidden, return last.
    func testBottomRowFromTheSetting() {
        var s = KeyboardSettings()
        XCTAssertEqual(s.bottomRow, TerminalKeyboard.rows.last!, "the default")
        s.bottomOrder = ".,? /"
        XCTAssertEqual(s.bottomRow, [.char("."), .char(","), .char("?"), .space, .char("/"), .emoji, .ret], "/ and ? swapped")
        s.bottomHidden = "?/ "
        XCTAssertEqual(s.bottomRow, [.char("."), .char(","), .space, .emoji, .ret], "space stays")
        s.bottomOrder = "x??"
        s.bottomHidden = ""
        XCTAssertEqual(s.bottomRow, [.char("?"), .char("."), .char(","), .char("/"), .space, .emoji, .ret])
        XCTAssertEqual(KeyboardSettings.order(""), Array(KeyboardSettings.bottomKeys))
    }

    func testBottomRowReadsWhatTheAppWrote() throws {
        let suite = "KeyboardSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/ ?.,", forKey: KeyboardSettings.Key.bottomOrder)
        defaults.set(",", forKey: KeyboardSettings.Key.bottomHidden)
        XCTAssertEqual(KeyboardSettings(defaults).bottomRow, [.char("/"), .space, .char("?"), .char("."), .emoji, .ret])
    }

    /// Both layouts, globe or not, lay the row out from the setting, rebuilt when it
    /// changes, and space takes a hidden key's room.
    func testHiddenKeysWidenSpace() throws {
        for layout in [TerminalKeyboard.Layout.english, .bulgarian] {
            for globe in [false, true] {
                let kb = TerminalKeyboard(layout: layout)
                kb.showsGlobe = globe
                kb.offersEmoji = false
                let wide = try XCTUnwrap(laidOut(kb)["space"]).frame
                var s = KeyboardSettings()
                s.bottomOrder = "?/ .,"
                s.bottomHidden = ".,"
                kb.settings = s
                let caps = laidOut(kb)
                let space = try XCTUnwrap(caps["space"]).frame
                let row = kb.subviews.compactMap { $0 as? UIButton }
                    .filter { $0.frame.midY == space.midY }.sorted { $0.frame.minX < $1.frame.minX }
                XCTAssertEqual(row.map { $0.accessibilityLabel ?? "" },
                               (globe ? ["next keyboard"] : []) + ["?", "/", "space", "new line"], "\(layout) \(globe)")
                XCTAssertNil(caps["."])
                XCTAssertEqual(space.width - wide.width, 2 * (caps["?"]!.frame.width + TerminalKeyboard.keyGap),
                               accuracy: 0.001, "two keys' room, gaps included")
                kb.settings = KeyboardSettings()
                XCTAssertEqual(laidOut(kb)["space"]?.frame, wide, "back to the default")
            }
        }
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

    // MARK: Space

    /// Two quick spaces after a word are two spaces through the proxy, the next letter
    /// still lowercase: no shortcut turns them into ". ".
    func testTwoQuickSpacesAreTwoSpacesThroughTheProxy() {
        let kb = TerminalKeyboard(), doc = FakeProxy()
        kb.target = doc
        kb.settings.autoCapitalization = true
        for k in ["o", "k"] { kb.press(.char(k)) }
        kb.press(.space); kb.press(.space)
        kb.press(.char("s"))
        XCTAssertEqual(doc.text, "ok  s")
        XCTAssertEqual(doc.calls.suffix(3), [" ", " ", "s"], "no deleteBackward")
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
    /// idle, the walk settled from the third poll after a move and timing out as the view's.
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
            walk.poll()
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

    /// A slide onto the globe, which takes its own touches, types nothing on lift, not the
    /// nearest key, return (QA's): from ?, from space short of the trackpad, from a held m.
    /// One lifting on return still types it.
    func testASlideOntoTheGlobeTypesNothing() throws {
        let kb = TerminalKeyboard()
        kb.offersEmoji = false
        kb.showsGlobe = true
        kb.settings = KeyboardSettings()
        let spy = SpyInput()
        kb.target = spy
        let caps = laidOut(kb)
        let own = try XCTUnwrap(caps["next keyboard"]).center
        for from in ["?", "space", "m"] {
            let p = try XCTUnwrap(caps[from]).center
            kb.track(.began, id: 1, at: p)
            if from == "m" { kb.fireHold() }
            kb.track(.moved, id: 1, at: own)
            kb.track(.ended, id: 1, at: own)
            XCTAssertEqual(spy.calls, [], from)
        }
        let p = try XCTUnwrap(caps["?"]).center, ret = try XCTUnwrap(caps["new line"]).center
        kb.track(.began, id: 1, at: p)
        kb.track(.moved, id: 1, at: own)
        kb.track(.ended, id: 1, at: ret)
        XCTAssertEqual(spy.calls, ["\n"])
    }

    /// A trackpad lifted over the globe keeps its caret walk and ends: a tap types.
    func testATrackpadLiftedOverTheGlobeEnds() throws {
        let kb = TerminalKeyboard(), doc = host(kit: true, "abcdefghijklmnopqrstuvwxyz")
        kb.offersEmoji = false
        kb.showsGlobe = true
        kb.settings = KeyboardSettings()
        kb.target = doc
        let caps = laidOut(kb)
        let space = try XCTUnwrap(caps["space"]).center, globe = try XCTUnwrap(caps["next keyboard"]).center
        let steps = Int((space.x - globe.x) / KeyTouchTracker.caretStep)
        XCTAssertGreaterThan(steps, 0)
        kb.track(.began, id: 1, at: space)
        kb.fireHold()
        kb.track(.moved, id: 1, at: globe)
        kb.track(.ended, id: 1, at: globe)
        for _ in 0..<20 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, String("abcdefghijklmnopqrstuvwxyz".dropLast(steps)))
        try tap(kb, "z")
        XCTAssertEqual(doc.text.last, "z", "the trackpad ended")
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

    /// A context neither landing explains (an older answer, or the text changed under the
    /// move) is waited out to the poll limit; one both explain alike is a landing, and
    /// neither teaches the walk anything about the host.
    func testAContextNeitherLandingExplainsIsWaitedOut() {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(1, before: "", after: "😀ab"), 2)
        XCTAssertEqual(walk.step(0, before: "q", after: "r"), 0)
        XCTAssertFalse(walk.idle)
        walk.timedOut()
        XCTAssertEqual(walk.step(0, before: "q", after: "r"), 0)
        XCTAssertTrue(walk.idle)
        XCTAssertNil(walk.utf16)
        var tie = CaretWalk()
        XCTAssertEqual(tie.step(1, before: "", after: "😀😀😀"), 2)
        XCTAssertEqual(tie.step(0, before: "😀", after: "😀"), 0)
        XCTAssertTrue(tie.idle)
        XCTAssertNil(tie.utf16)
    }

    /// A UITextView answering each move well after its proxy's guess, three steps left over
    /// "b", "a" and a skin-tone thumb: the guesses for the two letters are believed, then
    /// the answer to the first shows the caret back after "b". Nothing has been sent since,
    /// so that's an older answer: the third step waits for the latest instead of being
    /// sized from it, and the thumb is crossed whole.
    func testAnOlderAnswerIsNeverTakenForTheLatestMove() {
        let text = String(repeating: "ab😀👍🏽", count: 6)
        let doc = host(kit: true, String(text.prefix(22)), String(text.dropFirst(22)))
        doc.lags = true
        var walk = CaretWalk()
        walk.utf16 = true
        func step(_ n: Int) {
            let units = walk.step(n, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "")
            if units != 0 { doc.adjustTextPosition(byCharacterOffset: units) }
        }
        step(-1)
        step(0)
        step(-1)
        step(0)
        doc.answer()
        doc.showNext()
        step(-1)
        XCTAssertEqual(doc.moves, [-1, -1], "the older answer sizes nothing")
        doc.catchUp()
        step(0)
        XCTAssertEqual(doc.stops, [41, 40, 36])
    }

    /// A context that changes with nothing sent (the host edited its text) holds the steps
    /// only to the poll limit, and a touch starts afresh: typing between two holds never
    /// holds the next.
    func testOnlyTheMovesHoldBackTheNextOlderAnswer() throws {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(1, before: "", after: "ab"), 1)
        XCTAssertEqual(walk.step(0, before: "a", after: "b"), 0)
        XCTAssertEqual(walk.step(1, before: "xa", after: "b"), 0)
        walk.timedOut()
        XCTAssertEqual(walk.step(0, before: "xa", after: "b"), 1)
        XCTAssertEqual(walk.step(0, before: "xab", after: ""), 0)
        walk.drop()
        XCTAssertEqual(walk.step(-1, before: "yab", after: ""), -1)
        let kb = TerminalKeyboard(), doc = host(kit: true, "ab", "cd")
        kb.target = doc
        try drag(kb, doc, [1])
        try tap(kb, "z")
        try drag(kb, doc, [1], settle: false)
        XCTAssertEqual(doc.moves, [1, 1])
    }

    /// A field known to count units whose host is busy past the poll limit: its proxy's
    /// guess, the move taken in Characters, is still never taken for WebKit's overshoot.
    func testAKnownUnitsHostOutwaitsItsGuessPastThePollLimit() {
        let doc = host(kit: true, String(repeating: "ab😀👍🏽", count: 6))
        var walk = CaretWalk()
        walk.utf16 = true
        func step(_ n: Int) {
            let units = walk.step(n, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "")
            if units != 0 { doc.adjustTextPosition(byCharacterOffset: units) }
        }
        step(-1)
        for p in 1...20 { if p > 15 { walk.timedOut() }; step(0) }
        doc.answer()
        step(0)
        XCTAssertEqual(walk.utf16, true)
        XCTAssertEqual(doc.moves, [-4])
        XCTAssertEqual(doc.text.utf16.count, 44)
    }

    /// A UITextView answering each move 150 ms after its proxy's guess, dragged left over
    /// "b", "a" and a skin-tone thumb in a field the walk knows nothing about yet: the
    /// thumb's move waits behind the answers to the two letters, and its own comes more
    /// than 0.3 s after it was sent. Each new context restarts the poll limit, so the host
    /// is never taken for WebKit and the thumb is crossed whole. A move that shows nothing
    /// still times out on the 16th poll.
    func testAnOlderAnswerRestartsThePollLimit() {
        let text = String(repeating: "ab😀👍🏽", count: 6)
        let kb = TerminalKeyboard(), doc = host(kit: true, String(text.prefix(22)), String(text.dropFirst(22)))
        kb.target = doc
        doc.lags = true
        kb.caret(-1)
        kb.pollCaret()
        kb.caret(-1)
        kb.pollCaret()
        kb.caret(-1)
        kb.pollCaret()
        doc.answer()
        doc.showNext()
        for _ in 0..<8 { kb.pollCaret() }
        doc.showNext()
        for _ in 0..<8 { kb.pollCaret() }
        doc.catchUp()
        for _ in 0..<5 { kb.pollCaret() }
        XCTAssertEqual(doc.moves, [-1, -1, -4])
        XCTAssertEqual(doc.stops, [41, 40, 36])
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(1, before: "a", after: "😀"), 2)
        for _ in 0..<15 { walk.poll(); XCTAssertEqual(walk.step(0, before: "a", after: "😀"), 0) }
        XCTAssertNil(walk.utf16)
        walk.poll()
        XCTAssertEqual(walk.step(0, before: "a", after: "😀"), 1, "ignored past the end: WebKit")
        XCTAssertEqual(walk.utf16, false)
    }

    /// A thumb that rests on the space bar, then moves on over an emoji in a UITextView
    /// answering 100 ms late: the poll limit counts from the move, not from the rest, so the
    /// move waits for its answer and is never taken for WebKit's.
    func testAMoveAfterAPauseWaitsForALaggingHost() {
        let kb = TerminalKeyboard(), doc = host(kit: true, "ab😀c")
        kb.target = doc
        doc.lags = true
        kb.caret(-1)
        doc.catchUp()
        kb.pollCaret()
        for _ in 0..<20 { kb.pollCaret() }
        kb.caret(-1)
        for _ in 0..<5 { kb.pollCaret() }
        doc.catchUp()
        kb.pollCaret()
        XCTAssertEqual(doc.moves, [-1, -2], "the emoji crossed whole, nothing sent back")
        XCTAssertEqual(doc.stops, [4, 2])
    }

    /// A UITextView wrongly taken for WebKit steps one unit into a family's last emoji: the
    /// split teaches its units, and the rest of the family follows a code point at a time,
    /// never stopping between a surrogate pair's halves. Before the host answers each, its
    /// proxy guesses the rest of the family crossed in one, a context that splits nothing:
    /// that's outwaited, never taken for the landing.
    func testASplitsExtraOutwaitsTheGuess() {
        let family = "x👨‍👩‍👧"
        let doc = host(kit: true, family)
        var walk = CaretWalk()
        walk.utf16 = false
        func step(_ n: Int) {
            let units = walk.step(n, before: doc.documentContextBeforeInput ?? "", after: doc.documentContextAfterInput ?? "")
            if units != 0 { doc.adjustTextPosition(byCharacterOffset: units) }
        }
        step(-1)
        doc.answer()
        for _ in 0..<6 {
            step(0)
            step(0)
            doc.answer()
        }
        XCTAssertEqual(walk.utf16, true)
        XCTAssertEqual(doc.moves, [-1, -1, -1, -2, -1, -2])
        XCTAssertEqual(doc.stops, [8, 7, 6, 4, 3, 1])
        XCTAssertTrue(walk.idle)
    }

    // MARK: Trackpad lines

    /// `s` with `|` at the caret, in a UITextView (`kit`) or Safari, whose after-contexts
    /// stop at the caret line's end (`cut`), after `moves` of (steps, lines), each asked once
    /// the last has landed, or all at once up to a (0, 0) (`fast`), the host catching up
    /// after every `perRefresh` asks (0: its context never lags), rows of `wrap`, each move a
    /// new touch's (`touch`: the walk dropped first, as the view's does): the text with `|`
    /// where the caret ended. The caret never stops inside a Character but, in a UITextView,
    /// for a moment between a CR and its LF.
    private func lined(_ s: String, kit: Bool, cut: Bool = true, _ moves: [(Int, Int)], perRefresh: Int = 0,
                       fast: Bool = false, wrap: Int? = nil, touch: Bool = false, _ why: String = "",
                       tweak: (FakeProxy) -> Void = { _ in },
                       file: StaticString = #filePath, line: UInt = #line) -> String {
        let parts = s.components(separatedBy: "|"), text = parts.joined()
        let doc = host(kit: kit, parts[0], parts[1])
        doc.stopsAtLineEnd = cut
        tweak(doc)
        doc.lags = perRefresh > 0
        var walk = CaretWalk(), polls = 0
        walk.wrap = wrap
        func step(_ m: (Int, Int)) {
            let units = walk.step(m.0, lines: m.1, before: doc.documentContextBeforeInput ?? "",
                                  after: doc.documentContextAfterInput ?? "", settled: polls >= 3)
            if units != 0 { doc.adjustTextPosition(byCharacterOffset: units); polls = 0 }
        }
        func settle() { for _ in 0..<400 where !walk.idle { doc.catchUp(); polls += 1; walk.poll(); step((0, 0)) } }
        for (i, m) in moves.enumerated() {
            if touch { walk.drop() }
            step(m)
            if perRefresh > 0, (i + 1) % perRefresh == 0 { doc.catchUp(); step((0, 0)) }
            if !fast || m == (0, 0) { settle() }
        }
        settle()
        let at = "\(why) kit \(kit) cut \(cut) lag \(perRefresh) wrap \(wrap ?? 0)"
        XCTAssertTrue(walk.idle, at, file: file, line: line)
        let u = Array(text.utf16), crlf = u.indices.dropFirst().filter { u[$0 - 1] == 0x0D && u[$0] == 0x0A }
        let bad = doc.stops.filter { !boundaries(text).contains($0) && !(kit && crlf.contains($0)) }
        XCTAssertEqual(bad, [], "\(at): stopped inside a Character", file: file, line: line)
        return doc.text + "|" + (doc.after ?? "")
    }

    /// A line move in either host, lagging or not, the break past a line's end shown or
    /// not: it keeps its column through a short line, counts it in Characters, crosses a
    /// CR LF whole, stops at the text's start and end past its first and last lines, and
    /// lands where a line shows only in windows. Rows longer than any line change nothing.
    func testLineMovesKeepTheirColumnInEitherHost() {
        let long = String(repeating: "x", count: 150), x30 = String(repeating: "x", count: 30)
        let cases: [(String, [(Int, Int)], String, String)] = [
            ("ab|c\ndef", [(0, 1)], "abc\nde|f", "down keeps the column"),
            ("abc\nde|f", [(0, -1)], "ab|c\ndef", "up keeps the column"),
            ("abc\n|def", [(0, -1)], "|abc\ndef", "from a line's start"),
            ("abcdef|\nab\nabcdefgh", [(0, 1)], "abcdef\nab|\nabcdefgh", "a short line: its end"),
            ("abcdef|\nab\nabcdefgh", [(0, 1), (0, 1)], "abcdef\nab\nabcdef|gh", "the column back past it"),
            ("abcdef|\nab\nabcdefgh", [(0, 2)], "abcdef\nab\nabcdef|gh", "two lines in one move"),
            ("abcdefgh\nab\nabc|def", [(0, -2)], "abc|defgh\nab\nabcdef", "two lines up"),
            ("abcdefgh\nab\nabc|def", [(0, -1), (0, -1)], "abc|defgh\nab\nabcdef", "up, and up again"),
            ("a|bc\ndef", [(0, -1)], "|abc\ndef", "up on the first line: its start, as iOS's ↑"),
            ("abc\nd|ef", [(0, 1)], "abc\ndef|", "down on the last line: its end, as iOS's ↓"),
            ("a|b\ncd", [(0, 5)], "ab\ncd|", "more lines than there are: the text's end"),
            ("ab\nc|d", [(0, -5)], "|ab\ncd", "and its start"),
            ("abc|\n\nabc", [(0, 1)], "abc\n|\nabc", "an empty line"),
            ("abc|\n\nabc", [(0, 2)], "abc\n\nabc|", "past it, the column back"),
            ("abc\n\nab|c", [(0, -1)], "abc\n|\nabc", "up onto an empty line"),
            ("|", [(0, 1), (0, -1)], "|", "no text"),
            ("ab|c\r\ndef", [(0, 1)], "abc\r\nde|f", "a CR LF is one break"),
            ("abc\r\nde|f", [(0, -1)], "ab|c\r\ndef", "up over a CR LF"),
            ("abcdef\r\nab\r\n|abcdefgh", [(0, -1)], "abcdef\r\n|ab\r\nabcdefgh", "QA's: never between CR and LF"),
            ("abcdef\r\nab\r\nabcd|efgh", [(0, -2)], "abcd|ef\r\nab\r\nabcdefgh", "two up over CR LFs"),
            ("ab😀c|d\n😀😀😀xyz", [(0, 1)], "ab😀cd\n😀😀😀x|yz", "the column in Characters"),
            ("ab😀cd\n😀😀😀x|y", [(0, -1)], "ab😀c|d\n😀😀😀xy", "and back up"),
            ("a👨‍👩‍👧b|\n🇧🇬🇺🇸x", [(0, 1)], "a👨‍👩‍👧b\n🇧🇬🇺🇸x|", "a family and flags"),
            ("ab|c\u{2028}def", [(0, 1)], "abc\u{2028}de|f", "a line separator too"),
            ("ab|c\ndefg", [(1, 1)], "abc\ndef|g", "a diagonal moves both"),
            ("abcdef|\nab\nabcdefgh", [(0, 1), (-1, 0), (0, 1)], "abcdef\nab\na|bcdefgh",
             "a sideways step sets a new column"),
            (long + "\n" + x30 + "|" + long.dropFirst(30), [(0, -1)], x30 + "|" + long.dropFirst(30) + "\n" + long,
             "up into a line longer than Safari's windows"),
            (x30 + "|" + long.dropFirst(30) + "\n" + long, [(0, 1)], long + "\n" + x30 + "|" + long.dropFirst(30),
             "and down"),
            (String(repeating: "x", count: 90) + "|xxxxxxxxxx\n" + String(repeating: "😀", count: 100), [(0, 1)],
             String(repeating: "x", count: 100) + "\n" + String(repeating: "😀", count: 90) + "|😀😀😀😀😀😀😀😀😀😀",
             "a column past Safari's window"),
        ]
        for (s, moves, want, why) in cases {
            for kit in [true, false] {
                for cut in [true, false] {
                    for perRefresh in [0, 1] {
                        for wrap in [nil, 1000] {
                            XCTAssertEqual(lined(s, kit: kit, cut: cut, moves, perRefresh: perRefresh, wrap: wrap, why), want,
                                           "\(why) kit \(kit) cut \(cut) lag \(perRefresh) wrap \(wrap ?? 0)")
                        }
                    }
                }
            }
        }
    }

    /// A line move from far into a line whose start the context doesn't reach, cut at a
    /// sentence (a UITextView) or by a window (Safari), keeps the caret's true column.
    func testLineMovesKeepAColumnTheContextCutsOff() {
        let x120 = String(repeating: "x", count: 120), x30 = String(repeating: "x", count: 30)
        let long = x120 + x30, abc = "abcdefghijklmnop"
        let cases: [(String, [(Int, Int)], String, String)] = [
            (abc + "\nOne. Two. Th|ree.", [(0, -1)], "abcdefghijkl|mnop\nOne. Two. Three.", "up from a cut sentence"),
            ("One. Two. Th|ree.\n" + abc, [(0, 1)], "One. Two. Three.\nabcdefghijkl|mnop", "down from one"),
            ("ab\nOne. Two. Th|ree.\n" + abc, [(0, 1)], "ab\nOne. Two. Three.\nabcdefghijkl|mnop", "down, a line above"),
            (abc + "\nab\nOne. Two. Th|ree.", [(0, -2)], "abcdefghijkl|mnop\nab\nOne. Two. Three.", "up 2 past a short line"),
            (long + "\n" + x120 + "|" + x30, [(0, -1)], x120 + "|" + x30 + "\n" + long, "up from past a window"),
            ("ab\n" + x120 + "|" + x30 + "\n" + long, [(0, 1)], "ab\n" + long + "\n" + x120 + "|" + x30, "down from past one"),
        ]
        for (s, moves, want, why) in cases {
            for kit in [true, false] {
                for cut in [true, false] {
                    for perRefresh in [0, 1] {
                        for wrap in [nil, 1000] {
                            XCTAssertEqual(lined(s, kit: kit, cut: cut, moves, perRefresh: perRefresh, wrap: wrap, why,
                                                 tweak: { $0.sentenceBefore = kit }), want,
                                           "\(why) kit \(kit) cut \(cut) lag \(perRefresh) wrap \(wrap ?? 0)")
                        }
                    }
                }
                XCTAssertEqual(lined("ab\nOne. Two. Th|ree.\nabc", kit: kit, [(0, 1), (0, -1)], fast: true,
                                     tweak: { $0.sentenceBefore = kit }),
                               "ab\nOne. Two. Th|ree.\nabc", "down and up before the column shows: back where it was")
            }
        }
    }

    /// Safari's space after a break its context opens on is no Character of the line: the
    /// column doesn't count it and an up move doesn't cross a line more for it.
    func testLineMovesSeePastSafarisSpaceAfterABreak() {
        let cases: [(String, Int, String, String)] = [
            ("xy\n\nOne two thr|ee", -1, "xy\n|\nOne two three", "up onto an empty line"),
            ("abcdefghijklmnop\nOne two thr|ee", -1, "abcdefghijk|lmnop\nOne two three", "up at the column"),
            ("abc\nOne t|wo\nxyzxyzxyz", 1, "abc\nOne two\nxyzxy|zxyz", "down at the column"),
        ]
        for (s, n, want, why) in cases {
            for cut in [true, false] {
                for perRefresh in [0, 1] {
                    for wrap in [nil, 1000] {
                        XCTAssertEqual(lined(s, kit: false, cut: cut, [(0, n)], perRefresh: perRefresh, wrap: wrap, why,
                                             tweak: { $0.breakSpace = true }),
                                       want, "\(why) cut \(cut) lag \(perRefresh) wrap \(wrap ?? 0)")
                    }
                }
            }
        }
    }

    /// A line move whose landing the context shows goes there in one move, with no stop at a
    /// line's end on the way, in Safari and a UIKit host showing whole contexts, lagging or
    /// not; one it doesn't show (the text's first line, a last line shorter than the column,
    /// an after-context cut at the line's end) goes in legs as before. Each starts past a
    /// break, so the column shows.
    func testALineMoveTheContextShowsGoesInOneMove() {
        let cases: [(String, [(Int, Int)], String, [Int]?, Bool, String)] = [
            ("abc\nabcdef\nab|cdef", [(0, -1)], "abc\nab|cdef\nabcdef", [-7], true, "up"),
            ("x\nab|cdef\nabcdef\nabc", [(0, 1)], "x\nabcdef\nab|cdef\nabc", [7], false, "down"),
            ("x\nabc\nabcdef|", [(0, -1)], "x\nabc|\nabcdef", [-7], true, "up onto a shorter line: its end"),
            ("x\nabcdef|\nabc\nx", [(0, 1)], "x\nabcdef\nabc|\nx", [4], false, "down onto one"),
            ("x\nabcdefgh\nab\nabc|def", [(0, -2)], "x\nabc|defgh\nab\nabcdef", [-12], true, "up 2"),
            ("x\nabcdef\nab\nabcd|ef", [(0, -1), (0, -1)], "x\nabcd|ef\nab\nabcdef", [-5, -5], true,
             "up, and up again: the column back past a short line"),
            ("x\nab|c\ndef", [(0, 1)], "x\nabc\nde|f", [4], false, "down onto the last line"),
            ("abc\nde|f", [(0, -1)], "ab|c\ndef", nil, true, "up onto the first line: its start unseen"),
            ("x\nabcdef|\nab", [(0, 1)], "x\nabcdef\nab|", nil, false, "down onto a short last line: its end unseen"),
            ("x\nab|c\ndef", [(0, 1)], "x\nabc\nde|f", nil, true, "down past an after-context cut at the line's end"),
        ]
        for (s, moves, want, sent, cut, why) in cases {
            for kit in [true, false] {
                for perRefresh in [0, 1] {
                    var doc: FakeProxy?
                    let got = lined(s, kit: kit, cut: cut, moves, perRefresh: perRefresh, why,
                                    tweak: { $0.lineBefore = false; doc = $0 })
                    let at = "\(why) kit \(kit) lag \(perRefresh)"
                    XCTAssertEqual(got, want, at)
                    if let sent { XCTAssertEqual(doc?.moves, sent, at) } else { XCTAssertGreaterThan(doc?.moves.count ?? 0, 1, at) }
                }
            }
        }
    }

    /// The moves a line move up and down sends in each host's model, lagging or not:
    /// Safari's textarea, whose before-context spans lines (QA: about 3), goes up in one;
    /// a UITextView's, cut at the caret's line or sentence, and Safari's paragraph, opening
    /// on the caret line's break, never show the line above whole and go in legs; so does
    /// down wherever the after-context stops at the line's end, as every host's does.
    func testLineMovesPerHost() {
        let s = "zero\nfirst line here\nsecond| line text\nthird line, longer one", parts = s.components(separatedBy: "|")
        let models: [(String, Bool, (FakeProxy) -> Void, up: [Int], down: [Int])] = [
            ("UITextView", true, { _ in }, [-6, -1, -15, 6], [-6, 16, 1, 6]),
            ("Safari textarea", false, { $0.stopsAtLineEnd = true }, [-16], [10, 1, 6]),
            ("Safari paragraph", false, { $0.stopsAtLineEnd = true; $0.breakSpace = true }, [-7, -9], [10, 1, 6]),
            ("whole contexts", false, { $0.window = nil }, [-16], [17]),
        ]
        for (name, kit, tweak, up, down) in models {
            for (n, want) in [(-1, up), (1, down)] {
                for lag in [false, true] {
                    let doc = host(kit: kit, parts[0], parts[1])
                    tweak(doc)
                    doc.lags = lag
                    var walk = CaretWalk(), polls = 0
                    func step(_ l: Int) {
                        let u = walk.step(0, lines: l, before: doc.documentContextBeforeInput ?? "",
                                          after: doc.documentContextAfterInput ?? "", settled: polls >= 3)
                        if u != 0 { doc.adjustTextPosition(byCharacterOffset: u); polls = 0 }
                    }
                    step(n)
                    for _ in 0..<400 where !walk.idle { doc.catchUp(); polls += 1; walk.poll(); step(0) }
                    XCTAssertEqual(doc.moves, want, "\(name) \(n) lag \(lag)")
                }
            }
        }
    }

    /// A drag faster than the host: the line moves add up or cancel out, and the sideways
    /// steps asked during one wait for its landing, so a wobble never knocks it off its
    /// line, then set a new column.
    func testSidewaysStepsWaitForALineMoveToLand() {
        let cases: [(String, [(Int, Int)], String, String)] = [
            ("ab|c\nxyz\nmnop", [(0, 1), (-1, 0), (0, 1)], "abc\nxyz\nm|nop", "two down, then the step"),
            ("abc\n|xyz", [(0, -1), (1, 0)], "a|bc\nxyz", "up, then the step"),
            ("abcdef|\nab\nabcdefgh", [(0, 1), (-1, 0), (0, 0), (0, 1)], "abcdef\nab\na|bcdefgh",
             "the held step sets a new column"),
            ("abc\nde|f", [(0, -1), (0, 1)], "abc\nde|f", "up and down: back at the column"),
            ("abc\nxyz\nm|nop", [(0, -2), (0, 1)], "abc\nx|yz\nmnop", "up 2, down 1: the line above"),
        ]
        for (s, moves, want, why) in cases {
            for kit in [true, false] {
                for perRefresh in [0, 1] {
                    XCTAssertEqual(lined(s, kit: kit, moves, perRefresh: perRefresh, fast: true, why), want,
                                   "\(why) kit \(kit) lag \(perRefresh)")
                }
            }
        }
    }

    /// Through the view: a space-hold drag in a lagging UITextView moves by line, keeping
    /// its column through a short line, a diagonal moves both ways, and a new hold starts
    /// from the caret's own column. No text changes.
    func testTrackpadMovesByLineThroughTheProxy() throws {
        let kb = TerminalKeyboard(), doc = host(kit: true, "first line\nab\nthird", " line")
        kb.target = doc
        let space = try XCTUnwrap(laidOut(kb)["space"]).frame
        func drag(_ moves: [(CGFloat, CGFloat)]) {
            var p = CGPoint(x: space.midX, y: space.midY)
            doc.lags = true
            kb.track(.began, id: 1, at: p)
            kb.fireHold()
            for m in moves {
                p.x += m.0 * KeyTouchTracker.caretStep
                p.y += m.1 * KeyTouchTracker.lineStep
                kb.track(.moved, id: 1, at: p)
                kb.pollCaret()
            }
            kb.track(.ended, id: 1, at: p)
            for _ in 0..<100 { doc.catchUp(); kb.pollCaret() }
        }
        drag([(0, -1), (0, -1)])
        XCTAssertEqual(doc.text, "first", "up 2 through the short line, at its column")
        drag([(0, 1.5)])
        XCTAssertEqual(doc.text, "first line\nab", "the short line's end")
        drag([(0, -1)])
        XCTAssertEqual(doc.text, "first", "a new hold keeps the column, as iOS's arrows do")
        drag([(1, 1), (0, 1)])
        XCTAssertEqual(doc.text, "first line\nab\nthird ", "right and down, then down at that column")
        XCTAssertEqual(doc.text + (doc.after ?? ""), "first line\nab\nthird line", "no text typed")
        XCTAssertNil(kb.walkTimer)
    }

    /// The operator's repro (build 100): one paragraph a chat composer wraps to three rows,
    /// no break, the toolbar's ↓ from its first row through a host that lags. The walk went
    /// back to the text's start to count the column, on to its end (its only line's), probed
    /// past it blind and, 0.3 s after the host went quiet, walked back where it began. Now ↓
    /// goes a guessed row (`wrapGuess`) at a time, the last to the text's end, where it stays;
    /// ↑ the same way back to the start. The caret never goes back the way it came.
    func testTheToolbarsArrowsGoARowAtATimeInAWrappedParagraph() throws {
        let para = "това е дълъг абзац без нов ред, който полето за писане пренася на три реда, защото не се побира в ширината му"
        let start = "това е дълъг ".count
        for kit in [true, false] {
            let kb = TerminalKeyboard()
            _ = laidOut(kb)
            let w = try XCTUnwrap(kb.wrapGuess)
            let doc = host(kit: kit, String(para.prefix(start)), String(para.dropFirst(start)))
            kb.target = doc
            doc.lags = true
            func press(_ n: Int) -> (Int, [Int]) {
                let from = doc.stops.count
                kb.line(n)
                for i in 0..<120 { if i % 5 == 4 { doc.catchUp() }; kb.pollCaret() }
                return (doc.text.count, Array(doc.stops[from...]))
            }
            let (one, legs) = press(1)
            XCTAssertEqual(one, start + w, "kit \(kit): one row down, in one move")
            XCTAssertEqual(legs, [start + w], "kit \(kit)")
            for _ in 0..<3 { _ = press(1) }
            XCTAssertEqual(doc.text.count, para.count, "kit \(kit): the last row's ↓ goes to the end and stays")
            XCTAssertEqual(doc.stops, doc.stops.sorted(), "kit \(kit): never back the way it came")
            let down = doc.stops.count
            for _ in 0..<4 { _ = press(-1) }
            XCTAssertEqual(doc.text.count, 0, "kit \(kit): up to the start")
            XCTAssertEqual(Array(doc.stops[down...]), doc.stops[down...].sorted(by: >), "kit \(kit)")
            XCTAssertNil(kb.walkTimer, "kit \(kit)")
        }
    }

    /// The row guess at the operator's width: about what a field 20 pt in a side holds of
    /// body text (the repro's rows held 41 and 49), a little under, as word wrap is.
    func testTheRowGuessFitsAPhonesField() {
        let kb = TerminalKeyboard()
        _ = laidOut(kb, width: 402)
        XCTAssertNotNil(kb.wrapGuess)
        XCTAssertTrue((30...50).contains(kb.wrapGuess ?? 0), "\(kb.wrapGuess ?? 0)")
        kb.frame = .zero
        XCTAssertNil(kb.wrapGuess, "nothing to guess from")
    }

    /// QA's M3: unsure, the guess goes short rather than skip rows: a text size under large
    /// guesses as large does, one above it shorter, as a Dynamic Type host's rows are.
    func testTheRowGuessNeverGrowsPastLargeTexts() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let kb = TerminalKeyboard()
        _ = laidOut(kb, width: 402)
        func guess(_ size: UIContentSizeCategory) -> Int {
            kb.traitOverrides.preferredContentSizeCategory = size
            kb.updateTraitsIfNeeded()
            return kb.wrapGuess ?? 0
        }
        let large = guess(.large)
        XCTAssertEqual(guess(.extraSmall), large, "under large: as large")
        XCTAssertLessThan(guess(.accessibilityMedium), large, "above: shorter")
    }

    /// Rows of 10 in either host, lagging or not, its after-context cut at the line's end or
    /// not: a line move goes a row inside a wrapped line, keeps the goal's place in the row
    /// through a short last row, crosses a break to the next line's first row or the last
    /// line's last, takes a short line as one row, and stays at the text's edges.
    func testLineMovesGoARowInAWrappedLine() {
        let p = "abcdefghijklmnopqrstuvwxy", q = "ABCDEFGHIJKLMNOPQRSTUVWXY"
        func at(_ s: String, _ i: Int) -> String { String(s.prefix(i)) + "|" + s.dropFirst(i) }
        let two = p + "\n" + q
        let cases: [(String, [(Int, Int)], String, String)] = [
            (at(p, 3), [(0, 1)], at(p, 13), "down a row"),
            (at(p, 3), [(0, 2)], at(p, 23), "down 2 rows"),
            (at(p, 23), [(0, -1)], at(p, 13), "up a row"),
            (at(p, 17), [(0, 1)], at(p, 25), "onto a shorter last row: its end"),
            (at(p, 23), [(0, 1)], at(p, 25), "down on the last row: the text's end"),
            (at(p, 3), [(0, -1)], at(p, 0), "up on the first row: the text's start"),
            (at(p, 13), [(0, 1), (0, -1)], at(p, 13), "down and back"),
            (at(two, 26 + 3), [(0, -1)], at(two, 23), "up over a break: the last row"),
            (at(two, 23), [(0, 1)], at(two, 26 + 3), "down over a break: the first row"),
            (at(two, 13), [(0, 2)], at(two, 26 + 3), "a row, then over the break"),
            (at(two, 17), [(0, 1), (0, 1)], at(two, 26 + 7), "the place in the row kept past a short row"),
            (at(two, 26 + 13), [(0, -3)], at(two, 13), "three up, over the break"),
            ("ab|\n" + p, [(0, 1)], "ab\nab|" + p.dropFirst(2), "a short line is one row"),
            (p + "\nab|", [(0, -1)], at(p, 22) + "\nab", "up from one: the last row"),
        ]
        for (s, moves, want, why) in cases {
            for kit in [true, false] {
                for cut in [true, false] {
                    for perRefresh in [0, 1] {
                        XCTAssertEqual(lined(s, kit: kit, cut: cut, moves, perRefresh: perRefresh, wrap: 10, why), want,
                                       "\(why) kit \(kit) cut \(cut) lag \(perRefresh)")
                    }
                }
            }
        }
    }

    /// A wrapped line's rows go by the goal's place in them, not the caret's: ↓ from column 9
    /// clamped at a 45-Character line's end, then ↑, is back at 9, not 45's place, 4 (QA's
    /// M849), where the line's start shows. ↑ into a line whose start the context cuts, in pieces shorter than a row, counts
    /// what it walked back to that start (`.start`), so it lands in the line's last row, not
    /// its first (M853). `reach` into a line shown whole lands in its last row too (M852).
    func testWrappedRowsGoByTheGoalsPlace() {
        let x45 = String(repeating: "x", count: 45), l0 = "The first sentence is here. And the second one goes on for a while"
        for kit in [true, false] {
            for perRefresh in [0, 1] {
                let at = "kit \(kit) lag \(perRefresh)"
                XCTAssertEqual(lined("ab\nxxxxxxxxx|" + x45.dropFirst(9), kit: kit, [(0, 1), (0, -1)], perRefresh: perRefresh,
                                     wrap: 41, tweak: { $0.lineBefore = false }),
                               "ab\nxxxxxxxxx|" + x45.dropFirst(9), "M849 \(at)")
                XCTAssertEqual(lined(l0 + "\nmi|d", kit: kit, [(0, -1)], perRefresh: perRefresh, wrap: 41,
                                     tweak: { kit ? ($0.sentenceBefore = true) : ($0.window = 20) }),
                               String(l0.prefix(43)) + "|" + l0.dropFirst(43) + "\nmid", "M853 \(at)")
            }
        }
        let long = String(repeating: "abcdefghij", count: 13) + "abc", before = Array("\n" + long + "\nmid")
        XCTAssertEqual(CaretWalk.reach(-1, column: 50, wrap: 41, before: before, after: []), 1 + 132 - before.count,
                       "M852: column 132, the goal's place (9) in the last row")
    }

    /// The goal column outlives a touch, in either host, lagging or not: a line move from a
    /// short line a new touch began on goes on at the column the last one aimed for, in text
    /// lines and wrapped rows alike. A sideways step still sets a new one.
    func testTheGoalColumnOutlivesATouch() {
        let p = "abcdefghijklmnopqrstuvwxy", q = "ABCDEFGHIJKLMNOPQRSTUVWXY", three = p + "\nab\n" + q
        func at(_ s: String, _ i: Int) -> String { String(s.prefix(i)) + "|" + s.dropFirst(i) }
        let cases: [(String, [(Int, Int)], Int?, String, String)] = [
            ("the long line| one\nmid\nthe long line two", [(0, 1), (0, 1)], nil,
             "the long line one\nmid\nthe long line| two", "down, a touch, down"),
            ("the long line one\nmid\nthe long line| two", [(0, -1), (0, -1)], nil,
             "the long line| one\nmid\nthe long line two", "up, a touch, up"),
            ("the long line| one\nmid\nthe long line two", [(0, 1), (-1, 0), (0, 1)], nil,
             "the long line one\nmid\nth|e long line two", "a sideways step between: its column"),
            (at(three, 17), [(0, 1), (0, 1), (0, 1)], 10, at(three, 36), "wrapped rows through a short line"),
        ]
        for (s, moves, wrap, want, why) in cases {
            for kit in [true, false] {
                for cut in [true, false] {
                    for perRefresh in [0, 1] {
                        XCTAssertEqual(lined(s, kit: kit, cut: cut, moves, perRefresh: perRefresh, wrap: wrap, touch: true, why),
                                       want, "\(why) kit \(kit) cut \(cut) lag \(perRefresh)")
                    }
                }
            }
        }
    }

    /// Through the view, long, short, long lines: ↓ by a space-hold drag, then a new hold's
    /// ↓, lands at the first line's column; so do two toolbar taps.
    func testTheGoalColumnOutlivesAHoldAndAToolbarTap() throws {
        let start = "the long line", rest = " one\nmid\nthe long line two"
        let want = "the long line one\nmid\nthe long line"
        for kit in [true, false] {
            let kb = TerminalKeyboard(), doc = host(kit: kit, start, rest)
            kb.target = doc
            let space = try XCTUnwrap(laidOut(kb)["space"]).frame
            func drag() {
                let p = CGPoint(x: space.midX, y: space.midY)
                doc.lags = true
                kb.track(.began, id: 1, at: p)
                kb.fireHold()
                let to = CGPoint(x: p.x, y: p.y + KeyTouchTracker.lineStep)
                kb.track(.moved, id: 1, at: to)
                kb.track(.ended, id: 1, at: to)
                for _ in 0..<100 { doc.catchUp(); kb.pollCaret() }
            }
            drag()
            XCTAssertEqual(doc.text, "the long line one\nmid", "kit \(kit)")
            drag()
            XCTAssertEqual(doc.text, want, "kit \(kit): the hold's column")
            let bar = host(kit: kit, start, rest)
            kb.target = bar
            for _ in 0..<2 { kb.line(1); for _ in 0..<100 { bar.catchUp(); kb.pollCaret() } }
            XCTAssertEqual(bar.text, want, "kit \(kit): the taps' column")
        }
    }

    /// The host moving the caret between two toolbar taps (the user tapped the field): the
    /// next ↓ goes from that column, not the one the last tap aimed for.
    func testAHostCaretMoveDropsTheGoalColumn() {
        for kit in [true, false] {
            let kb = TerminalKeyboard()
            let doc = host(kit: kit, "the long line", " one\nmid\nthe long line two\nthe long line three")
            kb.target = doc
            kb.line(1)
            for _ in 0..<100 { doc.catchUp(); kb.pollCaret() }
            XCTAssertEqual(doc.text, "the long line one\nmid", "kit \(kit)")
            doc.text = "the long line one\nmid\nthe "; doc.after = "long line two\nthe long line three"
            kb.line(1)
            for _ in 0..<100 { doc.catchUp(); kb.pollCaret() }
            XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "the long line one\nmid\nthe long line two\nthe |long line three",
                           "kit \(kit): from the tapped column, moves \(doc.moves)")
        }
    }

    /// QA's M1: a UITextView the walk went idle on before it answered, UIKit's guess showing
    /// the after-context past the line's end where the host's answer, later, shows none. Long
    /// line, "x", long line: ↑ from column 20 lands at "x|", and once the host has answered,
    /// the next ↑ goes on at column 20, not 1. A typed letter or a sideways step between them
    /// still sets the column (as a host tap does, `testAHostCaretMoveDropsTheGoalColumn`).
    func testAHostsLateAnswerKeepsTheGoalColumn() {
        let top = "the first line of text, long", low = "and here is another long line"
        func landed() -> (TerminalKeyboard, FakeProxy) {
            let kb = TerminalKeyboard(), doc = host(kit: true, top + "\nx\n" + low.prefix(20), String(low.dropFirst(20)))
            doc.guessesPastLineEnd = true
            kb.target = doc
            kb.line(-1)
            for _ in 0..<100 { kb.pollCaret() }   // the host answers none of it yet
            XCTAssertEqual(doc.text, top + "\nx")
            doc.answer()
            return (kb, doc)
        }
        func up(_ kb: TerminalKeyboard, _ doc: FakeProxy) -> String {
            kb.line(-1)
            for _ in 0..<100 { kb.pollCaret() }
            return doc.text + "|" + (doc.after ?? "")
        }
        let (kb, doc) = landed()
        XCTAssertEqual(up(kb, doc), top.prefix(20) + "|" + top.dropFirst(20) + "\nx\n" + low, "moves \(doc.moves)")
        let typed = landed()
        typed.0.press(.char("y"))
        XCTAssertEqual(up(typed.0, typed.1), "th|" + top.dropFirst(2) + "\nxy\n" + low, "a typed letter: its column")
        let stepped = landed()
        stepped.0.caret(-1)
        for _ in 0..<100 { stepped.1.catchUp(); stepped.0.pollCaret() }
        XCTAssertEqual(up(stepped.0, stepped.1), "|" + top + "\nx\n" + low, "a sideways step: its column")
    }

    /// QA's BLOCK finding: a UITextView answering 240 ms late whose first ↓ went in legs sized
    /// from UIKit's guesses, answered one by one, shows a lag past 0.3 s. The walk waits that
    /// long from then on, so the next ↓'s blind crossing past a short line's end, answered
    /// inside it, is no text's end: it lands at the column, not the next line's start.
    func testALineMoveWaitsOutTheLagAHostShowed() {
        let text = ["the first line of text here, a long one with words", "x", "and here is another long line of words to go on"]
        func at(_ line: Int, _ col: Int) -> String {
            var lines = text
            lines[line].insert("|", at: lines[line].index(lines[line].startIndex, offsetBy: col))
            return lines.joined(separator: "\n")
        }
        var walk = CaretWalk()
        XCTAssertEqual(slow(at(0, 30), lines: 1, delay: 12, walk: &walk).0, at(1, 1))
        XCTAssertEqual(slow(at(1, 1), lines: 1, delay: 12, walk: &walk).0, at(2, 30))
    }

    /// Fast repeated steps, each asked before the last has landed (a quick drag, a tapped
    /// arrow), lagging or not: each is one line or row, never more, in logical lines and in
    /// a wrapped one.
    func testFastLineStepsGoOneEach() {
        let lines = "a|bc\nabc\nabc\nabc\nabc", p = String(repeating: "abcdefghij", count: 5)
        for kit in [true, false] {
            for perRefresh in [0, 1] {
                XCTAssertEqual(lined(lines, kit: kit, [(0, 1), (0, 1), (0, 1)], perRefresh: perRefresh, fast: true),
                               "abc\nabc\nabc\na|bc\nabc", "three lines, kit \(kit) lag \(perRefresh)")
                XCTAssertEqual(lined("ab|" + p.dropFirst(2), kit: kit, [(0, 1), (0, 1), (0, 1)], perRefresh: perRefresh,
                                     fast: true, wrap: 10),
                               String(p.prefix(32)) + "|" + p.dropFirst(32), "three rows, kit \(kit) lag \(perRefresh)")
            }
        }
    }

    /// The toolbar's ↑ through the view, once, on a host whose context lags several polls,
    /// or shows only a window or the caret's sentence: exactly one line up, at the column,
    /// with no stop on the line past it.
    func testOneUpThroughALaggingOrCutContextGoesOneLine() {
        let models: [(String, Bool, (FakeProxy) -> Void)] = [
            ("UITextView", true, { _ in }),
            ("UIKit, cut at a sentence", true, { $0.lineBefore = false; $0.sentenceBefore = true }),
            ("Safari, small windows", false, { $0.window = 6; $0.stopsAtLineEnd = true }),
            ("Safari paragraph", false, { $0.breakSpace = true; $0.stopsAtLineEnd = true }),
        ]
        for (name, kit, tweak) in models {
            let kb = TerminalKeyboard(), doc = host(kit: kit, "zero line\nOne. Two words\nAnd. More text h", "ere\nlast")
            kb.target = doc
            tweak(doc)
            doc.lags = true
            kb.line(-1)
            for i in 0..<200 { if i % 4 == 3 { doc.catchUp() }; kb.pollCaret() }
            XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "zero line\nOne. Two words|\nAnd. More text here\nlast", name)
            XCTAssertTrue(doc.stops.allSatisfy { (10...44).contains($0) },
                          "\(name): never on another line, stops \(doc.stops)")
            XCTAssertNil(kb.walkTimer, name)
        }
    }

    /// A line move with nowhere to go sends nothing and ends nothing: the word touch
    /// correction continues stays open and the suggestions hear of no move (QA's M188).
    /// One that goes ends them once.
    func testALineMoveWithNowhereToGoEndsNothing() {
        let kb = TerminalKeyboard(), doc = host(kit: true, "")
        kb.target = doc
        var moved = 0
        kb.didMoveCaret = { moved += 1 }
        kb.press(.char("a")); kb.press(.char("b"))
        doc.after = doc.text; doc.text = ""   // the user tapped the caret to the start
        kb.line(-1)
        for _ in 0..<40 { kb.pollCaret() }
        XCTAssertEqual(doc.moves, [])
        XCTAssertEqual(kb.word, "ab")
        XCTAssertEqual(moved, 0)
        kb.line(1)
        for _ in 0..<40 { kb.pollCaret() }
        XCTAssertEqual(doc.moves, [2, 1], "to the end, nothing past it: stays there")
        XCTAssertEqual(kb.word, "")
        XCTAssertEqual(moved, 1)
    }

    /// A line move that sent nothing is forgotten by the next touch: a step then ends the
    /// word once, not again for the line move.
    func testALineMoveThatSentNothingEndsWithItsTouch() throws {
        let kb = TerminalKeyboard(), doc = host(kit: true, "", "ab")
        kb.target = doc
        let space = try XCTUnwrap(laidOut(kb)["space"]).frame, p = CGPoint(x: space.midX, y: space.midY)
        var moved = 0
        kb.didMoveCaret = { moved += 1 }
        kb.line(-1)
        kb.track(.began, id: 1, at: p)
        kb.track(.cancelled, id: 1, at: p)
        kb.caret(1)
        XCTAssertEqual(doc.moves, [1])
        XCTAssertEqual(moved, 1)
    }

    /// A UITextView answering each caret move `delay` polls (20 ms each) late, one move at a
    /// time as a busy main thread does, in ASCII text: until it answers, its proxy shows its
    /// guess, the window it showed last with the caret moved inside it, so a side a move
    /// took all of reads empty. Its windows, cut as
    /// UIKit's: before, back to the caret line's break; after, to the end of the caret's
    /// sentence (". ") or line. `wide`: the first window's before reaches back over all the
    /// text, as one left from an earlier caret can. `sentences`: the before goes back that
    /// many sentence starts instead (after ". " or a break, the break unshown at the
    /// window's start), as QA's UIKit host's does: right after a break ("Uno d"), or at a
    /// line's last sentence ("Siete ocho nueve diez").
    private struct SlowKit {
        let text: [Character], delay: Int, sentences: Int
        private(set) var at: Int
        private(set) var shown = ("", "")
        private var due: [(poll: Int, at: Int)] = [], polls = 0, free = 0

        init(_ s: String, delay: Int, wide: Bool, sentences: Int = 0) {
            let parts = s.components(separatedBy: "|")
            text = Array(parts.joined())
            at = parts[0].count
            self.delay = delay
            self.sentences = sentences
            shown = window(at)
            if wide { shown.0 = parts[0] }
        }

        func window(_ i: Int) -> (String, String) {
            var end = i
            while end < text.count, text[end] != "\n" {
                end += 1
                if end > 1, text[end - 2] == ".", text[end - 1] == " " { break }
            }
            let starts = (0..<i).filter { $0 == 0 || text[$0 - 1] == "\n" || ($0 > 1 && text[$0 - 2] == "." && text[$0 - 1] == " ") }
            let start = sentences == 0 ? text[..<i].lastIndex(of: "\n") ?? 0 : starts.dropLast(sentences - 1).last ?? 0
            return (String(text[start..<i]), String(text[i..<end]))
        }

        mutating func move(_ n: Int) {
            at = min(max(at + n, 0), text.count)
            free = max(polls, free) + delay
            due.append((free, at))
            let (b, a) = shown
            shown = n > 0 ? (b + a.prefix(n), String(a.dropFirst(n))) : (String(b.dropLast(-n)), b.suffix(-n) + a)
        }

        /// One poll's time: the answers due by now show.
        mutating func tick() {
            polls += 1
            while let d = due.first, d.poll < polls { shown = window(d.at); due.removeFirst() }
        }
    }

    /// `s` with `|` at the caret in a `SlowKit`, after a line move of `lines` through a walk
    /// polled as the view polls it: the text with `|` where the host's caret ended, the
    /// polls it took, and the most in a row with nothing sent.
    private func slow(_ s: String, lines: Int, delay: Int, wide: Bool = false) -> (String, Int, Int) {
        var walk = CaretWalk()
        return slow(s, lines: lines, delay: delay, wide: wide, walk: &walk)
    }

    /// The same through `walk`, which keeps what it learned of the host, as the view's does
    /// from hold to hold in one field.
    private func slow(_ s: String, lines: Int, delay: Int, wide: Bool = false, sentences: Int = 0,
                      walk: inout CaretWalk) -> (String, Int, Int) {
        var host = SlowKit(s, delay: delay, wide: wide, sentences: sentences), polls = 0, total = 0, wait = 0
        walk.drop()
        func step(_ n: Int) {
            let units = walk.step(0, lines: n, before: host.shown.0, after: host.shown.1, settled: polls >= 3)
            if units != 0 { host.move(units); polls = 0 }
        }
        step(lines)
        for _ in 0..<400 where !walk.idle {
            host.tick(); polls += 1; total += 1; wait = max(wait, polls); walk.poll(); step(0)
        }
        XCTAssertTrue(walk.idle)
        return (String(host.text[..<host.at]) + "|" + String(host.text[host.at...]), total, wait)
    }

    /// QA's 489r finding 1: a UITextView that answers each move late, whose proxy cuts its
    /// after-context at a sentence. UIKit's guess right after a move to a sentence's end
    /// shows nothing after it, which is no line's end; and the host's late answer to the
    /// move before a blind crossing is no landing past the break. Down lands on its line
    /// and column at every lag, and up as it did. A host answering by the next poll never
    /// waits out the poll limit for it.
    func testASlowUITextViewLandsLineMovesOnTheirLine() {
        let text = ["north south east west up down left right", "Uno dos. Tres cuatro. Cinco seis. Siete ocho nueve diez",
                    "a slow grey cat naps on the warm sunny mat", "end"]
        func at(_ line: Int, _ col: Int) -> String {
            var lines = text
            lines[line].insert("|", at: lines[line].index(lines[line].startIndex, offsetBy: col))
            return lines.joined(separator: "\n")
        }
        let cases: [(from: (Int, Int), lines: Int, to: (Int, Int), why: String)] = [
            ((1, 40), 1, (2, 40), "down 1 from the last sentence"),
            ((0, 40), 2, (2, 40), "down 2 over a line of sentences"),
            ((1, 40), 2, (3, 3), "down 2 onto a short line"),
            ((0, 30), 1, (1, 30), "down 1 into the third sentence"),
            ((1, 10), 1, (2, 10), "down 1 from a sentence before the line's last, a fresh field's first leg"),
            ((2, 30), -1, (1, 30), "up 1 into it"),
            ((3, 3), -3, (0, 3), "up 3"),
            ((2, 40), -2, (0, 40), "up 2 over it"),
        ]
        for c in cases {
            for delay in 0...5 {
                for wide in [false, true] {
                    let (got, polls, _) = slow(at(c.from.0, c.from.1), lines: c.lines, delay: delay, wide: wide)
                    XCTAssertEqual(got, at(c.to.0, c.to.1), "\(c.why) delay \(delay) wide \(wide)")
                    if delay == 0 { XCTAssertLessThan(polls, 16, "\(c.why) wide \(wide): no wait at once") }
                }
            }
        }
        for delay in 0...5 {
            XCTAssertEqual(slow("Ends he|re. \nnext line", lines: 1, delay: delay).0, "Ends here. \nnext li|ne",
                           "a line that does end at a sentence's space: crossed at the poll limit, delay \(delay)")
        }
    }

    /// QA's 489r3 F1: up moves on a UITextView answering 50-80 ms late (delays 2-5), whose
    /// before-context is cut at a sentence's start or right after a break, run as QA's
    /// sweep did, twice over in one field after a first move down. The host's late answer
    /// to one leg is never taken for the next one's landing (shape A), and once it has shown
    /// its lag, a guess's empty before is never read as the line's start (B) or the text's
    /// (C). A host answering by the next poll never waits out the poll limit.
    func testASlowUITextViewLandsUpMovesOnTheirLine() {
        let text = ["north south east west up down left right", "Uno dos. Tres cuatro. Cinco seis. Siete ocho nueve diez",
                    "a slow grey cat naps on the warm sunny mat", "the end"]
        func at(_ line: Int, _ col: Int) -> String {
            var lines = text
            lines[line].insert("|", at: lines[line].index(lines[line].startIndex, offsetBy: col))
            return lines.joined(separator: "\n")
        }
        let cases: [(from: (Int, Int), lines: Int, to: (Int, Int), why: String)] = [
            ((0, 5), 1, (1, 5), "down 1, the field's first move"),
            ((2, 40), -1, (1, 40), "up 1 into the last sentence"),
            ((3, 5), -3, (0, 5), "up 3"),
            ((2, 25), -1, (1, 25), "up 1 into the third sentence"),
            ((1, 25), -1, (0, 25), "and onto the first line"),
        ]
        for delay in 0...6 {
            for sentences in [1, 2] {
                var walk = CaretWalk()
                for run in 1...2 {
                    for c in cases {
                        let (got, _, wait) = slow(at(c.from.0, c.from.1), lines: c.lines, delay: delay, sentences: sentences, walk: &walk)
                        let why = "\(c.why) delay \(delay) sentences \(sentences) run \(run)"
                        XCTAssertEqual(got, at(c.to.0, c.to.1), why)
                        if delay == 0 { XCTAssertLessThan(wait, 16, "\(why): no wait at once") }
                    }
                }
            }
        }
        for delay in 1...3 {
            var walk = CaretWalk()
            XCTAssertEqual(slow(at(2, 40), lines: -1, delay: delay, sentences: 2, walk: &walk).0, at(1, 40),
                           "a fresh field: the late answer to the crossing is no landing, delay \(delay)")
        }
    }

    /// The lag a host showed is the most it has: a faster answer since doesn't shorten it
    /// (QA's M625), and no landing is believed until a poll past it (M621), so a host that
    /// showed some lag and then stalls longer never has a leg sized from its guess.
    func testASlowUITextViewKeepsTheMostLagItShowed() {
        let text = ["north south east west up down left right", "Uno dos. Tres cuatro. Cinco seis. Siete ocho nueve diez",
                    "a slow grey cat naps on the warm sunny mat", "the end"]
        func at(_ line: Int, _ col: Int) -> String {
            var lines = text
            lines[line].insert("|", at: lines[line].index(lines[line].startIndex, offsetBy: col))
            return lines.joined(separator: "\n")
        }
        for (delays, why) in [([4, 1, 6], "slow, then fast: the slow lag stays"),
                              ([0, 2, 6], "a short lag, then a stall: a poll past it")] {
            var walk = CaretWalk()
            XCTAssertEqual(slow(at(0, 5), lines: 1, delay: delays[0], sentences: 2, walk: &walk).0, at(1, 5), why)
            XCTAssertEqual(slow(at(2, 40), lines: -1, delay: delays[1], sentences: 2, walk: &walk).0, at(1, 40), why)
            XCTAssertEqual(slow(at(2, 25), lines: -1, delay: delays[2], sentences: 2, walk: &walk).0, at(1, 25), why)
        }
    }

    /// A leg over a line break isn't plain: the line above's end shows nothing after it in
    /// UIKit, so a context reading so, and as where the leg left, is its landing (QA's M626).
    func testALegOverABreakLandsWhereNothingShowsPastIt() {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(0, lines: -1, before: "\nabc", after: ""), -4, "over the break")
        XCTAssertEqual(walk.step(0, before: "abc", after: ""), -3, "landed at the end of abc: on to its start")
    }

    /// A plain leg's landing showing nothing on the side it came from is the host's answer
    /// to a move before it only while the rest still reads as where the leg left: one over
    /// all the context shown, its window since widened, waits; a host that shows no
    /// after-context lands a step left at once, and so does an emptied field.
    func testOnlyAContextStillWhereTheLegLeftIsAnOlderAnswer() {
        var stayed = CaretWalk()
        XCTAssertEqual(stayed.step(-3, before: "abc", after: ""), -3)
        XCTAssertEqual(stayed.step(-1, before: "xabc", after: ""), 0, "still after the c: the host is behind")
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(-1, before: "abc", after: ""), -1)
        XCTAssertEqual(walk.step(-1, before: "ab", after: ""), -1, "landed: the next step goes")
        XCTAssertEqual(walk.step(0, before: "", after: ""), 0)
        XCTAssertTrue(walk.idle, "nothing shown either side: landed too")
    }

    /// Only UIKit's guess, the window a leg was sized in moved with it, waits where UIKit
    /// cuts: another window lands at once (QA's M546), and so does the guess once the view
    /// stopped waiting for the leg (QA's M545).
    func testOnlyAGuessOnTimeWaitsAtAUIKitCut() {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(0, lines: -1, before: "\nab", after: "c"), -3, "over the break")
        XCTAssertEqual(walk.step(0, before: "", after: "\nabc"), 0)
        XCTAssertFalse(walk.idle, "the guess waits")
        XCTAssertEqual(walk.step(0, before: "", after: "\nab"), 0)
        XCTAssertTrue(walk.idle, "another window: landed, on the empty line above")
        var late = CaretWalk()
        XCTAssertEqual(late.step(0, lines: -1, before: "\nab", after: "c"), -3)
        for _ in 0..<16 { late.poll() }
        XCTAssertEqual(late.step(0, before: "", after: "\nabc"), 0)
        XCTAssertTrue(late.idle, "the view stopped waiting: the guess lands at once")
    }

    /// A sideways step past a sentence's space at the context's end goes on at once: only
    /// a line move waits for the host to show whether the line goes on.
    func testSidewaysStepsDontWaitOutAGuess() {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(1, before: "x", after: " "), 1)
        XCTAssertEqual(walk.step(1, before: "x ", after: "", settled: false), 1)
    }

    /// A known UIKit host's before-context opening on a break shows the line as it is: a
    /// space after the break is the line's own, and the column counts it (QA's M466).
    func testAKnownUIKitHostKeepsTheSpaceAfterABreak() {
        var walk = CaretWalk()
        walk.utf16 = true
        XCTAssertEqual(walk.step(0, lines: -1, before: "\n xy", after: "z"), -4, "up over \" xy\" and the break")
        XCTAssertEqual(walk.step(0, before: "\nabcdef", after: ""), -3, "to column 3, the space counted")
    }

    /// A hold that ends during a line move takes its lines with it: the next hold's step
    /// goes alone (QA's M473).
    func testDropForgetsTheLinesAsked() {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(0, lines: 2, before: "\nab", after: "c\nxyz\nm"), 2, "over the break, a line still to go")
        walk.drop()
        XCTAssertEqual(walk.step(1, before: "\nab", after: "c\nxyz\nm"), 1, "the new hold's step, not the old lines")
    }

    /// A line move asked while the host shows an older answer than the landing the walk
    /// believed: nothing is sized from it, and the walk isn't idle, so the view keeps
    /// polling until the latest shows again (QA's M470, M495).
    func testAnOlderAnswerHoldsBackALineMove() {
        var walk = CaretWalk()
        XCTAssertEqual(walk.step(1, before: "\nab", after: "cd\nxyz"), 1)
        XCTAssertEqual(walk.step(0, before: "\nabc", after: "d\nxyz"), 0)
        XCTAssertTrue(walk.idle)
        XCTAssertEqual(walk.step(0, lines: 1, before: "\nab", after: "cd\nxyz"), 0, "the older answer sizes nothing")
        XCTAssertFalse(walk.idle, "a line still to move")
        XCTAssertEqual(walk.step(0, before: "\nabc", after: "d\nxyz"), 5, "the latest again: to the column below")
    }

    /// A line move as the first thing in another field starts a fresh walk there, never
    /// waiting on a move the last field left in flight (QA's M493).
    func testALineMoveIntoANewFieldStartsAfresh() {
        let kb = TerminalKeyboard(), old = host(kit: true, "abc", "def")
        kb.target = old
        kb.caret(-1)
        let doc = host(kit: true, "xy", "z\nw")
        kb.target = doc
        kb.line(1)
        XCTAssertEqual(doc.moves, [-2], "sized from this field at once: to its line's start")
        for _ in 0..<40 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "xyz\nw|")
    }

    /// With `moveCaret` set (the app), line moves go nowhere, even with a document proxy
    /// as the target: a shell's up and down are history (QA's M496).
    func testTheAppIgnoresLineMoves() {
        let kb = TerminalKeyboard(), doc = host(kit: true, "ab", "c\nxyz")
        kb.target = doc
        var sent: [Int] = []
        kb.moveCaret = { sent.append($0) }
        kb.line(1)
        kb.line(-1)
        for _ in 0..<20 { kb.pollCaret() }
        XCTAssertEqual(doc.moves, [])
        XCTAssertEqual(sent, [])
    }
}
