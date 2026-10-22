import XCTest
import UIKit
@testable import Prosper

/// The extension's suggestions bar, autocorrect, undo and learning (`Suggestions`,
/// `TypingMemory`, `SuggestionBar`), driven through the keyboard and a fake host field as
/// the extension's controller wires them. Learning goes to a throwaway defaults suite.
@MainActor
final class SuggestionsTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy
    typealias Slot = Suggestions.Slot

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "SuggestionsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A keyboard typing into a fake field with the bar attached. No auto-capitalization
    /// unless `configure` asks for it. Keep the proxy and the bar: the keyboard holds both
    /// weakly, as the extension's controller owns them.
    private func rig(_ configure: (Proxy) -> Void = { _ in }) -> (TerminalKeyboard, SuggestionBar, Proxy) {
        let doc = Proxy()
        doc.autocapitalizationType = .none
        configure(doc)
        let kb = TerminalKeyboard()
        kb.target = doc
        kb.doubleSpacePeriod = true
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults)))
        bar.attach(kb)
        kb.autoCapitalize()
        return (kb, bar, doc)
    }

    /// " " space, "\n" return, "⌫" backspace, anything else its key.
    private func typing(_ kb: TerminalKeyboard, _ s: String) {
        for c in s {
            switch c {
            case " ": kb.press(.space)
            case "\n": kb.press(.ret)
            case "⌫": kb.press(.backspace)
            default: kb.press(.char(String(c)))
            }
        }
    }

    private func slots(_ bar: SuggestionBar, file: StaticString = #filePath, line: UInt = #line) -> [Slot?] {
        guard case .slots(let s) = bar.state else { XCTFail("no slots: \(bar.state)", file: file, line: line); return [nil, nil, nil] }
        return s
    }

    // MARK: Words

    func testCurrentAndPreviousWord() {
        let w = Suggestions.currentWord
        XCTAssertEqual(w("hello wor"), "wor")
        XCTAssertEqual(w("I don't"), "don't")
        XCTAssertEqual(w("say 'hi"), "hi", "an opening quote isn't the word's")
        XCTAssertEqual(w("end. "), "")
        XCTAssertEqual(w("abc1"), "", "a digit ends it")
        XCTAssertEqual(w("x,y"), "y")
        XCTAssertEqual(w(nil), "")
        let p = Suggestions.previousWord
        XCTAssertEqual(p("Good "), "good")
        XCTAssertEqual(p("Good  "), "good")
        XCTAssertEqual(p("Hi. "), "", "a sentence start")
        XCTAssertEqual(p("line\n"), "")
        XCTAssertEqual(p(""), "")
    }

    func testEditDistanceAndConfidence() {
        let d = Suggestions.editDistance
        XCTAssertEqual(d("teh", "the"), 1, "a swap is one edit")
        XCTAssertEqual(d("recieve", "receive"), 1)
        XCTAssertEqual(d("kitten", "sitting"), 3)
        XCTAssertEqual(d("", "abc"), 3)
        XCTAssertEqual(d("same", "same"), 0)
        let ok = Suggestions.confident
        XCTAssertTrue(ok("teh", "the"))
        XCTAssertTrue(ok("Teh", "the"), "case doesn't count")
        XCTAssertTrue(ok("ab", "an"))
        XCTAssertTrue(ok("abcd", "abxy"), "2 edits from 4 letters")
        XCTAssertFalse(ok("ab", "cd"), "2 edits is too many at 3 letters or fewer")
        XCTAssertFalse(ok("cat", "dog"))
        XCTAssertFalse(ok("abcdef", "abxyzf"), "3 edits")
        XCTAssertFalse(ok("a", "an"), "one letter")
        XCTAssertFalse(ok("iPhnoe", "iPhone"), "camelCase is deliberate")
        XCTAssertFalse(ok("ab1", "abc"), "letters only")
    }

    func testMatchCase() {
        let m = Suggestions.matchCase
        XCTAssertEqual(m("the", "Teh"), "The")
        XCTAssertEqual(m("the", "TEH"), "THE")
        XCTAssertEqual(m("hello", "H"), "Hello", "one capital is a capitalized word")
        XCTAssertEqual(m("the", "teh"), "the")
        XCTAssertEqual(m("I", "i"), "I", "the dictionary's own capitals stay")
    }

    func testCenteredPutsTheBestInTheMiddle() {
        let s = ["a", "b", "c"].map { Slot(word: $0) }
        XCTAssertEqual(Suggestions.centered(s), [s[1], s[0], s[2]])
        XCTAssertEqual(Suggestions.centered(Array(s.prefix(1))), [nil, s[0], nil])
        XCTAssertEqual(Suggestions.centered([]), [nil, nil, nil])
    }

    // MARK: Autocorrect

    func testMisspellingShowsTheCorrectionAndSpaceAppliesIt() throws {
        let (kb, bar, doc) = rig()
        typing(kb, "teh")
        let s = slots(bar)
        XCTAssertEqual(s[0], Slot(word: "teh", quoted: true))
        XCTAssertEqual(s[1], Slot(word: "the", highlighted: true))
        let alt = try XCTUnwrap(s[2]?.word, "the next guess")
        XCTAssertFalse(["the", "teh"].contains(alt.lowercased()))
        XCTAssertEqual(bar.slotButtons.map { $0.title(for: .normal) }, ["“teh”", "the", alt])
        typing(kb, " ")
        XCTAssertEqual(doc.text, "the ")
        typing(kb, "teh,teh\n")
        XCTAssertEqual(doc.text, "the the,the\n", "punctuation and return autocorrect too")
        doc.text = "teh"; doc.after = "x"
        kb.press(.space)
        XCTAssertEqual(doc.text, "teh ", "never mid-word")
    }

    func testCaseFollowsTheTypedWordAndShift() throws {
        let (kb, bar, doc) = rig { $0.autocapitalizationType = .sentences }
        typing(kb, "teh")
        XCTAssertEqual(doc.text, "Teh", "auto-capitalized")
        XCTAssertEqual(slots(bar)[1], Slot(word: "The", highlighted: true))
        typing(kb, " ")
        XCTAssertEqual(doc.text, "The ")

        typing(kb, "⌫⌫⌫⌫")
        for _ in 0..<3 where kb.shift.mode != .locked { kb.press(.shift) }   // caps lock (auto-shift was on)
        XCTAssertEqual(kb.shift.mode, .locked)
        typing(kb, "t")
        XCTAssertEqual(doc.text, "T")
        let words = slots(bar).compactMap { $0?.word }
        XCTAssertFalse(words.isEmpty)
        XCTAssertEqual(words, words.map { $0.uppercased() }, "caps lock: all caps, even after one letter")
    }

    func testKnownWordsAreNeverCorrected() throws {
        // Each would be corrected if nothing knew it: unknown to the dictionary, a
        // confident guess.
        func wouldCorrect(_ w: String) -> Bool {
            !Suggestions.spelled(w) && Suggestions.guesses(w).first.map { Suggestions.confident(w, guess: $0) } == true
        }
        let shell = try XCTUnwrap(ShellWords.all.first(where: wouldCorrect), "a shell word the dictionary would correct")
        XCTAssertTrue(wouldCorrect("teh"))

        var (kb, bar, doc) = rig()
        typing(kb, shell + " ")
        XCTAssertEqual(doc.text, shell + " ", "a shell word")

        // The contact first: the learned word below persists in the suite.
        (kb, bar, doc) = rig()
        bar.suggestions.load([(userInput: "Teh", documentText: "Teh")])
        typing(kb, "teh ")
        XCTAssertEqual(doc.text, "teh ", "a contact name")
        XCTAssertTrue(bar.suggestions.personalWords.contains("teh"), "touch correction knows it too")

        (kb, bar, doc) = rig()
        bar.suggestions.memory.learn("teh")
        typing(kb, "teh")
        XCTAssertFalse(slots(bar).contains { $0?.highlighted == true })
        typing(kb, " ")
        XCTAssertEqual(doc.text, "teh ", "a learned word")
    }

    func testBackspaceRightAfterAnAutocorrectRevertsIt() {
        let (kb, bar, doc) = rig()
        typing(kb, "teh ")
        XCTAssertEqual(doc.text, "the ")
        typing(kb, "⌫")
        XCTAssertEqual(doc.text, "teh", "the typed word back, cursor after it")
        XCTAssertFalse(slots(bar).contains { $0?.highlighted == true }, "nothing pending for it now")
        typing(kb, " ")
        XCTAssertEqual(doc.text, "teh ", "not corrected again")
        typing(kb, "teh ⌫")
        XCTAssertEqual(doc.text, "teh teh", "nor later in the session; backspace is plain again")

        let (kb2, bar2, doc2) = rig()
        withExtendedLifetime(bar2) { typing(kb2, "teh x⌫⌫") }
        XCTAssertEqual(doc2.text, "the", "only the very next key undoes")
    }

    // MARK: Taps

    func testTappingACompletionReplacesTheWordAndAddsASpace() throws {
        let (kb, bar, doc) = rig()
        typing(kb, "thin")
        let s = slots(bar)
        XCTAssertEqual(s[0], Slot(word: "thin", quoted: true), "a word: kept in quotes")
        let completion = try XCTUnwrap(s[1])
        XCTAssertFalse(completion.highlighted)
        XCTAssertTrue(completion.word.hasPrefix("thin") && completion.word != "thin", completion.word)
        doc.calls = []
        bar.slotButtons[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(doc.text, completion.word + " ")
        XCTAssertEqual(doc.calls, ["⌫", "⌫", "⌫", "⌫", completion.word + " "])
    }

    /// Through UIKit's hit-testing, not the actions alone: a finger on a slot or on the
    /// key button lands on that button, inside the bar's 44 pt.
    func testTouchesReachTheBarsButtons() {
        let (kb, bar, doc) = rig()
        bar.frame = CGRect(x: 0, y: 0, width: 402, height: SuggestionBar.height)
        bar.layoutIfNeeded()
        typing(kb, "teh")
        XCTAssertEqual(doc.text, "teh")
        for b in bar.slotButtons {
            let center = b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: bar)
            XCTAssertTrue(bar.bounds.contains(center))
            XCTAssertTrue(bar.hitTest(center, with: nil) === b, "\(b.title(for: .normal) ?? "")")
        }
        let (_, login, _) = rig { $0.textContentType = .username }
        login.frame = bar.frame
        login.layoutIfNeeded()
        let hit = login.hitTest(CGPoint(x: 201, y: SuggestionBar.height / 2), with: nil)
        XCTAssertTrue(hit === login.autofillButton || hit?.isDescendant(of: login.autofillButton) == true, "\(String(describing: hit))")
    }

    /// Hosted as the extension hosts them (`host`), in a window just the bar plus the
    /// keyboard: iOS draws nothing above a custom keyboard, so a digit's bubble, pressed
    /// and then held, has to fit inside, rising into the bar.
    func testTopRowBubblesFitInTheExtensionsView() throws {
        let (kb, bar, doc) = rig()
        kb.bottomInset = 6
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402,
                                            height: SuggestionBar.height + TerminalKeyboard.keysHeight + 6))
        // A window with no scene takes its size class from its own size: this short one
        // would read compact. The extension's follows the device (the landscape test).
        if #available(iOS 17, *) { window.traitOverrides.verticalSizeClass = .regular }
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        bar.host(kb, in: view)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        XCTAssertEqual(bar.frame, CGRect(x: 0, y: 0, width: 402, height: SuggestionBar.height))
        XCTAssertEqual(kb.frame.minY, SuggestionBar.height)
        XCTAssertEqual(view.backgroundColor, TerminalKeyboard.Style.backdrop, "opaque dark behind both")
        for label in ["1", "0"] {
            let cap = try XCTUnwrap(kb.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label })
            let p = CGPoint(x: cap.frame.midX, y: cap.frame.midY)
            kb.track(.began, id: 1, at: p)
            XCTAssertEqual(kb.previewText, label)
            XCTAssertTrue(window.bounds.contains(try XCTUnwrap(kb.previewFrame)), "\(label): \(kb.previewFrame!)")
            kb.fireHold()
            XCTAssertEqual(kb.previewText, TerminalKeyboard.holdSymbol[label])
            XCTAssertTrue(window.bounds.contains(try XCTUnwrap(kb.previewFrame)), "\(label) held")
            kb.track(.ended, id: 1, at: p)
        }
        XCTAssertEqual(doc.text, "!)", "the held symbols typed")
    }

    /// The same in landscape: a 36 pt bar, the keys' 174 pt and its height constraint
    /// following, the digits' shorter bubbles still inside, and the bar back to 44 pt.
    func testTopRowBubblesFitInTheExtensionsViewInLandscape() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let (kb, bar, _) = rig()
        kb.bottomInset = 6
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 36 + 174 + 6))
        window.traitOverrides.verticalSizeClass = .compact
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        bar.host(kb, in: view)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let height = try XCTUnwrap(kb.constraints.first { $0.firstItem === kb && $0.firstAttribute == .height })
        XCTAssertEqual(height.constant, 174 + 6)
        XCTAssertEqual(bar.frame, CGRect(x: 0, y: 0, width: 874, height: 36))
        XCTAssertEqual(kb.frame.minY, 36)
        for label in ["1", "0"] {
            let cap = try XCTUnwrap(kb.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label })
            let p = CGPoint(x: cap.frame.midX, y: cap.frame.midY)
            kb.track(.began, id: 1, at: p)
            XCTAssertTrue(window.bounds.contains(try XCTUnwrap(kb.previewFrame)), "\(label): \(kb.previewFrame!)")
            kb.fireHold()
            XCTAssertTrue(window.bounds.contains(try XCTUnwrap(kb.previewFrame)), "\(label) held")
            kb.track(.ended, id: 1, at: p)
        }
        window.traitOverrides.verticalSizeClass = .regular
        window.layoutIfNeeded()
        XCTAssertEqual(bar.frame.height, SuggestionBar.height, "rotated back")
    }

    func testTappingTheQuotedWordKeepsAndLearnsIt() {
        let (kb, bar, doc) = rig()
        typing(kb, "teh")
        bar.slotButtons[0].sendActions(for: .touchUpInside)
        XCTAssertEqual(doc.text, "teh ")
        XCTAssertEqual(defaults.stringArray(forKey: TypingMemory.wordsKey), ["teh"])
        typing(kb, "teh ")
        XCTAssertEqual(doc.text, "teh teh ", "never corrected again")
        XCTAssertTrue(Suggestions(memory: TypingMemory(defaults: defaults)).knows("teh"), "a later session too")
    }

    func testLearnedWordsAreCapped() {
        let m = TypingMemory(defaults: defaults, wordCap: 2)
        for w in ["one", "two", "Two", "three"] { m.learn(w) }
        XCTAssertEqual(m.words, ["two", "three"], "lowercase, once, the oldest dropped")
        XCTAssertEqual(m.known, ["two", "three"])
        XCTAssertEqual(TypingMemory(defaults: defaults).words, ["two", "three"])
    }

    // MARK: Next-word predictions

    func testBigramsPredictAndEvictTheRarest() {
        let m = TypingMemory(defaults: defaults, pairCap: 4)
        m.record("Good", "Morning"); m.record("good", "morning"); m.record("good", "night")
        XCTAssertEqual(m.predict(after: "good"), ["morning", "night"])
        XCTAssertEqual(m.predict(after: "bad"), ["morning", "night"], "no pair: the most typed words")
        m.record("", "hello"); m.record("", "hello"); m.record("", "hello")
        XCTAssertEqual(m.predict(after: "good"), ["morning", "night", "hello"], "topped up")

        let fresh = UserDefaults(suiteName: suite + ".evict")!
        defer { fresh.removePersistentDomain(forName: suite + ".evict") }
        let e = TypingMemory(defaults: fresh, pairCap: 4)
        e.record("a", "b"); e.record("a", "b"); e.record("a", "b")
        e.record("c", "d"); e.record("c", "d")
        e.record("e", "f"); e.record("g", "h")
        e.record("", "new")   // fifth pair, and first among the rarest: they go, down to 90% of the cap
        XCTAssertEqual(Set(e.pairs.keys), ["a b", "c d", " new"], "never the pair just typed")
        XCTAssertEqual(TypingMemory(defaults: fresh).pairs, e.pairs, "persisted")
    }

    func testPredictionsAfterASpaceFollowWhatWasTyped() {
        let (kb, bar, doc) = rig { $0.autocapitalizationType = .sentences }
        XCTAssertEqual(slots(bar), [nil, nil, nil], "nothing learned yet: blank")
        typing(kb, "good morning. ")
        XCTAssertEqual(doc.text, "Good morning. ")
        XCTAssertEqual(slots(bar)[1]?.word, "Good", "a sentence start: what started one, capitalized")
        typing(kb, "good ")
        XCTAssertEqual(slots(bar)[1]?.word, "morning")
        bar.slotButtons[1].sendActions(for: .touchUpInside)
        XCTAssertEqual(bar.suggestions.memory.pairs["good morning"], 2, "a tapped prediction counts too")
    }

    // MARK: Supplementary lexicon

    func testTextReplacementAppliesOnSpaceAndNamesComplete() {
        let (kb, bar, doc) = rig()
        bar.suggestions.load([(userInput: "omw", documentText: "On my way!"),
                              (userInput: "Ann", documentText: "Ann"),
                              (userInput: "Ann Lee", documentText: "Ann Lee")])
        typing(kb, "omw")
        XCTAssertEqual(slots(bar)[0], Slot(word: "omw", quoted: true))
        XCTAssertEqual(slots(bar)[1], Slot(word: "On my way!", highlighted: true))
        typing(kb, " ")
        XCTAssertEqual(doc.text, "On my way! ")
        typing(kb, "⌫")
        XCTAssertEqual(doc.text, "omw", "undoable like an autocorrect")

        typing(kb, " an")
        XCTAssertEqual(slots(bar)[1]?.word, "Ann", "a contact name leads the completions")
        XCTAssertNil(bar.suggestions.names["ann lee"], "one word only")
    }

    // MARK: Fields

    func testLoginFieldsShowTheKeyButtonAndLearnNothing() {
        for type in [UITextContentType.username, .oneTimeCode, .password, .newPassword] {
            let (kb, bar, doc) = rig { $0.textContentType = type }
            XCTAssertEqual(bar.state, .autofill, type.rawValue)
            XCTAssertFalse(bar.autofillButton.isHidden)
            XCTAssertTrue(bar.slotButtons.allSatisfy(\.isHidden))
            var switched = 0
            bar.nextKeyboard = { switched += 1 }
            bar.autofillButton.sendActions(for: .touchUpInside)
            XCTAssertEqual(switched, 1, "the key button goes to the next keyboard")
            typing(kb, "teh good ")
            XCTAssertEqual(doc.text, "teh good ", "no autocorrect")
            XCTAssertTrue(bar.suggestions.memory.pairs.isEmpty, "nothing learned")
        }
        let (_, bar, _) = rig { $0.isSecureTextEntry = true }
        XCTAssertEqual(bar.state, .autofill)
        let (_, plain, _) = rig { $0.textContentType = .name }
        XCTAssertTrue(plain.autofillButton.isHidden)
        XCTAssertFalse(plain.slotButtons[1].isHidden)
    }

    func testNoAutocorrectOrLearningWhereTheFieldTurnsItOff() {
        let off: [(String, (Proxy) -> Void)] = [
            ("autocorrection off", { $0.autocorrectionType = .no }),
            ("spell checking off", { $0.spellCheckingType = .no }),
            ("email", { $0.keyboardType = .emailAddress }),
            ("URL", { $0.keyboardType = .URL }),
            ("web search", { $0.keyboardType = .webSearch }),
            ("number pad", { $0.keyboardType = .numberPad }),
        ]
        for (name, configure) in off {
            let (kb, bar, doc) = rig(configure)
            typing(kb, "teh")
            XCTAssertFalse(slots(bar).contains { $0?.highlighted == true }, name)
            typing(kb, " teh. good ")
            XCTAssertEqual(doc.text, "teh teh. good ", name)
            XCTAssertTrue(bar.suggestions.memory.pairs.isEmpty, "\(name): nothing learned")
        }
        for type in [UITextAutocorrectionType.yes, .default] {
            let (kb, bar, doc) = rig { $0.autocorrectionType = type }
            withExtendedLifetime(bar) { typing(kb, "teh ") }
            XCTAssertEqual(doc.text, "the ", "\(type.rawValue) autocorrects")
        }
    }

    /// The terminal's keyboard has no bar: nothing hooks its keys, nothing is corrected.
    func testTheAppKeyboardIsUnchanged() {
        final class Spy: NSObject, UIKeyInput {
            var calls: [String] = []
            var hasText: Bool { true }
            func insertText(_ text: String) { calls.append(text) }
            func deleteBackward() { calls.append("⌫") }
        }
        let kb = TerminalKeyboard(), spy = Spy()
        kb.target = spy
        XCTAssertNil(kb.willPress)
        XCTAssertNil(kb.didPress)
        typing(kb, "teh ⌫")
        XCTAssertEqual(spy.calls, ["t", "e", "h", " ", "⌫"])

        let bare = TerminalKeyboard(), doc = Proxy()
        bare.target = doc
        typing(bare, "teh ")
        XCTAssertEqual(doc.text, "teh ", "a proxy without the bar: still nothing")
    }
}
