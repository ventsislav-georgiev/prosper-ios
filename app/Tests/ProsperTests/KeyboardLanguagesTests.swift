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

    /// The Prosper keyboard shows the last language switched to while it's still on, else
    /// the first; the Bulgarian extension is Bulgarian only, whatever the setting says. The
    /// pick round-trips through the App Group.
    func testTheShownLanguageAndTheBulgarianExtension() {
        var s = KeyboardSettings()
        s.languages = [.english, .bulgarian]
        XCTAssertTrue(KeyboardSettings.languages(fixed: .english, settings: s, active: .bulgarian) == ([.english, .bulgarian], .bulgarian))
        XCTAssertTrue(KeyboardSettings.languages(fixed: .english, settings: s, active: nil) == ([.english, .bulgarian], .english))
        s.languages = [.english]
        XCTAssertTrue(KeyboardSettings.languages(fixed: .english, settings: s, active: .bulgarian) == ([.english], .english),
                      "Bulgarian turned off: back to English")
        for languages in [[Layout.english], [.english, .bulgarian]] {
            s.languages = languages
            XCTAssertTrue(KeyboardSettings.languages(fixed: .bulgarian, settings: s, active: .english) == ([.bulgarian], .bulgarian),
                          "the Bulgarian extension stays Bulgarian with \(languages)")
        }

        let saved = KeyboardSettings.store
        defer { KeyboardSettings.store = saved }
        KeyboardSettings.store = { [defaults] in defaults }
        XCTAssertNil(KeyboardSettings.activeLanguage)
        KeyboardSettings.activeLanguage = .bulgarian
        XCTAssertEqual(KeyboardSettings.activeLanguage, .bulgarian)
        XCTAssertEqual(Layout.bulgarian.primaryLanguage, "bg-BG")
        XCTAssertEqual(Layout.english.primaryLanguage, "en-US")
    }

    /// A switch rebuilds the letters and their holds in place, and the bar's suggestions take
    /// the new layout's dictionary and neighbors; the controller hears of it once.
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
        XCTAssertEqual(bar.menuItems.map(\.title), ["Next Keyboard"])
        kb.languages = [.english, .bulgarian]
        XCTAssertEqual(bar.menuItems.map(\.title), ["Български", "Next Keyboard"])
        try XCTUnwrap(bar.menuItems.first { $0.title == "Български" }).run()
        XCTAssertEqual(kb.layout, .bulgarian)
        XCTAssertEqual(bar.menuItems.map(\.title), ["English", "Next Keyboard"])
        for item in bar.menuItems { XCTAssertNotNil(UIImage(systemName: item.symbol), item.title) }
    }
}
