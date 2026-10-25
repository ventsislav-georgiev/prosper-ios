import XCTest
import UIKit
@testable import Prosper

/// The Bulgarian system keyboard (`TerminalKeyboard.Layout.bulgarian`): Apple's
/// "Bulgarian – QWERTY" letters, English's holds on the same keys, a dictionary only when
/// the checker really has Bulgarian, and the app's keyboard still English. Driven like
/// SuggestionsTests: a fake host field, the bar attached, a throwaway defaults suite.
@MainActor
final class BulgarianKeyboardTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy
    typealias Layout = TerminalKeyboard.Layout

    private var suite = ""
    private var defaults: UserDefaults!
    private var spells = false

    override func setUp() {
        super.setUp()
        suite = "BulgarianKeyboardTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        spells = TerminalKeyboard.bulgarianSpells
        TerminalKeyboard.bulgarianSpells = false   // the simulator's: no Bulgarian lexicon
    }

    override func tearDown() {
        TerminalKeyboard.bulgarianSpells = spells
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func chars(_ keys: [TerminalKeyboard.Key]) -> String {
        keys.map { if case .char(let c) = $0 { return c } else { return "|" } }.joined()
    }

    /// The Bulgarian keyboard typing into a fake field with the bar attached, as the
    /// extension's controller wires it. Keep the bar: the keyboard holds it weakly.
    private func rig(_ configure: (Proxy) -> Void = { _ in }) -> (TerminalKeyboard, SuggestionBar, Proxy) {
        let doc = Proxy()
        doc.autocapitalizationType = .none
        configure(doc)
        let kb = TerminalKeyboard(layout: .bulgarian)
        kb.target = doc
        kb.settings.autoCapitalization = true   // the field's type decides
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults), layout: .bulgarian))
        bar.attach(kb)
        kb.autoCapitalize()
        return (kb, bar, doc)
    }

    /// " " space, "⌫" backspace, anything else its key.
    private func typing(_ kb: TerminalKeyboard, _ s: String) {
        for c in s {
            switch c {
            case " ": kb.press(.space)
            case "⌫": kb.press(.backspace)
            default: kb.press(.char(String(c)))
            }
        }
    }

    private func laidOut(_ kb: TerminalKeyboard, width: CGFloat = 402) -> [String: UIButton] {
        kb.frame = CGRect(x: 0, y: 0, width: width, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews { caps[b.title(for: .normal) ?? b.accessibilityLabel ?? ""] = b }
        return caps
    }

    // MARK: Layout

    func testRowsAreApplesBulgarianQwerty() {
        let bg = Layout.bulgarian.rows
        XCTAssertEqual(bg.map(chars), ["1234567890", "явертъуиопю", "асдфгхйклшщ", "|зьцжбнмч|", ".,/|?||"])
        XCTAssertEqual(bg[3].first, .shift)
        XCTAssertEqual(bg[3].last, .backspace)
        XCTAssertEqual(bg[0], TerminalKeyboard.rows[0], "Prosper's digits")
        XCTAssertEqual(bg[4], TerminalKeyboard.rows[4], "Prosper's bottom row")
        XCTAssertEqual(Layout.english.rows.map(chars),
                       ["1234567890", "qwertyuiop", "asdfghjkl", "|zxcvbnm|", ".,/|?||"], "English unchanged")
        XCTAssertEqual(Layout.bulgarian.letterRows.map { String($0) }, ["явертъуиопю", "асдфгхйклшщ", "зьцжбнмч"])
        XCTAssertEqual(Layout.english.letterRows.map { String($0) }, ["qwertyuiop", "asdfghjkl", "zxcvbnm"])
        XCTAssertEqual(Set(Layout.bulgarian.letterRows.joined()).count, 30, "30 letters, none twice")
    }

    func testTheLayoutComesFromPrimaryLanguage() {
        XCTAssertEqual(Layout(primaryLanguage: "bg-BG"), .bulgarian)
        XCTAssertEqual(Layout(primaryLanguage: "en-US"), .english)
        XCTAssertEqual(Layout(primaryLanguage: nil), .english)
        XCTAssertEqual(Layout(extension: .main), .english, "the app's bundle names none")
        XCTAssertEqual(TerminalKeyboard().layout, .english, "English by default")
    }

    /// The app embeds both keyboards, each naming its layout in its Info.plist.
    func testTheAppEmbedsBothKeyboards() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let keyboards = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "appex" }.compactMap(Bundle.init(url:))
            .filter { ($0.infoDictionary?["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]
                        as? String == "com.apple.keyboard-service" }
        let found = Dictionary(uniqueKeysWithValues: keyboards.map { ($0.bundleIdentifier ?? "", Layout(extension: $0)) })
        XCTAssertEqual(found, ["eu.illegible.prosperios.keyboard": .english,
                               "eu.illegible.prosperios.keyboard-bg": .bulgarian])
        let names = keyboards.compactMap { $0.infoDictionary?["CFBundleDisplayName"] as? String }
        XCTAssertEqual(names, ["Prosper", "Prosper"], "iOS shows the language under the name")
    }

    /// The terminal's keyboard is English whatever keyboards the system has.
    func testTheAppsKeyboardIsEnglish() throws {
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
        let kb = try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard)
        XCTAssertEqual(kb.layout, .english)
        let caps = laidOut(kb)
        XCTAssertNotNil(caps["q"])
        XCTAssertNil(caps["я"])
        XCTAssertNotNil(caps["space"])
    }

    // MARK: Holds

    /// Every English hold on the same key position, and so all 32 ASCII symbols; и holds ѝ
    /// and ю the > it gave up; ш, щ and ч hold nothing.
    func testHoldsStayOnTheirKeys() {
        let en = Layout.english, bg = Layout.bulgarian
        // Each row's first 10 / 9 / 7 Cyrillic letters sit where q…p / a…l / z…m do.
        for (enRow, bgRow) in zip(en.rows, bg.rows) {
            for (ec, bc) in zip(chars(enRow).split(separator: "|").joined(), chars(bgRow).split(separator: "|").joined())
            where bc != "и" {
                XCTAssertEqual(bg.holdSymbol[String(bc)], en.holdSymbol[String(ec)], "\(bc) where \(ec) is")
            }
        }
        XCTAssertEqual(bg.holdSymbol["и"], "ѝ")
        XCTAssertEqual(bg.holdSymbol["ю"], ">")
        XCTAssertEqual(en.holdSymbol["i"], ">", "English keeps its own")
        for c in ["ш", "щ", "ч"] { XCTAssertNil(bg.holdSymbol[c], c) }
        let letters = Set(bg.letterRows.joined().map(String.init))
        XCTAssertEqual(Set(bg.holdSymbol.keys).subtracting("0123456789".map(String.init)),
                       letters.subtracting(["ш", "щ", "ч"]), "only keys on the keyboard")
        let taps = bg.rows.joined().compactMap { k -> String? in if case .char(let c) = k { return c } else { return nil } }
        let symbols = Set((0x21...0x7E).map { String(UnicodeScalar(UInt8($0))) }).filter { !$0.first!.isLetter && !$0.first!.isNumber }
        XCTAssertEqual(symbols.count, 32)
        XCTAssertEqual(symbols.subtracting(taps + bg.holdSymbol.values).sorted(), [], "unreachable")
    }

    /// Through the view: holding и types ѝ (shifted Ѝ, and its bubble shows Ѝ too), ю types
    /// >, ш has nothing to hold.
    func testHoldsThroughTheKeyboard() throws {
        let (kb, bar, doc) = rig()
        let caps = laidOut(kb)
        var previews: [String?] = []
        func hold(_ label: String, id: Int) throws {
            let f = try XCTUnwrap(caps[label], label).frame, p = CGPoint(x: f.midX, y: f.midY)
            kb.track(.began, id: id, at: p)
            kb.fireHold()
            previews.append(kb.previewText)
            kb.track(.ended, id: id, at: p)
        }
        try withExtendedLifetime(bar) {
            try hold("и", id: 1)
            try hold("ю", id: 2)
            try hold("ш", id: 3)
            kb.press(.shift)
            try hold("и", id: 4)
        }
        XCTAssertEqual(previews, ["ѝ", ">", "ш", "Ѝ"], "the bubble shows what the lift types")
        XCTAssertEqual(doc.text, "ѝ>шЍ")
        XCTAssertEqual(caps["и"]?.subviews.compactMap { ($0 as? UILabel)?.text }.contains("ѝ"), true, "its hint")
    }

    // MARK: Fit

    /// Eleven keys a row fit every iPhone width and landscape without overlapping, and the
    /// shift row's letters are as wide as the top row's.
    func testElevenKeyRowsFit() throws {
        for width in [375, 393, 402, 440, 874] as [CGFloat] {
            let kb = TerminalKeyboard(layout: .bulgarian)
            let caps = laidOut(kb, width: width)
            let rows = Dictionary(grouping: kb.subviews.compactMap { $0 as? UIButton }, by: \.frame.minY)
                .sorted { $0.key < $1.key }.map { $0.value.sorted { $0.frame.minX < $1.frame.minX } }
            XCTAssertEqual(rows.map(\.count), [10, 11, 11, 10, 7], "at \(width)")
            for row in rows {
                XCTAssertGreaterThanOrEqual(row.first!.frame.minX, 0)
                XCTAssertLessThanOrEqual(row.last!.frame.maxX, width)
                for (a, b) in zip(row, row.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b.frame.minX - a.frame.maxX, TerminalKeyboard.keyGap - 0.001,
                                                "\(a.accessibilityLabel!) overlaps \(b.accessibilityLabel!) at \(width)")
                }
            }
            let ya = try XCTUnwrap(caps["я"]).frame.width, ze = try XCTUnwrap(caps["з"]).frame.width
            XCTAssertEqual(ze, ya, accuracy: 0.001, "at \(width)")
            XCTAssertGreaterThanOrEqual(ya, 24, "still a finger wide at \(width)")
            let english = try XCTUnwrap(laidOut(TerminalKeyboard(), width: width)["space"]).frame
            XCTAssertEqual(try XCTUnwrap(caps["БГ"]).frame, english, "the bottom row as English's at \(width)")
        }
    }

    /// At the narrowest iPhone each hint stays in its cap's top-right quadrant, shifted too.
    func testHintsSitTopRightOnElevenKeyRows() throws {
        let kb = TerminalKeyboard(layout: .bulgarian)
        let caps = laidOut(kb, width: 375)
        kb.press(.shift)
        kb.layoutIfNeeded()
        for (key, symbol) in Layout.bulgarian.holdSymbol {
            let cap = try XCTUnwrap(caps[key], key)
            cap.layoutIfNeeded()
            let hint = try XCTUnwrap(cap.subviews.compactMap { $0 as? UILabel }
                .first { $0 !== cap.titleLabel && $0.text == symbol }, key)
            XCTAssertGreaterThanOrEqual(hint.frame.minX, cap.bounds.midX, key)
            XCTAssertLessThanOrEqual(hint.frame.maxX, cap.bounds.maxX, key)
            XCTAssertLessThanOrEqual(hint.frame.maxY, cap.bounds.midY, key)
        }
    }

    func testLandscapeRowsFit() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.traitOverrides.verticalSizeClass = .compact
        let kb = TerminalKeyboard(layout: .bulgarian)
        kb.frame = CGRect(x: 0, y: 0, width: 874, height: TerminalKeyboard.height)
        window.addSubview(kb)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let caps = kb.subviews.compactMap { $0 as? UIButton }
        XCTAssertEqual(Set(caps.map(\.frame.minY)).count, 5)
        XCTAssertTrue(caps.allSatisfy { $0.frame.height == 26 })
        for label in ["ю", "щ", "ч", "я"] {
            let f = try XCTUnwrap(caps.first { $0.accessibilityLabel == label }, label).frame
            XCTAssertEqual(kb.key(at: CGPoint(x: f.midX, y: f.midY)), .char(label))
        }
    }

    // MARK: Typing

    /// Shift capitals, a capital after ". ", two spaces and backspace, in
    /// Cyrillic; the space bar carries the БГ tag.
    func testTypingCyrillic() throws {
        let (kb, bar, doc) = rig { $0.autocapitalizationType = .sentences }
        XCTAssertEqual(kb.shift.mode, .once, "the field's start")
        typing(kb, "здравей. как си")
        XCTAssertEqual(doc.text, "Здравей. Как си")
        typing(kb, "  утре")
        XCTAssertEqual(doc.text, "Здравей. Как си  утре", "two spaces are two spaces")
        typing(kb, "⌫⌫")
        XCTAssertEqual(doc.text, "Здравей. Как си  ут")
        kb.press(.shift)
        typing(kb, "ж")
        XCTAssertEqual(doc.text, "Здравей. Как си  утЖ")
        kb.press(.shift); kb.press(.shift)   // caps lock
        typing(kb, "щ ю")
        XCTAssertEqual(doc.text, "Здравей. Как си  утЖЩ Ю")
        withExtendedLifetime(bar) {}
        XCTAssertEqual(laidOut(kb)["БГ"]?.accessibilityLabel, "space")
    }

    // MARK: Suggestions

    /// No Bulgarian dictionary (the probe failed): the bar shows only the typed word, space
    /// changes nothing, and English never stands in, even for Latin text.
    func testWithoutADictionaryNothingIsGuessedOrCorrected() {
        let s = Suggestions(memory: TypingMemory(defaults: defaults), layout: .bulgarian)
        XCTAssertNil(s.language)
        let (kb, bar, doc) = rig()
        for word in ["къша", "teh", "helo"] {
            doc.text = ""
            typing(kb, word)
            XCTAssertEqual(bar.state, .slots([Suggestions.Slot(word: word, quoted: true), nil, nil]), word)
            typing(kb, " ")
            XCTAssertEqual(doc.text, word + " ", "\(word) stays as typed")
        }
        XCTAssertFalse(s.knows("teh"))
        XCTAssertTrue(Suggestions.guesses("teh", language: s.language).isEmpty)
        XCTAssertTrue(Suggestions.completions("hel", language: s.language).isEmpty)
    }

    /// Learning, text replacements and predictions still work without a dictionary.
    func testLearningAndReplacementsWorkWithoutADictionary() throws {
        let (kb, bar, doc) = rig()
        bar.suggestions.load([("бгр", "България")])
        typing(kb, "бгр ")
        XCTAssertEqual(doc.text, "България ", "a text replacement")
        typing(kb, "ябълка")
        bar.suggestions.tap(Suggestions.Slot(word: "ябълка", quoted: true), in: doc)
        XCTAssertTrue(bar.suggestions.memory.known.contains("ябълка"), "learned")
        doc.text = ""
        typing(kb, "ябъ")
        bar.refresh()
        guard case .slots(let slots) = bar.state else { return XCTFail("\(bar.state)") }
        XCTAssertTrue(slots.contains { $0?.word == "ябълка" }, "the learned word completes")
    }

    /// The probe spells Bulgarian only when the typo is listed, flagged and guessed for.
    func testSpellsNeedsAFlaggedTypoWithGuesses() {
        func spells(_ listed: Bool, _ flags: Bool, _ guesses: [String]) -> Bool {
            TerminalKeyboard.spells(listed: listed, flags: { flags }, guesses: { guesses })
        }
        XCTAssertFalse(spells(false, true, ["кърша"]), "not listed")
        XCTAssertFalse(spells(true, false, ["кърша"]), "listed, every word passes")
        XCTAssertFalse(spells(true, true, []), "flagged, nothing guessed")
        XCTAssertTrue(spells(true, true, ["кърша"]))
    }

    /// With a Bulgarian dictionary the checker is asked in Bulgarian; English keeps its own.
    func testWithADictionaryBulgarianIsUsed() {
        TerminalKeyboard.bulgarianSpells = true
        XCTAssertEqual(Layout.bulgarian.language, "bg_BG")
        XCTAssertEqual(Suggestions(memory: TypingMemory(defaults: defaults), layout: .bulgarian).language, "bg_BG")
        XCTAssertEqual(Suggestions(memory: TypingMemory(defaults: defaults)).language, TerminalKeyboard.language)
        XCTAssertEqual(Layout.english.language, TerminalKeyboard.language)
        XCTAssertNotNil(TerminalKeyboard.language)
    }

    func testNeighborsFollowTheBulgarianRows() {
        let rows = Layout.bulgarian.letterRows
        func n(_ a: Character, _ b: Character) -> Bool { Suggestions.neighbors(a, b, rows: rows) }
        XCTAssertTrue(n("я", "в"))
        XCTAssertTrue(n("я", "а"), "a row apart")
        XCTAssertTrue(n("ю", "щ"), "the eleventh column")
        XCTAssertTrue(n("м", "ч"))
        XCTAssertFalse(n("я", "ю"), "the row's two ends")
        XCTAssertFalse(n("я", "е"), "two keys apart")
        XCTAssertFalse(n("я", "з"), "two rows apart")
        XCTAssertFalse(Suggestions.neighbors("я", "в"), "not on the English rows")
        XCTAssertTrue(Suggestions.neighbors("q", "w"), "English's default")
        XCTAssertTrue(Suggestions.isConfident("сал", guess: "дал", rows: rows), "с and д are neighbors")
        XCTAssertFalse(Suggestions.isConfident("сал", guess: "дал", rows: Layout.english.letterRows))
    }
}
