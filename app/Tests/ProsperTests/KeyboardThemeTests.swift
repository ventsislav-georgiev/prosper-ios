import XCTest
import UIKit
@testable import Prosper

/// Keyboard themes and accents (#626): the default palette's tokens, Light and True Black on
/// a built keyboard, the accent on return, a live change redrawing in place, the bar, panels
/// and numpad following, and the settings' round trip through the App Group store.
@MainActor
final class KeyboardThemeTests: XCTestCase {
    typealias Style = TerminalKeyboard.Style
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var suite = ""
    private var defaults: UserDefaults!
    private var store: (() -> UserDefaults?)!
    private var palette: Style.Palette!

    override func setUp() {
        super.setUp()
        suite = "KeyboardThemeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = KeyboardSettings.store
        KeyboardSettings.store = { [defaults] in defaults }
        palette = Style.palette
        Style.palette = Style.Palette(KeyboardSettings())
    }

    override func tearDown() {
        Style.palette = palette
        KeyboardSettings.store = store
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func laidOut() -> TerminalKeyboard {
        let kb = TerminalKeyboard()
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        return kb
    }

    private func caps(_ kb: TerminalKeyboard) -> [UIButton] { kb.subviews.compactMap { $0 as? UIButton } }

    /// The cap showing `title` (its accessibility label for a glyph cap).
    private func cap(_ kb: TerminalKeyboard, _ title: String) throws -> UIButton {
        try XCTUnwrap(caps(kb).first { !$0.isHidden && ($0.title(for: .normal) ?? $0.accessibilityLabel) == title }, title)
    }

    /// The default: Dark with the violet accent, the redesign's tokens.
    func testTheDefaultIsTheRedesignedDarkWithViolet() {
        let settings = KeyboardSettings()
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertEqual(settings.accent, .violet)
        let p = Style.Palette(settings)
        XCTAssertEqual(p.backdrop, UIColor(hex: 0x101115))
        XCTAssertEqual(p.key, UIColor(hex: 0x2B2D34))
        XCTAssertEqual(p.keyPressed, UIColor(hex: 0x3B3E47))
        XCTAssertEqual(p.special, UIColor(hex: 0x1D1F25))
        XCTAssertEqual(p.specialPressed, UIColor(hex: 0x2B2D34))
        XCTAssertEqual(p.surface, p.special, "Dark's surfaces are its specials")
        XCTAssertEqual(p.surfacePressed, p.specialPressed)
        XCTAssertEqual(Style.Palette.black.surface, Style.Palette.black.special)
        XCTAssertEqual(Style.Palette.light.surface, UIColor(hex: 0xFFFFFF), "Light's surfaces are white")
        XCTAssertEqual(Style.Palette.light.surfacePressed, UIColor(hex: 0xE4E6EA))
        XCTAssertEqual(Style.Palette.light.special, UIColor(hex: 0xADB1BA))
        XCTAssertEqual(p.label, UIColor(hex: 0xF2F3F5))
        XCTAssertEqual(p.hint, UIColor(white: 1, alpha: 0.55))
        XCTAssertEqual(p.hairline, UIColor(white: 1, alpha: 0.07))
        XCTAssertEqual(p.accent, UIColor(hex: 0x8B7CFF))
        XCTAssertEqual(p.accentEnd, UIColor(hex: 0x5E8BFF))
        XCTAssertEqual(p.onAccent, .white)
        XCTAssertEqual(p.style, .dark)
        XCTAssertEqual(Style.radius, 8)

        let kb = laidOut()
        XCTAssertEqual(try cap(kb, "q").backgroundColor, p.key)
        XCTAssertEqual(try cap(kb, "q").titleColor(for: .normal), p.label)
        XCTAssertEqual(try cap(kb, "shift").backgroundColor, p.special)
        XCTAssertEqual(kb.backgroundColor, p.backdrop)
        XCTAssertEqual(try cap(kb, "q").layer.cornerRadius, 8)
    }

    /// Light and True Black recolour a built keyboard's caps, labels and backdrop in place:
    /// the caps are made again, as many as before, none left behind.
    func testLightAndTrueBlackRecolourABuiltKeyboard() throws {
        let kb = laidOut()
        let count = caps(kb).count
        let dark = try cap(kb, "q").backgroundColor
        for (theme, want) in [(KeyboardSettings.Theme.light, Style.Palette.light), (.black, .black)] {
            kb.settings.theme = theme
            kb.layoutIfNeeded()
            XCTAssertEqual(caps(kb).count, count, "\(theme): no caps leak")
            XCTAssertEqual(try cap(kb, "q").backgroundColor, want.key, "\(theme)")
            XCTAssertNotEqual(try cap(kb, "q").backgroundColor, dark, "\(theme)")
            XCTAssertEqual(try cap(kb, "q").titleColor(for: .normal), want.label, "\(theme)")
            XCTAssertEqual(try cap(kb, "5").backgroundColor, want.special, "\(theme): the digit row")
            XCTAssertEqual(kb.backgroundColor, want.backdrop, "\(theme)")
            XCTAssertEqual(kb.overrideUserInterfaceStyle, want.style, "\(theme)")
        }
        XCTAssertEqual(Style.Palette.light.label, UIColor(hex: 0x111111))
        XCTAssertEqual(Style.Palette.black.backdrop, .black)
        kb.settings.theme = .dark
        XCTAssertEqual(try cap(kb, "q").backgroundColor, dark, "back")
        XCTAssertEqual(caps(kb).count, count)
    }

    /// The accent fills return, and its label reads on it; None is the labels' colour.
    func testTheAccentTintsReturn() throws {
        let kb = laidOut()
        XCTAssertEqual(try cap(kb, "new line").backgroundColor, UIColor(hex: 0x8B7CFF))
        XCTAssertEqual(try cap(kb, "new line").tintColor, .white)
        kb.settings.accent = .green
        XCTAssertEqual(try cap(kb, "new line").backgroundColor, UIColor(hex: 0x34D399))
        XCTAssertEqual(try cap(kb, "delete").backgroundColor, Style.special, "only return")
        kb.settings.accent = .none
        XCTAssertEqual(try cap(kb, "new line").backgroundColor, Style.label)
        XCTAssertEqual(try cap(kb, "new line").tintColor, Style.backdrop)
    }

    /// The extension's bar, toolbar, panels and numpad take the keyboard's theme: what's open
    /// as the theme changes is redrawn, a panel opened after is made in it.
    func testTheBarPanelsAndNumpadFollowTheTheme() throws {
        let doc = Proxy()
        let kb = TerminalKeyboard()
        kb.target = doc
        kb.offersEmoji = false
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults)))
        bar.attach(kb)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Theme-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        bar.history = ClipboardHistory(dir: dir.appendingPathComponent("Clips"))
        bar.snippets = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        bar.suggestions.pasteboard = { pb }
        kb.allowsNumbersKey = true
        let light = Style.Palette.light
        XCTAssertEqual(view.backgroundColor, Style.Palette.dark.backdrop)

        var settings = KeyboardSettings()
        settings.theme = .light
        settings.numbers = .key
        kb.settings = settings
        XCTAssertEqual(view.backgroundColor, light.backdrop, "the host's backdrop")
        XCTAssertEqual(bar.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(bar.toggle?.configuration?.background.backgroundColor, light.surface, "the toggle")
        let toolbar = try XCTUnwrap(bar.toolbar)
        let toolCap = try XCTUnwrap(Self.all(toolbar).compactMap { $0 as? KeyCapButton }.first { $0.accessibilityLabel == "tab" })
        XCTAssertEqual(toolCap.configuration?.background.backgroundColor, light.surface, "the toolbar's caps")

        kb.showNumpad(true, animated: false)
        XCTAssertEqual(try cap(kb, "5").backgroundColor, light.key, "the numpad's digits")
        XCTAssertEqual(try cap(kb, "5").titleColor(for: .normal), light.label)
        kb.showNumpad(false, animated: false)

        bar.showClips(true)
        let clips = try XCTUnwrap(bar.clipsPanel)
        XCTAssertEqual(clips.backgroundColor, light.backdrop)
        XCTAssertEqual(clips.title.textColor, light.label)
        XCTAssertEqual(clips.table.backgroundColor, light.surface, "the card")
        bar.showSnippets(true)
        XCTAssertEqual(try XCTUnwrap(bar.snippetsPanel).backgroundColor, light.backdrop)
        bar.showMenu(true)
        let tile = try XCTUnwrap(bar.menuPanel?.tiles.first)
        tile.setNeedsUpdateConfiguration()
        tile.layoutIfNeeded()
        XCTAssertEqual(tile.configuration?.background.backgroundColor, light.surface, "the menu's tiles")
        bar.showMenu(false)

        kb.showEmoji(true)
        let picker = try XCTUnwrap(kb.emojiPicker)
        XCTAssertEqual(picker.groupButtons.first?.tintColor, Style.accent, "Recents lit")
        withExtendedLifetime((doc, kb)) {}
    }

    private static func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }

    /// Both settings round-trip through the App Group store; unknown or absent values and no
    /// Full Access read as the defaults.
    func testThemeAndAccentRoundTripThroughTheStore() {
        XCTAssertEqual(KeyboardSettings.current().theme, .dark)
        XCTAssertEqual(KeyboardSettings.current().accent, .violet)
        defaults.set(KeyboardSettings.Theme.black.rawValue, forKey: "keyboard.theme")
        defaults.set(KeyboardSettings.Accent.pink.rawValue, forKey: "keyboard.accent")
        XCTAssertEqual(KeyboardSettings.current().theme, .black)
        XCTAssertEqual(KeyboardSettings.current().accent, .pink)
        XCTAssertEqual(KeyboardSettings.current(fullAccess: false).theme, .dark)
        XCTAssertEqual(KeyboardSettings.current(fullAccess: false).accent, .violet)
        defaults.set("sepia", forKey: "keyboard.theme")
        defaults.set("teal", forKey: "keyboard.accent")
        XCTAssertEqual(KeyboardSettings.current().theme, .dark)
        XCTAssertEqual(KeyboardSettings.current().accent, .violet)
    }
}
