import XCTest
import UIKit
import ImageIO
@testable import Prosper

/// The README's keyboard gallery and the App Store's keyboard slides (#670), drawn from the
/// production views with made-up data: each scene is rigged as the extension's controller and
/// the terminal rig them (`SuggestionBar.host`, `KeyboardToolbarTests.hostedRig`), put in a
/// window and drawn with `drawHierarchy` at 3x, 440 pt wide (an iPhone Pro Max), so 1320 px.
/// Then four 1320x2868 store slides from those crops, opaque: App Store Connect refuses alpha.
///
/// Off unless PROSPER_SHOTS names an output folder (`TEST_RUNNER_PROSPER_SHOTS`); run it with
/// scripts/keyboard-shots.sh, which copies the PNGs to store/keyboard and fastlane.
@MainActor
final class ScreenshotTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy
    typealias Theme = KeyboardSettings.Theme
    typealias Style = TerminalKeyboard.Style

    static let width: CGFloat = 440
    static let store = CGSize(width: 1320, height: 2868)

    private var out: URL!
    private var dir: URL!
    private var suite = ""
    private var window: UIWindow!
    private var saved: (Style.Palette, Style.Palette)!
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
        ("Sign-off", "Kind regards, and thanks again!"),
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

    /// The system keyboard's toolbar: the panels' keys first, then the arrows; as many as fit unscrolled.
    private static let toolbar = ["clips", "snips", "qlinks", "mic", "rewrite", "left", "right", "up", "down"]
    /// The terminal's bar, two rows as on a phone.
    private static let terminal = ["clips", "pasteImg", "up", "down", "tab", "wordBack", "wordNext", "insert",
                                   "esc", "ctrl", "left", "right", "pgup", "pgdn", "snips", "enter"]

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
        var shots: [String: UIImage] = [:]
        func shot(_ name: String, _ image: UIImage) throws {
            shots[name] = image
            try write(image, "keyboard-\(name).png", size: nil)
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

        try slide("iphone67_7-themes", "Make it yours",
                  "\(Theme.allCases.count) themes, toolbar themes and accents.",
                  colours: (0x0B1018, 0x1A1238, 0x8B7CFF), ink: .white,
                  [shots["theme-blossom"], shots["theme-amber"], shots["theme-mixed"], shots["theme-dark"]], overlap: 0.475)   // cut between the q and a rows
        try slide("iphone67_8-clipboard", "Saved, a tap away",
                  "Clipboard history, snippets and quicklinks.",
                  colours: (0x080813, 0x1E1E38, 0x7075FF), ink: .white,
                  [shots["clipboard"], shots["snippets"], shots["quicklinks"]])
        try slide("iphone67_9-menu", "Everything a hold away",
                  "Panels, numbers and the look, from the keys.",
                  colours: (0x05080D, 0x0B1E2E, 0x21CCFF), ink: .white,
                  [shots["menu"], shots["appearance"], shots["numpad"]])
        try slide("iphone67_10-ai", "Write it better, or say it",
                  "On-device Fix, Rewrite, Summarize, dictation.",
                  colours: (0xF5F0FA, 0xE3D8F0, 0x8945E3), ink: UIColor(hex: 0x241434),
                  [shots["ai"], shots["ai-result"], shots["dictation"]])
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
        // Rewrite shows on the English layout only (`SuggestionBar.rewrites`: the model has no
        // Bulgarian); tab takes its place so the row still fills.
        let ids = layout == .english ? Self.toolbar : Self.toolbar.map { $0 == "rewrite" ? "tab" : $0 }
        let keys = ids.compactMap { id in Shortcuts.Bar.toolbar.catalog.first { $0.id == id } }
        bar.addToolbar { keys }
        if layout != .english { kb.languages = [.english, layout] }
        kb.settings = settings
        bar.showsToolbar = true
        let view = UIView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 400))
        bar.host(kb, in: view)
        var rig = Rig(kb: kb, bar: bar, doc: doc, view: view)
        kept += [kb, bar, doc, view, dictation]
        let height = try XCTUnwrap(kb.constraints.first { $0.firstItem === kb && $0.firstAttribute == .height })
        try place(view, height: SuggestionBar.height + kb.numberRowHeight + height.constant)
        try then(rig)
        rig.image = try draw(view)
        return rig
    }

    /// The terminal's keyboard as `TerminalHostVC` has it: its two-row shortcut bar resting on
    /// the keys, which keep the digit row, the emoji key and the home indicator's pad.
    private func terminalKeyboard(_ settings: KeyboardSettings) throws -> UIImage {
        (Style.palette, Style.bar) = (Style.Palette(settings), Style.Palette.bar(settings))
        let kb = TerminalKeyboard()
        kb.settings = settings
        let keys = Self.terminal.compactMap { id in Shortcuts.Bar.terminal.catalog.first { $0.id == id } }
        let bar = ShortcutBar(keys: { keys })
        bar.frame = CGRect(x: 0, y: 0, width: Self.width, height: 86)
        for _ in 0..<2 { bar.layoutIfNeeded() }
        let barHeight = bar.intrinsicContentSize.height
        let view = UIView()
        view.backgroundColor = Style.backdrop
        bar.frame = CGRect(x: 0, y: 0, width: Self.width, height: barHeight)
        kb.frame = CGRect(x: 0, y: barHeight, width: Self.width, height: TerminalKeyboard.height)
        view.addSubview(kb)
        view.addSubview(bar)
        kept += [kb, bar, view]
        try place(view, height: barHeight + TerminalKeyboard.height)
        return try draw(view)
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

    /// `view` alone in the window, `height` tall, laid out.
    private func place(_ view: UIView, height: CGFloat) throws {
        XCTAssertGreaterThan(height, 100)
        window.subviews.forEach { $0.removeFromSuperview() }
        window.frame = CGRect(x: 0, y: 0, width: Self.width, height: height)
        view.frame = window.bounds
        window.addSubview(view)
        for _ in 0..<3 { window.layoutIfNeeded() }
    }

    /// The view as the screen shows it, at 3x and opaque: `drawHierarchy` keeps the caps' glow
    /// and the panels' table, which `layer.render` drops. Animations (the mic's pulse) removed first.
    private func draw(_ view: UIView) throws -> UIImage {
        for _ in 0..<3 { view.layoutIfNeeded() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))   // the tables' cells, the async layouts
        view.layoutIfNeeded()
        func still(_ layer: CALayer) { layer.removeAllAnimations(); layer.sublayers?.forEach(still) }
        still(view.layer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        var ok = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            ok = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(ok, "drawHierarchy drew nothing")
        return image
    }

    private func until(_ done: () -> Bool) throws {
        let end = Date().addingTimeInterval(3)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(done(), "timed out")
    }

    /// A store slide: the headline and its line over a gradient with a glow in the accent, then
    /// the crops as rounded cards, stacked to fit, or each but the last showing only its top
    /// `overlap` share, a deck whose front card is whole.
    private func slide(_ name: String, _ headline: String, _ line: String, colours: (UInt32, UInt32, UInt32),
                       ink: UIColor, _ crops: [UIImage?], overlap: CGFloat? = nil) throws {
        let cards = crops.compactMap { $0 }
        XCTAssertEqual(cards.count, crops.count, name)
        let size = Self.store
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
            cg.drawRadialGradient(halo, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 1250, options: [])

            let centred = NSMutableParagraphStyle()
            centred.alignment = .center
            let rounded = { (size: CGFloat, weight: UIFont.Weight) -> UIFont in
                let base = UIFont.systemFont(ofSize: size, weight: weight)
                return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
            }
            let title = NSAttributedString(string: headline, attributes: [
                .font: rounded(104, .heavy), .foregroundColor: ink, .paragraphStyle: centred, .kern: -1])
            let sub = NSAttributedString(string: line, attributes: [
                .font: rounded(50, .medium), .foregroundColor: ink.withAlphaComponent(0.72), .paragraphStyle: centred])
            let textWidth: CGFloat = 1160
            var y: CGFloat = 200
            for (text, gap) in [(title, CGFloat(28)), (sub, CGFloat(0))] {
                let r = text.boundingRect(with: CGSize(width: textWidth, height: 600),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                text.draw(with: CGRect(x: (size.width - textWidth) / 2, y: y, width: textWidth, height: ceil(r.height)),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += ceil(r.height) + gap
            }

            let area = CGRect(x: 72, y: y + 110, width: size.width - 144, height: size.height - y - 110 - 96)
            let gap: CGFloat = 44
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
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 48)
                cg.saveGState()
                cg.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: UIColor.black.withAlphaComponent(0.45).cgColor)
                UIColor.black.setFill()
                path.fill()
                cg.restoreGState()
                cg.saveGState()
                path.addClip()
                card.draw(in: rect)
                cg.restoreGState()
                UIColor(white: 1, alpha: 0.1).setStroke()
                path.lineWidth = 2
                path.stroke()
                cy += h * width * (overlap ?? 1) + (overlap == nil ? gap : 0)
            }
        }
        try write(image, "\(name).png", size: size)
    }

    /// The PNG, checked as App Store Connect checks it: `size` in pixels (any height, 1320 wide,
    /// without one) and no alpha channel (IMAGE_ALPHA_NOT_ALLOWED).
    private func write(_ image: UIImage, _ file: String, size: CGSize?) throws {
        let data = try XCTUnwrap(image.pngData(), file)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], file)
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file)
        XCTAssertEqual(cg.width, Int(size?.width ?? 1320), file)
        if let size { XCTAssertEqual(cg.height, Int(size.height), file) }
        XCTAssertNotEqual(props[kCGImagePropertyHasAlpha] as? Bool, true, "\(file): alpha")
        XCTAssertTrue([.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo), "\(file): \(cg.alphaInfo.rawValue)")
        try data.write(to: out.appendingPathComponent(file), options: .atomic)
    }
}
