import XCTest
import UIKit
import UniformTypeIdentifiers
@testable import Prosper

/// The app's shortcut keys as the system keyboard's toolbar (`SuggestionBar.addToolbar`):
/// what each key does in a host field, the toggle and its pick, AutoFill and Paste over
/// the toolbar, its Paste key, its own key list (`Shortcuts.Bar.toolbar`), and the keys'
/// move to the App Group (`Shortcuts.shared`).
@MainActor
final class KeyboardToolbarTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "KeyboardToolbarTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A keyboard on a fake field, the bar attached with the default keys as its toolbar.
    /// Keep all three: the keyboard holds the proxy and the bar weakly.
    private func rig(_ text: String = "", after: String = "",
                     keys: [ShortcutKey] = Shortcuts.defaults) -> (TerminalKeyboard, SuggestionBar, Proxy) {
        let doc = Proxy()
        doc.text = text; doc.after = after
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults)))
        bar.attach(kb)
        bar.addToolbar { keys }
        return (kb, bar, doc)
    }

    private func key(_ id: String) throws -> ShortcutKey {
        try XCTUnwrap(Shortcuts.catalog.first { $0.id == id })
    }

    private static func caps(_ v: UIView) -> [KeyCapButton] {
        v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) }
    }

    /// Every catalog key, in order: what it does in a host field, or hidden (nil).
    func testEachCatalogKeyMapsOrHides() {
        let want: [(String, Shortcuts.HostKey?)] = [
            ("esc", nil), ("tab", .key(.char("\t"))), ("stab", nil), ("ctrl", nil), ("alt", nil),
            ("shift", nil), ("ctlc", nil), ("ctld", nil), ("ctlr", nil),
            ("up", .line(-1)), ("down", .line(1)), ("left", .caret(-1)), ("right", .caret(1)),
            ("home", .lineEdge(-1)), ("end", .lineEdge(1)), ("pgup", nil), ("pgdn", nil),
            ("slash", .key(.char("/"))), ("pipe", .key(.char("|"))), ("paste", .paste), ("pasteImg", nil),
            ("insert", nil), ("snl", .key(.ret)), ("enter", .key(.ret)), ("redraw", nil),
        ]
        XCTAssertEqual(Shortcuts.catalog.map(\.id), want.map(\.0), "a new catalog key needs a mapping here")
        for (id, action) in want { XCTAssertEqual(Shortcuts.hostKey(id), action, id) }
        let (_, bar, _) = rig()
        XCTAssertEqual(Self.caps(try XCTUnwrap(bar.toolbar)).compactMap(\.accessibilityLabel),
                       ["↑", "↓", "tab", "home", "←", "→", "end", "send"], "the hidden ones aren't caps, nor Paste without Full Access")
    }

    /// The keys in the field: sideways and to the line's ends through the caret walk, ↑
    /// and ↓ a line through it (#541), the rest typed as the keyboard's own keys.
    func testToolbarKeysActInTheHostField() throws {
        let (kb, bar, doc) = rig("abc\nde", after: "f")
        func press(_ id: String) throws {
            bar.press(try key(id))
            for _ in 0..<40 { doc.catchUp(); kb.pollCaret() }
        }
        try press("up")
        XCTAssertEqual(doc.text, "ab", "up keeps the column")
        XCTAssertEqual(doc.after, "c\ndef")
        try press("down")
        XCTAssertEqual(doc.text, "abc\nde")
        try press("home")
        XCTAssertEqual(doc.text, "abc\n")
        try press("end")
        XCTAssertEqual(doc.text, "abc\ndef")
        try press("left")
        XCTAssertEqual(doc.text, "abc\nde")
        try press("right")
        XCTAssertEqual(doc.text, "abc\ndef")
        doc.calls = []
        for id in ["tab", "slash", "pipe", "snl", "enter", "esc", "ctlc"] { try press(id) }
        XCTAssertEqual(doc.calls, ["\t", "/", "|", "\n", "\n"], "esc and ^C do nothing")

        let (safariKB, safariBar, safari) = rig("abc\nde", after: "f")
        safari.breakSpace = true
        safariBar.press(try key("home"))
        for _ in 0..<40 { safari.catchUp(); safariKB.pollCaret() }
        XCTAssertEqual(safari.text, "abc\n", "Safari's space after the break isn't the line's")
    }

    /// The toggle flips the slots and the toolbar, and its pick outlives the bar.
    func testTheToggleSwitchesAndPersists() throws {
        let (_, bar, _) = rig()
        let toolbar = try XCTUnwrap(bar.toolbar), toggle = try XCTUnwrap(bar.toggle)
        XCTAssertTrue(toolbar.isHidden, "the suggestions first")
        XCTAssertFalse(bar.slotButtons[0].isHidden)
        XCTAssertEqual(toggle.accessibilityLabel, "Show toolbar")
        toggle.sendActions(for: .touchUpInside)
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertTrue(bar.slotButtons.allSatisfy(\.isHidden))
        XCTAssertEqual(toggle.accessibilityLabel, "Show suggestions")
        XCTAssertTrue(defaults.bool(forKey: SuggestionBar.toolbarKey))
        let (_, again, _) = rig()
        XCTAssertFalse(try XCTUnwrap(again.toolbar).isHidden, "a new keyboard keeps the pick")
        try XCTUnwrap(again.toggle).sendActions(for: .touchUpInside)
        XCTAssertFalse(defaults.bool(forKey: SuggestionBar.toolbarKey))
        XCTAssertTrue(try XCTUnwrap(again.toolbar).isHidden)
    }

    /// A login field shows AutoFill over the toolbar, the toggle out of the way; away from it
    /// the toolbar is back, and the pick never changed. A fresh clip doesn't: the toolbar has
    /// its own Paste (#553), and the bar's shows over the suggestions only.
    func testAutoFillShowsOverTheToolbarAndPasteDoesnt() throws {
        let (_, bar, doc) = rig()
        bar.showsToolbar = true
        let toolbar = try XCTUnwrap(bar.toolbar), toggle = try XCTUnwrap(bar.toggle)
        doc.isSecureTextEntry = true
        bar.refresh()
        XCTAssertEqual(bar.state, .autofill)
        XCTAssertTrue(toolbar.isHidden)
        XCTAssertTrue(toggle.isHidden)
        XCTAssertFalse(bar.autofillButton.isHidden)
        doc.isSecureTextEntry = false
        bar.refresh()
        XCTAssertFalse(toolbar.isHidden, "back to the toolbar")
        XCTAssertFalse(toggle.isHidden)

        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        pb.string = "clip"
        bar.suggestions.pasteboard = { pb }
        bar.refresh()
        XCTAssertNotEqual(bar.state, .paste)
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertTrue(bar.pasteControl.isHidden)
        bar.showsToolbar = false
        XCTAssertEqual(bar.state, .paste, "over the suggestions")
        XCTAssertFalse(bar.pasteControl.isHidden)
        XCTAssertTrue(toggle.isHidden)
        bar.suggestions.pasteboard = { nil }
        bar.refresh()
        bar.showsToolbar = true
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertTrue(bar.showsToolbar, "the pick stays the user's")
    }

    /// The bar the app kept in its own defaults is copied to the App Group once; one already
    /// there wins. No group access (the extension without Full Access): the default set.
    func testTheKeysMoveToTheAppGroupOnce() throws {
        let group = try XCTUnwrap(UserDefaults(suiteName: suite + ".group"))
        let store = KeyboardSettings.store, old = UserDefaults.standard.string(forKey: Shortcuts.storageKey)
        KeyboardSettings.store = { group }
        defer {
            KeyboardSettings.store = store
            group.removePersistentDomain(forName: suite + ".group")
            UserDefaults.standard.set(old, forKey: Shortcuts.storageKey)
        }
        let mine = try ["esc", "tab", "enter"].map(key)
        Shortcuts.save(mine, to: .standard)
        XCTAssertEqual(Shortcuts.load().map(\.id), ["esc", "tab", "enter"], "copied over")
        XCTAssertNotNil(group.string(forKey: Shortcuts.storageKey))
        XCTAssertNotNil(UserDefaults.standard.string(forKey: Shortcuts.storageKey), "kept for an older build")
        Shortcuts.save(try ["pipe", "enter"].map(key), to: .standard)
        XCTAssertEqual(Shortcuts.load().map(\.id), ["esc", "tab", "enter"], "the group's wins")
        Shortcuts.save(try ["slash", "enter"].map(key))
        XCTAssertEqual(Shortcuts.load(group).map(\.id), ["slash", "enter"], "the editor writes the group")
        XCTAssertEqual(Shortcuts.load(nil).map(\.id), Shortcuts.defaults.map(\.id))
    }

    private func suiteStore(_ name: String) throws -> UserDefaults {
        let store = try XCTUnwrap(UserDefaults(suiteName: suite + name))
        addTeardownBlock { store.removePersistentDomain(forName: self.suite + name) }
        return store
    }

    private static func pasteControls(_ v: UIView) -> [UIPasteControl] {
        v.subviews.flatMap { ($0 as? UIPasteControl).map { [$0] } ?? pasteControls($0) }
    }

    /// Nothing saved, terminal bar untouched: the default bar's keys a text field can use, in
    /// its order, less send, Paste first; saved, so the terminal bar no longer feeds it. No
    /// group (no Full Access): the same default.
    func testToolbarListDefaultsToTheHostKeysWithPasteAndNoSend() throws {
        let store = try suiteStore(".default")
        let want = ["paste", "up", "down", "tab", "home", "left", "right", "end"]
        XCTAssertEqual(Shortcuts.Bar.toolbar.defaults.map(\.id), want)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), want)
        XCTAssertNotNil(store.string(forKey: Shortcuts.Bar.toolbar.storageKey), "seeded once")
        Shortcuts.save(try ["pipe", "enter"].map(key), to: store)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), want, "a later terminal edit doesn't reach it")
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(nil).map(\.id), want)
        XCTAssertNotEqual(Shortcuts.Bar.toolbar.storageKey, Shortcuts.storageKey)
    }

    /// A customised terminal bar seeds the toolbar once: its keys a text field can use, in
    /// its order, send included, plus Paste (first, or where the bar had it).
    func testToolbarListSeedsOnceFromACustomisedTerminalBar() throws {
        let store = try suiteStore(".custom")
        Shortcuts.save(try ["esc", "left", "enter", "ctlc", "pipe"].map(key), to: store)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), ["paste", "left", "enter", "pipe"])
        Shortcuts.save(try ["slash", "enter"].map(key), to: store)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), ["paste", "left", "enter", "pipe"], "once")

        let had = try suiteStore(".hadPaste")
        Shortcuts.save(try ["tab", "paste", "insert", "enter"].map(key), to: had)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(had).map(\.id), ["tab", "paste", "enter"])
    }

    /// Send is an ordinary key on the toolbar: a list without it stays without it, an empty
    /// one stays empty. The terminal's still gets send back, and its editor can't drop it.
    func testSendlessToolbarStaysSendlessAndTheTerminalForcesSend() throws {
        let store = try suiteStore(".send")
        Shortcuts.save(try ["left", "right"].map(key), to: store, key: Shortcuts.Bar.toolbar.storageKey)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), ["left", "right"])
        Shortcuts.save([], to: store, key: Shortcuts.Bar.toolbar.storageKey)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), [], "emptied stays empty")
        Shortcuts.save(try ["esc", "esc", "paste"].map(key), to: store, key: Shortcuts.Bar.toolbar.storageKey)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), ["paste"], "terminal-only keys dropped")
        XCTAssertFalse(Shortcuts.Bar.toolbar.sendMandatory)
        XCTAssertTrue(Shortcuts.Bar.toolbar.catalog.contains { $0.id == Shortcuts.sendID }, "send can come back")

        Shortcuts.save(try ["esc", "tab"].map(key), to: store)
        XCTAssertEqual(Shortcuts.Bar.terminal.load(store).map(\.id), ["esc", "tab", "enter"])
        XCTAssertTrue(Shortcuts.Bar.terminal.sendMandatory)
        XCTAssertEqual(Shortcuts.Bar.terminal.catalog.map(\.id), Shortcuts.catalog.map(\.id))
    }

    /// The toolbar's Paste is the system's control, pasting into the toolbar: its clip goes
    /// in as is and is retired, like the bar's. Never a pasteboard read (`press` does nothing).
    /// No Full Access or landscape: no control; a hidden toolbar loads nothing.
    func testToolbarPasteInsertsTheClipThroughTheSystemControl() throws {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        pb.string = "clip"
        let (kb, bar, doc) = rig("say h", keys: Shortcuts.Bar.toolbar.defaults)   // mid-word: no bar Paste
        let toolbar = try XCTUnwrap(bar.toolbar)
        XCTAssertTrue(Self.pasteControls(toolbar).isEmpty, "no Full Access")
        bar.suggestions.pasteboard = { pb }
        toolbar.reload()
        bar.showsToolbar = true
        bar.refresh()
        XCTAssertNotEqual(bar.state, .paste)
        XCTAssertFalse(toolbar.isHidden)
        let control = try XCTUnwrap(Self.pasteControls(toolbar).first)
        XCTAssertTrue(control.target === toolbar)
        XCTAssertEqual(toolbar.pasteConfiguration?.acceptableTypeIdentifiers, [UTType.plainText.identifier])
        XCTAssertEqual(control.maximumContentSizeCategory, .large, "larger draws blank")

        bar.press(try key("paste"))
        XCTAssertEqual(doc.text, "say h", "the key itself never reads the pasteboard")
        toolbar.paste(itemProviders: [NSItemProvider(object: "clip" as NSString)])
        let deadline = Date() + 2
        while doc.text == "say h", Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
        XCTAssertEqual(doc.text, "say hclip")
        XCTAssertEqual(bar.suggestions.memory.retiredClip, pb.changeCount)

        bar.showsToolbar = false
        toolbar.paste(itemProviders: [NSItemProvider(object: "late" as NSString)])
        RunLoop.main.run(until: Date() + 0.2)
        XCTAssertEqual(doc.text, "say hclip", "a hidden toolbar's control loads nothing")

        bar.suggestions.pasteFits = false
        toolbar.reload()
        XCTAssertTrue(Self.pasteControls(toolbar).isEmpty, "landscape: blank under 36 pt")
        withExtendedLifetime(kb) {}
    }

    /// The Paste cap looks like the others whatever the system draws the control as: a
    /// container with a cap's fill, border, radius and halo, the control inside it (#558).
    func testToolbarPasteSitsInACapStyledContainer() throws {
        let toolbar = ShortcutBar(keys: { Shortcuts.Bar.toolbar.defaults }, oneRow: true)
        let control = try XCTUnwrap(Self.pasteControls(toolbar).first)
        XCTAssertTrue(control.target === toolbar)
        let box = try XCTUnwrap(control.superview), cap = try XCTUnwrap(Self.caps(toolbar).first)
        let bg = try XCTUnwrap(cap.configuration?.background)
        XCTAssertEqual(box.backgroundColor, bg.backgroundColor)
        XCTAssertEqual(box.layer.borderColor, bg.strokeColor?.cgColor)
        XCTAssertEqual(box.layer.borderWidth, bg.strokeWidth)
        XCTAssertEqual(box.layer.cornerRadius, bg.cornerRadius)
        XCTAssertEqual(box.layer.shadowColor, cap.layer.shadowColor)
        XCTAssertEqual(box.layer.shadowOpacity, cap.layer.shadowOpacity)
        XCTAssertEqual(box.layer.shadowRadius, cap.layer.shadowRadius)
        XCTAssertEqual(box.layer.shadowOffset, cap.layer.shadowOffset)
        XCTAssertEqual(box.subviews, [control], "nothing over the control")
    }

    /// A toolbar shown in a window at `size`, Full Access on so Paste is in it, laid out.
    @available(iOS 17, *)
    private func shown(at size: UIContentSizeCategory) throws -> (UIWindow, SuggestionBar, TerminalKeyboard) {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        let (kb, bar, _) = rig("say h", keys: Shortcuts.Bar.toolbar.defaults)
        bar.suggestions.pasteboard = { pb }
        try XCTUnwrap(bar.toolbar).reload()
        bar.showsToolbar = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.traitOverrides.preferredContentSizeCategory = size
        bar.frame = CGRect(x: 0, y: 0, width: 402, height: 44)
        window.addSubview(bar)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        window.layoutIfNeeded()
        return (window, bar, kb)
    }

    /// QA's #559: at accessibility-large every cap keeps the Paste cap's radius, 7, not
    /// UIButton's dynamic one, which grows with the text (the button draws its
    /// background at its layer's radius).
    func testCapsKeepThePasteCapsRadiusAtAccessibilitySizes() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let (_, bar, kb) = try shown(at: .accessibilityLarge)
        let toolbar = try XCTUnwrap(bar.toolbar)
        let paste = try XCTUnwrap(Self.pasteControls(toolbar).first?.superview)
        for cap in Self.caps(toolbar) {
            XCTAssertEqual(cap.layer.cornerRadius, paste.layer.cornerRadius, cap.accessibilityLabel ?? "")
        }
        withExtendedLifetime(kb) {}
    }

    /// QA's #559: the Show toolbar / Show suggestions glyph fits its button, and the button
    /// the bar, at every text size, accessibility-large too.
    func testTheToggleGlyphFitsAtAccessibilitySizes() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        for size in [UIContentSizeCategory.large, .accessibilityLarge, .accessibilityExtraExtraExtraLarge] {
            for tools in [false, true] {
                let (_, bar, kb) = try shown(at: size)
                bar.showsToolbar = tools
                bar.layoutIfNeeded()
                let toggle = try XCTUnwrap(bar.toggle), image = try XCTUnwrap(toggle.imageView)
                toggle.layoutIfNeeded()
                XCTAssertTrue(toggle.bounds.contains(image.frame), "\(size) \(tools): \(image.frame) in \(toggle.bounds)")
                XCTAssertTrue(bar.bounds.contains(toggle.convert(image.frame, to: bar)), "\(size) \(tools)")
                withExtendedLifetime(kb) {}
            }
        }
    }

    /// M893: the Paste control is never squeezed under its own height in a laid-out
    /// toolbar (below it, the control draws blank).
    func testThePasteControlKeepsItsHeightInALaidOutToolbar() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let (window, bar, kb) = try shown(at: .large)
        let control = try XCTUnwrap(Self.pasteControls(try XCTUnwrap(bar.toolbar)).first)
        // The control learns its size from the system a runloop turn after it's shown.
        let deadline = Date() + 2
        while control.intrinsicContentSize.height == 0, Date() < deadline { RunLoop.main.run(until: Date() + 0.05) }
        window.layoutIfNeeded()
        XCTAssertGreaterThan(control.intrinsicContentSize.height, 0)
        XCTAssertGreaterThanOrEqual(control.bounds.height, control.intrinsicContentSize.height)
        withExtendedLifetime(kb) {}
    }

    /// Rotating rebuilds the toolbar: Paste leaves in landscape and comes back in portrait,
    /// with nothing else reloading it.
    func testRotatingDropsAndRestoresTheToolbarPaste() throws {
        guard #available(iOS 17, *) else { throw XCTSkip("traitOverrides is iOS 17") }
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        let (kb, bar, _) = rig("say h", keys: Shortcuts.Bar.toolbar.defaults)
        bar.suggestions.pasteboard = { pb }
        let toolbar = try XCTUnwrap(bar.toolbar)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        bar.frame = CGRect(x: 0, y: 0, width: 402, height: 44)
        window.addSubview(bar)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        XCTAssertFalse(Self.pasteControls(toolbar).isEmpty, "portrait")

        window.traitOverrides.verticalSizeClass = .compact
        window.layoutIfNeeded()
        XCTAssertTrue(Self.pasteControls(toolbar).isEmpty, "landscape")

        window.traitOverrides.verticalSizeClass = .regular
        window.layoutIfNeeded()
        XCTAssertFalse(Self.pasteControls(toolbar).isEmpty, "portrait again")
        withExtendedLifetime(kb) {}
    }

    // MARK: Edits (#553)

    /// A toolbar edit pressed, then the walk polling until it lands, the host catching up
    /// every `every` polls.
    private func edit(_ id: String, _ kb: TerminalKeyboard, _ bar: SuggestionBar, _ doc: Proxy,
                      every: Int = 1) throws {
        bar.press(try XCTUnwrap(Shortcuts.Bar.toolbar.catalog.first { $0.id == id }, id))
        for i in 1...3_000 {
            if i % every == 0 { doc.catchUp() }
            kb.pollCaret()
        }
    }

    /// The text, "|" at the caret.
    private static func at(_ doc: Proxy) -> String { doc.text + "|" + (doc.after ?? "") }

    /// A plain UITextView's proxy: the before-context the caret's line (its LF alone at a
    /// line's start), the after-context stopping at the line's end, edits shown only on a
    /// later poll, and after them only what's left of the window they were cut from.
    private static func textView(_ d: Proxy) {
        d.lineBefore = true; d.stopsAtLineEnd = true; d.lagsEdits = true; d.cutsEdits = true
    }
    /// Safari's: windows either side, a space after a break that isn't in the text, edits
    /// shown only on a later poll, and after them only what's left of the window.
    private static func safari(_ d: Proxy) { d.window = 6; d.breakSpace = true; d.lagsEdits = true; d.cutsEdits = true }

    /// The edits are the toolbar's only, each an icon with a spoken label; the terminal's
    /// catalog and its saved keys never see them, the toolbar's keep them.
    func testEditKeysAreToolbarOnlyIconsWithLabels() throws {
        let ids = ["wordNext", "wordEnd", "wordBack", "delWord", "delHome", "delEnd", "delLine", "delAll",
                   "copyLine", "cutLine"]
        XCTAssertEqual(Shortcuts.hostOnly.map(\.id), ids)
        let edits: [Shortcuts.Edit] = [.wordNext, .wordEnd, .wordBack, .deleteWord, .deleteToStart, .deleteToEnd,
                                       .deleteLine, .deleteAll, .copyLine, .cutLine]
        for (k, e) in zip(Shortcuts.hostOnly, edits) {
            XCTAssertEqual(Shortcuts.hostKey(k.id), .edit(e), k.id)
            XCTAssertNotNil(UIImage(systemName: try XCTUnwrap(k.systemImage, k.id)), k.id)
            XCTAssertGreaterThan(k.label.count, 3, "VoiceOver reads it: \(k.id)")
        }
        XCTAssertTrue(Set(ids).isDisjoint(with: Shortcuts.catalog.map(\.id)))
        XCTAssertTrue(Set(ids).isDisjoint(with: Shortcuts.Bar.terminal.catalog.map(\.id)))
        XCTAssertTrue(Set(ids).isSubset(of: Shortcuts.Bar.toolbar.catalog.map(\.id)))
        XCTAssertTrue(Set(ids).isDisjoint(with: Shortcuts.Bar.toolbar.defaults.map(\.id)), "added in the editor")

        let store = try suiteStore(".edits")
        let saved = Shortcuts.hostOnly.prefix(3) + [try key("left")]
        Shortcuts.save(Array(saved), to: store, key: Shortcuts.Bar.toolbar.storageKey)
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), ["wordNext", "wordEnd", "wordBack", "left"])
        let (_, bar, _) = rig(keys: Shortcuts.hostOnly)
        XCTAssertEqual(Self.caps(try XCTUnwrap(bar.toolbar)).compactMap(\.accessibilityLabel),
                       Shortcuts.hostOnly.filter { !["copyLine", "cutLine"].contains($0.id) }.map(\.label),
                       "no copy or cut without Full Access")
    }

    /// nvim's word classes: letters, digits and "_" one, other punctuation another, blanks
    /// between. `w` lands on the next word's start, `e` after the word's end, `b` on its start.
    func testWordMotionsFollowNvimsClasses() throws {
        XCTAssertEqual(SuggestionBar.toNextWord("foo_bar1.baz qux"), 8, "to the dot")
        XCTAssertEqual(SuggestionBar.toNextWord(".baz qux"), 1)
        XCTAssertEqual(SuggestionBar.toNextWord("...  qux"), 5)
        XCTAssertEqual(SuggestionBar.toNextWord("  \n qux"), 4)
        XCTAssertEqual(SuggestionBar.toNextWord("здравей свят"), 8)
        XCTAssertEqual(SuggestionBar.toNextWord(""), 0)
        XCTAssertEqual(SuggestionBar.toWordEdge("  baz.qux"), 5)
        XCTAssertEqual(SuggestionBar.toWordEdge("o bar"), 1)
        XCTAssertEqual(SuggestionBar.toWordEdge("->x"), 2)
        XCTAssertEqual(SuggestionBar.toWordEdge("say foo ".reversed()), 4)

        let (kb, bar, doc) = rig("say hello", after: " world.foo")
        try edit("wordNext", kb, bar, doc)
        XCTAssertEqual(doc.text, "say hello ")
        try edit("wordEnd", kb, bar, doc)
        XCTAssertEqual(doc.text, "say hello world")
        try edit("wordNext", kb, bar, doc)
        XCTAssertEqual(doc.text, "say hello world.")
        try edit("wordBack", kb, bar, doc)
        XCTAssertEqual(doc.text, "say hello world", "the dot is a word of its own")
        try edit("wordBack", kb, bar, doc)
        XCTAssertEqual(doc.text, "say hello ")
        try edit("wordBack", kb, bar, doc)
        XCTAssertEqual(doc.text, "say ")
        XCTAssertEqual(doc.after, "hello world.foo")

        let (ekb, ebar, said) = rig("say", after: " hello world")
        try edit("wordEnd", ekb, ebar, said)
        XCTAssertEqual(Self.at(said), "say hello| world", "e goes past the word w lands on")
    }

    /// `w` and `e` cross line ends where the after-context stops there: one step blind over
    /// the break, then on. An empty line is a word to `w`; the text's end clamps.
    func testWordMotionsCrossLineEnds() throws {
        let (kb, bar, doc) = rig("one two", after: "\n  three four\n\nfive")
        Self.textView(doc)
        try edit("wordNext", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "one two\n  |three four\n\nfive", "over the break and the blanks")
        try edit("wordEnd", kb, bar, doc)
        try edit("wordEnd", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "one two\n  three four|\n\nfive")
        try edit("wordNext", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "one two\n  three four\n|\nfive", "an empty line")
        try edit("wordNext", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "one two\n  three four\n\n|five")
        try edit("wordEnd", kb, bar, doc)
        try edit("wordNext", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "one two\n  three four\n\nfive|", "the text's end")
        doc.text = "one two\n"; doc.after = "\nfive"
        try edit("wordEnd", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "one two\n\nfive|", "e from an empty line")
        doc.text = "one two"; doc.after = "\n\nthree four"
        try edit("wordEnd", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "one two\n\nthree| four", "e skips an empty line, as nvim's (#553 QA)")
    }

    /// ctrl-w and ctrl-u delete back; ctrl-u reads the context again after each batch, so a
    /// host showing only the caret's sentence or a window still loses the whole line, and
    /// no more: the break before it and the lines above stay.
    func testDeletesBackThroughATruncatedContext() throws {
        let (kb, bar, doc) = rig("top\nFirst one. Second tw", after: "o")
        try edit("delWord", kb, bar, doc)
        XCTAssertEqual(doc.text, "top\nFirst one. Second ")
        try edit("delWord", kb, bar, doc)
        XCTAssertEqual(doc.text, "top\nFirst one. ")
        let (bkb, bbar, lines) = rig("one two\n", after: "three four")
        try edit("delWord", bkb, bbar, lines)
        XCTAssertEqual(Self.at(lines), "one two|three four", "at a line's start only the break")
        lines.text = "foo\n   "; lines.after = ""
        try edit("delWord", bkb, bbar, lines)
        XCTAssertEqual(Self.at(lines), "foo\n|", "blanks stop at the break")
        doc.text = "top\nFirst one. Second tw"
        doc.sentenceBefore = true
        try edit("delHome", kb, bar, doc)
        XCTAssertEqual(doc.text, "top\n")
        XCTAssertEqual(doc.after, "o")

        let (wkb, wbar, safari) = rig("top\nthe quick brown fox", after: " jumps")
        safari.window = 4
        try edit("delHome", wkb, wbar, safari)
        XCTAssertEqual(safari.text, "top\n")
        safari.text = "top\nnext"
        safari.window = nil
        safari.breakSpace = true
        try edit("delHome", wkb, wbar, safari)
        XCTAssertEqual(safari.text, "top\n", "Safari's space after the break isn't the line's")
        // A window cut just after the break, at Safari's space: the anchor is the line's
        // first Character, which the next context, opening on the break, ends in.
        safari.text = "top\nabcdef"
        safari.window = 7
        safari.lagsEdits = true
        try edit("delHome", wkb, wbar, safari)
        XCTAssertEqual(safari.text, "top\n", "a context starting at Safari's space")

        let (ckb, cbar, word) = rig("abc")
        word.lagsEdits = true
        cbar.press(try key(Shortcuts.hostOnly, "delWord"))
        XCTAssertEqual(word.calls, ["⌫", "⌫", "⌫"], "a word the whole context shows goes in one batch")
        for _ in 0..<40 { word.catchUp(); ckb.pollCaret() }
        XCTAssertEqual(Self.at(word), "|")
    }

    /// ctrl-k, dd and delete all walk the caret forward first, a leg per window of context,
    /// then delete back: in Safari's windows, and where the after-context stops at the
    /// line's end and the before-context starts at it (a UITextView).
    func testForwardEditsWalkATruncatedContext() throws {
        for (name, cut) in [("windows", { (d: Proxy) in d.window = 5 }),
                            ("lines", { (d: Proxy) in d.stopsAtLineEnd = true; d.lineBefore = true })] {
            let (kb, bar, doc) = rig("one\nthe qu", after: "ick brown fox\nlast line")
            cut(doc)
            try edit("delEnd", kb, bar, doc)
            XCTAssertEqual(doc.text, "one\nthe qu", name)
            XCTAssertEqual(doc.after, "\nlast line", name)
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(doc.text + (doc.after ?? ""), "one\nlast line", name)
            doc.text = "one\ntwo\nthr"; doc.after = "ee"
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(doc.text + (doc.after ?? ""), "one\ntwo", "the last line takes the break before it: \(name)")
            doc.text = "first line\nsecond li"; doc.after = "ne\nthird line\nend"
            try edit("delAll", kb, bar, doc)
            XCTAssertEqual(doc.text, "", name)
            XCTAssertEqual(doc.after, "", name)
        }
    }

    /// Copy line puts the caret's line on the pasteboard and the caret back where it was;
    /// cut line is dd that copies. Both need Full Access: hidden, and doing nothing, without.
    func testCopyAndCutLineNeedFullAccess() throws {
        let (kb, bar, doc) = rig("one\ntw", after: "o\nthree", keys: Shortcuts.hostOnly)
        doc.window = 2
        try edit("copyLine", kb, bar, doc)
        try edit("cutLine", kb, bar, doc)
        XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "one\ntw|o\nthree", "nothing without Full Access")

        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        bar.suggestions.pasteboard = { pb }
        let toolbar = try XCTUnwrap(bar.toolbar)
        toolbar.reload()
        XCTAssertEqual(Self.caps(toolbar).suffix(2).compactMap(\.accessibilityLabel), ["copy line", "cut line"])
        try edit("copyLine", kb, bar, doc)
        XCTAssertEqual(pb.string, "two")
        XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "one\ntw|o\nthree", "the caret back")
        try edit("cutLine", kb, bar, doc)
        XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "one\n|three")
        try edit("copyLine", kb, bar, doc)
        XCTAssertEqual(pb.string, "three")
        try edit("delLine", kb, bar, doc)
        XCTAssertEqual(pb.string, "three", "dd copies nothing")
        XCTAssertEqual(Self.at(doc), "|one", "the last line's dd: the line above's start")
        doc.text = "one\n"; doc.after = "\ntwo"
        try edit("copyLine", kb, bar, doc)
        XCTAssertEqual(pb.string, "three", "an empty line leaves the clip be")
    }

    /// A host that never shows the deletes: the batch waits 0.3 s for it and stops, rather
    /// than deleting again from a context that still shows what went. Moves that lag are
    /// waited for, so the deletes after them start in the right place.
    func testEditsStopWhenTheContextLags() throws {
        let (kb, bar, doc) = rig("abc\ndef", after: "")
        doc.lineBefore = true
        doc.lagsEdits = true
        bar.press(try XCTUnwrap(Shortcuts.Bar.toolbar.catalog.first { $0.id == "delAll" }))
        for _ in 0..<100 { kb.pollCaret() }   // the host never answers the deletes
        XCTAssertEqual(doc.text, "abc\nd", "one batch, its anchor kept")
        doc.catchUp()
        try edit("delAll", kb, bar, doc)   // the host answering, a second press goes on
        XCTAssertEqual(doc.text, "")

        let (lkb, lbar, late) = rig("x the qu", after: "ick fox\nnext")
        late.lags = true
        late.window = 3
        try edit("delEnd", lkb, lbar, late)
        XCTAssertEqual(late.text + "|" + (late.after ?? ""), "x the qu|\nnext")
        try edit("delLine", lkb, lbar, late)
        XCTAssertEqual(late.text + "|" + (late.after ?? ""), "|next")
    }

    /// Delete all in a long text on hosts that show each batch only a turn later, as a
    /// UITextView and Safari do: every batch waits for it, so all of it goes (#553 QA: about
    /// two lines a press).
    func testDeleteAllEmptiesALongTextOnARealHost() throws {
        let all = (1...40).map { "line \($0) of the text" }.joined(separator: "\n")
        let cut = try XCTUnwrap(all.range(of: "line 20 of")).upperBound
        let hosts: [(String, (Proxy) -> Void)] = [("text view", Self.textView),
                                                  ("sentences", { Self.textView($0); $0.lineBefore = false; $0.sentenceBefore = true }),
                                                  ("safari", Self.safari)]
        for (name, host) in hosts {
            let text = name == "sentences" ? all.replacingOccurrences(of: " of", with: ". Of") : all
            let (kb, bar, doc) = rig(String(text[..<cut]), after: String(text[cut...]))
            host(doc)
            bar.press(try key(Shortcuts.hostOnly, "delAll"))
            XCTAssertTrue(doc.calls.contains("⌫"), "what the context shows goes at the press: \(name) (#553 QA: 2 s)")
            for _ in 1...3_000 { doc.catchUp(); kb.pollCaret() }
            XCTAssertEqual(Self.at(doc), "|", name)
        }
        // An empty line's break reads the same once one went, as in a UITextView: no anchor
        // tells that answer apart, so the deletes go on from a fresh context.
        let (kb, bar, doc) = rig("one\n\n\ntwo")
        doc.lineBefore = true; doc.lagsEdits = true
        try edit("delAll", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "|", "empty lines")
    }

    /// ctrl-u, ctrl-k and dd on a line longer than any one context, cut at its sentences (a
    /// UITextView) or in windows (Safari): the whole extent goes, and no more (#553 QA).
    func testLineDeletesCrossACutLongLine() throws {
        let line = "First one is here. Second two is here. Third three is here. Fourth four is here."
        let hosts: [(String, (Proxy) -> Void)] = [("text view", { Self.textView($0); $0.sentenceBefore = true }),
                                                  ("safari", Self.safari)]
        for (name, host) in hosts {
            let (kb, bar, doc) = rig("top\n" + line, after: "\nbottom")
            host(doc)
            try edit("delHome", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "top\n|\nbottom", "ctrl-u: \(name)")
            doc.text = "top\nFirst"; doc.after = String(line.dropFirst(5)) + "\nbottom"
            try edit("delEnd", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "top\nFirst|\nbottom", "ctrl-k: \(name)")
            doc.text = "top\nFirst one is here. Second two is here. Third "
            doc.after = "three is here. Fourth four is here.\nbottom"
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "top\n|bottom", "dd: \(name)")
        }
    }

    /// dd takes the line and a break, as nvim's: the one after it, the caret then on the next
    /// line's start, or on the last line the one before it, the caret on the line above's
    /// start. Where the after-context stops at the line's end it steps over the break blind.
    /// Empty lines go too, the first and the last (#553 QA).
    func testDeleteLineTakesTheLineAndABreak() throws {
        for (name, host) in [("text view", Self.textView), ("safari", Self.safari)] {
            let (kb, bar, doc) = rig("one two\nthr", after: "ee four\nfive six")
            host(doc)
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "one two\n|five six", name)
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "|one two", "the last line: \(name)")
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "|", "the only line: \(name)")
            doc.text = "one\n"; doc.after = "\ntwo"
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "one\n|two", "an empty line: \(name)")
            doc.text = ""; doc.after = "\nsecond"
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "|second", "an empty first line: \(name)")
            doc.text = "one\n"; doc.after = ""
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "|one", "an empty last line: \(name)")
            doc.text = "one two\nthree four\nfi"; doc.after = "ve six"
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "one two\n|three four", "the last line, its window without the break: \(name)")
            // The context an edit left, "" at its window's start, never moved since (#553 QA:
            // the line above went).
            doc.text = "one two\nthree four\nx"; doc.after = ""
            doc.deleteBackward(); doc.catchUp()
            XCTAssertEqual(doc.documentContextBeforeInput, name == "safari" ? "\n " : "", name)
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "one two\n|three four", "a stale empty last line: \(name)")
            doc.text = "first line, long enough to wrap around in the field: a b c d e f g h"; doc.after = "\nsecond"
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "|second", "a long first line: \(name)")
        }
    }

    /// Hosts whose context is stale when an edit reads it: one still showing the last Character
    /// deleted at the text's start, on its own (a UITextView's) or answering 0.3 s late (a
    /// stalling host's), and one answering each move late, without the deletes sent since (a
    /// blocking host's). The steps that look for a fresh context net nothing at the text's
    /// start and wait for the host's answer, so nothing past the extent goes (#553 QA).
    func testEditsNeverActOnAStaleContext() throws {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        let first = "first line, long enough to wrap around in the field: a b c d e f g h"
        let hosts: [(String, Int, (Proxy) -> Void)] = [
            ("text view", 1, { $0.stopsAtLineEnd = true; $0.lagsEdits = true; $0.staleAtStart = true }),
            ("stalling", 15, { $0.stopsAtLineEnd = true; $0.lagsEdits = true; $0.lags = true; $0.staleAtStart = true }),
        ]
        for (name, every, host) in hosts {
            let (kb, bar, doc) = rig("first line", after: String(first.dropFirst(10)) + "\nsecond\nthird line")
            host(doc)
            bar.suggestions.pasteboard = { pb }
            try edit("delLine", kb, bar, doc, every: every)
            XCTAssertEqual(Self.at(doc), "|second\nthird line", "dd: \(name)")
            doc.text = "first line"; doc.after = String(first.dropFirst(10)) + "\nsecond\nthird line"; doc.catchUp()
            try edit("cutLine", kb, bar, doc, every: every)
            XCTAssertEqual(Self.at(doc), "|second\nthird line", "cut line: \(name)")
            XCTAssertEqual(pb.string, first, "cut line's clip: \(name)")
            doc.text = "alpha beta mu"; doc.after = "short"; doc.catchUp()
            try edit("delHome", kb, bar, doc, every: every)
            XCTAssertEqual(Self.at(doc), "|short", "ctrl-u: \(name)")
        }
        let (kb, bar, doc) = rig("alpha beta mu\nfoo", after: "_bar1.baz qux\nshort")
        doc.stopsAtLineEnd = true; doc.answersLate = true
        try edit("delEnd", kb, bar, doc, every: 8)
        XCTAssertEqual(Self.at(doc), "alpha beta mu\nfoo|\nshort", "ctrl-k: blocking")
        XCTAssertEqual(doc.documentContextBeforeInput, "alpha beta mu\nfoo_bar1.baz qux", "the move's answer, the deletes not in it")
        try edit("delLine", kb, bar, doc, every: 8)
        XCTAssertEqual(Self.at(doc), "alpha beta mu\n|short", "dd after ctrl-k: blocking")
    }

    /// A field that shows no context reads as empty: an edit there never steps back to look
    /// for a fresh one, so the caret isn't left a Character back.
    func testEditsTakeNoStepBackInAFieldWithoutContext() throws {
        let (kb, bar, doc) = rig("ab", after: "cd")
        doc.hidesContext = true
        try edit("delAll", kb, bar, doc)
        XCTAssertFalse(doc.moves.contains { $0 < 0 }, "\(doc.moves)")
        XCTAssertEqual(doc.calls, [], "no deletes")
    }

    /// dd whose walk to the line's end stopped short (a run of one Character in Safari's
    /// windows reads the same after a leg) deletes nothing: from there it would take part of
    /// the line and join the rest on.
    func testDeleteLineDoesNothingWhereTheWalkStopsShort() throws {
        let (kb, bar, doc) = rig("top\n", after: String(repeating: "a", count: 12) + "\nnext")
        doc.window = 2
        try edit("delLine", kb, bar, doc)
        XCTAssertEqual(doc.text + (doc.after ?? ""), "top\n" + String(repeating: "a", count: 12) + "\nnext")
        XCTAssertEqual(doc.calls, [], "no deletes")
    }

    /// A host one edit behind: after a batch its context changes but still shows the last
    /// Character deleted, catching up a few polls on. No batch is sized from that, so nothing
    /// past the extent goes (#553 QA: dd took Characters of the line above).
    func testAHostOneEditBehindNeverOverDeletes() throws {
        let (kb, bar, doc) = rig("seven eight nine\nfoo", after: "\nshort")
        doc.lineBefore = true; doc.stopsAtLineEnd = true; doc.behind = true
        try edit("delLine", kb, bar, doc, every: 3)
        XCTAssertEqual(Self.at(doc), "seven eight nine\n|short")
        doc.text = "seven eight nine\nfoo bar"; doc.after = ""
        try edit("delHome", kb, bar, doc, every: 3)
        XCTAssertEqual(Self.at(doc), "seven eight nine\n|")
        doc.text = "top\naardvark"
        try edit("delHome", kb, bar, doc, every: 3)
        XCTAssertEqual(Self.at(doc), "top\n|", "a doubled letter")
        doc.text = "one\ntwo three"; doc.after = " four\nfive"
        try edit("delAll", kb, bar, doc, every: 3)
        XCTAssertEqual(Self.at(doc), "|")
    }

    /// The keyboard's own copies are retired at once, and while the toolbar shows, a fresh
    /// clip never takes its place: ctrl-w, ctrl-u and dd land on word starts (#553 QA).
    func testAFreshClipNeverHidesTheToolbar() throws {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        let (kb, bar, doc) = rig("one two\nthree fo", after: "ur", keys: Shortcuts.hostOnly)
        bar.suggestions.pasteboard = { pb }
        bar.showsToolbar = true
        let toolbar = try XCTUnwrap(bar.toolbar)
        try edit("copyLine", kb, bar, doc)
        XCTAssertEqual(pb.string, "three four")
        XCTAssertEqual(bar.suggestions.memory.retiredClip, pb.changeCount, "yy's clip is its own")
        try edit("cutLine", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "|one two")
        XCTAssertEqual(bar.suggestions.memory.retiredClip, pb.changeCount, "and cut line's")
        pb.string = "elsewhere"
        doc.text = "one two"; doc.after = ""
        try edit("delWord", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "one |")
        XCTAssertNotEqual(bar.state, .paste)
        XCTAssertFalse(toolbar.isHidden, "the toolbar stays, its own Paste in it")
        bar.showsToolbar = false
        XCTAssertEqual(bar.state, .paste, "the suggestions still offer it")
    }

    /// yy walks to the line's start and back, the rest waiting on each landing, and delete
    /// all's batches wait on the host the same way: a key, a touch and the poll limit each
    /// drop what waits, so a late landing moves, copies and deletes nothing more.
    func testAKeyATouchOrThePollLimitDropsAPendingEdit() throws {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        for interrupt in ["key", "touch", "poll limit"] {
            let (kb, bar, doc) = rig("one\ntwo thr", after: "ee\nfour", keys: Shortcuts.hostOnly)
            bar.suggestions.pasteboard = { pb }
            doc.lags = true
            let clip = pb.changeCount
            bar.press(try key(Shortcuts.hostOnly, "copyLine"))
            kb.pollCaret()   // the host hasn't shown the move
            let cap = try XCTUnwrap(laidOut(kb)["z"]).frame, p = CGPoint(x: cap.midX, y: cap.midY)
            switch interrupt {
            case "key": kb.press(.char("x"))
            case "touch": kb.track(.began, id: 1, at: p)
            default: for _ in 0..<100 { kb.pollCaret() }
            }
            for _ in 0..<200 { doc.catchUp(); kb.pollCaret() }
            XCTAssertEqual(pb.changeCount, clip, interrupt)
            if interrupt == "touch" { kb.track(.ended, id: 1, at: p) }
        }

        let (kb, bar, doc) = rig("abc\ndef", after: "")
        Self.textView(doc)
        bar.press(try key(Shortcuts.hostOnly, "delAll"))
        for _ in 0..<100 where doc.calls.isEmpty { kb.pollCaret() }
        kb.press(.char("x"))
        for _ in 0..<200 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(doc.text, "abc\ndx", "a key ends delete all's batches")
    }

    /// ctrl-w ends as every edit does (`edited`): shift on at a sentence's start, and the bar
    /// recomputed from the text now, here Paste at a word start.
    func testDeleteWordUpdatesShiftAndTheBar() throws {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        pb.string = "clip"
        let (kb, bar, doc) = rig("One. Two", keys: Shortcuts.hostOnly)
        doc.autocapitalizationType = .sentences
        kb.settings.autoCapitalization = true
        bar.suggestions.pasteboard = { pb }
        bar.refresh()
        XCTAssertNotEqual(bar.state, .paste, "mid-word")
        XCTAssertEqual(kb.shift.mode, .off)
        try edit("delWord", kb, bar, doc)
        XCTAssertEqual(doc.text, "One. ")
        XCTAssertEqual(kb.shift.mode, .once)
        XCTAssertEqual(bar.state, .paste)
    }

    private func key(_ keys: [ShortcutKey], _ id: String) throws -> ShortcutKey {
        try XCTUnwrap(keys.first { $0.id == id }, id)
    }

    private func laidOut(_ kb: TerminalKeyboard) -> [String: UIButton] {
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews { caps[b.accessibilityLabel ?? ""] = b }
        return caps
    }
}
