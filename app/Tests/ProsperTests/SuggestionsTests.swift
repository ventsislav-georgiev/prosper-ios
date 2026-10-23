import XCTest
import UIKit
import UniformTypeIdentifiers
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
    /// unless `configure` asks for it (the setting is on, the field's type decides). Keep
    /// the proxy and the bar: the keyboard holds both weakly, as the extension's controller
    /// owns them.
    private func rig(_ configure: (Proxy) -> Void = { _ in }) -> (TerminalKeyboard, SuggestionBar, Proxy) {
        let doc = Proxy()
        doc.autocapitalizationType = .none
        configure(doc)
        let kb = TerminalKeyboard()
        kb.target = doc
        kb.doubleSpacePeriod = true
        kb.settings.autoCapitalization = true
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

    /// Auto-Correction off: the bar still offers the guesses, but none is highlighted and a
    /// separator leaves the word as typed, "i" included.
    func testAutoCorrectionSwitch() {
        let (kb, bar, doc) = rig()
        bar.suggestions.settings.autoCorrection = false
        typing(kb, "teh")
        let s = slots(bar)
        XCTAssertEqual(s[0], Slot(word: "teh", quoted: true))
        XCTAssertFalse(s.contains { $0?.highlighted == true }, "nothing for space to apply")
        XCTAssertTrue(s.contains { $0?.word == "the" }, "still a suggestion")
        typing(kb, " i ")
        XCTAssertEqual(doc.text, "teh i ")
        bar.suggestions.settings.autoCorrection = true
        typing(kb, "teh ")
        XCTAssertEqual(doc.text, "teh i the ", "on again")
    }

    /// Predictive Text off: no words in the slots, typing or at a word start, while
    /// autocorrect still runs and Paste still shows.
    func testPredictiveTextSwitch() throws {
        let (kb, bar, doc) = rig()
        bar.suggestions.memory.record("", "hello")
        bar.refresh()
        XCTAssertEqual(slots(bar)[1]?.word, "hello", "on: a prediction")
        bar.suggestions.settings.predictiveText = false
        bar.refresh()
        XCTAssertEqual(slots(bar), [nil, nil, nil], "no prediction")
        typing(kb, "teh")
        XCTAssertEqual(slots(bar), [nil, nil, nil], "no completions or guesses")
        XCTAssertTrue(bar.slotButtons.allSatisfy { $0.title(for: .normal) == nil })
        typing(kb, " ")
        XCTAssertEqual(doc.text, "the ", "Auto-Correction is its own switch")

        let pb = try clipboard()
        pb.string = "copied text"
        let (pkb, paste, pdoc) = pasteRig(pb)
        paste.suggestions.settings.predictiveText = false
        withExtendedLifetime((pkb, pdoc)) { paste.refresh() }
        XCTAssertEqual(paste.state, .paste, "Paste stays")
    }

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

    /// "." waits for a space: "jane.doe" and "example.com" go on past it.
    func testAPeriodDefersTheCorrectionToTheSpace() {
        let (kb, bar, doc) = rig()
        typing(kb, "teh.")
        XCTAssertEqual(doc.text, "teh.", "not corrected by the period")
        typing(kb, " ")
        XCTAssertEqual(doc.text, "the. ", "the space corrects it, the period kept")
        typing(kb, "⌫")
        XCTAssertEqual(doc.text, "teh.", "undone, period and all")
        typing(kb, " ")
        XCTAssertEqual(doc.text, "teh. ", "not corrected again")
        XCTAssertEqual(bar.suggestions.memory.pairs[" the"], 1, "the correction counted, at the space")
    }

    /// The first letter changes only for a slip onto a neighboring key with the length kept
    /// ("rhe" → "the"); a guess that drops or adds one ("iphone" → "phone") leaves it as typed.
    func testTheFirstLetterChangesOnlyForANeighboringKey() {
        for (word, fix) in [("rhe", "the"), ("tou", "you")] {
            XCTAssertEqual(Suggestions.guesses(word).first, fix, "the checker's first guess")
            let (kb, bar, doc) = rig()
            withExtendedLifetime(bar) { typing(kb, word + " ") }
            XCTAssertEqual(doc.text, fix + " ")
        }
        for word in ["iphone", "ipad"] {
            let (kb, bar, doc) = rig()
            typing(kb, word)
            XCTAssertFalse(slots(bar).contains { $0?.highlighted == true }, word)
            typing(kb, " ")
            XCTAssertEqual(doc.text, word + " ")
        }
        let ok = Suggestions.confident
        XCTAssertTrue(ok("gello", "hello"), "g and h are neighbors")
        XCTAssertFalse(ok("pello", "hello"), "p and h aren't")
        XCTAssertTrue(ok("qnd", "and"), "a row apart")
        XCTAssertFalse(ok("ehat", "that"), "two keys apart in a row")
        XCTAssertFalse(ok("zuick", "quick"), "two rows apart")
        XCTAssertFalse(ok("ghat", "hat"), "a neighbor, but a letter dropped")
        XCTAssertTrue(ok("Gelo", "gel"), "case doesn't count")
        XCTAssertTrue(ok("Rhe", "the"), "case doesn't count")
    }

    /// What `typed` mirrors, key by key: backspace pops it, a correction and its revert
    /// replace their word in it, and it holds more than a short word.
    func testTheTypedMirrorFollowsEveryEdit() {
        for (keys, text) in [("tehx⌫ ", "the "), ("becuase ", "because "),
                             ("teh x⌫⌫rr ", "there "), ("wrld ⌫d ", "wild ")] {
            let (kb, bar, doc) = rig()
            withExtendedLifetime(bar) { typing(kb, keys) }
            XCTAssertEqual(doc.text, text, keys)
        }
    }

    /// A letter run after a digit or `@ # _ / .` is part of a token: space leaves it and
    /// the bar highlights nothing for it.
    func testGluedRunsAreNeverCorrected() {
        for text in ["2nd ", "1st ", "@jdoe ", "#teh ", "x_teh ", "jane.doe@example.com ",
                     "www.example.com/path ", "e.g. "] {
            let (kb, bar, doc) = rig()
            typing(kb, String(text.dropLast()))
            XCTAssertFalse(slots(bar).contains { $0?.highlighted == true }, text)
            typing(kb, " ")
            XCTAssertEqual(doc.text, text)
        }
    }

    func testAStandaloneIIsCapitalized() {
        let (kb, bar, doc) = rig()
        typing(kb, "so i")
        XCTAssertEqual(slots(bar)[1], Slot(word: "I", highlighted: true))
        typing(kb, " i'm i’ll ")
        XCTAssertEqual(doc.text, "so I I'm I’ll ")
        typing(kb, "i ⌫")
        XCTAssertEqual(doc.text, "so I I'm I’ll i", "undoable")

        let (kb2, bar2, doc2) = rig { $0.autocorrectionType = .no }
        withExtendedLifetime(bar2) { typing(kb2, "so i ") }
        XCTAssertEqual(doc2.text, "so i ", "only where autocorrect applies")
    }

    /// Text this keyboard didn't type, or didn't type whole, is left as it is: the bar
    /// highlights nothing for it and space doesn't change it. Typed words still correct.
    func testOnlyWordsTypedWholeAreCorrected() throws {
        let pb = try clipboard()
        pb.string = "hello wrld"
        var (kb, bar, doc) = pasteRig(pb)
        paste(bar, doc)
        XCTAssertFalse(slots(bar).contains { $0?.highlighted == true }, "a pasted tail")
        typing(kb, " ")
        XCTAssertEqual(doc.text, "hello wrld ", "a paste")

        (kb, bar, doc) = rig()
        typing(kb, "ok ")
        doc.text = "hello wrld"   // as a cursor moved after it leaves the text, unannounced
        bar.refresh()
        XCTAssertFalse(slots(bar).contains { $0?.highlighted == true }, "text already there")
        typing(kb, " ")
        XCTAssertEqual(doc.text, "hello wrld ", "text already there")

        pb.string = "foo "
        (kb, bar, doc) = pasteRig(pb)
        paste(bar, doc)
        typing(kb, "teh ")
        XCTAssertEqual(doc.text, "foo the ", "typed after a paste")

        pb.string = "wr"
        (kb, bar, doc) = pasteRig(pb)
        paste(bar, doc)
        typing(kb, "ld")
        XCTAssertFalse(slots(bar).contains { $0?.highlighted == true }, "half pasted")
        typing(kb, " ")
        XCTAssertEqual(doc.text, "wrld ", "half pasted")
    }

    // MARK: Trackpad

    /// The rig's keys laid out, by title or accessibility label.
    private func caps(_ kb: TerminalKeyboard) -> [String: UIButton] {
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews {
            caps[b.title(for: .normal) ?? b.accessibilityLabel ?? ""] = b
        }
        return caps
    }

    /// Holds space and drags it by each of `offsets` caret steps in turn, then lifts.
    private func drag(_ kb: TerminalKeyboard, _ offsets: [CGFloat]) throws {
        let space = try XCTUnwrap(caps(kb)["space"]).frame
        var p = CGPoint(x: space.midX, y: space.midY)
        kb.track(.began, id: 1, at: p)
        kb.fireHold()
        for o in offsets {
            p.x += o * KeyTouchTracker.caretStep
            kb.track(.moved, id: 1, at: p)
        }
        kb.track(.ended, id: 1, at: p)
    }

    /// The trackpad moves the field's caret through the proxy and changes no text. The
    /// autocorrect just before it is no longer backspace's to undo: undoing it there would
    /// also reject "teh" for good, and the next "teh " would stay.
    func testTrackpadMovesTheCaretAndEndsTheUndo() throws {
        let (kb, bar, doc) = rig()
        typing(kb, "teh ")
        XCTAssertEqual(doc.text, "the ")
        try drag(kb, [-1.5, 1.7])
        XCTAssertEqual(doc.moves, [-1, 1])
        XCTAssertEqual(doc.text + (doc.after ?? ""), "the ", "the text is unchanged")
        typing(kb, "⌫")
        XCTAssertEqual(doc.text, "the", "a plain delete, not the undo")
        typing(kb, " teh ")
        XCTAssertEqual(doc.text, "the the ", "teh is still corrected")
        XCTAssertTrue(slots(bar).allSatisfy { $0?.highlighted != true })
    }

    /// A word typed after a caret move doesn't continue the one before it: "tes", the
    /// caret to the start, then a touch on r's right edge types r (after "tes" it would
    /// be corrected to t); and letters typed onto a word the keyboard didn't type there
    /// ("te" + "h") aren't autocorrected as if typed whole.
    func testAWordAfterACaretMoveStartsAfresh() throws {
        var (kb, bar, doc) = rig()
        typing(kb, "tes")
        try drag(kb, [-3.5])
        XCTAssertEqual(doc.moves, [-3])
        XCTAssertEqual(doc.text, "")
        XCTAssertEqual(kb.word, "")
        let r = try XCTUnwrap(caps(kb)["r"]).frame, edge = CGPoint(x: r.maxX - 1, y: r.midY)
        kb.track(.began, id: 2, at: edge)
        kb.track(.ended, id: 2, at: edge)
        XCTAssertEqual(doc.text + (doc.after ?? ""), "rtes", "the touch is r, not t")

        (kb, bar, doc) = rig()
        doc.text = "te "   // the host's text, not typed here
        bar.refresh()
        typing(kb, "te")
        try drag(kb, [-3.5])
        XCTAssertEqual(doc.text, "te")
        typing(kb, "h ")
        XCTAssertEqual(doc.text + (doc.after ?? ""), "teh  te", "not corrected: half the host's")
        XCTAssertTrue(slots(bar).allSatisfy { $0?.highlighted != true })
    }

    /// Quick taps on the space bar still type spaces, and the second one after a word
    /// still makes ". "; no hold timer is left to fire.
    func testSpaceTapsAndTheDoubleSpacePeriodAreUnchanged() throws {
        let (kb, _, doc) = rig()
        let space = try XCTUnwrap(caps(kb)["space"]).frame, p = CGPoint(x: space.midX, y: space.midY)
        typing(kb, "hi")
        for id in 1...2 {
            kb.track(.began, id: id, at: p)
            kb.track(.ended, id: id, at: p)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(KeyTouchTracker.holdDelay + 0.1))
        XCTAssertEqual(doc.text, "hi. ")
        kb.track(.began, id: 3, at: p)
        kb.track(.ended, id: 3, at: p)
        XCTAssertEqual(doc.text, "hi.  ")
        XCTAssertEqual(doc.moves, [])
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

    /// The same in landscape: a 32 pt bar, the keys' 149 pt and its height constraint
    /// following, the digits' shorter bubbles still inside, and the bar back to 44 pt.
    func testTopRowBubblesFitInTheExtensionsViewInLandscape() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let (kb, bar, _) = rig()
        kb.bottomInset = 6
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: SuggestionBar.height(compact: true)
                                            + TerminalKeyboard.keysHeight(compact: true) + 6))
        window.traitOverrides.verticalSizeClass = .compact
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        bar.host(kb, in: view)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let height = try XCTUnwrap(kb.constraints.first { $0.firstItem === kb && $0.firstAttribute == .height })
        XCTAssertEqual(height.constant, TerminalKeyboard.keysHeight(compact: true) + 6)
        XCTAssertEqual(bar.frame, CGRect(x: 0, y: 0, width: 874, height: 32))
        XCTAssertEqual(kb.frame.minY, SuggestionBar.height(compact: true))
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

    func testTappingTheQuotedWordLearnsNothingWhereAutocorrectIsOff() throws {
        let (kb, bar, doc) = rig { $0.autocorrectionType = .no }
        typing(kb, "qzxv")
        let i = try XCTUnwrap(slots(bar).firstIndex { $0?.quoted == true })
        bar.slotButtons[i].sendActions(for: .touchUpInside)
        XCTAssertEqual(doc.text, "qzxv ", "still typed")
        XCTAssertNil(defaults.stringArray(forKey: TypingMemory.wordsKey), "not learned")
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

        // A fresh keyboard: the undo above leaves "omw" alone from then on.
        let (kb2, bar2, doc2) = rig()
        bar2.suggestions.load([(userInput: "omw", documentText: "On my way!")])
        typing(kb2, "omw. ")
        XCTAssertEqual(doc2.text, "On my way! ", "its own \"!\" ends the sentence: no \".\" after it")
        typing(kb2, "⌫")
        XCTAssertEqual(doc2.text, "omw.", "undone, period and all")
        typing(kb2, " teh ")
        XCTAssertEqual(doc2.text, "omw. the ", "typed still in step")

        // A fresh keyboard each, for the same reason.
        for (input, phrase) in [("addr", "12 Main St."), ("elp", "Wait…")] {
            let (kb, bar, doc) = rig()
            bar.suggestions.load([(userInput: input, documentText: phrase)])
            withExtendedLifetime(bar) { typing(kb, input + ". ") }
            XCTAssertEqual(doc.text, phrase + " ", "no second sentence end after \(phrase)")
        }
    }

    // MARK: Fields

    func testLoginFieldsShowTheKeyButtonAndLearnNothing() {
        for type in [UITextContentType.username, .oneTimeCode, .password, .newPassword] {
            let (kb, bar, doc) = rig { $0.textContentType = type }
            XCTAssertEqual(bar.state, .autofill, type.rawValue)
            XCTAssertFalse(bar.autofillButton.isHidden)
            XCTAssertTrue(bar.slotButtons.allSatisfy(\.isHidden))
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

    /// The key button's touches all go to the input-mode list, which advances on a tap and
    /// lists the keyboards on a hold. A tap's lift marks the hop; a hold's doesn't.
    func testTheKeyButtonMarksATapAndHandsEveryTouchToTheList() throws {
        let saved = KeyboardSettings.store
        defer { KeyboardSettings.store = saved }
        let suite = "Hop.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        KeyboardSettings.store = { defaults }
        let (_, bar, _) = rig { $0.textContentType = .username }
        let key = bar.autofillButton
        var touches = 0
        bar.inputModeList = { view, _ in XCTAssertTrue(view === key); touches += 1 }
        // As UIKit sends them: with the touches' event, which sendActions(for:) leaves nil.
        func send(_ e: UIControl.Event) {
            key.sendActions(for: e)
            for name in key.actions(forTarget: bar, forControlEvent: e) ?? [] {
                key.sendAction(Selector(name), to: bar, for: UIEvent())
            }
        }
        send(.touchDown)
        send(.touchUpInside)
        XCTAssertEqual(touches, 2, "down and up")
        let mark = try XCTUnwrap(KeyboardSettings.takeHop(), "a tap marks the hop")
        XCTAssertEqual(mark.from, Bundle.main.bundleIdentifier)
        XCTAssertLessThan(Date().timeIntervalSince(mark.at), 1)
        for e in [UIControl.Event.touchDragInside, .touchDragExit, .touchUpOutside, .touchCancel] {
            send(e)
        }
        XCTAssertEqual(touches, 6, "every touch")
        XCTAssertNil(KeyboardSettings.takeHop(), "only a lift inside marks")

        send(.touchDown)
        bar.pressedAt = Date() - 1.5   // held: the list showed, and the lift picks from it
        send(.touchUpInside)
        XCTAssertNil(KeyboardSettings.takeHop(), "a hold's pick doesn't hop")
        send(.touchUpInside)
        XCTAssertNil(KeyboardSettings.takeHop(), "a lift with no press doesn't either")
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

    // MARK: Paste

    /// `rig` on a throwaway named pasteboard, offered while `fullAccess` is on.
    private func pasteRig(_ pb: UIPasteboard, fullAccess: @escaping () -> Bool = { true },
                          _ configure: (Proxy) -> Void = { _ in }) -> (TerminalKeyboard, SuggestionBar, Proxy) {
        let (kb, bar, doc) = rig(configure)
        bar.suggestions.pasteboard = { fullAccess() ? pb : nil }
        bar.refresh()
        return (kb, bar, doc)
    }

    private func clipboard() throws -> UIPasteboard {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        return pb
    }

    /// A tap on the Paste control, as iOS delivers it: the clip as an item provider (the
    /// pasteboard's own string), loaded off the main thread. Waits for it to go in.
    private func paste(_ bar: SuggestionBar, _ doc: Proxy) {
        let clip = bar.suggestions.pasteboard()?.string ?? ""
        let before = doc.text
        bar.paste(itemProviders: [NSItemProvider(object: clip as NSString)])
        let deadline = Date() + 2
        while doc.text == before, Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
    }

    func testPasteShowsAtAWordStartWithAFreshTextClip() throws {
        let pb = try clipboard()
        let (_, empty, _) = pasteRig(pb)
        XCTAssertNotEqual(empty.state, .paste, "an empty pasteboard")
        XCTAssertTrue(empty.pasteControl.isHidden)
        pb.image = UIImage(systemName: "star")
        let (_, image, _) = pasteRig(pb)
        XCTAssertNotEqual(image.state, .paste, "image-only: insertText takes only text")
        pb.string = "copied text"
        var access = false
        let (kb, bar, doc) = pasteRig(pb, fullAccess: { access })
        XCTAssertNotEqual(bar.state, .paste, "no Full Access")
        XCTAssertTrue(bar.pasteControl.isHidden, "no Full Access")
        access = true
        withExtendedLifetime((kb, doc)) { bar.refresh() }
        XCTAssertEqual(bar.state, .paste)
        XCTAssertFalse(bar.pasteControl.isHidden)
        XCTAssertTrue(bar.autofillButton.isHidden)
        XCTAssertTrue(bar.slotButtons.allSatisfy(\.isHidden))
        XCTAssertTrue(bar.pasteControl.target === bar, "the control pastes into the bar")
        XCTAssertTrue(bar.pasteControl.superview === bar)
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.pasteControl.frame, bar.bounds.insetBy(dx: 3, dy: 4), "the bar's area")
        XCTAssertGreaterThanOrEqual(bar.pasteControl.frame.height, 36, "shorter draws blank")
        XCTAssertEqual(bar.pasteControl.maximumContentSizeCategory, .large, "larger draws blank")
        XCTAssertEqual(bar.pasteConfiguration?.acceptableTypeIdentifiers, [UTType.plainText.identifier])
        let (_, mid, _) = pasteRig(pb) { $0.text = "hel" }
        XCTAssertNotEqual(mid.state, .paste, "mid-word")
        XCTAssertTrue(mid.pasteControl.isHidden, "mid-word")
    }

    func testTappingPasteInsertsTheClipAsIsAndRetiresIt() throws {
        let pb = try clipboard()
        pb.string = "one two\n"
        let (_, bar, doc) = pasteRig(pb) { $0.text = "say " }
        paste(bar, doc)
        XCTAssertEqual(doc.text, "say one two\n", "exactly the clip, no space")
        XCTAssertNotEqual(bar.state, .paste)
        let (_, fresh, _) = pasteRig(pb)
        XCTAssertNotEqual(fresh.state, .paste, "retired across launches: the same defaults")
        XCTAssertEqual(fresh.suggestions.memory.retiredClip, pb.changeCount)
        bar.paste(itemProviders: [NSItemProvider(object: "again" as NSString)])
        RunLoop.main.run(until: Date() + 0.2)
        XCTAssertEqual(doc.text, "say one two\n", "a paste (or a drop) once Paste is gone")
    }

    /// A double tap's second tap arrives once Paste is gone: its provider is never loaded,
    /// since loading it raises Allow Paste.
    func testALateTapLoadsNothing() throws {
        let pb = try clipboard()
        pb.string = "copied"
        let (_, bar, doc) = pasteRig(pb) { $0.text = "say h" }   // mid-word: no Paste
        XCTAssertNotEqual(bar.state, .paste)
        var loaded = false
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSString.self, visibility: .all) { done in
            loaded = true
            done("copied" as NSString, nil)
            return nil
        }
        bar.paste(itemProviders: [provider])
        RunLoop.main.run(until: Date() + 0.2)
        XCTAssertFalse(loaded, "loading the clip after Paste is gone raises Allow Paste")
        XCTAssertEqual(doc.text, "say h")
    }

    /// No Paste in landscape (OQ-43): the control draws blank and dead in the 32 pt bar.
    /// Slots show instead, a letter typed there leaves the clip fresh, and rotating to
    /// portrait brings Paste back, then rotating again takes it away.
    func testLandscapeShowsSlotsOverPasteAndPortraitBringsItBack() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let pb = try clipboard()
        pb.string = "copied"
        let (kb, bar, doc) = pasteRig(pb)
        defer { withExtendedLifetime(doc) {} }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: SuggestionBar.height(compact: true)
                                            + TerminalKeyboard.keysHeight(compact: true) + 6))
        window.traitOverrides.verticalSizeClass = .compact
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        bar.host(kb, in: view)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        XCTAssertNotEqual(bar.state, .paste, "landscape")
        XCTAssertTrue(bar.pasteControl.isHidden)
        XCTAssertFalse(bar.slotButtons.contains(where: \.isHidden), "slots")
        typing(kb, "h⌫")
        XCTAssertNotEqual(bar.suggestions.memory.retiredClip, pb.changeCount, "Paste never showed")
        window.traitOverrides.verticalSizeClass = .regular
        window.layoutIfNeeded()
        XCTAssertEqual(bar.state, .paste, "portrait")
        XCTAssertFalse(bar.pasteControl.isHidden)
        window.traitOverrides.verticalSizeClass = .compact
        window.layoutIfNeeded()
        XCTAssertNotEqual(bar.state, .paste, "landscape again")
        XCTAssertTrue(bar.pasteControl.isHidden)
        window.traitOverrides.verticalSizeClass = .regular
        window.layoutIfNeeded()
        XCTAssertEqual(bar.state, .paste, "the clip still fresh")
    }

    func testTypingRetiresTheClipAndANewCopyBringsItBack() throws {
        let pb = try clipboard()
        pb.string = "copied"
        let (kb, bar, doc) = pasteRig(pb)
        defer { withExtendedLifetime(doc) {} }
        XCTAssertEqual(bar.state, .paste)
        typing(kb, "h")
        XCTAssertNotEqual(bar.state, .paste)
        typing(kb, "⌫")
        XCTAssertNotEqual(bar.state, .paste, "deleting back to a word start doesn't bring it back")
        pb.string = "copied again"
        bar.refresh()
        XCTAssertEqual(bar.state, .paste, "a new copy")
    }

    /// After a paste ending a sentence or a line, shift is on for the next one.
    func testPasteAutoCapitalizesAfterIt() throws {
        let pb = try clipboard()
        for clip in ["Done.\n", "ok. "] {
            pb.string = clip
            let (kb, bar, doc) = pasteRig(pb) { $0.autocapitalizationType = .sentences; $0.text = "say " }
            XCTAssertEqual(kb.shift.mode, .off, clip)
            paste(bar, doc)
            XCTAssertEqual(doc.text, "say " + clip)
            XCTAssertEqual(kb.shift.mode, .once, clip)
        }
    }

    /// Only a letter types over the clip: space, return and backspace at a word start
    /// leave it offered.
    func testSpaceReturnAndBackspaceKeepPasteShowing() throws {
        let pb = try clipboard()
        pb.string = "copied"
        let (kb, bar, doc) = pasteRig(pb)
        for (key, name) in [(TerminalKeyboard.Key.space, "space"), (.ret, "return"), (.backspace, "backspace")] {
            kb.press(key)
            XCTAssertEqual(bar.state, .paste, name)
        }
        XCTAssertEqual(doc.text, " ")
        XCTAssertNotEqual(bar.suggestions.memory.retiredClip, pb.changeCount)
    }

    /// Paste only where a word would start: not glued to a token.
    func testPasteOnlyAfterWhitespaceOrAtTheStart() throws {
        let pb = try clipboard()
        pb.string = "copied"
        for (text, offered) in [("", true), ("hi ", true), ("hi\n", true),
                                ("abc1", false), ("mail@", false), ("alex.", false)] {
            let (_, bar, _) = pasteRig(pb) { $0.text = text }
            XCTAssertEqual(bar.state == .paste, offered, text)
        }
    }

    func testLoginFieldsKeepAutoFillOverPaste() throws {
        let pb = try clipboard()
        pb.string = "copied"
        let (_, bar, _) = pasteRig(pb) { $0.textContentType = .username }
        XCTAssertEqual(bar.state, .autofill)
        XCTAssertTrue(bar.pasteControl.isHidden)
    }
}
