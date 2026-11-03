import XCTest
import UIKit
import ImageIO
import SwiftUI
@testable import Prosper

/// The README's keyboard gallery and the App Store's keyboard slides (#670), drawn from the
/// production views with made-up data: each scene is rigged as the extension's controller and
/// the terminal rig them (`SuggestionBar.host`, `KeyboardToolbarTests.hostedRig`), put in a
/// window and drawn with `drawHierarchy` at the target's width and scale (an iPhone Pro Max: 440 pt
/// at 3x, so 1320 px). Then four store slides from those crops, opaque: App Store Connect refuses alpha.
///
/// The app's own slides 1-3 (`testAppShots`) are the app's screens the same way, full screen, on the
/// offline demo (`DemoTransport`) and a made-up Mac: no real machine, session or account.
///
/// One run per simulator (`Target.here`): an iPhone Pro Max draws the iphone67 slides and the README's
/// keyboard crops; an iPad Pro 13" draws the ipad13 slides and the iPhone Duo's (no simulator of its
/// own) in a window of the Duo's inner display, 669x951 pt, at 3x.
///
/// Off unless PROSPER_SHOTS names an output folder (`TEST_RUNNER_PROSPER_SHOTS`); run it with
/// scripts/keyboard-shots.sh, which copies the PNGs to store/keyboard and fastlane.
@MainActor
final class ScreenshotTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy
    typealias Theme = KeyboardSettings.Theme
    typealias Style = TerminalKeyboard.Style

    /// A store device class: its screen in points, its scale, the slides' file prefix. The slides
    /// are the screen in pixels; App Store Connect takes the device class from that size.
    struct Target {
        let name: String
        let points: CGSize
        let scale: CGFloat
        /// Drawn in a window of `points` on a bigger screen, with an iPhone's portrait size classes.
        var hosted = false
        var store: CGSize { CGSize(width: points.width * scale, height: points.height * scale) }

        static let iphone67 = Target(name: "iphone67", points: CGSize(width: 440, height: 956), scale: 3)
        static let ipad13 = Target(name: "ipad13", points: CGSize(width: 1032, height: 1376), scale: 2)
        /// The unfolded inner display: 2007x2853, deliver's APP_IPHONE_DUO.
        static let iphoneduo = Target(name: "iphoneduo", points: CGSize(width: 669, height: 951), scale: 3, hosted: true)

        /// This simulator's targets, by its screen's width: the iPhone Pro Max's, or the iPad's and the Duo's.
        static func here(_ screen: CGSize) throws -> [Target] {
            switch screen.width {
            case iphone67.points.width: return [.iphone67]
            case ipad13.points.width: return [.ipad13, .iphoneduo]
            default: throw XCTSkip("Marketing shots: an iPhone Pro Max or an iPad Pro 13\" simulator, not \(screen)")
            }
        }
    }

    /// What's being drawn: every rig, screen and slide is at its width and scale.
    private var target = Target.iphone67

    private var out: URL!
    private var dir: URL!
    private var suite = ""
    private var window: UIWindow!
    private var saved: (Style.Palette, Style.Palette)!
    private var savedStore = KeyboardSettings.store
    /// Every rig's views, alive until the test ends: the keyboard holds its proxy and bar weakly.
    private var kept: [AnyObject] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let path = ProcessInfo.processInfo.environment["PROSPER_SHOTS"], !path.isEmpty else {
            throw XCTSkip("Marketing shots: set TEST_RUNNER_PROSPER_SHOTS=<dir> (scripts/keyboard-shots.sh)")
        }
        out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotTests-\(UUID())")
        suite = "ScreenshotTests.\(UUID().uuidString)"
        saved = (Style.palette, Style.bar)
        // The emoji picker's recents (`EmojiRecents`) from a suite of the test's own, not the App Group.
        let recents = UserDefaults(suiteName: suite)
        recents?.set(Self.recents, forKey: EmojiRecents.key)
        savedStore = KeyboardSettings.store
        KeyboardSettings.store = { recents }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        window = UIWindow(windowScene: scene)
        if #available(iOS 17, *) { window.traitOverrides.verticalSizeClass = .regular }
        window.isHidden = false
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        kept = []
        if let saved { (Style.palette, Style.bar) = saved }
        KeyboardSettings.store = savedStore
        if let dir { try? FileManager.default.removeItem(at: dir) }
        if !suite.isEmpty { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    // MARK: - Sample data (invented; never the user's own files)

    private static let clips: [(text: String, pinned: Bool, mac: Bool)] = [
        ("Meeting moved to Thursday at 10:00, same room as last time.", false, false),
        ("https://example.com/docs/getting-started", true, false),
        ("Thanks! I'll take a look this afternoon and get back to you.", false, true),
        ("1 Example Street, Springfield 12345", false, false),
        ("Order #A-20481 ships within 2 business days.", false, false),
        ("git checkout -b feature/new-onboarding", false, false),
    ]

    private static let snippets: [(name: String, text: String)] = [
        ("Address", "1 Example Street, Springfield 12345"),
        ("Availability", "Free Tuesday or Thursday afternoon."),
        ("Bio", "Designer, keyboard fan, coffee lover."),
        ("Call me", "Can you call me when you have a minute?"),
        ("Directions", "Second entrance, lift to floor 3."),
        ("Follow-up", "Just following up. Any news?"),
        ("Greeting", "Hi there! Thanks for reaching out."),
        ("Invoice note", "Payment due within 14 days. Thank you!"),
        ("Meeting link", "https://meet.example.com/team-sync"),
        ("On my way", "On my way, see you in 10 minutes."),
        ("Out of office", "I'm out of the office until Monday."),
        ("Sign-off", "Kind regards, and talk soon!"),
        ("Thanks", "Thank you so much, really!"),
        ("Wi-Fi", "Network: Guest · Password: example-guest"),
    ]

    private static let quicklinks: [(name: String, url: String)] = [
        ("Search GitHub", "https://github.com/search?q={query}"),
        ("Maps", "https://maps.example.com/?q={query}"),
        ("Translate", "https://translate.example.com/?text={query}"),
        ("Dictionary", "https://dictionary.example.com/{query}"),
        ("Weather", "https://weather.example.com/{query}"),
        ("News", "https://news.example.com/search?q={query}"),
        ("Recipes", "https://recipes.example.com/?q={query}"),
        ("Help center", "https://help.example.com"),
    ]

    /// The emoji picker's Recents, a colourful mix from every group, four columns of five.
    private static let recents = ["😂", "❤️", "👍", "🎉", "🔥", "😍", "🙏", "✨", "☕️", "🍕",
                                  "🥳", "🌸", "🐶", "🌈", "🚀", "🎂", "💯", "🍓", "⚽️", "🎶"]


    private static let draft = "hey can u send me the notes from todays meeting, i want to look at them before tmrw. "
        + "also whats the deadline for the budget draft, i think we said friday but not sure. "
        + "and can we move our 1:1 to the afternoon, mornings are packed this week. thx"
    /// Long enough to fill the result card: a short reply leaves an empty slab under it.
    private static let rewritten = "Hi! Could you send me the notes from today's meeting? I'd like to look them over "
        + "before tomorrow. Also, what's the deadline for the budget draft? I think we said Friday, "
        + "but I'm not sure. And could we move our one-on-one to the afternoon? My mornings are "
        + "packed this week.\n\nThanks so much!"

    // MARK: - The shots

    func testKeyboardShots() throws {
        try forEachTarget(keyboardShots)
    }

    private func keyboardShots() throws {
        var shots: [String: UIImage] = [:]
        func shot(_ name: String, _ image: UIImage) throws {
            shots[name] = image
            // The README's gallery is the phone's; the other targets' crops go only into their slides.
            if target.name == Target.iphone67.name { try write(image, "keyboard-\(name).png", size: nil) }
        }

        try shot("terminal-neon", terminalKeyboard(look(.neon)))

        try shot("theme-dark", system(look(.dark)).image)
        try shot("theme-blossom", system(look(.blossom)).image)
        try shot("theme-amber", system(look(.amber)).image)
        try shot("theme-mixed", system(look(.black, toolbar: .rose, accent: .pink)).image)
        try shot("bulgarian", system(look(.teal), layout: .bulgarian).image)

        let menu = try system(look(.neon)) { $0.bar.showMenu(true) }
        try shot("menu", menu.image)
        try shot("appearance", system(look(.neon)) { $0.bar.showAppearance(true) }.image)

        let indigo = look(.indigo)
        try shot("clipboard", system(indigo) { $0.bar.showClips(true) }.image)
        try shot("snippets", system(indigo) { $0.bar.showSnippets(true) }.image)
        try shot("quicklinks", system(indigo, text: "café") { $0.bar.showQuicklinks(true) }.image)
        // Filter mode (#665): a query typed on its own keys, two rows of ranked results.
        try shot("clipboard-search", system(indigo) { rig in
            rig.bar.showClips(true)
            try self.search(rig, "exam")
        }.image)
        try shot("snippets-search", system(indigo) { rig in
            rig.bar.showSnippets(true)
            try self.search(rig, "thanks")
        }.image)

        // The picker (#664) as the hold menu's Emoji opens it, in its slide's Neon: four columns of Recents, then
        // Smileys & People. Not five-plus of Smileys: 🫡 (the 36th) is drawn clipped on its right.
        try shot("emoji", system(look(.neon)) { $0.kb.showEmoji(true) }.image)

        var daylight = look(.daylight)
        daylight.numbers = .key
        try shot("numbers-key", system(daylight).image)
        var neonPad = look(.neon)   // the hold menu's slide's theme
        neonPad.numbers = .key
        try shot("numpad", system(neonPad) { $0.kb.showNumpad(true, animated: false) }.image)

        for size in KeyboardSettings.KeySize.allCases {
            var s = look(.emerald)
            s.keySize = size
            try shot("size-\(size.rawValue)", system(s).image)
        }

        let lavender = look(.lavender)
        try shot("ai", system(lavender, text: Self.draft) { $0.bar.showRewrite(true) }.image)
        try shot("ai-result", system(lavender, text: Self.draft) { rig in
            rig.doc.selectedText = Self.draft   // selected: Replace too, not Insert only
            rig.bar.showRewrite(true)
            let panel = try XCTUnwrap(rig.bar.rewritePanel)
            panel.run(.rewrite)
            try self.until { panel.result != nil }
        }.image)
        try shot("dictation", system(lavender, text: "Running a few minutes late, ") { rig in
            rig.bar.dictationStrip.show(.listening("see you at the café at ten"))
            rig.bar.dictationStrip.isHidden = false
        }.image)

        try slide("\(target.name)_4-themes", "Make it yours",
                  "\(Theme.allCases.count) themes, toolbar themes and accents.",
                  colours: (0x0B1018, 0x1A1238, 0x8B7CFF), ink: .white,
                  [shots["theme-blossom"], shots["theme-amber"], shots["theme-mixed"], shots["theme-dark"]], overlap: 0.475)   // cut between the q and a rows
        try slide("\(target.name)_5-clipboard", "Saved, a tap away",
                  "Clipboard, snippets and quicklinks, with search.",
                  colours: (0x080813, 0x1E1E38, 0x7075FF), ink: .white,
                  [shots["clipboard"], shots["snippets-search"], shots["quicklinks"]])
        try slide("\(target.name)_6-menu", "Everything a hold away",
                  "Panels, emoji and the look, from the keys.",
                  colours: (0x05080D, 0x0B1E2E, 0x21CCFF), ink: .white,
                  [shots["menu"], shots["emoji"], shots["appearance"]])
        try slide("\(target.name)_7-ai", "Write it better, or say it",
                  "On-device Fix, Rewrite, Summarize, dictation.",
                  colours: (0xF5F0FA, 0xE3D8F0, 0x8945E3), ink: UIColor(hex: 0x241434),
                  [shots["ai"], shots["ai-result"], shots["dictation"]])
    }

    /// The app's slides: the demo's session list and terminal, and the Machines screen with a
    /// made-up Mac, each drawn full screen in dark mode as a phone shows it.
    func testAppShots() throws {
        try forEachTarget(appShots)
    }

    private func appShots() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = MachineStore(defaults: defaults)
        store.machines = [Machine(name: "Studio Mac", addresses: ["studio-mac.example.ts.net"])]
        let account = AccountStore()
        try XCTSkipIf(account.isSignedIn, "signed in on this simulator: the home card would show")

        let terminal = try screen(NavigationStack {
            TerminalScreen(transport: DemoTransport(), session: DchSession(name: "demo", alias: "Demo session"))
        }, settle: 4)   // the demo's script typed out. Keyboard down: drawHierarchy draws its window blank.
        let sessions = try screen(NavigationStack {
            SessionListView(transport: DemoTransport(), title: demoTitle, machine: nil, store: store, account: account)
        }, settle: 2)
        let machines = try screen(NavigationStack { ConnectScreen(store: store) { _ in } }, settle: 1)

        try slide("\(target.name)_1-terminal", "Your Mac's terminal, anywhere",
                  "The same session, scrollback and all.",
                  colours: (0x05080D, 0x0B1E2E, 0x21CCFF), ink: .white, [terminal])
        try slide("\(target.name)_2-sessions", "Every session at a glance",
                  "Agents, pull requests and tasks, live.",
                  colours: (0x080813, 0x1E1E38, 0x7075FF), ink: .white, [sessions])
        try slide("\(target.name)_3-machines", "No passwords",
                  "Your Mac over your own Tailscale network.",
                  colours: (0x0B1018, 0x1A1238, 0x8B7CFF), ink: .white, [machines])
    }

    /// `body` once per target of this simulator, the window's size classes as that device's.
    private func forEachTarget(_ body: () throws -> Void) throws {
        let scene = try XCTUnwrap(window.windowScene)
        for t in try Target.here(scene.screen.bounds.size) {
            target = t
            // A phone in portrait is compact wide; the iPad's own window keeps the scene's regular.
            if #available(iOS 17, *) {
                if t.hosted { window.traitOverrides.horizontalSizeClass = .compact }
                else { window.traitOverrides.remove(UITraitHorizontalSizeClass.self) }
            }
            try body()
        }
    }

    // MARK: - Rigs

    /// The extension's look for `theme`; the toolbar's own theme and the accent if given.
    private func look(_ theme: Theme, toolbar: Theme? = nil, accent: KeyboardSettings.Accent = .violet) -> KeyboardSettings {
        var s = KeyboardSettings()
        s.theme = theme
        s.toolbarTheme = toolbar
        s.accent = accent
        return s
    }

    private struct Rig {
        let kb: TerminalKeyboard
        let bar: SuggestionBar
        let doc: Proxy
        let view: UIView
        var image = UIImage()
    }

    /// The Prosper keyboard as its controller rigs it (`KeyboardViewController.viewDidLoad`):
    /// the bar over the keys in one view, Full Access on an empty named pasteboard, the four
    /// stores filled with the sample data, the toolbar showing, the model a canned reply.
    /// `then` opens what the shot shows, before it's drawn.
    private func system(_ settings: KeyboardSettings, layout: TerminalKeyboard.Layout = .english,
                        text: String = "", then: (Rig) throws -> Void = { _ in }) throws -> Rig {
        (Style.palette, Style.bar) = (Style.Palette(settings), Style.Palette.bar(settings))   // every view made below
        let doc = Proxy()
        doc.text = text
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard(layout: layout)
        kb.target = doc
        kb.bottomInset = TerminalKeyboard.extensionBottomInset
        kb.offersEmoji = false
        kb.allowsNumbersKey = true
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults), layout: layout))
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.shots.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        bar.suggestions.pasteboard = { pb }
        bar.history = clipHistory()
        bar.snippets = snippetStore()
        bar.quicklinks = quicklinkStore()
        let dictation = DictationClient(store: Dictation.Store(dir: dir.appendingPathComponent("Dictation-\(UUID())")))
        dictation.polls = false
        dictation.ping = { _ in }
        dictation.open = { _, done in done(false) }
        bar.dictation = dictation
        bar.rewrite = { _, _ in Self.rewritten }
        bar.attach(kb)
        // The toolbar a new install shows (#690), as the store shows the app out of the box.
        let keys = Shortcuts.Bar.toolbar.defaults
        bar.addToolbar { keys }
        if layout != .english { kb.languages = [.english, layout] }
        kb.settings = settings
        bar.showsToolbar = true
        let view = UIView(frame: CGRect(x: 0, y: 0, width: target.points.width, height: 400))
        bar.host(kb, in: view)
        var rig = Rig(kb: kb, bar: bar, doc: doc, view: view)
        kept += [kb, bar, doc, view, dictation]
        let height = try XCTUnwrap(kb.constraints.first { $0.firstItem === kb && $0.firstAttribute == .height })
        try place(view, height: SuggestionBar.height + kb.numberRowHeight + height.constant)
        try then(rig)
        rig.image = try draw(view)
        return rig
    }

    /// The terminal's keyboard as `TerminalHostVC` has it: its default two-row shortcut bar resting on
    /// the keys, which keep the digit row, the emoji key and the home indicator's pad.
    private func terminalKeyboard(_ settings: KeyboardSettings) throws -> UIImage {
        (Style.palette, Style.bar) = (Style.Palette(settings), Style.Palette.bar(settings))
        let kb = TerminalKeyboard()
        kb.settings = settings
        let keys = Shortcuts.defaults   // the bar a new install shows (#690)
        let bar = ShortcutBar(keys: { keys })
        bar.frame = CGRect(x: 0, y: 0, width: target.points.width, height: 86)
        for _ in 0..<2 { bar.layoutIfNeeded() }
        let barHeight = bar.intrinsicContentSize.height
        let view = UIView()
        view.backgroundColor = Style.backdrop
        bar.frame = CGRect(x: 0, y: 0, width: target.points.width, height: barHeight)
        kb.frame = CGRect(x: 0, y: barHeight, width: target.points.width, height: TerminalKeyboard.height)
        view.addSubview(kb)
        view.addSubview(bar)
        kept += [kb, bar, view]
        try place(view, height: barHeight + TerminalKeyboard.height)
        return try draw(view)
    }

    /// The open panel's filter mode with `query` typed into it, key by key.
    private func search(_ rig: Rig, _ query: String) throws {
        let panel = try XCTUnwrap(rig.bar.panel)
        panel.filter(true)
        let filter = try XCTUnwrap(panel.filter)
        for c in query { filter.type(String(c)) }
        XCTAssertGreaterThanOrEqual(filter.matches.count, 2, query)
        rig.view.layoutIfNeeded()
    }

    private func clipHistory() -> ClipboardHistory {
        let history = ClipboardHistory(dir: dir.appendingPathComponent("Clips-\(UUID())"))
        let now = Date()
        history.merge(Self.clips.enumerated().map { i, c in
            ClipboardHistory.Clip(text: c.text, date: now.addingTimeInterval(-Double(i + 1) * 900), pinned: c.pinned,
                                  source: c.mac ? ClipboardHistory.mac : nil)
        })
        return history
    }

    private func snippetStore() -> SnippetStore {
        let store = SnippetStore(url: dir.appendingPathComponent("Snippets-\(UUID())/Snippets/snippets.json"))
        for s in Self.snippets { _ = store.put(.init(name: s.name, text: s.text), replacing: nil) }
        return store
    }

    private func quicklinkStore() -> QuicklinkStore {
        let store = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks-\(UUID())/Quicklinks/quicklinks.json"))
        for q in Self.quicklinks { _ = store.put(.init(name: q.name, url: q.url), replacing: nil) }
        return store   // no recents: their header pushes the third row half under the card's edge
    }

    // MARK: - Drawing

    /// `view` alone in the window, `height` tall, laid out. Mid-screen, clear of the Dynamic
    /// Island's and the home indicator's safe area, as a keyboard's view has none: at the top,
    /// filter mode's results (#665), which reach over the bar, took the island's inset.
    private func place(_ view: UIView, height: CGFloat) throws {
        XCTAssertGreaterThan(height, 100)
        window.subviews.forEach { $0.removeFromSuperview() }
        let screen = try XCTUnwrap(window.windowScene).screen.bounds
        window.frame = CGRect(x: 0, y: ((screen.height - height) / 2).rounded(), width: target.points.width, height: height)
        view.frame = window.bounds
        window.addSubview(view)
        for _ in 0..<3 { window.layoutIfNeeded() }
        XCTAssertEqual(view.safeAreaInsets, .zero, "a keyboard has no safe area")
    }

    /// The view as the screen shows it, at the target's scale and opaque: `drawHierarchy` keeps the caps' glow
    /// and the panels' table, which `layer.render` drops. Animations (the mic's pulse) removed first.
    private func draw(_ view: UIView) throws -> UIImage {
        for _ in 0..<3 { view.layoutIfNeeded() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))   // the tables' cells, the async layouts
        view.layoutIfNeeded()
        func still(_ layer: CALayer) { layer.removeAllAnimations(); layer.sublayers?.forEach(still) }
        still(view.layer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = target.scale
        format.opaque = true
        var ok = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            ok = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(ok, "drawHierarchy drew nothing")
        return image
    }

    /// `view` as the app's whole screen, dark, `settle` seconds after it appears, at the target's
    /// size and scale. No status bar, which isn't the app's to draw. A hosted target's screen is a
    /// window of its size at the screen's top left, under the status bar as a phone's is, with the
    /// iPad's home indicator inset (20 pt) added at its foot.
    private func screen<V: View>(_ view: V, settle: TimeInterval) throws -> UIImage {
        let scene = try XCTUnwrap(window.windowScene)
        if target.hosted {
            XCTAssertTrue(target.points.width <= scene.screen.bounds.width
                          && target.points.height <= scene.screen.bounds.height, "\(target.name) fits the screen")
        } else {
            XCTAssertEqual(scene.screen.bounds.size, target.points, "a \(target.name) simulator")
        }
        window.subviews.forEach { $0.removeFromSuperview() }
        window.frame = CGRect(origin: .zero, size: target.points)
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark))
        // Clear of the screen's bottom edge, a hosted window has no home indicator's inset: a phone's has one.
        if target.hosted { host.additionalSafeAreaInsets.bottom = 20 }
        window.rootViewController = host
        window.makeKeyAndVisible()
        kept.append(host)
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        return try draw(window)
    }

    private func until(_ done: () -> Bool) throws {
        let end = Date().addingTimeInterval(3)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done(), "timed out")
    }

    /// A store slide: the headline and its line over a gradient with a glow in the accent, then
    /// the crops as rounded cards, stacked to fit, or each but the last showing only its top
    /// `overlap` share, a deck whose front card is whole. Laid out for the iPhone's 1320 px and
    /// scaled with the canvas's width, so every target's slide reads as the iPhone's does.
    private func slide(_ name: String, _ headline: String, _ line: String, colours: (UInt32, UInt32, UInt32),
                       ink: UIColor, _ crops: [UIImage?], overlap: CGFloat? = nil) throws {
        let cards = crops.compactMap { $0 }
        XCTAssertEqual(cards.count, crops.count, name)
        let size = target.store
        let k = size.width / 1320
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let (top, bottom, glow) = (UIColor(hex: colours.0), UIColor(hex: colours.1), UIColor(hex: colours.2))
            let fill = CGGradient(colorsSpace: space, colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(fill, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let halo = CGGradient(colorsSpace: space, colors: [glow.withAlphaComponent(0.38).cgColor,
                                                               glow.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            let centre = CGPoint(x: size.width / 2, y: size.height * 0.62)
            cg.drawRadialGradient(halo, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 1250 * k, options: [])

            let centred = NSMutableParagraphStyle()
            centred.alignment = .center
            let rounded = { (size: CGFloat, weight: UIFont.Weight) -> UIFont in
                let base = UIFont.systemFont(ofSize: size, weight: weight)
                return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
            }
            let title = NSAttributedString(string: headline, attributes: [
                .font: rounded(104 * k, .heavy), .foregroundColor: ink, .paragraphStyle: centred, .kern: -k])
            let sub = NSAttributedString(string: line, attributes: [
                .font: rounded(50 * k, .medium), .foregroundColor: ink.withAlphaComponent(0.72), .paragraphStyle: centred])
            let textWidth = 1160 * k
            var y = 200 * k
            for (text, gap) in [(title, 28 * k), (sub, 0)] {
                let r = text.boundingRect(with: CGSize(width: textWidth, height: 600 * k),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                text.draw(with: CGRect(x: (size.width - textWidth) / 2, y: y, width: textWidth, height: ceil(r.height)),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += ceil(r.height) + gap
            }

            let area = CGRect(x: 72 * k, y: y + 110 * k, width: size.width - 144 * k, height: size.height - y - (110 + 96) * k)
            let gap = 44 * k
            let heights = cards.map { $0.size.height / $0.size.width }   // per unit of width
            let width: CGFloat
            if let overlap {
                let total = heights.dropLast().reduce(0) { $0 + $1 * overlap } + heights.last!
                width = min(area.width, area.height / total)
            } else {
                width = min(area.width, (area.height - gap * CGFloat(cards.count - 1)) / heights.reduce(0, +))
            }
            let used = overlap.map { o in heights.dropLast().reduce(0) { $0 + $1 * o * width } + heights.last! * width }
                ?? heights.reduce(0) { $0 + $1 * width } + gap * CGFloat(cards.count - 1)
            var cy = area.minY + (area.height - used) / 2
            for (card, h) in zip(cards, heights) {
                let rect = CGRect(x: (size.width - width) / 2, y: cy, width: width, height: h * width)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 48 * k)
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: 24 * k), blur: 60 * k, color: UIColor.black.withAlphaComponent(0.45).cgColor)
                UIColor.black.setFill()
                path.fill()
                cg.restoreGState()
                cg.saveGState()
                path.addClip()
                card.draw(in: rect)
                cg.restoreGState()
                UIColor(white: 1, alpha: 0.1).setStroke()
                path.lineWidth = 2 * k
                path.stroke()
                cy += h * width * (overlap ?? 1) + (overlap == nil ? gap : 0)
            }
        }
        try write(image, "\(name).png", size: size)
    }

    /// The PNG, checked as App Store Connect checks it: `size` in pixels (any height, the target's
    /// width, without one) and no alpha channel (IMAGE_ALPHA_NOT_ALLOWED).
    private func write(_ image: UIImage, _ file: String, size: CGSize?) throws {
        let data = try XCTUnwrap(image.pngData(), file)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], file)
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file)
        XCTAssertEqual(cg.width, Int(size?.width ?? target.store.width), file)
        if let size { XCTAssertEqual(cg.height, Int(size.height), file) }
        XCTAssertNotEqual(props[kCGImagePropertyHasAlpha] as? Bool, true, "\(file): alpha")
        XCTAssertTrue([.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo), "\(file): \(cg.alphaInfo.rawValue)")
        try data.write(to: out.appendingPathComponent(file), options: .atomic)
    }
}
