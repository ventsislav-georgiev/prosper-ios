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
            XCTAssertEqual(p.keyPressed, c[9], "\(theme): cardHi")
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
        XCTAssertEqual(Style.Palette(.neon, accent: .none).backdrop, UIColor(hex: 0x05080D))
        for theme in [Theme.dark, .light, .black] {
            XCTAssertNil(Style.Palette(theme, accent: .violet).neon, "\(theme)")
            XCTAssertNotEqual(Style.Palette(theme, accent: .violet), Style.Palette(theme, accent: .green), "\(theme)")
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
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults }
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
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults }
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
}
