import XCTest
import UIKit
@testable import Prosper

/// One Prosper keyboard with English and Bulgarian (#624): the Languages setting
/// (`KeyboardSettings.languages`), the layout following the shown language, the toggle's
/// menu tile that switches it, and the Bulgarian extension staying
/// Bulgarian only.
@MainActor
final class KeyboardLanguagesTests: XCTestCase {
    typealias Layout = TerminalKeyboard.Layout
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var suite = ""
    private var defaults: UserDefaults!
    private var spells = false

    override func setUp() {
        super.setUp()
        suite = "KeyboardLanguagesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        spells = TerminalKeyboard.bulgarianSpells
        TerminalKeyboard.bulgarianSpells = false   // the simulator's: no Bulgarian lexicon
    }

    override func tearDown() {
        TerminalKeyboard.bulgarianSpells = spells
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A keyboard on a fake field, laid out, the bar attached, with `languages`.
    private func rig(_ languages: [Layout]) -> (TerminalKeyboard, SuggestionBar, Proxy) {
        let doc = Proxy()
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        kb.languages = languages
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults)))
        bar.attach(kb)
        return (kb, bar, doc)
    }

    private func titles(_ kb: TerminalKeyboard) -> [String] {
        kb.layoutIfNeeded()
        return kb.subviews.compactMap { ($0 as? UIButton)?.title(for: .normal) }
    }

    /// English only until someone turns Bulgarian on: nothing stored, junk, or an empty list
    /// is English; what's stored decodes in `allCases` order, once each.
    func testLanguagesDecodeAndDefaultToEnglishOnly() {
        XCTAssertEqual(KeyboardSettings().languages, [.english])
        XCTAssertEqual(KeyboardSettings(defaults).languages, [.english], "nothing stored")
        XCTAssertEqual(KeyboardSettings.languages(""), [.english])
        XCTAssertEqual(KeyboardSettings.languages("klingon"), [.english], "unknown dropped, never empty")
        XCTAssertEqual(KeyboardSettings.languages("bulgarian"), [.bulgarian])
        XCTAssertEqual(KeyboardSettings.languages("bulgarian,english,bulgarian"), [.english, .bulgarian])
        defaults.set("english,bulgarian", forKey: KeyboardSettings.Key.languages)
        XCTAssertEqual(KeyboardSettings(defaults).languages, [.english, .bulgarian])
    }

    /// Prosper always has the setting; Prosper (Bulgarian) has it when Bulgarian is in it, else
    /// Bulgarian only. Each opens in its own language, or the first of `all` without it (#640).
    func testEachExtensionsLanguagesForEachSetting() {
        let en = Layout.english, bg = Layout.bulgarian
        let cases: [(settings: [Layout], fixed: Layout, all: [Layout], own: Layout)] = [
            ([en], en, [en], en), ([en], bg, [bg], bg),
            ([bg], en, [bg], bg), ([bg], bg, [bg], bg),
            ([en, bg], en, [en, bg], en), ([en, bg], bg, [en, bg], bg),
        ]
        for c in cases {
            var s = KeyboardSettings()
            s.languages = c.settings
            let other: Layout = c.fixed == en ? bg : en
            let label = "\(c.fixed) with \(c.settings)"
            func shown(_ last: Layout?, _ active: Layout?) -> Layout {
                let l = KeyboardSettings.languages(fixed: c.fixed, main: c.fixed == en, settings: s, fullAccess: true,
                                                   last: last, active: active)
                XCTAssertEqual(l.all, c.all, label)
                return l.shown
            }
            XCTAssertEqual(shown(nil, nil), c.own, "\(label): first appear")
            XCTAssertEqual(shown(other, other), c.own, "\(label): after a globe hop, its own")
            XCTAssertEqual(shown(other, nil), c.own, "\(label): after a globe hop, nothing switched")
            XCTAssertEqual(shown(c.fixed, other), c.all.contains(other) ? other : c.own,
                           "\(label): re-shown, the last switched to while it's in all")
            XCTAssertEqual(shown(nil, other), c.all.contains(other) ? other : c.own, "\(label): no record reads as a re-show")
        }
    }

    /// Bulgarian only, with Prosper alone (the #624 path): it types Bulgarian, as before #640.
    func testProsperAloneWithBulgarianOnlyTypesBulgarian() {
        var s = KeyboardSettings()
        s.languages = [.bulgarian]
        func main(_ last: Layout?, _ active: Layout?, fullAccess: Bool = true, _ settings: KeyboardSettings? = nil)
            -> (all: [Layout], shown: Layout) {
            KeyboardSettings.languages(fixed: .english, main: true, settings: settings ?? s, fullAccess: fullAccess,
                                       last: last, active: active)
        }
        XCTAssertTrue(main(nil, nil) == ([.bulgarian], .bulgarian), "fresh")
        XCTAssertTrue(main(.bulgarian, .english) == ([.bulgarian], .bulgarian), "after a hop from Prosper (Bulgarian)")
        XCTAssertTrue(main(.english, .bulgarian) == ([.bulgarian], .bulgarian), "re-shown")
        XCTAssertTrue(main(.english, .english) == ([.bulgarian], .bulgarian), "re-shown, English since turned off")
        XCTAssertTrue(main(nil, nil, fullAccess: false, KeyboardSettings.current(fullAccess: false)) == ([.english], .english),
                      "no Full Access: the defaults, English")
        var english = KeyboardSettings()
        english.languages = [.english]
        XCTAssertTrue(KeyboardSettings.languages(fixed: .bulgarian, main: false, settings: english,
                                                 fullAccess: true, last: .english, active: .english) == ([.bulgarian], .bulgarian),
                      "Prosper (Bulgarian) with English only: Bulgarian only")
    }

    /// The App Group round trip as the controller drives it: appear, on screen, switch (#640).
    func testAGlobeHopOpensEachExtensionInItsOwnLanguage() {
        let saved = KeyboardSettings.store
        defer { KeyboardSettings.store = saved }
        KeyboardSettings.store = { [defaults] in defaults }
        var s = KeyboardSettings()
        s.languages = [.english, .bulgarian]
        func appear(_ fixed: Layout) -> Layout {
            let l = KeyboardSettings.languages(fixed: fixed, main: fixed == .english, settings: s, fullAccess: true)
            XCTAssertEqual(l.all, [.english, .bulgarian])
            KeyboardSettings.shown(fixed, in: l.shown, fullAccess: true)
            return l.shown
        }
        XCTAssertEqual(appear(.english), .english)
        XCTAssertEqual(KeyboardSettings.shownExtension, .english)
        KeyboardSettings.activeLanguage = .bulgarian   // the key or the menu
        XCTAssertEqual(appear(.english), .bulgarian, "Prosper re-shown keeps the last switched to")
        XCTAssertEqual(appear(.bulgarian), .bulgarian, "the globe to Prosper (Bulgarian)")
        KeyboardSettings.activeLanguage = .english
        XCTAssertEqual(appear(.bulgarian), .english, "Prosper (Bulgarian) re-shown keeps it too")
        KeyboardSettings.activeLanguage = .bulgarian
        XCTAssertEqual(appear(.english), .english, "the globe back to Prosper: English, not the Bulgarian left")
        XCTAssertEqual(appear(.english), .english, "and re-shown, what it showed")
        XCTAssertEqual(appear(.bulgarian), .bulgarian)

        XCTAssertEqual(Layout.bulgarian.primaryLanguage, "bg-BG")
        XCTAssertEqual(Layout.english.primaryLanguage, "en-US")
    }

    /// Without Full Access each opens in its own language, and the group is never touched.
    func testWithoutFullAccessEachOpensInItsOwnLanguage() {
        let saved = KeyboardSettings.store
        defer { KeyboardSettings.store = saved }
        KeyboardSettings.store = { [defaults] in defaults }
        KeyboardSettings.shownExtension = .english
        KeyboardSettings.activeLanguage = .english
        var reads = 0
        KeyboardSettings.store = { [defaults] in reads += 1; return defaults }
        let s = KeyboardSettings.current(fullAccess: false)
        for fixed in Layout.allCases {
            let l = KeyboardSettings.languages(fixed: fixed, main: fixed == .english, settings: s, fullAccess: false)
            XCTAssertTrue(l == ([fixed], fixed), "\(fixed)")
            KeyboardSettings.shown(fixed, in: fixed, fullAccess: false)
            var all = KeyboardSettings()
            all.languages = [.english, .bulgarian]
            XCTAssertEqual(KeyboardSettings.languages(fixed: fixed, main: fixed == .english, settings: all, fullAccess: false,
                                                      last: fixed, active: fixed == .english ? .bulgarian : .english).shown,
                           fixed, "stale values passed in are ignored")
        }
        XCTAssertEqual(reads, 0, "no App Group reads or writes")
        KeyboardSettings.store = { [defaults] in defaults }
        XCTAssertEqual(KeyboardSettings.shownExtension, .english, "unchanged")
    }

    func testTheLayoutFollowsTheLanguage() {
        let (kb, bar, _) = rig([.english, .bulgarian])
        var heard: [Layout] = []
        bar.languageChanged = { heard.append($0) }
        XCTAssertTrue(titles(kb).contains("q"))
        kb.layout = .bulgarian
        XCTAssertTrue(titles(kb).contains("я"))
        XCTAssertFalse(titles(kb).contains("q"))
        XCTAssertTrue(titles(kb).contains("БГ"), "space says so")
        XCTAssertEqual(bar.suggestions.layout, .bulgarian)
        XCTAssertNil(bar.suggestions.language, "no Bulgarian checker here: no English in its place")
        kb.layout = .bulgarian
        XCTAssertEqual(heard, [.bulgarian], "an unchanged layout tells no one")
        kb.layout = .english
        XCTAssertTrue(titles(kb).contains("q"))
        XCTAssertEqual(bar.suggestions.language, TerminalKeyboard.language)
        XCTAssertEqual(heard, [.bulgarian, .english])
    }

    /// With two languages the menu offers the other one, before Next Keyboard, and its pick
    /// switches; with one, no language tile.
    func testTheMenuOffersTheOtherLanguageOnlyWithTwo() throws {
        let (kb, bar, _) = rig([.english])
        XCTAssertEqual(bar.menuItems.map(\.title), ["Emoji", "Appearance", "Next Keyboard"])
        kb.languages = [.english, .bulgarian]
        XCTAssertEqual(bar.menuItems.map(\.title), ["Emoji", "Български", "Appearance", "Next Keyboard"])
        try XCTUnwrap(bar.menuItems.first { $0.title == "Български" }).run()
        XCTAssertEqual(kb.layout, .bulgarian)
        XCTAssertEqual(bar.menuItems.map(\.title), ["Emoji", "English", "Appearance", "Next Keyboard"])
        for item in bar.menuItems { XCTAssertNotNil(UIImage(systemName: item.symbol), item.title) }
    }

    /// One store holds both languages' words: an empty field offers the shown layout's only,
    /// the same after a switch as at a launch in it, both ways (#635).
    func testEmptyFieldSlotsFollowASwitch() {
        let memory = TypingMemory(defaults: defaults)
        for (w, n) in [("the", 3), ("a", 2), ("o", 1), ("и", 3), ("да", 2), ("на", 1)] {
            for _ in 0..<n { memory.record("", w) }
        }
        let (kb, bar, doc) = rig([.english, .bulgarian])
        func slots(_ s: Suggestions) -> [String?] {
            guard case .slots(let slots) = s.state(doc, shift: .off) else { return [] }
            return slots.map { $0?.word }
        }
        let launched = { (layout: Layout) in slots(Suggestions(memory: memory, layout: layout)) }
        XCTAssertEqual(launched(.english), ["a", "the", "o"])
        XCTAssertEqual(launched(.bulgarian), ["да", "и", "на"])
        kb.layout = .bulgarian
        XCTAssertEqual(slots(bar.suggestions), ["да", "и", "на"], "Bulgarian's, as a Bulgarian launch")
        kb.layout = .english
        XCTAssertEqual(slots(bar.suggestions), ["a", "the", "o"], "and English's back")
        doc.text = "д"
        kb.layout = .bulgarian
        XCTAssertEqual(slots(bar.suggestions), launched(.bulgarian), "mid-word too")
    }

    // MARK: Language key (#638)

    private func caps(_ kb: TerminalKeyboard) -> [UIButton] {
        kb.layoutIfNeeded()
        return kb.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden }
    }

    private func languageKey(_ kb: TerminalKeyboard) -> UIButton? {
        caps(kb).first { $0.accessibilityLabel?.hasPrefix("Switch to") == true }
    }

    func testTheLanguageKeyShowsOnlyWithTwoLanguages() {
        XCTAssertFalse(TerminalKeyboard().shownKeys.joined().contains(.language), "the app's keyboard: no languages")
        let (kb, _, _) = rig([.english])
        XCTAssertFalse(kb.shownKeys.joined().contains(.language), "one language: no key")
        let one = kb.shownKeys.last
        kb.languages = [.english, .bulgarian]
        XCTAssertEqual(kb.shownKeys.last?.first, .language, "it leads the bottom row")
        XCTAssertNotNil(languageKey(kb))
        kb.languages = [.english]
        XCTAssertEqual(kb.shownKeys.last, one, "Bulgarian turned off: the row as it was")
        XCTAssertNil(languageKey(kb))
    }

    func testATapSwitchesToTheNextLanguageAndRelabels() throws {
        let (kb, bar, doc) = rig([.english, .bulgarian])
        var heard: [Layout] = []
        bar.languageChanged = { heard.append($0) }
        func tap() throws {
            let f = try XCTUnwrap(languageKey(kb)).frame
            kb.track(.began, id: 1, at: CGPoint(x: f.midX, y: f.midY))
            kb.track(.ended, id: 1, at: CGPoint(x: f.midX, y: f.midY))
        }
        let key = try XCTUnwrap(languageKey(kb))
        XCTAssertEqual(key.title(for: .normal), "БГ", "named for where it goes")
        XCTAssertEqual(key.accessibilityLabel, "Switch to Български")
        XCTAssertTrue(key.accessibilityTraits.contains(.keyboardKey))
        XCTAssertEqual(key.backgroundColor, TerminalKeyboard.Style.special)
        XCTAssertFalse(key.isUserInteractionEnabled, "a tracked key, not one with its own touches")
        try tap()
        XCTAssertEqual(kb.layout, .bulgarian, "one tap switches")
        XCTAssertEqual(heard, [.bulgarian], "layoutChanged reaches the bar")
        XCTAssertEqual(bar.suggestions.layout, .bulgarian)
        XCTAssertEqual(try XCTUnwrap(languageKey(kb)).title(for: .normal), "EN")
        XCTAssertEqual(languageKey(kb)?.accessibilityLabel, "Switch to English")
        try tap()
        XCTAssertEqual(kb.layout, .english, "and wraps around")
        XCTAssertEqual(heard, [.bulgarian, .english])
        XCTAssertEqual(doc.text, "", "it types nothing")
    }

    func testTheLanguageKeyFollows123AndPrecedesTheGlobe() {
        let (kb, _, _) = rig([.english, .bulgarian])
        kb.offersEmoji = false
        kb.showsGlobe = true
        kb.allowsNumbersKey = true
        kb.settings.numbers = .key
        let row: [TerminalKeyboard.Key] = [.numbers, .language, .globe, .char("."), .char(","), .char("/"), .space, .char("?"), .ret]
        XCTAssertEqual(kb.shownKeys.last, row)
        let shown = caps(kb).filter { $0.frame.midY == languageKey(kb)?.frame.midY }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(shown.map { $0.accessibilityLabel ?? "" },
                       ["numbers", "Switch to Български", "next keyboard", ".", ",", "/", "space", "?", "new line"])
        for (a, b) in zip(shown, shown.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.frame.minX - a.frame.maxX, TerminalKeyboard.keyGap - 0.001, "\(a.accessibilityLabel!) overlaps")
        }
        kb.press(.numbers)
        XCTAssertFalse(kb.shownKeys.joined().contains(.language), "none on the numpad")
        kb.press(.numbers)
        XCTAssertEqual(kb.shownKeys.last, row, "back with the letters")
    }

    func testALetterTouchIsNeverCorrectedOntoTheLanguageKey() throws {
        let (kb, _, _) = rig([.english, .bulgarian])
        kb.press(.char("t"))   // a word under way: touches off a letter's center may be corrected
        let all = caps(kb)
        let key = try XCTUnwrap(languageKey(kb)).frame
        var x = key.minX - 30
        while x < key.maxX + 30 {
            var y = key.minY - 60
            while y < key.maxY + 10 {
                let p = CGPoint(x: x, y: y)
                let nearest = all.min { TerminalKeyboard.distance(p, $0.frame) < TerminalKeyboard.distance(p, $1.frame) }
                if nearest?.frame != key {
                    XCTAssertNotEqual(kb.key(at: p), .language, "\(p), nearest \(nearest?.accessibilityLabel ?? "")")
                }
                y += 2
            }
            x += 2
        }
    }
}
