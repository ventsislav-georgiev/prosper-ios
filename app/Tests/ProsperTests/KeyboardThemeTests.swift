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
    private var barPalette: Style.Palette!

    override func setUp() {
        super.setUp()
        suite = "KeyboardThemeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = KeyboardSettings.store
        KeyboardSettings.store = { [defaults] in defaults }
        (palette, barPalette) = (Style.palette, Style.bar)
        (Style.palette, Style.bar) = (Style.Palette(KeyboardSettings()), Style.Palette.bar(KeyboardSettings()))
    }

    override func tearDown() {
        (Style.palette, Style.bar) = (palette, barPalette)
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
        bar.addToolbar { Shortcuts.Bar.arrowsToolbar }
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

    // MARK: - The Mac themes (#642)

    typealias Theme = KeyboardSettings.Theme

    func testEveryMacThemeParsesIntoAPalette() {
        XCTAssertEqual(Theme.allCases.count, 24)
        XCTAssertEqual(Theme.mac.count, 21)
        XCTAssertEqual(Array(Theme.allCases.prefix(4)), [.dark, .light, .black, .neon], "#626's first, then Neon")
        XCTAssertEqual(Theme.allCases.filter(\.isMac).count, 21)
        XCTAssertEqual(Theme.neon.title, "Neon")
        XCTAssertEqual(Theme.black.title, "True Black")
        XCTAssertEqual(Theme.contrastDark.rawValue, "contrast-dark")
        XCTAssertEqual(Theme.mac.values.filter { $0.light }.count, 8)
        for theme in Theme.allCases where theme.isMac {
            let mac = Theme.mac[theme]!
            XCTAssertEqual(mac.hex.count, 12, "\(theme)")
            XCTAssertEqual(Set(mac.hex.map { $0 >> 24 }), [0], "\(theme): RGB only")
            XCTAssertFalse(mac.title.isEmpty)
            let p = Style.Palette(theme, accent: .violet)
            let c = mac.hex.map { UIColor(hex: $0) }
            XCTAssertEqual(p.key, c[8], "\(theme): card")
            if !mac.light {
                XCTAssertEqual(p.keyPressed, c[9], "\(theme): cardHi")
                XCTAssertEqual(p.specialPressed, c[8], "\(theme): card")
            }
            XCTAssertEqual(p.special, c[7], "\(theme): sidebar")
            XCTAssertEqual(p.surface, c[8], "\(theme)")
            XCTAssertEqual(p.backdrop, c[6], "\(theme): bgBottom")
            XCTAssertEqual(p.label, c[10], "\(theme): textPrimary")
            XCTAssertEqual(p.hint, c[11], "\(theme): textSecondary")
            XCTAssertEqual(p.icon, c[1], "\(theme): glyphs in blueBright")
            XCTAssertEqual(p.accent, c[0], "\(theme): return and send in blue")
            XCTAssertEqual(p.accentEnd, c[0])
            XCTAssertEqual(p.neon, c[0])
            XCTAssertEqual(p.border, c[0].withAlphaComponent(0.55))
            XCTAssertEqual(p.style, mac.light ? .light : .dark, "\(theme)")
            XCTAssertEqual(p.glow, mac.light ? nil : c[0], "\(theme): a light one keeps the border, no glow")
            XCTAssertEqual(Style.Palette(theme, accent: .green), p, "\(theme): its own accent")
        }
        XCTAssertEqual(Style.Palette(.neon, accent: .none).neon, UIColor(hex: 0x21CCFF))
        XCTAssertEqual(Style.Palette(.daylight, accent: .violet).keyPressed, UIColor(hex: 0xD0D3D6), "a fifth of its text in")
        XCTAssertEqual(Style.Palette(.neon, accent: .none).backdrop, UIColor(hex: 0x05080D))
        for theme in [Theme.dark, .light, .black] {
            XCTAssertNil(Style.Palette(theme, accent: .violet).neon, "\(theme)")
            XCTAssertNotEqual(Style.Palette(theme, accent: .violet), Style.Palette(theme, accent: .green), "\(theme)")
        }
    }

    /// A light theme's pressed fill reads (#655): clearly darker than the fill, for the letters
    /// and the special keys, where cardHi was barely off the card and a special key went lighter.
    func testALightThemesPressedFillIsClearlyDarker() {
        func luminance(_ color: UIColor) -> CGFloat {
            var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let lin = { (c: CGFloat) in c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let light = Theme.allCases.filter { Theme.mac[$0]?.light == true }
        XCTAssertEqual(light.count, 8)
        for theme in light {
            let p = Style.Palette(theme, accent: .violet)
            XCTAssertLessThan(luminance(p.keyPressed), luminance(p.key) - 0.15, "\(theme): letters")
            XCTAssertLessThan(luminance(p.specialPressed), luminance(p.special) - 0.15, "\(theme): special keys")
        }
    }

    func testNeonKeysDrawTheBorderAndGlow() throws {
        let kb = laidOut()
        let dark = try cap(kb, "q")
        XCTAssertEqual(dark.layer.borderWidth, 1 / max(dark.traitCollection.displayScale, 1), "Dark's hairline")
        XCTAssertEqual(dark.layer.shadowRadius, 0)
        XCTAssertNil(dark.layer.shadowPath, "Dark's crisp shadow as it was")

        kb.settings.theme = .neon
        kb.layoutIfNeeded()
        let blue = UIColor(hex: 0x21CCFF)
        for title in ["q", "shift", "5", "space"] {
            let c = try cap(kb, title)
            XCTAssertEqual(c.backgroundColor, title == "q" || title == "space" ? UIColor(hex: 0x131923) : UIColor(hex: 0x080C13), title)
            XCTAssertEqual(c.layer.borderWidth, 1, title)
            XCTAssertEqual(c.layer.borderColor, blue.withAlphaComponent(0.55).cgColor, title)
            XCTAssertEqual(c.layer.shadowColor, blue.cgColor, title)
            XCTAssertEqual(c.layer.shadowRadius, 5, title)
            XCTAssertEqual(c.layer.shadowOpacity, 0.5, title)
            XCTAssertEqual(c.layer.shadowOffset, .zero, title)
            XCTAssertEqual(c.layer.shadowPath?.boundingBox, c.bounds, "\(title): the glow has its path")
        }
        XCTAssertEqual(try cap(kb, "q").titleColor(for: .normal), UIColor(hex: 0xE8F2FC), "letters in textPrimary")
        XCTAssertEqual(try cap(kb, "new line").backgroundColor, blue, "return in blue")
        XCTAssertEqual(try cap(kb, "new line").tintColor, UIColor(hex: 0x05080D))
        XCTAssertEqual(kb.backgroundColor, UIColor(hex: 0x05080D), "bgBottom")

        kb.settings.theme = .daylight
        kb.layoutIfNeeded()
        let q = try cap(kb, "q")
        XCTAssertEqual(q.layer.borderWidth, 1)
        XCTAssertEqual(q.layer.borderColor, UIColor(hex: 0x0062D1).withAlphaComponent(0.55).cgColor)
        XCTAssertEqual(q.layer.shadowRadius, 0, "a light Mac theme: no glow")
        XCTAssertNil(q.layer.shadowPath)
        XCTAssertEqual(kb.overrideUserInterfaceStyle, .light)
    }

    func testMatchKeysOrASeparateToolbarThemeOnABuiltKeyboard() throws {
        let doc = Proxy()
        let kb = TerminalKeyboard()
        kb.target = doc
        kb.offersEmoji = false
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults)))
        bar.attach(kb)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.arrowsToolbar }
        bar.showsToolbar = true
        let neon = Style.Palette(.neon, accent: .violet), dark = Style.Palette(.dark, accent: .violet)
        func toolCap() throws -> KeyCapButton {
            try XCTUnwrap(Self.all(try XCTUnwrap(bar.toolbar)).compactMap { $0 as? KeyCapButton }.first { $0.accessibilityLabel == "tab" })
        }
        func check(keys: Style.Palette, toolbar: Style.Palette, _ note: String) throws {
            view.layoutIfNeeded()
            XCTAssertEqual(try cap(kb, "q").backgroundColor, keys.key, "\(note): the keys")
            XCTAssertEqual(view.backgroundColor, keys.backdrop, "\(note): the backdrop")
            let t = try toolCap()
            XCTAssertEqual(t.configuration?.background.backgroundColor, toolbar.surface, "\(note): the toolbar's caps")
            XCTAssertEqual(t.configuration?.background.strokeColor, toolbar.border, note)
            XCTAssertEqual(t.configuration?.baseForegroundColor, toolbar.icon, note)
            XCTAssertEqual(t.layer.shadowRadius, toolbar.glow == nil ? 0 : 5, "\(note): the toolbar's glow")
            let toggle = try XCTUnwrap(bar.toggle)
            XCTAssertEqual(toggle.configuration?.background.backgroundColor, toolbar.surface, "\(note): the toggle")
            XCTAssertEqual(toggle.layer.shadowRadius, toolbar.glow == nil ? 0 : 5, "\(note): the toggle's glow")
            if toolbar.glow != nil {
                XCTAssertEqual(toggle.layer.shadowPath?.boundingBox, toggle.bounds, "\(note): the toggle's path")
                XCTAssertEqual(t.layer.shadowPath?.boundingBox, t.bounds, "\(note): the cap's path")
            }
        }
        try check(keys: dark, toolbar: dark, "the default")

        var settings = KeyboardSettings()
        settings.theme = .neon
        kb.settings = settings
        XCTAssertNil(settings.toolbarTheme, "Match keys")
        try check(keys: neon, toolbar: neon, "Neon, Match keys")

        settings.toolbarTheme = .dark
        kb.settings = settings
        try check(keys: neon, toolbar: dark, "Neon keys, Dark toolbar")

        settings.theme = .dark
        settings.toolbarTheme = .neon
        kb.settings = settings
        try check(keys: dark, toolbar: neon, "Dark keys, Neon toolbar")
        XCTAssertEqual(Style.palette, dark)
        XCTAssertEqual(Style.bar, neon)
        bar.showMenu(true)
        let tile = try XCTUnwrap(bar.menuPanel?.tiles.first)
        tile.setNeedsUpdateConfiguration()
        tile.layoutIfNeeded()
        XCTAssertEqual(tile.configuration?.background.backgroundColor, dark.surface, "the menu follows the keys")
        bar.showMenu(false)

        // A lit modifier in the toolbar's blue, whatever the keys'.
        let ctrl = ShortcutKey(id: "ctrl", label: "ctrl", kind: .ctrl)
        let tools = ShortcutBar(keys: { [ctrl] }, oneRow: true)
        tools.modes = [.ctrl: .once]
        let lit = try XCTUnwrap(Self.all(tools).compactMap { $0 as? KeyCapButton }.first)
        XCTAssertEqual(lit.configuration?.background.backgroundColor, neon.accent)
        XCTAssertEqual(lit.configuration?.baseForegroundColor, neon.onAccent)
        withExtendedLifetime((doc, kb)) {}
    }

    /// The terminal's own bar (not `oneRow`) on the keys' backdrop, not the system's chrome,
    /// and again when the app's keyboard takes another theme (`restyled`, as the host wires it).
    func testTheTerminalBarsBackdropFollowsTheTheme() throws {
        let kb = laidOut()
        let bar = ShortcutBar(keys: { Shortcuts.defaults })
        bar.frame = CGRect(x: 0, y: 0, width: 402, height: 86)
        kb.restyled = { [weak bar] in bar?.reload() }
        XCTAssertEqual(bar.backgroundColor, Style.Palette.dark.backdrop, "Dark: its backdrop")
        XCTAssertFalse(Self.all(bar).contains { $0 is UIVisualEffectView }, "no system blur")
        for theme in [Theme.light, .black, .neon] {
            kb.settings.theme = theme
            let want = Style.Palette(theme, accent: .violet)
            XCTAssertEqual(bar.backgroundColor, want.backdrop, "\(theme)")
            XCTAssertEqual(bar.backgroundColor, kb.backgroundColor, "\(theme): one backdrop with the keys")
            bar.layoutIfNeeded()
            let tab = try XCTUnwrap(Self.all(bar).compactMap { $0 as? KeyCapButton }.first { $0.accessibilityLabel == "tab" })
            XCTAssertEqual(tab.configuration?.background.backgroundColor, want.surface, "\(theme): its caps")
        }
        XCTAssertEqual(Style.Palette.black.backdrop, .black)
    }

    /// The glow isn't cut into a band at the scroll view's edges (#622's band, #642): it reaches
    /// past the caps by more than the glow on top, bottom and left, and every cap stays where
    /// it was, 8 pt in and 4 pt down, in Dark and Neon, in the keyboard's bar and the app's.
    func testTheToolbarsGlowIsNotClippedAndNoCapMoves() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 300))
        window.isHidden = false
        defer { window.isHidden = true }
        for oneRow in [true, false] {
            var placed: [[CGRect]] = []
            for theme in [Theme.dark, .neon] {
                var settings = KeyboardSettings()
                settings.theme = theme
                (Style.palette, Style.bar) = (Style.Palette(settings), Style.Palette.bar(settings))
                let bar = ShortcutBar(keys: { Shortcuts.defaults }, oneRow: oneRow)
                if oneRow { bar.twoRows = true }
                bar.frame = CGRect(x: 0, y: 100, width: 402, height: 86)
                window.addSubview(bar)
                bar.layoutIfNeeded()
                bar.layoutIfNeeded()
                let caps = Self.all(bar).compactMap { $0 as? KeyCapButton }.filter { $0.window != nil }
                XCTAssertGreaterThan(caps.count, 8, "\(theme) oneRow \(oneRow)")
                let frames = caps.map { $0.convert($0.bounds, to: nil) }
                let union = frames.reduce(frames[0]) { $0.union($1) }
                XCTAssertEqual(union.minX, 8, accuracy: 0.01, "\(theme) oneRow \(oneRow): 8 pt in")
                XCTAssertEqual(union.minY, 104, accuracy: 0.01, "\(theme) oneRow \(oneRow): 4 pt down")
                XCTAssertEqual(frames[0].height, 36, accuracy: 0.01)
                let scroll = try XCTUnwrap(caps[0].superview?.superview?.superview as? UIScrollView)
                XCTAssertTrue(scroll.clipsToBounds)
                let clip = scroll.convert(scroll.bounds, to: nil)
                XCTAssertGreaterThanOrEqual(union.minY - clip.minY, 5, "\(theme) oneRow \(oneRow): room on top")
                XCTAssertGreaterThanOrEqual(clip.maxY - union.maxY, 5, "\(theme) oneRow \(oneRow): below")
                XCTAssertGreaterThanOrEqual(union.minX - clip.minX, 5, "\(theme) oneRow \(oneRow): left")
                XCTAssertEqual(scroll.contentSize.width - scroll.bounds.width,
                               union.width - (402 - 16), accuracy: 0.5, "\(theme) oneRow \(oneRow): scrolls as far as before")
                if theme == .neon { XCTAssertEqual(caps[0].layer.shadowRadius, 5) }
                placed.append(frames)
                bar.removeFromSuperview()
            }
            XCTAssertEqual(placed[0], placed[1], "oneRow \(oneRow): Neon's caps where Dark's are")
        }
    }

    /// Hosted under the bar the keyboard paints no backdrop of its own, the host view does: an
    /// opaque keyboard cut a Neon toolbar's glow off in a line at the bar's bottom edge (#642).
    /// Through a rebuild that isn't a restyle too; on its own (the app's) it keeps its backdrop.
    func testTheHostedKeyboardLeavesTheToolbarsGlowUncut() throws {
        XCTAssertEqual(laidOut().backgroundColor, Style.Palette.dark.backdrop, "not hosted: its own backdrop (#626)")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        window.isHidden = false
        defer { window.isHidden = true }
        let doc = Proxy()
        let kb = TerminalKeyboard()
        kb.target = doc
        kb.offersEmoji = false
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults)))
        bar.attach(kb)
        let view = UIView(frame: window.bounds)
        window.addSubview(view)
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.arrowsToolbar }
        bar.showsToolbar = true
        var settings = KeyboardSettings()
        settings.toolbarTheme = .neon   // Dark keys under a Neon toolbar
        kb.settings = settings
        kb.languages = [.english, .bulgarian]   // a rebuild that isn't a restyle
        let backdrop = Style.Palette.dark.backdrop
        XCTAssertEqual(kb.backgroundColor, .clear, "hosted: no fill of its own")
        XCTAssertEqual(view.backgroundColor, backdrop, "the host view's instead")
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard   // 8-bit RGBA, read below
        let shot = { UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) } }
        _ = shot()   // the bar settles its height in the window's traits
        let image = try XCTUnwrap(shot().cgImage), scale = CGFloat(image.width) / view.bounds.width
        let tab = try XCTUnwrap(Self.all(try XCTUnwrap(bar.toolbar)).compactMap { $0 as? KeyCapButton }.first { $0.accessibilityLabel == "tab" })
        XCTAssertEqual(tab.layer.shadowRadius, 5, "Neon's glow")
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let edge = Int((bar.convert(bar.bounds, to: view).maxY + 1) * scale)   // just past the bar's bottom edge
        let row = (0..<image.width).map { x in (0..<3).map { data[edge * image.bytesPerRow + x * image.bitsPerPixel / 8 + $0] }.max()! }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        backdrop.getRed(&r, green: &g, blue: &b, alpha: &a)
        let flat = Int(([r, g, b].max()! * 255).rounded())
        XCTAssertGreaterThan(Int(row.max()!) - flat, 8, "the glow, not the flat backdrop, past the bar's edge")
        withExtendedLifetime((doc, kb)) {}
    }

    func testToolbarThemeRoundTripsAndUnknownValuesReadAsTheDefaults() {
        XCTAssertNil(KeyboardSettings.current().toolbarTheme, "absent is Match keys")
        defaults.set("neon", forKey: "keyboard.theme")
        defaults.set("daylight", forKey: "keyboard.toolbarTheme")
        XCTAssertEqual(KeyboardSettings.current().theme, .neon)
        XCTAssertEqual(KeyboardSettings.current().toolbarTheme, .daylight)
        XCTAssertEqual(Style.Palette.bar(.current()), Style.Palette(.daylight, accent: .violet))
        XCTAssertNil(KeyboardSettings.current(fullAccess: false).toolbarTheme)
        defaults.set("contrast-light", forKey: "keyboard.toolbarTheme")
        XCTAssertEqual(KeyboardSettings.current().toolbarTheme, .contrastLight)
        defaults.set("", forKey: "keyboard.toolbarTheme")
        XCTAssertNil(KeyboardSettings.current().toolbarTheme, "Settings' Match keys")
        XCTAssertEqual(Style.Palette.bar(.current()), Style.Palette(.current()), "Match keys: the keys' palette")
        defaults.set("default", forKey: "keyboard.toolbarTheme")
        defaults.set("sepia", forKey: "keyboard.theme")
        XCTAssertNil(KeyboardSettings.current().toolbarTheme, "unknown is Match keys")
        XCTAssertEqual(KeyboardSettings.current().theme, .dark, "unknown is Dark")
    }

    // MARK: - Appearance from the keys (#641)

    /// A hosted keyboard and bar on the isolated store, its settings read from it, with Full
    /// Access on a named pasteboard or without.
    private func appearanceRig(fullAccess: Bool = true) throws -> (TerminalKeyboard, SuggestionBar, UIView, Proxy) {
        let doc = Proxy()
        let kb = TerminalKeyboard()
        kb.target = doc
        kb.offersEmoji = false
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: UserDefaults(suiteName: suite + ".memory")!)))
        addTeardownBlock { [suite] in UserDefaults().removePersistentDomain(forName: suite + ".memory") }
        bar.attach(kb)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.arrowsToolbar }
        if fullAccess {
            let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
            addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
            bar.suggestions.pasteboard = { pb }
        }
        kb.settings = .current(fullAccess: fullAccess)
        return (kb, bar, view, doc)
    }

    private func selected(_ row: [UIButton]) -> [String?] {
        row.filter { $0.accessibilityTraits.contains(.selected) }.map(\.accessibilityLabel)
    }

    private func tap(_ row: [UIButton], _ name: String) throws {
        try XCTUnwrap(row.first { $0.accessibilityLabel == name }, name).sendActions(for: .touchUpInside)
    }

    private var stored: [String?] {
        [KeyboardSettings.Key.theme, KeyboardSettings.Key.toolbarTheme, KeyboardSettings.Key.accent].map(defaults.string)
    }

    /// The menu's Appearance, before Next Keyboard, opens the panel; Light from it stores
    /// "light" for the app's Settings, the keys and the toolbar (Match Keys) turn Light, and the
    /// panel is drawn again in Light with Light ringed.
    func testALightPickAppliesLiveStoresAndRedrawsThePanel() throws {
        let (kb, bar, view, doc) = try appearanceRig()
        bar.showMenu(true)
        let menu = try XCTUnwrap(bar.menuPanel)
        XCTAssertEqual(menu.items.suffix(2).map(\.title), ["Appearance", "Next Keyboard"])
        XCTAssertEqual(menu.items.first { $0.title == "Appearance" }?.symbol, "paintpalette")
        XCTAssertNotNil(UIImage(systemName: "paintpalette"))
        try tap(menu.tiles, "Appearance")
        XCTAssertNil(bar.menuPanel)
        let panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertTrue(panel.superview === view, "over the keys")
        XCTAssertEqual(panel.title.text, "Appearance")
        XCTAssertTrue(panel.note.isHidden)
        XCTAssertEqual(selected(panel.keys), ["Dark"])

        try tap(panel.keys, "Light")
        let light = Style.Palette(.light, accent: .violet)
        XCTAssertEqual(stored, ["light", nil, nil], "only the theme, as Settings' picker stores it")
        XCTAssertEqual(KeyboardSettings.current().theme, .light, "the app's Settings follow")
        XCTAssertEqual(kb.settings.theme, .light)
        XCTAssertEqual(Style.palette, light)
        XCTAssertEqual(Style.bar, light, "Match Keys")
        XCTAssertEqual(try cap(kb, "q").backgroundColor, light.key, "the keys")
        XCTAssertEqual(view.backgroundColor, light.backdrop)
        XCTAssertEqual(bar.toggle?.configuration?.background.backgroundColor, light.surface, "the bar")
        let redrawn = try XCTUnwrap(bar.appearancePanel)
        XCTAssertFalse(redrawn === panel, "drawn again")
        XCTAssertNil(panel.superview)
        XCTAssertEqual(redrawn.backgroundColor, light.backdrop, "the panel in Light")
        XCTAssertEqual(redrawn.overrideUserInterfaceStyle, .light)
        XCTAssertEqual(redrawn.title.textColor, light.label)
        XCTAssertEqual(selected(redrawn.keys), ["Light"])
        let ring = try XCTUnwrap(redrawn.keys.first { $0.accessibilityLabel == "Light" }).configuration?.background
        XCTAssertEqual(ring?.strokeColor, light.accent, "ringed in the accent")
        XCTAssertEqual(ring?.strokeWidth, 2)
        withExtendedLifetime((doc, view)) {}
    }

    /// A toolbar pick stores keyboard.toolbarTheme and turns only the toolbar (`Style.bar`);
    /// Match Keys, first, stores Settings' "" and the toolbar follows the keys again.
    func testAToolbarPickRestylesOnlyTheToolbarAndMatchKeysClearsIt() throws {
        let (kb, bar, view, doc) = try appearanceRig()
        bar.showAppearance(true)
        let panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(panel.toolbar.first?.accessibilityLabel, "Match Keys")
        XCTAssertEqual(selected(panel.toolbar), ["Match Keys"])
        let neon = Style.Palette(.neon, accent: .violet), dark = Style.Palette(.dark, accent: .violet)
        try tap(panel.toolbar, "Neon")
        XCTAssertEqual(stored, [nil, "neon", nil])
        XCTAssertEqual(KeyboardSettings.current().toolbarTheme, .neon)
        XCTAssertEqual(Style.palette, dark, "the keys unchanged")
        XCTAssertEqual(Style.bar, neon)
        XCTAssertEqual(try cap(kb, "q").backgroundColor, dark.key)
        XCTAssertEqual(bar.toggle?.configuration?.background.backgroundColor, neon.surface, "the toolbar's toggle")
        let redrawn = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(selected(redrawn.toolbar), ["Neon"])
        XCTAssertEqual(selected(redrawn.keys), ["Dark"])
        XCTAssertEqual(redrawn.backgroundColor, dark.backdrop, "the panel is the keys'")

        try tap(redrawn.toolbar, "Match Keys")
        XCTAssertEqual(stored, [nil, "", nil], "Settings' Match Keys")
        XCTAssertNil(KeyboardSettings.current().toolbarTheme)
        XCTAssertNil(kb.settings.toolbarTheme)
        XCTAssertEqual(Style.bar, dark)
        XCTAssertEqual(selected(try XCTUnwrap(bar.appearancePanel).toolbar), ["Match Keys"])
        withExtendedLifetime((doc, view)) {}
    }

    /// The accent row, while the keys or the toolbar are Dark, Light or True Black: a pick
    /// stores keyboard.accent and lights return in it; Neon keys hide the row, a Dark toolbar
    /// brings it back (#655), and so do True Black keys.
    func testAnAccentPickLightsReturnAndTheRowIsForTheThreeOnly() throws {
        let (kb, bar, view, doc) = try appearanceRig()
        bar.showAppearance(true)
        let panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(panel.accents.map(\.accessibilityLabel), ["Violet", "Blue", "Pink", "Orange", "Green", "None"])
        XCTAssertEqual(selected(panel.accents), ["Violet"])
        try tap(panel.accents, "Green")
        XCTAssertEqual(stored, [nil, nil, "green"])
        XCTAssertEqual(KeyboardSettings.current().accent, .green)
        XCTAssertEqual(try cap(kb, "new line").backgroundColor, UIColor(hex: 0x34D399), "return in green")
        var redrawn = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(selected(redrawn.accents), ["Green"])
        XCTAssertEqual(redrawn.accents[4].configuration?.background.strokeColor, UIColor(hex: 0x34D399))

        try tap(redrawn.keys, "Neon")
        redrawn = try XCTUnwrap(bar.appearancePanel)
        XCTAssertTrue(redrawn.accents.isEmpty, "a Mac theme lights in its own colour")
        XCTAssertEqual(redrawn.keys.count, 24)
        // Neon keys with a Dark toolbar: the row is back as Settings has it, its dots Dark's (#655).
        try tap(redrawn.toolbar, "Dark")
        redrawn = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(redrawn.accents.count, 6, "the accent lights the toolbar")
        let none = redrawn.accents.last?.configuration?.image?.pngData()
        XCTAssertEqual(none, AppearancePanel.dot(Style.Palette(.dark, accent: .none).accent).pngData(), "Dark's labels")
        XCTAssertNotEqual(none, AppearancePanel.dot(Style.Palette(.neon, accent: .none).accent).pngData())
        try tap(redrawn.toolbar, "Match Keys")
        XCTAssertTrue(try XCTUnwrap(bar.appearancePanel).accents.isEmpty)
        let cases: [(Theme, Theme, Theme?)] = [(.neon, .light, .light), (.black, .neon, .black), (.neon, .daylight, nil)]
        for (keys, toolbar, lit) in cases {
            var s = KeyboardSettings()
            (s.theme, s.toolbarTheme) = (keys, toolbar)
            XCTAssertEqual(s.accentTheme, lit, "\(keys) keys, \(toolbar) toolbar")
        }

        try tap(try XCTUnwrap(bar.appearancePanel).keys, "True Black")
        redrawn = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(redrawn.accents.count, 6)
        XCTAssertEqual(stored, ["black", "", "green"])
        withExtendedLifetime((doc, view)) {}
    }

    /// Without Full Access the tile is there, the rows are off under the note, and a tap
    /// writes nothing and changes nothing.
    func testWithoutFullAccessTheRowsAreOffAndNothingIsWritten() throws {
        let (kb, bar, view, doc) = try appearanceRig(fullAccess: false)
        XCTAssertTrue(bar.menuItems.contains { $0.title == "Appearance" })
        bar.showAppearance(true)
        let panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertFalse(panel.note.isHidden)
        XCTAssertEqual(panel.note.text, "Turn on Full Access to change the look here")
        let all = panel.keys + panel.toolbar + panel.accents + panel.sizes + panel.numbers + panel.numpad
        XCTAssertEqual(all.count, 24 + 25 + 6 + 3 + 2 + 2)
        XCTAssertFalse(all.contains { $0.isEnabled })
        for b in all { XCTAssertTrue(b.accessibilityTraits.contains(.notEnabled), "\(b.accessibilityLabel!): VoiceOver says dimmed (#649)") }
        try tap(panel.keys, "Light")
        try tap(panel.toolbar, "Neon")
        try tap(panel.accents, "Green")
        try tap(panel.sizes, "Large")
        try tap(panel.numbers, "Key")
        try tap(panel.numpad, "On")
        XCTAssertEqual(stored, [nil, nil, nil], "nothing written")
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("keyboard.") }, [])
        XCTAssertEqual(kb.settings, KeyboardSettings())
        XCTAssertEqual(Style.palette, Style.Palette(KeyboardSettings()))
        XCTAssertTrue(bar.appearancePanel === panel, "nothing to redraw")
        withExtendedLifetime((doc, view)) {}
    }

    /// The Layout group (#650) under the theme rows: Key Size, Numbers and Numpad Hides Toolbar
    /// as chips, the current one ringed. A pick stores only its key as Settings does, the keys
    /// re-lay live (taller rows; the digit row to the toolbar's band), and the panel, drawn
    /// again over them with the pick ringed, still scrolls its last row clear of the keys' pad.
    func testALayoutPickStoresOnlyItsKeyAndReLaysTheKeysLive() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        if #available(iOS 17, *) { window.traitOverrides.verticalSizeClass = .regular }
        window.isHidden = false
        defer { window.isHidden = true }
        let (kb, bar, view, doc) = try appearanceRig()
        kb.allowsNumbersKey = true
        kb.bottomInset = TerminalKeyboard.extensionBottomInset
        window.addSubview(view)
        func fit() {
            view.frame.size.height = view.systemLayoutSizeFitting(CGSize(width: 402, height: 0), withHorizontalFittingPriority: .required,
                                                                  verticalFittingPriority: .fittingSizeLevel).height
            view.layoutIfNeeded()
            view.layoutIfNeeded()
        }
        let keyed = [KeyboardSettings.Key.keySize, KeyboardSettings.Key.numbers, KeyboardSettings.Key.numpadHidesToolbar]
        bar.showAppearance(true)
        fit()
        var panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(panel.sizes.map(\.accessibilityLabel), ["Normal", "Medium", "Large"])
        XCTAssertEqual(panel.numbers.map(\.accessibilityLabel), ["Row", "Key"])
        XCTAssertEqual(panel.numpad.map(\.accessibilityLabel), ["Off", "On"])
        XCTAssertEqual(selected(panel.sizes) + selected(panel.numbers) + selected(panel.numpad), ["Normal", "Row", "Off"])
        XCTAssertTrue(panel.toolbarRows.isEmpty, "Toolbar Rows with Key only (#694)")
        XCTAssertGreaterThan(panel.sizes[0].convert(panel.sizes[0].bounds, to: panel).minY,
                             panel.toolbar[0].convert(panel.toolbar[0].bounds, to: panel).maxY, "under the theme rows")
        XCTAssertEqual(panel.bottomInset, TerminalKeyboard.extensionBottomInset)
        let normal = kb.frame.height, barHeight = bar.frame.height

        try tap(panel.sizes, "Large")
        fit()
        XCTAssertEqual(keyed.map { defaults.object(forKey: $0) as? String }, ["large", nil, nil], "only Key Size, as Settings' picker")
        XCTAssertEqual(stored, [nil, nil, nil])
        XCTAssertEqual(KeyboardSettings.current().keySize, .large, "the app's Settings follow")
        XCTAssertGreaterThan(kb.frame.height, normal + 10, "taller rows, live")
        panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(selected(panel.sizes), ["Large"], "drawn again, Large ringed")
        XCTAssertEqual(panel.sizes[2].configuration?.background.strokeWidth, 2)
        XCTAssertEqual(panel.frame, kb.frame, "over the keys at their new height")

        try tap(panel.numbers, "Key")
        fit()
        XCTAssertEqual(keyed.map { defaults.object(forKey: $0) as? String }, ["large", "key", nil])
        XCTAssertTrue(kb.numbersKey)
        XCTAssertEqual(kb.shownKeys.last?.first, .numbers, "123 on the keys")
        let m = TerminalKeyboard.metrics(compact: false, size: .large)
        XCTAssertEqual(bar.frame.height, barHeight + m.row + m.gap, accuracy: 0.5, "the digit row's height to the bar")
        panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(selected(panel.numbers), ["Key"])
        XCTAssertEqual(panel.frame, kb.frame)
        XCTAssertEqual(panel.toolbarRows.map(\.accessibilityLabel), ["One", "Two"])
        XCTAssertEqual(selected(panel.toolbarRows), ["Two"])

        try tap(panel.toolbarRows, "One")   // #694
        fit()
        XCTAssertEqual(defaults.string(forKey: KeyboardSettings.Key.toolbarRows), "one")
        XCTAssertEqual(KeyboardSettings.current().toolbarRows, .one, "the app's Settings follow")
        XCTAssertEqual(bar.frame.height, barHeight, accuracy: 0.5, "one row, the digit row's height gone")
        panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(selected(panel.toolbarRows), ["One"])
        XCTAssertEqual(panel.frame, kb.frame)

        try tap(panel.numpad, "On")
        fit()
        XCTAssertEqual(defaults.object(forKey: KeyboardSettings.Key.numpadHidesToolbar) as? Bool, true)
        XCTAssertTrue(kb.settings.numpadHidesToolbar)
        panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(selected(panel.numpad), ["On"])
        XCTAssertEqual(Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("keyboard.") }), Set(keyed + [KeyboardSettings.Key.toolbarRows]), "nothing else")

        // Scrolled to its end, the last row clears the keys' pad.
        let scroll = try XCTUnwrap(panel.subviews.first { $0 is UIScrollView && !($0 is UITableView) } as? UIScrollView)
        scroll.contentOffset.y = max(0, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        let on = panel.numpad[1].convert(panel.numpad[1].bounds, to: panel)
        XCTAssertLessThanOrEqual(on.maxY, panel.bounds.maxY - kb.bottomInset, "clear of the pad")
        XCTAssertGreaterThanOrEqual(on.minY, 42, "under the header")

        // A pick there keeps the redrawn panel at its end, the bottom inset counted (#652).
        let end = scroll.contentOffset.y
        try tap(panel.numpad, "Off")
        fit()
        panel = try XCTUnwrap(bar.appearancePanel)
        let redrawn = try XCTUnwrap(panel.subviews.first { $0 is UIScrollView && !($0 is UITableView) } as? UIScrollView)
        XCTAssertGreaterThan(end, 0)
        XCTAssertEqual(redrawn.contentOffset.y, end, accuracy: 1, "kept in place")
        withExtendedLifetime((doc, view)) {}
    }

    /// VoiceOver: every swatch a button named for its theme or accent, the current one
    /// selected. Each row starts with the current one in view, and a pick's redraw keeps the
    /// rows where they were.
    func testEachSwatchIsANamedButtonAndTheCurrentOneIsInView() throws {
        defaults.set("violet", forKey: KeyboardSettings.Key.theme)   // the Keys row's last
        defaults.set("teal", forKey: KeyboardSettings.Key.toolbarTheme)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 500))
        window.isHidden = false
        defer { window.isHidden = true }
        let (_, bar, view, doc) = try appearanceRig()
        window.addSubview(view)
        bar.showAppearance(true)
        view.layoutIfNeeded()
        view.layoutIfNeeded()
        let panel = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(panel.keys.map(\.accessibilityLabel), Theme.allCases.map(\.title))
        XCTAssertEqual(panel.toolbar.map(\.accessibilityLabel), ["Match Keys"] + Theme.allCases.map(\.title))
        XCTAssertTrue(panel.accents.isEmpty, "Violet keys are a Mac theme")
        for b in panel.keys + panel.toolbar + panel.sizes + panel.numbers + panel.numpad {
            XCTAssertTrue(b.accessibilityTraits.contains(.button), "\(b.accessibilityLabel!)")
            XCTAssertFalse(b.accessibilityTraits.contains(.notEnabled), "\(b.accessibilityLabel!): on with Full Access")
        }
        XCTAssertEqual(selected(panel.keys), ["Violet"])
        XCTAssertEqual(selected(panel.toolbar), ["Teal"])
        func strip(_ b: UIButton) throws -> UIScrollView { try XCTUnwrap(b.superview?.superview as? UIScrollView) }
        for row in [panel.keys, panel.toolbar] {
            let on = try XCTUnwrap(row.first { $0.accessibilityTraits.contains(.selected) })
            let s = try strip(on)
            XCTAssertGreaterThan(s.contentSize.width, s.bounds.width, "it scrolls sideways")
            XCTAssertGreaterThan(s.contentOffset.x, 0, "\(on.accessibilityLabel!): scrolled to")
            XCTAssertTrue(s.bounds.contains(on.convert(on.bounds, to: s)), "\(on.accessibilityLabel!) in view")
        }
        let keysOffset = try strip(panel.keys[0]).contentOffset
        try tap(panel.toolbar, "Neon")
        view.layoutIfNeeded()
        let redrawn = try XCTUnwrap(bar.appearancePanel)
        XCTAssertEqual(try strip(redrawn.keys[0]).contentOffset, keysOffset, "kept where it was")
        withExtendedLifetime((doc, view)) {}
    }

    /// The menu's seven to ten tiles (Rewrite's the tenth, #612) fit the keys at every Key Size,
    /// Numbers: Key too, on a 375 and a 402 pt portrait and a 750 pt landscape (its safe area off
    /// an 874 pt screen): inside the
    /// panel under its caption, none overlapping, each as tall as its content and as wide as
    /// its title, landscape's one row with Numbers: Key too (#649). Numbers is a tile with a 123
    /// key too (#691), so ten fit four rows' keys. Six in portrait keep #626's three a row at 72 pt.
    func testTheMenuFitsSevenToTenTilesInPortraitAndLandscape() {
        let all = ["Clipboard", "Snippets", "Quicklinks", "Dictate", "Rewrite", "Emoji", "Numbers", "Български", "Appearance",
                   "Next Keyboard"]
        for count in [7, 8, 9, 10] {
            for (compact, width) in [(false, 375), (false, 402), (true, 750)] as [(Bool, CGFloat)] {
                for size in KeyboardSettings.KeySize.allCases {
                    for rows in [5, 4] {
                        let note = "\(count) tiles, \(compact ? "landscape" : "portrait") \(width) \(size) \(rows) rows"
                        let menu = ToggleMenu(items: all.suffix(count).map { .init(title: $0, symbol: "paintpalette") {} })
                        menu.frame = CGRect(x: 0, y: 0, width: width,
                                            height: TerminalKeyboard.keysHeight(compact: compact, size: size, rows: rows)
                                                + TerminalKeyboard.extensionBottomInset)
                        menu.layoutIfNeeded()
                        let frames = menu.tiles.map(\.frame)
                        for (tile, frame) in zip(menu.tiles, frames) {
                            XCTAssertTrue(menu.bounds.insetBy(dx: 7.9, dy: 7.9).contains(frame), note)   // 8 pt in, give or take rounding
                            XCTAssertGreaterThanOrEqual(frame.minY, 46, "\(note): under the caption")
                            let fits = tile.intrinsicContentSize
                            XCTAssertLessThanOrEqual(fits.height, frame.height + 0.5, "\(note): \(tile.accessibilityLabel!)")
                            XCTAssertLessThanOrEqual(fits.width, frame.width + 0.5, "\(note): \(tile.accessibilityLabel!) whole")
                        }
                        // #691: Numbers beside a 123 key reaches ten tiles over four rows. Portrait's
                        // four a row can't take "Next Keyboard" at 13 pt (92 pt in a 76 pt tile), nor
                        // wrap it in a 48 pt tile, so only the floor holds there.
                        let ten = count == 10 && rows == 4
                        XCTAssertGreaterThanOrEqual(menu.titleSize, 10, "\(note): still legible")
                        if !compact, !ten { XCTAssertTrue([13, 15].contains(menu.titleSize), "\(note): portrait's sizes as they were") }
                        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), note) } }
                    }
                }
            }
        }
        let six = ToggleMenu(items: all.prefix(6).map { .init(title: $0, symbol: "globe") {} })
        six.frame = CGRect(x: 0, y: 0, width: 375, height: TerminalKeyboard.keysHeight(compact: false) + TerminalKeyboard.extensionBottomInset)
        six.layoutIfNeeded()
        XCTAssertEqual(six.tiles.map(\.frame.height), Array(repeating: 72, count: 6))
        XCTAssertEqual(Set(six.tiles.map(\.frame.minY)).count, 2, "three a row")
    }
}
