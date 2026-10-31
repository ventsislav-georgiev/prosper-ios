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

    /// A login field shows AutoFill over the toolbar, the toggle beside it (#623); away from it
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
        XCTAssertFalse(toggle.isHidden, "the way to the toolbar (#623)")
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
        XCTAssertFalse(toggle.isHidden, "the way back to the toolbar (#622)")
        bar.suggestions.pasteboard = { nil }
        bar.refresh()
        bar.showsToolbar = true
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertTrue(bar.showsToolbar, "the pick stays the user's")
    }

    /// #622: the paste offer keeps the toggle, laid out beside it, and the toggle goes from
    /// the offer to the toolbar and back; a fresh clip at a word start with the toolbar
    /// chosen keeps the toolbar. AutoFill hides the toolbar and Paste, not the toggle (#623).
    func testThePasteOfferKeepsTheToggle() throws {
        let (_, bar, doc) = rig()
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        pb.string = "clip"
        bar.suggestions.pasteboard = { pb }
        bar.refresh()
        let toolbar = try XCTUnwrap(bar.toolbar), toggle = try XCTUnwrap(bar.toggle)
        XCTAssertEqual(bar.state, .paste)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertTrue(toggle.isEnabled)
        bar.layoutIfNeeded()
        XCTAssertFalse(toggle.frame.intersects(bar.pasteControl.frame), "Paste takes the rest")

        toggle.sendActions(for: .touchUpInside)
        XCTAssertTrue(bar.showsToolbar)
        XCTAssertFalse(toolbar.isHidden, "the toolbar over the paste offer")
        XCTAssertTrue(bar.pasteControl.isHidden)
        XCTAssertFalse(toggle.isHidden)
        doc.text = "word "
        bar.refresh()
        XCTAssertFalse(toolbar.isHidden, "a word start, the clip still fresh")

        toggle.sendActions(for: .touchUpInside)
        XCTAssertEqual(bar.state, .paste, "back to the paste offer")
        XCTAssertTrue(toolbar.isHidden)
        XCTAssertFalse(bar.pasteControl.isHidden)
        XCTAssertFalse(toggle.isHidden)

        doc.isSecureTextEntry = true
        bar.refresh()
        XCTAssertEqual(bar.state, .autofill)
        XCTAssertFalse(toggle.isHidden)
        XCTAssertTrue(toolbar.isHidden)
        XCTAssertTrue(bar.pasteControl.isHidden)
    }

    // MARK: - The toggle's hold menu (#623)

    /// `rig`, the bar hosted in a view so a panel can cover the keys, with Full Access on a
    /// named pasteboard and all four stores, or none of them.
    private func hostedRig(fullAccess: Bool = true, stores: Bool = true)
        throws -> (TerminalKeyboard, SuggestionBar, Proxy, UIView, DictationClient) {
        let (kb, bar, doc) = rig()
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        bar.host(kb, in: view)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ToggleMenu-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let dictation = DictationClient(store: Dictation.Store(dir: dir.appendingPathComponent("Dictation")))
        dictation.polls = false
        dictation.ping = { _ in }
        dictation.open = { _, done in done(false) }
        if stores {
            bar.history = ClipboardHistory(dir: dir.appendingPathComponent("Clips"))
            bar.snippets = SnippetStore(url: dir.appendingPathComponent("Snippets/snippets.json"))
            bar.quicklinks = QuicklinkStore(url: dir.appendingPathComponent("Quicklinks/quicklinks.json"))
            bar.dictation = dictation
        }
        if fullAccess {
            let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
            addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
            bar.suggestions.pasteboard = { pb }
        }
        return (kb, bar, doc, view, dictation)
    }

    /// A hold (0.4 s) on the toggle opens the menu over the keys: each panel and the mic with
    /// Full Access and its store, as their toolbar keys, whether on the toolbar or not; Next
    /// Keyboard always. VoiceOver's "More" opens the same.
    func testAHoldOnTheToggleOpensTheMenuOfWhatWorksHere() throws {
        let (kb, bar, _, view, _) = try hostedRig()
        let toggle = try XCTUnwrap(bar.toggle)
        let hold = try XCTUnwrap(toggle.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }.first)
        XCTAssertEqual(hold.minimumPressDuration, 0.4, accuracy: 0.01)
        XCTAssertNil(bar.menuPanel)
        bar.showMenu(true)
        let menu = try XCTUnwrap(bar.menuPanel)
        XCTAssertTrue(menu.superview === view, "over the keys")
        XCTAssertEqual(menu.items.map(\.title), ["Clipboard", "Snippets", "Quicklinks", "Dictate", "Next Keyboard"])
        XCTAssertEqual(menu.tiles.map(\.accessibilityLabel), menu.items.map(\.title))
        for item in menu.items { XCTAssertNotNil(UIImage(systemName: item.symbol), item.title) }
        XCTAssertFalse(Self.caps(try XCTUnwrap(bar.toolbar)).contains { $0.accessibilityLabel == "clipboard history" },
                       "the clipboard isn't on the toolbar, and is in the menu")

        bar.showMenu(false)
        XCTAssertNil(bar.menuPanel)
        let more = try XCTUnwrap(toggle.accessibilityCustomActions?.first { $0.name == "More" })
        XCTAssertTrue(more.actionHandler?(more) == true)
        XCTAssertNotNil(bar.menuPanel, "VoiceOver's way to the hold")

        for (full, stores) in [(false, true), (true, false)] {
            let (kb2, bar2, _, _, _) = try hostedRig(fullAccess: full, stores: stores)
            XCTAssertEqual(bar2.menuItems.map(\.title), ["Next Keyboard"], "full \(full) stores \(stores)")
            withExtendedLifetime(kb2) {}
        }
        withExtendedLifetime((kb, view)) {}
    }

    /// Each pick does its thing and closes the menu: the clipboard, snippets and quicklinks
    /// panels in its place, the mic starts, Next Keyboard is the controller's advance.
    func testEachMenuPickDoesItsThingAndClosesTheMenu() throws {
        let (kb, bar, _, view, dictation) = try hostedRig()
        var advanced = 0
        bar.nextKeyboard = { advanced += 1 }
        func pick(_ title: String) throws {
            bar.showMenu(true)
            let menu = try XCTUnwrap(bar.menuPanel)
            try XCTUnwrap(menu.tiles.first { $0.accessibilityLabel == title }).sendActions(for: .touchUpInside)
            XCTAssertNil(bar.menuPanel, "\(title) closes the menu")
        }
        try pick("Clipboard")
        XCTAssertNotNil(bar.clipsPanel)
        try pick("Snippets")
        XCTAssertNotNil(bar.snippetsPanel)
        try pick("Quicklinks")
        XCTAssertNotNil(bar.quicklinksPanel)
        try pick("Dictate")
        XCTAssertNil(bar.panel, "the keys back")
        XCTAssertNotNil(dictation.store.request, "the mic started")
        XCTAssertEqual(advanced, 0)
        try pick("Next Keyboard")
        XCTAssertEqual(advanced, 1)
        XCTAssertNil(bar.panel)
        withExtendedLifetime((kb, view)) {}
    }

    /// A tap still switches the toolbar and the suggestions, and opens no menu; with the menu
    /// open it only closes it, as the keyboard button and a tap off the tiles do.
    func testATapOnTheToggleSwitchesOrClosesTheMenu() throws {
        let (kb, bar, _, view, _) = try hostedRig()
        let toggle = try XCTUnwrap(bar.toggle)
        toggle.sendActions(for: .touchUpInside)
        XCTAssertTrue(bar.showsToolbar)
        XCTAssertNil(bar.menuPanel)
        bar.showMenu(true)
        toggle.sendActions(for: .touchUpInside)
        XCTAssertNil(bar.menuPanel)
        XCTAssertTrue(bar.showsToolbar, "the tap closed the menu, no switch")
        bar.showMenu(true)
        try XCTUnwrap(bar.menuPanel).backButton.sendActions(for: .touchUpInside)
        XCTAssertNil(bar.menuPanel, "the keyboard button")
        withExtendedLifetime((kb, view)) {}
    }

    /// From a stale AutoFill bar there's a way to the toolbar (#599 QA): the toggle beside the
    /// AutoFill button, a tap shows the toolbar over it and a second tap AutoFill again; a
    /// refresh keeps what the tap chose, and AutoFill never shows the toolbar by itself, even
    /// with it picked elsewhere. The hold menu opens there too.
    func testTheToggleShowsTheToolbarOverAutoFillOnlyAtItsTap() throws {
        let (kb, bar, doc, view, _) = try hostedRig()
        let toolbar = try XCTUnwrap(bar.toolbar), toggle = try XCTUnwrap(bar.toggle)
        doc.textContentType = .username
        bar.refresh()
        XCTAssertEqual(bar.state, .autofill)
        bar.layoutIfNeeded()
        XCTAssertFalse(toggle.isHidden)
        XCTAssertFalse(bar.autofillButton.isHidden)
        XCTAssertTrue(toolbar.isHidden)
        XCTAssertFalse(toggle.frame.intersects(bar.autofillButton.frame), "beside AutoFill")

        toggle.sendActions(for: .touchUpInside)
        XCTAssertFalse(toolbar.isHidden, "the toolbar over AutoFill")
        XCTAssertTrue(bar.autofillButton.isHidden)
        XCTAssertEqual(toggle.accessibilityLabel, "Show AutoFill")
        XCTAssertFalse(bar.showsToolbar, "the pick elsewhere unchanged")
        bar.refresh()
        XCTAssertFalse(toolbar.isHidden, "the user chose it")
        toggle.sendActions(for: .touchUpInside)
        XCTAssertTrue(toolbar.isHidden, "AutoFill back")
        XCTAssertFalse(bar.autofillButton.isHidden)
        XCTAssertEqual(toggle.accessibilityLabel, "Show toolbar")

        bar.showsToolbar = true
        XCTAssertTrue(toolbar.isHidden, "never by itself (#599)")
        toggle.sendActions(for: .touchUpInside)
        XCTAssertFalse(toolbar.isHidden)
        doc.textContentType = nil
        bar.refresh()
        XCTAssertFalse(toolbar.isHidden, "a plain field: the pick")
        doc.textContentType = .username
        bar.refresh()
        XCTAssertTrue(toolbar.isHidden, "a login field again: AutoFill, the tap was for that one")
        XCTAssertTrue(bar.showsToolbar)

        bar.showMenu(true)
        XCTAssertEqual(try XCTUnwrap(bar.menuPanel).items.last?.title, "Next Keyboard")
        withExtendedLifetime((kb, view)) {}
    }

    /// #622: the keyboard's toolbar sits on the keyboard's backdrop, no blur band; the
    /// terminal's bar over Apple's keyboard keeps its blur.
    func testOnlyTheTerminalBarBlurs() throws {
        func effect(_ bar: ShortcutBar) throws -> UIVisualEffect? {
            try XCTUnwrap(bar.subviews.compactMap { $0 as? UIVisualEffectView }.first).effect
        }
        let (_, bar, _) = rig()
        XCTAssertNil(try effect(try XCTUnwrap(bar.toolbar)))
        XCTAssertNotNil(try effect(ShortcutBar()))
    }

    /// #599: from a textarea to a login field whose traits catch up after `textDidChange`, as
    /// Safari's do, AutoFill shows once they have, with no further host call, whatever the
    /// toolbar's keys: Paste alone (QA's failing config) or the arrows.
    func testALoginFieldsLateTraitsReachAutoFillOverAnyToolbar() throws {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        pb.string = "clip"
        for keys in [[try key("paste")], Shortcuts.Bar.toolbar.defaults.filter { $0.id != "paste" }] {
            let (kb, bar, doc) = rig(keys: keys)
            bar.suggestions.pasteboard = { pb }
            try XCTUnwrap(bar.toolbar).reload()
            bar.showsToolbar = true
            bar.hostChanged()   // the switch: the textarea's traits still
            XCTAssertNotEqual(bar.state, .autofill)
            doc.textContentType = .username
            let deadline = Date() + 2
            while bar.state != .autofill, Date() < deadline { RunLoop.main.run(until: Date() + 0.05) }
            XCTAssertEqual(bar.state, .autofill, "\(keys.map(\.id))")
            XCTAssertTrue(try XCTUnwrap(bar.toolbar).isHidden)
            withExtendedLifetime(kb) {}
        }
    }

    /// #599 review: a host text change in the same field, its traits unchanged, leaves a shift
    /// the user tapped right after it alone: the late re-read is for a field switch only.
    func testAShiftTappedAfterATextChangeOutlivesTheTraitReRead() {
        let (kb, bar, doc) = rig("word ")
        doc.autocapitalizationType = .sentences
        kb.settings.autoCapitalization = true
        bar.hostChanged()
        kb.press(.shift)
        XCTAssertEqual(kb.shift.mode, .once)
        RunLoop.main.run(until: Date() + SuggestionBar.traitLag + 0.3)
        XCTAssertEqual(kb.shift.mode, .once, "the user's shift stays")
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
        XCTAssertEqual(Shortcuts.Bar.terminal.catalog.map(\.id), Shortcuts.catalog.map(\.id)
                       + Shortcuts.hostOnly.map(\.id) + ["clips", "snips", "qlinks", "mic"])
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
        bar.press(try XCTUnwrap(Shortcuts.hostOnly.first { $0.id == id }, id))
        for i in 1...3_000 {
            if i % every == 0 { doc.catchUp() }
            kb.pollCaret()
        }
    }

    /// The text, "|" at the caret.
    private static func at(_ doc: Proxy) -> String { doc.text + "|" + (doc.after ?? "") }

    /// A plain UITextView's proxy: the before-context the caret's line (its LF alone at a
    /// line's start), the after-context stopping at the line's end, edits shown only on a
    /// later poll, and after them only what's left of the window they were cut from, both
    /// contexts nil where that leaves none either side, and at an empty first line's start.
    private static func textView(_ d: Proxy) {
        d.lineBefore = true; d.stopsAtLineEnd = true; d.lagsEdits = true; d.cutsEdits = true; d.nilsAtEnd = true
        d.nilsAtStart = true
    }
    /// Safari's: windows either side, a space after a break that isn't in the text, edits
    /// shown only on a later poll, and after them only what's left of the window, both
    /// contexts nil at the text's end where that leaves none (#553 QA: `b="" a=nil` there),
    /// and at an empty first line's start.
    private static func safari(_ d: Proxy) {
        d.window = 6; d.breakSpace = true; d.lagsEdits = true; d.cutsEdits = true; d.nilsAtEnd = true
        d.nilsAtStart = true
    }

    /// The edits, each an icon with a spoken label: the toolbar's keep them, and the
    /// terminal's catalog has them all (`testTerminalOffersReadlineEdits`).
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

    /// The terminal's catalog offers the edits as readline keystrokes (#603: word end as next
    /// word's M-f, delete all and cut line as delete line's ^E ^U), copy line with none (the
    /// terminal reads the screen). The toolbar's catalog has them all, and a terminal bar
    /// holding a delete seeds it with that one.
    func testTerminalOffersReadlineEdits() throws {
        let want: [(String, [UInt8])] = [("wordNext", [0x1b, 0x66]), ("wordEnd", [0x1b, 0x66]), ("wordBack", [0x1b, 0x62]),
                                         ("delWord", [0x17]), ("delHome", [0x15]), ("delEnd", [0x0b]),
                                         ("delLine", [0x05, 0x15]), ("delAll", [0x05, 0x15]), ("copyLine", []),
                                         ("cutLine", [0x05, 0x15])]
        let terminal = Shortcuts.Bar.terminal.catalog
        for (id, bytes) in want {
            let k = try XCTUnwrap(terminal.first { $0.id == id }, id)
            XCTAssertEqual(k.kind, .bytes, id)
            XCTAssertEqual(k.bytes, bytes, id)
            XCTAssertEqual(k, try XCTUnwrap(Shortcuts.hostOnly.first { $0.id == id }), "same label and icon: \(id)")
        }
        XCTAssertEqual(Set(terminal.map(\.id)).count, terminal.count, "no duplicate ids")
        XCTAssertEqual(Shortcuts.Bar.terminal.defaults.map(\.id), Shortcuts.defaults.map(\.id), "not in the defaults")

        let toolbar = Shortcuts.Bar.toolbar.catalog.map(\.id)
        XCTAssertEqual(toolbar, ["tab", "up", "down", "left", "right", "home", "end", "slash", "pipe", "paste", "snl",
                                 "enter", "wordNext", "wordEnd", "wordBack", "delWord", "delHome", "delEnd", "delLine",
                                 "delAll", "copyLine", "cutLine", "clips", "snips", "qlinks", "mic"])
        XCTAssertEqual(Set(toolbar).count, toolbar.count, "no duplicate ids")

        let store = try suiteStore(".terminalEdits")
        let delLine = try XCTUnwrap(terminal.first { $0.id == "delLine" })
        let stale = ShortcutKey(id: "delWord", label: "old", kind: .bytes)
        Shortcuts.save([try key("left"), delLine, stale], to: store)
        let loaded = Shortcuts.Bar.terminal.load(store)
        XCTAssertEqual(loaded.map(\.id), ["left", "delLine", "delWord", "enter"])
        XCTAssertEqual(loaded[2].bytes, [0x17], "a saved key takes the catalog's definition")
        XCTAssertEqual(Shortcuts.Bar.toolbar.load(store).map(\.id), ["paste", "left", "delLine", "delWord", "enter"])
    }

    /// Parity (#603, #604): every key the toolbar offers, the terminal's bar offers too, but
    /// those named here. A new toolbar key fails this until the terminal offers it or it's listed.
    func testTerminalOffersEveryToolbarKey() {
        var notOnTerminal: Set<String> = []
        #if targetEnvironment(macCatalyst)
        // No Prosper keyboard on the Mac; dictation off there; the Mac's Prosper expands snippets
        // and opens quicklinks.
        notOnTerminal = [Shortcuts.clipboard.id, Shortcuts.dictate.id, Shortcuts.snippets.id, Shortcuts.quicklinks.id]
        #endif
        if #unavailable(iOS 26) { notOnTerminal.insert(Shortcuts.dictate.id) }   // no SpeechAnalyzer
        let terminal = Set(Shortcuts.Bar.terminal.catalog.map(\.id))
        XCTAssertEqual(Set(Shortcuts.Bar.toolbar.catalog.map(\.id)).subtracting(terminal), notOnTerminal)
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
        // A window of one, used up with a Character left: the step for a fresh context lands
        // at the text's start, the Character after the caret, so the caret comes back for it.
        let (okb, obar, one) = rig("ab", after: "")
        one.window = 1; one.cutsEdits = true
        try edit("delHome", okb, obar, one)
        XCTAssertEqual(Self.at(one), "|", "a window of one: \(one.moves)")

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

    /// A host that never shows the deletes: the batch waits 0.3 s for it, then steps for a
    /// fresh context, and stops when that doesn't show it either, rather than deleting again
    /// from a context that still shows what went. Moves that lag are waited for, so the
    /// deletes after them start in the right place.
    func testEditsStopWhenTheContextLags() throws {
        let (kb, bar, doc) = rig("abc\ndef", after: "")
        doc.lineBefore = true
        doc.lagsEdits = true
        bar.press(try XCTUnwrap(Shortcuts.hostOnly.first { $0.id == "delAll" }))
        for _ in 0..<100 { kb.pollCaret() }   // the host never answers the deletes
        XCTAssertEqual(doc.text + (doc.after ?? ""), "abc\nd", "one batch, its anchor kept")
        doc.catchUp()
        try edit("delAll", kb, bar, doc)   // the host answering, a second press goes on
        XCTAssertEqual(doc.text, "")

        // A host answering from its copy of the text before the batch, moves and all, for
        // 0.8 s: the batch waits for it through fresh contexts, so nothing past the extent
        // goes, and the rest goes after it (#553 QA: a stalling host's delete all stopped).
        let (okb, obar, old) = rig("top\nabcdefgh")
        old.window = 6; old.showsOld = true
        try edit("delHome", okb, obar, old, every: 40)
        XCTAssertEqual(Self.at(old), "top\n|", "answered from the text before the batch")

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
    /// From mid-text and from the end, also on a UITextView answering 0.3 s late, Safari
    /// keeping its old window at times, a host showing edits later than 0.3 s, and one
    /// answering each move late (#553 QA: the text after the caret lost a window and stopped;
    /// Safari stopped after 2-3 windows; a stalling host's stopped at 869 of 1009). Nothing
    /// after the caret goes before all before it has (#553 QA: a blocking host's took
    /// `15 of th` there).
    func testDeleteAllEmptiesALongTextOnARealHost() throws {
        let all = (1...40).map { "line \($0) of the text" }.joined(separator: "\n")
        let mid = try XCTUnwrap(all.range(of: "line 20 of")).upperBound
        let hosts: [(String, Int, (Proxy) -> Void)] = [
            ("text view", 1, Self.textView),
            ("sentences", 1, { Self.textView($0); $0.lineBefore = false; $0.sentenceBefore = true }),
            ("safari", 1, Self.safari),
            ("safari keeping its window", 1, { Self.safari($0); $0.stallsEdits = 40 }),
            ("stalling", 15, { Self.textView($0); $0.lags = true }),
            ("late", 20, { $0.stopsAtLineEnd = true; $0.lagsEdits = true }),
            ("blocking", 8, { $0.stopsAtLineEnd = true; $0.answersLate = true }),
            ("blocking, stale at the start", 8, { $0.stopsAtLineEnd = true; $0.answersLate = true; $0.staleAtStart = true }),
            ("blocking text view", 8, { Self.textView($0); $0.answersLate = true }),
            ("flipping text view", 8, { Self.textView($0); $0.flipsEdits = true }),
            ("blocking, flipping", 8, { Self.textView($0); $0.answersLate = true; $0.flipsEdits = true }),
        ]
        for (name, every, host) in hosts {
            let text = name == "sentences" ? all.replacingOccurrences(of: " of", with: ". Of") : all
            for cut in [mid, text.endIndex] {
                let from = "\(name), from \(cut == mid ? "mid-text" : "the end")"
                let (kb, bar, doc) = rig(String(text[..<cut]), after: String(text[cut...]))
                host(doc)
                bar.press(try key(Shortcuts.hostOnly, "delAll"))
                XCTAssertTrue(doc.calls.contains("⌫"), "what the context shows goes at the press: \(from) (#553 QA: 2 s)")
                let after = String(text[cut...])
                var before = true, gone = 0
                for i in 1...12_000 {
                    if i % every == 0 { doc.catchUp() }
                    kb.pollCaret()
                    if gone == 0, Self.at(doc) == "|" { gone = i }
                    guard before else { continue }
                    let rest = doc.text + (doc.after ?? "")
                    XCTAssertTrue(rest.hasSuffix(after), "the text after the caret kept: \(from), at \(i)")
                    before = rest != after
                    if !rest.hasSuffix(after) { break }
                }
                XCTAssertEqual(Self.at(doc), "|", from)
                // A host turning between two contexts goes quiet in 0.3 s a batch (#553 QA: a
                // blocking host's never did, and the 2 s limit dropped delete all).
                if name == "flipping text view" { XCTAssertLessThanOrEqual(gone, 2_000, "polls: \(from)") }
                // A step pair a line, for the line's window: none for its break's (#553 QA: 10 s),
                // and one at the text's start, which shows none once the text is gone.
                if name == "text view", cut != mid { XCTAssertLessThanOrEqual(doc.moves.count, 82, from) }
            }
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
            // Both contexts nil there: the step for a fresh one stops at the text's start and
            // isn't taken back (#553 QA: the step back went down a line and dd deleted nothing).
            doc.text = ""; doc.after = "\none\n\ntwo\n"
            for id in ["delHome", "delWord", "delEnd"] {
                try edit(id, kb, bar, doc)
                XCTAssertEqual(Self.at(doc), "|\none\n\ntwo\n", "\(id) at an empty first line: \(name)")
            }
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "|one\n\ntwo\n", "dd at an empty first line: \(name)")
            doc.text = ""; doc.after = "\none\n\ntwo\n"
            try edit("delLine", kb, bar, doc)
            try edit("delLine", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "|\ntwo\n", "dd twice at an empty first line: \(name)")
            // A press while dd's step pair there takes no step back goes after dd, not in its place.
            for (id, want) in [("delLine", "|\ntwo\n"), ("delHome", "|one\n\ntwo\n"), ("delEnd", "|\n\ntwo\n")] {
                doc.text = ""; doc.after = "\none\n\ntwo\n"
                bar.press(try key(Shortcuts.hostOnly, "delLine"))
                try edit(id, kb, bar, doc)
                XCTAssertEqual(Self.at(doc), want, "dd, then \(id) at once, at an empty first line: \(name)")
            }
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
            XCTAssertEqual(doc.documentContextBeforeInput, name == "safari" ? "\n " : nil, name)
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

    /// ctrl-u on a busy UITextView, its answers to moves late and its context cut at a line
    /// or a sentence: no delete back takes text after the caret (#553 QA: a blocking host's
    /// delete all took `15 of th` after it, each step pair's step on landing and its step back
    /// ignored at a start a stale context hid).
    func testABackwardDeleteNeverTakesTextAfterTheCaret() throws {
        let line = "First one is here. Second two is here. Third three is here. Fourth four is here."
        let hosts: [(String, Int, (Proxy) -> Void)] = [
            ("text view", 3, { Self.textView($0); $0.answersLate = true }),
            ("sentences", 8, { Self.textView($0); $0.lineBefore = false; $0.sentenceBefore = true; $0.answersLate = true }),
        ]
        for (name, every, host) in hosts {
            for (text, after) in [("row 15 of th", "e text\nrow 16"), (String(line.prefix(40)), String(line.dropFirst(40)) + "\nend")] {
                let (kb, bar, doc) = rig(text, after: after)
                host(doc)
                try edit("delHome", kb, bar, doc, every: every)
                XCTAssertEqual(Self.at(doc), "|" + after, "\(name): \(text)")
            }
        }
    }

    /// A UITextView whose context is the caret's sentence, answering late: from its copy before
    /// the last batch, moves and all (a stalling host's, 300 or 700 ms), or each move's answer
    /// later, without the deletes since (a blocking host's). ctrl-u, dd and ctrl-k take their
    /// extent and no more: no batch crosses a break it hasn't seen, none takes text after the
    /// caret (#553 QA: the answer after the line's last window was that window, and the next
    /// batch took the break and the line above).
    func testLateSentenceHostsTakeTheExtentOnly() throws {
        let line = "First one is here. Second two is here. Third three is here. Fourth four is here."
        let hosts: [(String, Int, (Proxy) -> Void)] = [
            ("stalling 300 ms", 15, { Self.textView($0); $0.sentenceBefore = true; $0.showsOld = true }),
            ("stalling 700 ms", 35, { Self.textView($0); $0.sentenceBefore = true; $0.showsOld = true }),
            ("blocking", 8, { Self.textView($0); $0.sentenceBefore = true; $0.answersLate = true }),
        ]
        let mid = String(line.prefix(45)), rest = String(line.dropFirst(45))
        let cases: [(String, String, String, String)] = [
            ("delHome", "top\n" + mid, rest + "\nend", "top\n|" + rest + "\nend"),
            ("delHome", "top\n" + line, "\nend", "top\n|\nend"),
            ("delLine", "top\n" + mid, rest + "\nend", "top\n|end"),
            ("delEnd", "top\nFirst", String(line.dropFirst(5)) + "\nend", "top\nFirst|\nend"),
        ]
        for (name, every, host) in hosts {
            for (id, text, after, want) in cases {
                let (kb, bar, doc) = rig(text, after: after)
                host(doc)
                try edit(id, kb, bar, doc, every: every)
                XCTAssertEqual(Self.at(doc), want, "\(id) from \(text.count): \(name)")
            }
        }
        // A blocking host one edit behind, a second press 0.3 s after the first: neither takes
        // the break a stale answer hides (#553 QA: ctrl-u twice took the run's break, dd twice
        // emptied the field).
        let block: (Proxy) -> Void = { Self.textView($0); $0.answersLate = true; $0.behind = true }
        let quick: [(String, String, String, String)] = [
            ("delHome", "x\n" + String(repeating: "a", count: 40), " end\ny", "x\n| end\ny"),
            ("delLine", "one", " two\nthree four\nfive six", "|five six"),
        ]
        for (id, text, after, want) in quick {
            let (kb, bar, doc) = rig(text, after: after)
            block(doc)
            bar.press(try key(Shortcuts.hostOnly, id))
            for i in 1...15 {
                if i % 8 == 0 { doc.catchUp() }
                kb.pollCaret()
            }
            try edit(id, kb, bar, doc, every: 8)
            XCTAssertEqual(Self.at(doc), want, "\(id) twice, blocking one edit behind")
        }
    }

    /// QA's test host: a UITextView windowing both contexts at the caret's sentence, slowed as
    /// QA slows it (#553 QA). It takes the calls in order; the proxy shows UIKit's guess for a
    /// move and its own copy for an edit until the host answers the move. BLOCK: each move
    /// costs its main thread 150 ms, an edit nothing. STALL: the main thread stops 300 ms of
    /// every 700 ms, here at five phases.
    private static func qaHosts() -> [(String, (Proxy) -> Void)] {
        let host = { (d: Proxy) in
            Self.textView(d); d.sentenceBefore = true; d.sentenceAfter = true; d.answersLate = true
        }
        return [("kit", { host($0); $0.moveCost = 1 }), ("BLOCK", { host($0); $0.moveCost = 8 })]
            + stride(from: 0, to: 35, by: 7).map { at in ("STALL at \(at)", { host($0); $0.moveCost = 1; $0.stalls = (35, 17, at) }) }
    }

    /// Each line edit on QA's slow hosts takes its extent and no more, the caret where nvim
    /// leaves it, alone and with a second press 0.3 s after the first (#553 QA: BLOCK ctrl-k
    /// took to the first sentence's end, dd the line's break and the line above, ctrl-u from
    /// the line's end the break before it, dd twice on the last line all of the text).
    func testQAHostsTakeTheExtentOnly() throws {
        let line = "First one is here. Second two is here. Third three is here. Fourth four is here."
        let mid = String(line.prefix(45)), rest = String(line.dropFirst(45))
        let cases: [(String, String, String, String)] = [
            ("delHome", "top\n" + mid, rest + "\nend", "top\n|" + rest + "\nend"),
            ("delHome", "top\n" + line, "\nend", "top\n|\nend"),
            ("delLine", "top\n" + mid, rest + "\nend", "top\n|end"),
            ("delEnd", "top\nFirst", String(line.dropFirst(5)) + "\nend", "top\nFirst|\nend"),
            ("delWord", "top\n" + mid, rest + "\nend", "top\nFirst one is here. Second two is here. |" + rest + "\nend"),
        ]
        let twice: [(String, String, String, String)] = [
            ("delHome", "x\n" + String(repeating: "a", count: 40), " end\ny", "x\n| end\ny"),
            ("delLine", "one", " two\nthree four\nfive six", "|five six"),
            ("delLine", "one two\nthr", "ee four\nfive six", "|one two"),
        ]
        for (name, host) in Self.qaHosts() {
            for (id, text, after, want) in cases {
                let (kb, bar, doc) = rig(text, after: after)
                host(doc)
                try edit(id, kb, bar, doc)
                XCTAssertEqual(Self.at(doc), want, "\(id) from \(text.count): \(name)")
            }
            for (id, text, after, want) in twice {
                for gap in [15, 3_000] {
                    let (kb, bar, doc) = rig(text, after: after)
                    host(doc)
                    bar.press(try key(Shortcuts.hostOnly, id))
                    for _ in 1...gap { doc.catchUp(); kb.pollCaret() }
                    try edit(id, kb, bar, doc)
                    XCTAssertEqual(Self.at(doc), want, "\(id) twice, \(gap) polls apart, from \(text.count): \(name)")
                }
            }
        }
        // At every phase of the stall, the edits stepping back from a line's start: a stall can
        // fall between the host's answers to the step away and back.
        for at in 0..<35 {
            for (id, text, after, want) in [cases[1], twice[2]] {
                let (kb, bar, doc) = rig(text, after: after)
                Self.qaHosts()[2].1(doc)
                doc.stalls = (35, 17, at)
                if id == "delLine" { try edit(id, kb, bar, doc) }
                try edit(id, kb, bar, doc)
                XCTAssertEqual(Self.at(doc), want, "\(id) from \(text.count): STALL at \(at)")
            }
        }
    }

    /// dd on a host answering a move later than the keyboard waits for one (1 s) takes the line
    /// or nothing, the caret where it was: a step after a walk that stopped at a sentence's
    /// window, landing in the line, is no text's end (#553 QA: BLOCK dd took a sentence and the
    /// line above).
    func testDeleteLineOnAHostSlowerThanItsWaitsTakesTheLineOrNothing() throws {
        let line = "First one is here. Second two is here. Third three is here."
        let (kb, bar, doc) = rig("top\nFirst one", after: String(line.dropFirst(9)) + "\nend")
        Self.qaHosts()[0].1(doc)
        doc.moveCost = 50
        try edit("delLine", kb, bar, doc)
        XCTAssertTrue(["top\nFirst one|" + line.dropFirst(9) + "\nend", "top\n|end"].contains(Self.at(doc)), Self.at(doc))
    }

    /// Line edits on hosts answering a move later than the keyboard waits for some take part of
    /// their extent at most, one run of it, and never move the caret off what's left: a context
    /// still stale after a step pair stops the edit (#553 QA: a late answer still showing
    /// Characters deleted sized the next batch past the extent).
    /// ponytail: up to 0.8 s a move, the edge's wait from the step (#553 QA r9: it was 1.1 s,
    /// and held the toolbar that long after a line edit); a host answering a step from no
    /// context later than that leaves ctrl-u's caret a Character back.
    func testLineEditsOnAHostSlowerThanTheirWaitsTakeTheirExtentOrLess() throws {
        let line = "First one is here. Second two is here. Third three is here."
        let cut = line.index(line.startIndex, offsetBy: 45)
        // The edit, the text before and after the caret, and the extent's start and end.
        let cases: [(String, String, String, Int, Int)] = [
            ("delHome", String(line[..<cut]), String(line[cut...]), 0, 45),
            ("delHome", line, "", 0, line.count),
            ("delWord", String(line[..<cut]), String(line[cut...]), 39, 45),
            ("delEnd", String(line[..<cut]), String(line[cut...]), 45, line.count),
        ]
        for cost in [30, 40] {   // 0.6 s and 0.8 s a move
            for (id, before, after, from, to) in cases {
                let (kb, bar, doc) = rig("top\n" + before, after: after + "\nend")
                Self.qaHosts()[1].1(doc)
                doc.moveCost = cost
                try edit(id, kb, bar, doc)
                let what = "\(id) from \(before.count), a move \(cost) polls: \(Self.at(doc))"
                let all = doc.text + (doc.after ?? "")
                XCTAssertTrue(all.hasPrefix("top\n" + line.prefix(from)) && all.hasSuffix(line.dropFirst(to) + "\nend"), what)
                // What's left of the extent is it less one run.
                let left = Array(all.dropFirst(4 + from).dropLast(line.count - to + 4))
                let extent = Array(line.dropFirst(from).prefix(to - from))
                let head = zip(left, extent).prefix { $0 == $1 }.count
                let tail = zip(left.reversed(), extent.reversed()).prefix { $0 == $1 }.count
                XCTAssertTrue(left.count <= extent.count && head + tail >= left.count, what)
                if id != "delEnd" { XCTAssertEqual(doc.after, after + "\nend", what) }
            }
        }
    }

    /// Delete all, cut line and dd on hosts answering a move later than the keyboard waits
    /// take one run of their extent at most, the caret where it went, and cut line's clip holds
    /// the run: stopping early there is fine, more, elsewhere or the caret off never (#553
    /// round 9: the step pair at the text's edge counts its answer's wait from the step).
    /// ponytail: cut line and dd on a line ending the text or before another aren't covered:
    /// on a host taking 0.6 s a move they take a slow answer to the step away for their step
    /// on's, and leave the caret a Character back or clip a Character the deletes left.
    func testDeleteAllCutLineAndDdOnAHostSlowerThanTheirWaitsTakeOneRunAtMost() throws {
        // The edit, the text before and after the caret, and what's outside its extent.
        let cases: [(String, String, String, String, String)] = [
            ("delAll", "one two", "", "", ""), ("delAll", "one", " two", "", ""), ("delAll", "one", "\ntwo", "", ""),
            ("delAll", "", "one\ntwo", "", ""), ("delAll", "a\nb c", "", "", ""), ("delAll", "a\nb", "\n", "", ""),
            ("cutLine", "one", " two", "", ""), ("delLine", "one", "\ntwo", "", "two"),
        ]
        for cost in [30, 50] {   // 0.6 s and 1 s a move
            for (id, text, after, keepHead, keepTail) in cases {
                let (kb, bar, doc) = rig(text, after: after, keys: Shortcuts.hostOnly)
                Self.qaHosts()[1].1(doc)
                doc.moveCost = cost
                let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
                addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
                pb.string = "old"
                bar.suggestions.pasteboard = { pb }
                bar.toolbar?.reload()
                bar.press(try key(Shortcuts.hostOnly, id))
                for _ in 1...3_000 { doc.catchUp(); kb.pollCaret() }
                let all = text + after, head = doc.text, tail = doc.after ?? ""
                let what = "\(id) on \(text)|\(after), a move \(cost) polls: \(Self.at(doc))"
                print("QA-SLOW " + what.debugDescription)
                XCTAssertTrue(all.hasPrefix(head) && all.hasSuffix(tail) && head.count + tail.count <= all.count, what)
                XCTAssertTrue(head.hasPrefix(keepHead) && tail.hasSuffix(keepTail), what)
                let run = String(all.dropFirst(head.count).dropLast(tail.count))
                // Nothing gone: the caret where it was, or at the line's end the walk went to.
                XCTAssertTrue(!run.isEmpty || head == text || tail.isEmpty || tail.first?.isNewline == true, what)
                if id == "cutLine" {
                    let line = run.trimmingCharacters(in: .newlines)
                    XCTAssertEqual(pb.string, line.isEmpty ? "old" : line, what)
                }
            }
        }
    }

    /// Each line edit from the start, the middle and the end of a 1,217-Character line takes
    /// its extent and no more, Character for Character, and cut line's clip is the line, on
    /// hosts whose window a batch takes whole and that answer the step pair for a fresh one
    /// late (#570 QA: Safari's fresh "u" and the kit's " t" went as a batch, the host's late
    /// answer still ending in it sized the next, one past its window: the clip read "laz" and
    /// "juumps", dd and ctrl-u took the break and "p"). So too where Safari shows none either
    /// side after such a batch, and takes the delete after a step sent then (#570 QA: dd left
    /// "…lazy doga", a Character kept past one gone). Delete all there stops part way, as a
    /// fresh empty context is the text's start: what it leaves is one run of the text.
    func testLineEditsOnALongLineTakeEachCharacterOnce() throws {
        let line = String((1...40).map { "The quick brown fox \($0) jumps over the lazy dog." }.joined(separator: " ").prefix(1217))
        let text = "top\n" + line + "\nnext"
        let safari = { (d: Proxy) in Self.safari(d); d.window = 100; d.answersLate = true; d.moveCost = 1; d.stepCost = 3 }
        let hosts: [(String, (Proxy) -> Void)] = [
            ("Safari", safari), ("Safari, none at a cut", { safari($0); $0.nilsAtCut = true }),
            ("Safari, deletes after the step", { safari($0); $0.nilsAtCut = true; $0.defersCutDeletes = true }),
            ("kit", { Self.textView($0); $0.answersLate = true; $0.window = 300; $0.moveCost = 1; $0.stepCost = 3 }),
            ("BLOCK", Self.qaHosts()[1].1),
        ]
        for (name, host) in hosts {
            for id in ["cutLine", "delLine", "delHome", "delEnd", "delAll"] {
                for col in [0, 600, 1217] {
                    let what = "\(id) on \(name) from \(col)"
                    let (kb, bar, doc) = rig("top\n" + line.prefix(col), after: String(line.dropFirst(col)) + "\nnext",
                                             keys: Shortcuts.hostOnly)
                    host(doc)
                    let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
                    addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
                    bar.suggestions.pasteboard = { pb }
                    bar.toolbar?.reload()
                    try edit(id, kb, bar, doc)
                    let want = ["cutLine": "top\n|next", "delLine": "top\n|next", "delAll": "|",
                                "delHome": "top\n|" + line.dropFirst(col) + "\nnext",
                                "delEnd": "top\n" + line.prefix(col) + "|\nnext"][id]!
                    let kept = want.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    let left = doc.text + (doc.after ?? "")
                    let head = zip(left, text).prefix { $0 == $1 }.count
                    let tail = zip(left.reversed(), text.reversed()).prefix { $0 == $1 }.count
                    XCTAssert(head + tail >= left.count && doc.text.hasPrefix(kept[0]) && (doc.after ?? "").hasSuffix(kept[1]),
                              "\(what): one run of the text, within the edit's extent: \(Self.at(doc).debugDescription)")
                    if id != "delAll" || !doc.nilsAtCut { XCTAssertEqual(Self.at(doc), want, what) }
                    if id == "cutLine" { XCTAssertEqual(pb.string, line, what) }
                }
            }
        }
    }

    /// On the kit and Safari, the toolbar is free within 1.2 s of delete all's or cut line's
    /// last delete showing: one step pair at the text's edge, the walk's 0.3 s for the clamped
    /// step and the 0.8 s a host may take to answer it, then nothing more (#553 QA: delete all
    /// on two words held it 8.3 s after the text went, two step pairs at none and a walk
    /// between); from the text's end 0.9 s, the answer's wait counted from the step away. A
    /// caret left on a line's start past which the after-context stops (the kit's) goes on to
    /// the text after it. QA's slow hosts end right too.
    func testLineEditsFreeTheToolbarSoonAfterTheirLastDelete() throws {
        let cases: [(String, String, String, String)] = [
            ("delAll", "one two", "", ""), ("delAll", "one", " two", ""), ("delAll", "", "one two", ""),
            ("delAll", "one", "\ntwo", ""), ("delAll", "a\nb", "\n\nc d", ""), ("delAll", "a\nb c", "", ""),
            ("cutLine", "one two", "", ""), ("cutLine", "top\none two", "\nend", "top\nend"),
        ]
        let fast: [(String, (Proxy) -> Void)] = [("Safari", { Self.safari($0) }), Self.qaHosts()[0]]
        for (name, host) in fast + Self.qaHosts().dropFirst() {
            for (id, text, after, left) in cases {
                let (kb, bar, doc) = rig(text, after: after, keys: Shortcuts.hostOnly)
                host(doc)
                let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
                addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
                bar.suggestions.pasteboard = { pb }
                bar.toolbar?.reload()
                bar.press(try key(Shortcuts.hostOnly, id))
                bar.press(try key("tab"))
                var gone: Int?, free: Int?
                for i in 1...3_000 where free == nil {
                    doc.catchUp()
                    kb.pollCaret()
                    if gone == nil, doc.text + (doc.after ?? "") == left { gone = i }
                    if doc.calls.last == "\t" { free = i }
                }
                let what = "\(id) on \(name) from \(text.count): gone at \(gone ?? -1), free at \(free ?? -1)"
                print("QA-FREE " + what)
                XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), left == "top\nend" ? "top\n\t|end" : "\t|", what)
                if fast.contains(where: { $0.0 == name }) {
                    XCTAssertLessThanOrEqual((free ?? 9_999) - (gone ?? 0), id == "delAll" && after.isEmpty ? 45 : 60, what)
                }
            }
        }
    }

    /// On the kit and Safari, the toolbar is free within 1 s of a line edit's field showing
    /// empty, in time, with each poll 20 ms apart or 60-80 ms, as the kit's came after a long
    /// edit: delete all from the end, mid-text and the start of a long text, cut line and dd of
    /// the last line (#553 QA r9: the kit held it 3.1-6 s on a long text, waits counted in
    /// polls). All three on an empty field, measured from the press, within 2.1 s: one that
    /// shows no context reads the same till a step's answer is due.
    func testLineEditsFreeTheToolbarWithinASecondOfTheFieldShowingEmpty() throws {
        let long = (1...20).map { "Line \($0) holds a few words and then some more." }.joined(separator: "\n")
        let mid = long.index(long.startIndex, offsetBy: 500)
        let cases: [(String, String, String)] = [
            ("delAll", long, ""), ("delAll", String(long[..<mid]), String(long[mid...])), ("delAll", "", long),
            ("cutLine", "one two", ""), ("delLine", "five six", ""),
            ("delAll", "", ""), ("cutLine", "", ""), ("delLine", "", ""),
        ]
        let hosts: [(String, (Proxy) -> Void)] = [("Safari", { Self.safari($0) }), Self.qaHosts()[0]]
        for poll in [0.02, 0.06, 0.08] {
            for (name, host) in hosts {
                for (id, text, after) in cases {
                    let (kb, bar, doc) = rig(text, after: after, keys: Shortcuts.hostOnly)
                    host(doc)
                    var now = 0.0
                    kb.clock = { now }
                    let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
                    addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
                    bar.suggestions.pasteboard = { pb }
                    bar.toolbar?.reload()
                    bar.press(try key(Shortcuts.hostOnly, id))
                    bar.press(try key("tab"))
                    var empty: Double?, free: Double?
                    for _ in 1...20_000 where free == nil {
                        now += poll
                        doc.catchUp()
                        kb.pollCaret()
                        if empty == nil, doc.text + (doc.after ?? "") == "" { empty = text + after == "" ? 0 : now }
                        if doc.calls.last == "\t" { free = now }
                    }
                    let what = "\(id) on \(name) from \(text.count) of \((text + after).count), polls \(poll) s: "
                        + "empty at \(empty ?? -1), free at \(free ?? -1)"
                    print("QA-TIME " + what)
                    XCTAssertEqual(Self.at(doc), "\t|", what)
                    XCTAssertLessThanOrEqual((free ?? 999) - (empty ?? 0), text + after == "" ? 2.1 : 1, what)
                }
            }
        }
    }

    /// A poll counts the 20 ms ticks since the last, but 5 at most: one after a stalled main
    /// thread can't time a wait out before the host's queued answer is read.
    func testAPollCountsItsTimeInTicksUpToFive() {
        let (kb, _, _) = rig("one")
        var now = 0.0
        kb.clock = { now }
        kb.pollCaret()
        for (gap, n) in [(0.02, 1), (0.06, 3), (0.08, 4), (1.0, 5), (0.001, 1)] {
            let t = kb.ticks
            now += gap
            kb.pollCaret()
            XCTAssertEqual(kb.ticks - t, n, "a poll \(gap) s on")
        }
    }

    /// A tap into another field while a line edit and a second press held behind it are under
    /// way, at any point of them (a batch sent and not shown, a walk leg, a step pair away,
    /// the press held), reaches nothing there: no delete, no move, no insert, no clip of its
    /// text, and a key typed there, at once or later, goes in as typed, nothing sent back
    /// first; dd there then takes its line. So too where the host serves no field for a moment,
    /// nil (#569 QA: Safari, dd twice, then a tap into a second textarea: the first dd's
    /// deletes went on there, the second's took its break).
    func testAFieldSwitchMidEditReachesNothingInTheNewField() throws {
        let long = (1...6).map { "Row \($0) has a few words and then more of them." }.joined(separator: "\n")
        let row = String(repeating: "word ", count: 60)
        let cases: [(String, String, String)] = [
            ("delLine", String(row.prefix(150)), String(row.dropFirst(150)) + "\n\nnext"),
            ("cutLine", String(row.prefix(150)), String(row.dropFirst(150)) + "\nnext"),
            ("delAll", long, ""), ("delAll", String(long.prefix(100)), String(long.dropFirst(100))),
        ]
        let hosts: [(String, (Proxy) -> Void)] = [("Safari", { Self.safari($0) }), Self.qaHosts()[0]]
        for (name, host) in hosts {
            for (id, text, after) in cases {
                for at in stride(from: 16, to: 320, by: 8) {
                    for mode in ["new", "none first", "typed at once"] {
                        try switchMidEdit(id, text, after, on: (name, host), at: at, mode, polls: 400)
                    }
                }
            }
        }
    }

    /// A tap into another field on a stalling host, which takes it only once out of the stall,
    /// right after the answers it owed, and shows it to the keyboard a poll later, reaches
    /// nothing there, at any point of delete all, dd, ctrl-u and ctrl-k; so too one the host
    /// takes at once, before the first batch shows or between batches (#575 QA: STALL delete
    /// all, a tap into a second field 1.5 s on; the host took it 1.1 s late, right after its
    /// last answer in the first, and the batch that answer sized wiped the second).
    /// ponytail: a tap the host takes at a stall's end owing no answer shows the keyboard
    /// nothing first; a batch or a step the keyboard sends that very poll, on a wait's timeout
    /// or its own last batch, still goes there: one batch at most, a sentence on these windows.
    /// So may one after answers to moves the edit sent mid-stall, on a timeout: dd on the host
    /// taking 60 ms a move.
    func testATapQueuedInAStallReachesNothingInTheNewField() throws {
        let other = "keep these words\nand this line too"
        let long = (1...20).map { "Line \($0) holds a few words and then some more." }.joined(separator: "\n")
        let line = "First one is here. Second two is here. Third three is here. Fourth four is here."
        let cases: [(String, String, String)] = [
            ("delAll", long, ""), ("delLine", "top\n" + line.prefix(45), String(line.dropFirst(45)) + "\nend"),
            ("delHome", "top\n" + line, "\nend"), ("delEnd", "top\nFirst", String(line.dropFirst(5)) + "\nend"),
        ]
        var afterAnswer = 0, owingNone = 0, reached = 0
        // Delete all also where each move costs 60 ms: the host answers a few moves in turn
        // after the stall, then takes the tap.
        let slower = [0, 14].map { at in ("STALL at \(at), 60 ms a move", { (d: Proxy) in Self.qaHosts()[2].1(d); d.stalls = (35, 17, at); d.moveCost = 3 }) }
        for (name, host) in Self.qaHosts().dropFirst(2) + slower {
            for (id, text, after) in cases where slower.allSatisfy({ $0.0 != name }) || id == "delAll" {
                for at in stride(from: 1, to: id == "delAll" ? 700 : 200, by: id == "delAll" ? 4 : 2) {
                    let (kb, bar, doc) = rig(text, after: after, keys: Shortcuts.hostOnly)
                    host(doc)
                    let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
                    defer { UIPasteboard.remove(withName: pb.name) }
                    bar.suggestions.pasteboard = { pb }
                    bar.toolbar?.reload()
                    bar.press(try key(Shortcuts.hostOnly, id))
                    for i in 1...(at + 300) {
                        if i == at { doc.tapQueued(other) }
                        doc.catchUp()
                        kb.pollCaret()
                    }
                    let what = "\(id) on \(name), a tap \(at) polls on"
                    guard doc.tookAfterAnswer == false else {
                        if doc.tookAfterAnswer == true { afterAnswer += 1 }
                        XCTAssertEqual(Self.at(doc), other + "|", what)
                        continue
                    }
                    owingNone += 1
                    if Self.at(doc) != other + "|" { reached += 1 }
                    XCTAssertLessThanOrEqual(other.count - (doc.text + (doc.after ?? "")).count, 21, what)
                }
            }
        }
        print("QA-575 queued after an answer \(afterAnswer), owing none \(owingNone), reached there \(reached)")
        XCTAssertGreaterThan(afterAnswer, 100)
    }

    /// So too where the edit's writes and its own step pair go out mid-stall, the host showing
    /// none of them till it is out, its first answer over 200 ms after the first and 100 ms or
    /// more after the steps: ctrl-u mid-way along one long line, the host's window 300 units
    /// either side (#575 QA r2, um: ctrl-u on a 2319-Character line, its step pair sent 125 ms
    /// before the stall's end, the next 300-Character batch 41 ms after the host's answer,
    /// unheld).
    func testATapQueuedInAStallReachesNothingAfterTheEditsOwnStepsThere() throws {
        let other = "keep these words\nand this line too"
        let line = String((1...500).map { "w\($0) " }.joined().prefix(2319))
        var afterAnswer = 0
        for phase in 21...24 {
            for at in stride(from: 1, to: 100, by: 4) {
                let (kb, bar, doc) = rig(String(line.prefix(1500)), after: String(line.dropFirst(1500)),
                                         keys: Shortcuts.hostOnly)
                Self.qaHosts()[2].1(doc)
                doc.stalls = (35, 17, phase)
                doc.window = 300
                let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
                defer { UIPasteboard.remove(withName: pb.name) }
                bar.suggestions.pasteboard = { pb }
                bar.toolbar?.reload()
                bar.press(try key(Shortcuts.hostOnly, "delHome"))
                for i in 1...(at + 400) {
                    if i == at { doc.tapQueued(other) }
                    doc.catchUp()
                    kb.pollCaret()
                }
                if doc.tookAfterAnswer == true { afterAnswer += 1 }
                XCTAssertEqual(Self.at(doc), other + "|", "stall at \(phase), a tap \(at) polls on")
            }
        }
        XCTAssertGreaterThan(afterAnswer, 40)
    }

    /// So too the toolbar's kept keys, on a host taking 0.8 s a move: ctrl-w and ctrl-u twice,
    /// a tap into another field after the second press, a new one or none first (#569 QA: they
    /// go through the same deletes, walk and steps).
    func testAFieldSwitchMidKeptEditOnASlowHostReachesNothingInTheNewField() throws {
        let line = "First one is here. Second two is here. Third three is here."
        let slow: (String, (Proxy) -> Void) = ("a host 0.8 s a move", { Self.qaHosts()[1].1($0); $0.moveCost = 40 })
        for id in ["delWord", "delHome"] {
            for at in stride(from: 16, to: 700, by: 20) {
                for mode in ["new", "none first"] {
                    try switchMidEdit(id, "top\n" + line, "\nend", on: slow, at: at, mode, polls: 1_000, dd: false)
                }
            }
        }
    }

    /// A walk under way with nothing else pending, a trackpad drag or a word motion twice, on
    /// a host taking 0.8 s a move, goes no further once the host serves another field, a new
    /// one or none first: no move there, and a key goes in where the tap put the caret (#569
    /// review: the walk's rest moved the caret in the next field).
    func testAWalkUnderWayStopsAtAFieldSwitch() throws {
        let other = "keep these words\nand this line too"
        let text = "top\n" + String(repeating: "First one is here. ", count: 4)
        for motion in ["drag", "wordNext"] {
            for at in stride(from: motion == "drag" ? 2 : 16, to: 400, by: 12) {   // after the second press
                for gap in [false, true] {
                    let (kb, bar, doc) = rig(motion == "drag" ? text : "top\n", after: motion == "drag" ? "\nend" : String(text.dropFirst(4)),
                                             keys: Shortcuts.hostOnly)
                    Self.qaHosts()[1].1(doc)
                    doc.moveCost = 40
                    bar.toolbar?.reload()
                    let what = "\(motion), a tap \(at) polls on\(gap ? ", none first" : "")"
                    if motion == "drag" { kb.caret(-30) } else { bar.press(try key(Shortcuts.hostOnly, "wordNext")) }
                    for i in 1...600 {
                        if motion != "drag", i == 15 { bar.press(try key(Shortcuts.hostOnly, "wordNext")) }
                        if i == at { doc.focus(other, id: gap ? nil : UUID()); doc.moves = [] }
                        if gap, i == at + 5 { doc.identifier = UUID() }
                        doc.catchUp()
                        kb.pollCaret()
                    }
                    XCTAssertEqual(doc.moves, [], what)
                    kb.press(.char("z"))
                    XCTAssertEqual(Self.at(doc), other + "z|", what)
                }
            }
        }
    }

    /// `id` twice, 15 polls apart, on `host`, the host serving another field `at` polls on (a
    /// new one, none first, or a key typed in it at once): nothing of the edits reaches it, and
    /// dd there then takes its line (not on a host slower than dd's waits, which may stop short).
    private func switchMidEdit(_ id: String, _ text: String, _ after: String, on host: (String, (Proxy) -> Void),
                               at: Int, _ mode: String, polls: Int, dd: Bool = true) throws {
        let other = "keep these words\nand this line too"
        let (kb, bar, doc) = rig(text, after: after, keys: Shortcuts.hostOnly)
        host.1(doc)
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        defer { UIPasteboard.remove(withName: pb.name) }
        bar.suggestions.pasteboard = { pb }
        bar.toolbar?.reload()
        let what = "\(id) twice on \(host.0), a tap \(at) polls on, \(mode)"
        let gap = mode == "none first", typed = mode == "typed at once"
        bar.press(try key(Shortcuts.hostOnly, id))
        for i in 1...polls {
            if i == 15 { bar.press(try key(Shortcuts.hostOnly, id)) }
            if i == at {
                doc.focus(other, id: gap ? nil : UUID()); doc.calls = []; doc.moves = []
                if typed { kb.press(.char("z")) }
            }
            if gap, i == at + 5 { doc.identifier = UUID() }
            doc.catchUp()
            kb.pollCaret()
        }
        XCTAssertEqual(Self.at(doc), other + (typed ? "z|" : "|"), what)
        XCTAssertEqual(doc.calls, typed ? ["z"] : [], what)
        XCTAssertEqual(doc.moves, [], what)
        XCTAssertFalse(["keep", "too"].contains { pb.string?.contains($0) == true }, "\(what): \(pb.string ?? "")")
        if !typed { kb.press(.char("z")) }
        XCTAssertEqual(Self.at(doc), other + "z|", what)
        XCTAssertEqual(doc.moves, [], what)
        guard dd else { return }
        for _ in 1...5 { doc.catchUp(); kb.pollCaret() }   // the host shows the key
        bar.press(try key(Shortcuts.hostOnly, "delLine"))
        for _ in 1...polls { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(Self.at(doc), "|keep these words", what)
    }

    /// A field the host serves no identifier for, mid-way through a focus change, takes a
    /// trackpad move and a toolbar edit as any: nothing traps on the nil (#569 QA: a walk's
    /// read of it crashed the keyboard).
    func testAFieldWithNoIdentifierTakesMovesAndEdits() throws {
        let (kb, bar, doc) = rig("one two", after: " three")
        doc.identifier = nil
        kb.caret(-3)
        for _ in 1...50 { doc.catchUp(); kb.pollCaret() }
        XCTAssertEqual(Self.at(doc), "one |two three")
        try edit("delAll", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "|")
    }

    /// ctrl-k over a line of sentences on the kit, whose after-context stops after each
    /// sentence's space: each leg there goes on at the host's answer, 20-160 ms on, not after
    /// the 0.8 s a stalled host may take (#553 QA: the kit's sentence-windowed line edits took
    /// 0.7-2.5 s; a walk ignoring the answer there waited each sentence out).
    func testDeleteToEndGoesOnAtTheKitsAnswerAfterEachSentence() throws {
        let line = "First one is here. Second two is here. Third three is here. Fourth four is here."
        for cost in [1, 2, 4, 8] {
            let (kb, bar, doc) = rig("top\nFirst", after: String(line.dropFirst(5)) + "\nend")
            Self.qaHosts()[0].1(doc)
            doc.moveCost = cost
            bar.press(try key(Shortcuts.hostOnly, "delEnd"))
            bar.press(try key("tab"))
            var free: Int?
            for i in 1...3_000 where free == nil {
                doc.catchUp()
                kb.pollCaret()
                if doc.calls.last == "\t" { free = i }
            }
            XCTAssertEqual(Self.at(doc), "top\nFirst\t|\nend", "\(cost)")
            XCTAssertLessThanOrEqual(free ?? 9_999, 100, "\(cost): the line's end waited out, not its three sentence ends")
        }
    }

    /// Cut line writes the clip as its deletes go: a key during the step pairs after them, which
    /// drops the edit, leaves it written (#553 QA: a key 1.5 s on kept the old clip).
    func testCutLineWritesTheClipBeforeItsTail() throws {
        for (name, host) in [("Safari", { Self.safari($0) })] + Self.qaHosts() {
            let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
            addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
            pb.string = "old"
            let (kb, bar, doc) = rig("one one", keys: Shortcuts.hostOnly)
            host(doc)
            bar.suggestions.pasteboard = { pb }
            bar.toolbar?.reload()
            bar.press(try key(Shortcuts.hostOnly, "cutLine"))
            var i = 0
            while i < 3_000, Self.at(doc) != "|" { doc.catchUp(); kb.pollCaret(); i += 1 }
            doc.catchUp(); kb.pollCaret()
            kb.press(.char("q"))
            for _ in 1...3_000 { doc.catchUp(); kb.pollCaret() }
            XCTAssertEqual(pb.string, "one one", name)
            XCTAssertEqual(Self.at(doc), "q|", name)
        }
    }

    /// Delete all on QA's slow hosts empties the field from the end and from mid-text, nothing
    /// after the caret going before all before it has (#553 QA: STALL stopped from the end
    /// with 2145 of 2261 left, the caret a Character back, and from a row's fourth Character
    /// with 65 left, the step from none read none in a stall; BLOCK left the `n` after the
    /// caret at 17.8 s, and from mid-text stopped with 1147 left).
    func testQAHostsDeleteAll() throws {
        let rows = (10...49).map { "row \($0): a red fox runs past the old dog in the yard" }.joined(separator: "\n")
        let sentences = (10...49).map { "Row \($0) is here. It has two. Then the end" }.joined(separator: "\n")
        for (name, host) in Self.qaHosts() {
            for all in [rows, sentences] {
            let mid = try XCTUnwrap(all.range(of: "ow 30")).upperBound
            let early = all.index(try XCTUnwrap(all.range(of: "ow 15")).lowerBound, offsetBy: 3)
            for cut in [mid, early, all.endIndex, all.index(before: all.endIndex)] {
                let from = "\(name), \(all == rows ? "rows" : "sentences") from \(all.distance(from: all.startIndex, to: cut))"
                let (kb, bar, doc) = rig(String(all[..<cut]), after: String(all[cut...]))
                host(doc)
                bar.press(try key(Shortcuts.hostOnly, "delAll"))
                let after = String(all[cut...])
                var before = true, gone = 0
                for i in 1...12_000 {
                    doc.catchUp()
                    kb.pollCaret()
                    if gone == 0, Self.at(doc) == "|" { gone = i }
                    guard before else { continue }
                    let rest = doc.text + (doc.after ?? "")
                    XCTAssertTrue(rest.hasSuffix(after), "the text after the caret kept: \(from), at \(i)")
                    before = rest != after
                    if !rest.hasSuffix(after) { break }
                }
                XCTAssertEqual(Self.at(doc), "|", from)
                print("QA-DELALL \(from): \(gone) polls")
            }
            }
        }
    }

    /// Delete all from mid-text on a blocking host that also lays out after each delete, so its
    /// answers to the walk come late and its legs read the context from two legs back in turn,
    /// as QA's did (#553 QA: BLOCK's legs went +45, +1, +44, +1 for 101 moves and 1147 were
    /// left): the walk still reaches the end and the field empties, a leg at a time.
    /// ponytail: about 100 legs for 20 lines; a host showing that cycle for longer than the
    /// walk's leg budget stops partway, the text after the caret kept.
    func testDeleteAllWalksToTheEndOnABusyHost() throws {
        let rows = (0..<40).map { String(format: "item %02d the tall grey frog hops over the calm ponds again", $0) }
            .joined(separator: "\n")
        let cut = rows.index(try XCTUnwrap(rows.range(of: "item 20")).lowerBound, offsetBy: 12)
        for (name, host) in Self.qaHosts().prefix(2) {
            let (kb, bar, doc) = rig(String(rows[..<cut]), after: String(rows[cut...]))
            host(doc)
            doc.editsPerPoll = 2
            bar.press(try key(Shortcuts.hostOnly, "delAll"))
            for _ in 1...12_000 where Self.at(doc) != "|" { doc.catchUp(); kb.pollCaret() }
            let legs = doc.moves.filter { $0 > 1 }
            print("QA-LEGS \(name): \(legs.count) \(legs.prefix(12))")
            XCTAssertEqual(Self.at(doc), "|", name)
        }
    }

    /// A tab or a Paste pressed right behind delete all goes once the field is empty, on the
    /// fakes of QA's slow hosts too. (#553 QA: its STALL with Paste stopped at 406, BLOCK with
    /// tab at row 27 and with Paste at 581, a step pair never landing before the poll limit, and
    /// the press went in there; these fakes don't show that.)
    func testAPressBehindDeleteAllGoesOnceTheFieldIsEmpty() throws {
        let rows = (10...49).map { "row \($0): a red fox runs past the old dog in the yard" }.joined(separator: "\n")
        for (name, host) in [("Safari", { Self.safari($0) })] + Self.qaHosts() {
            for second in ["tab", "paste"] {
                let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
                addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
                pb.string = "clip"
                let (kb, bar, doc) = rig(rows, keys: Shortcuts.Bar.toolbar.defaults)
                host(doc)
                bar.suggestions.pasteboard = { pb }
                let toolbar = try XCTUnwrap(bar.toolbar)
                toolbar.reload()
                bar.showsToolbar = true
                bar.refresh()
                bar.press(try key(Shortcuts.hostOnly, "delAll"))
                if second == "tab" { bar.press(try key("tab")) } else {
                    toolbar.paste(itemProviders: [NSItemProvider(object: "clip" as NSString)])
                    RunLoop.main.run(until: Date() + 0.2)
                }
                for _ in 1...12_000 { doc.catchUp(); kb.pollCaret() }
                XCTAssertEqual(Self.at(doc), second == "tab" ? "\t|" : "clip|", "\(name), \(second)")
            }
        }
    }

    /// ctrl-u and delete all over a run of one Character: its batches of one leave an anchor,
    /// so they take no steps between them (#553 QA: a step pair a batch, 10-20 times slower).
    func testARunOfOneCharacterGoesWithoutSteps() throws {
        let run = (1...12).map { _ in String(repeating: "b", count: 60) }.joined(separator: "\n")
        for (name, host) in [("text view", Self.textView), ("safari", Self.safari)] {
            let (kb, bar, doc) = rig("top\n" + String(repeating: "a", count: 150))
            host(doc)
            try edit("delHome", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "top\n|", "ctrl-u: \(name)")
            if name == "text view" { XCTAssertLessThanOrEqual(doc.moves.count, 4, "ctrl-u's steps: \(doc.moves)") }
            doc.text = "top\n" + run + "\nend"; doc.after = ""
            try edit("delAll", kb, bar, doc)
            XCTAssertEqual(Self.at(doc), "|", "delete all: \(name)")
        }
    }

    /// A field that shows no context reads as empty: an edit there deletes nothing, and a step
    /// back looking for a fresh context that shows none either isn't followed by a step on: it
    /// reads as the text's start, as an empty first line's does (#553 QA: the step on there
    /// took the caret a line down). So in an empty one, which shows no context as a field whose
    /// window a delete used up does (#553 QA): its steps net nothing. One pair a press decides
    /// it: dd's deletes after its pair take none. (Round 7: the caret ends where the press
    /// found it, the blind step on undone by the step back, not a Character on.)
    func testEditsTakeNoStepBackInAFieldWithoutContext() throws {
        let (kb, bar, doc) = rig("ab", after: "cd")
        doc.hidesContext = true
        try edit("delAll", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "ab|cd", "the blind step to the end, and the step back: \(doc.moves)")
        XCTAssertEqual(doc.calls, [], "no deletes")
        doc.text = ""; doc.after = ""; doc.moves = []
        try edit("delAll", kb, bar, doc)
        XCTAssertEqual(doc.moves, [1, -1], "the blind step to the end, and a step back that finds none")
        doc.text = "ab"; doc.after = "cd"; doc.moves = []
        try edit("delLine", kb, bar, doc)
        XCTAssertEqual(Self.at(doc), "ab|cd", "dd: the step back, and the blind step over the break")
        XCTAssertEqual(doc.moves, [-1, 1], "dd: one step finds none, then no more steps")
    }

    /// A press while an edit's step pair is under way, the step away sent and the step back
    /// not, or the step back sent and not shown: a toolbar edit waits for the caret to come
    /// back and for the edit to end, and acts from there, a key, a touch, an arrow, a line
    /// move or the poll limit gets it back first and drops the edit's rest. None touches the
    /// text after the caret but its own (#553 QA: a second ctrl-u in Safari dropped the step
    /// back and took the space after the run).
    /// A key while an edit waits for the host drops the edit and the hold it has on toolbar
    /// presses: the next goes at once (`TerminalKeyboard.holding`).
    func testAKeyDuringAnEditFreesTheToolbar() throws {
        let (kb, bar, doc) = rig("one two")
        doc.lagsEdits = true   // the deletes show only at `catchUp`: ctrl-w waits for them
        bar.press(try key(Shortcuts.hostOnly, "delWord"))
        XCTAssertEqual(Self.at(doc), "one |", "ctrl-w's deletes at the press")
        kb.press(.char("z"))
        doc.catchUp()
        bar.press(try key(Shortcuts.hostOnly, "delWord"))
        XCTAssertEqual(Self.at(doc), "one |", "the second ctrl-w at once")
    }

    /// The poll limit drops an edit the host never shows, not the toolbar press it held: that
    /// goes then (#553 QA: a held press was dropped with the edit).
    func testThePollLimitDropsAnEditNotThePressItHeld() throws {
        let (kb, bar, doc) = rig("x\n" + String(repeating: "a", count: 50), after: " end\ny")
        Self.safari(doc)
        doc.lags = true   // the step away never shows
        bar.press(try key(Shortcuts.hostOnly, "delHome"))
        for _ in 1...3_000 where doc.moves.isEmpty {
            doc.catchUp()
            kb.pollCaret()
        }
        bar.press(try key("tab"))
        XCTAssertFalse(doc.calls.contains("\t"), "the tab held")
        for _ in 0..<100 { kb.pollCaret() }
        XCTAssertEqual(Self.at(doc), "x\n" + String(repeating: "a", count: doc.text.filter { $0 == "a" }.count) + "\t| end\ny",
                       "the tab where the step pair came back to")
    }

    /// A toolbar press while dd waits for a busy host's answer to its step goes after dd, from
    /// where dd left the caret (#553 QA: a held ← went before or not at all).
    func testAPressWhileAnEditWaitsForTheHostGoesAfterIt() throws {
        let (kb, bar, doc) = rig("one\ntw", after: "o\nthree")
        Self.qaHosts()[1].1(doc)   // BLOCK
        bar.press(try key(Shortcuts.hostOnly, "delLine"))
        for _ in 1...3_000 where doc.moves.count < 2 {
            doc.catchUp()
            kb.pollCaret()
        }
        XCTAssertEqual(doc.moves, [1, 1], "the walk to the line's end, and dd's step over the break")
        XCTAssertEqual(doc.calls, [], "waiting for the step's answer")
        bar.press(try key("left"))
        for _ in 1...3_000 {
            doc.catchUp()
            kb.pollCaret()
        }
        XCTAssertEqual(Self.at(doc), "one|\nthree")
    }

    /// So too a toolbar press held by an edit's walk leg (`holding`), not a step pair: the leg
    /// never shows, the limit drops ctrl-k, and the press goes then, where the leg left the
    /// caret, nothing deleted.
    func testThePollLimitDropsAWalkNotThePressItHeld() throws {
        let (kb, bar, doc) = rig("x\none", after: " two\ny")
        doc.lags = true   // the leg never shows
        bar.press(try key(Shortcuts.hostOnly, "delEnd"))
        XCTAssertEqual(doc.moves, [4], "the leg to the line's end")
        bar.press(try key("tab"))
        XCTAssertEqual(doc.calls, [], "the tab held")
        for _ in 0..<100 { kb.pollCaret() }
        XCTAssertEqual(doc.calls, ["\t"], "the tab, and no deletes")
        XCTAssertEqual(doc.moves, [4], "no other move")
        XCTAssertEqual(Self.at(doc), "x\none two\t|\ny")
    }

    func testAPressDuringAStepPairActsWhereTheEditLeftTheCaret() throws {
        for by in ["toolbar", "ctrl-k", "key", "touch", "arrow", "line", "poll limit", "toolbar on the step back",
                   "key on the step back"] {
            let (kb, bar, doc) = rig("x\n" + String(repeating: "a", count: 50), after: " end\ny")
            Self.safari(doc)
            doc.lags = by == "poll limit"   // the step away never shows
            bar.press(try key(Shortcuts.hostOnly, "delHome"))
            let steps = by.hasSuffix("step back") ? 2 : 1
            for _ in 1...3_000 where doc.moves.count < steps {
                doc.catchUp()
                kb.pollCaret()
            }
            XCTAssertEqual(doc.moves, [1, -1].prefix(steps).map { $0 }, "the pair's steps, on: \(by)")
            let run = "x\n" + String(repeating: "a", count: doc.text.filter { $0 == "a" }.count)
            switch by {
            case "toolbar", "toolbar on the step back": bar.press(try key(Shortcuts.hostOnly, "delHome"))
            case "ctrl-k": bar.press(try key(Shortcuts.hostOnly, "delEnd"))
            case "key", "key on the step back": kb.press(.char("z"))
            case "arrow": kb.caret(1)
            case "line": kb.line(1)
            case "poll limit": for _ in 0..<100 { kb.pollCaret() }
            default:
                kb.track(.began, id: 1, at: CGPoint(x: -500, y: -500))
                XCTAssertEqual(Self.at(doc), run + "| end\ny", "at the touch")
                kb.track(.cancelled, id: 1, at: CGPoint(x: -500, y: -500))
            }
            for _ in 1...3_000 {
                doc.catchUp()
                kb.pollCaret()
            }
            // The touch types what it lands nearest, where the caret came back to.
            let typed = by == "touch" ? doc.text.dropFirst(run.count) : ""
            // ctrl-k goes once ctrl-u ended, as a second dd does after the first (#553 QA).
            let want = ["toolbar": "x\n| end\ny", "toolbar on the step back": "x\n| end\ny", "ctrl-k": "x\n|\ny",
                        "key": run + "z| end\ny", "key on the step back": run + "z| end\ny",
                        "touch": run + typed + "| end\ny", "arrow": run + " |end\ny", "line": run + " end\ny|",
                        "poll limit": run + "| end\ny"][by]
            XCTAssertEqual(Self.at(doc), want, "\(by): \(doc.moves)")
        }
    }

    /// The toolbar's Paste during an edit's step pair goes in once the pair is back, as a
    /// toolbar press does: where the edit left the caret (#553 QA: it went in mid-pair).
    func testToolbarPasteDuringAStepPairGoesWhereTheEditLeftTheCaret() throws {
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        pb.string = "clip"
        let (kb, bar, doc) = rig("x\n" + String(repeating: "a", count: 50), after: " end\ny",
                                 keys: Shortcuts.Bar.toolbar.defaults)
        Self.safari(doc)
        bar.suggestions.pasteboard = { pb }
        let toolbar = try XCTUnwrap(bar.toolbar)
        toolbar.reload()
        bar.showsToolbar = true
        bar.refresh()
        bar.press(try key(Shortcuts.hostOnly, "delHome"))
        for _ in 1...3_000 where doc.moves.isEmpty {
            doc.catchUp()
            kb.pollCaret()
        }
        XCTAssertEqual(doc.moves, [1], "mid-pair")
        toolbar.paste(itemProviders: [NSItemProvider(object: "clip" as NSString)])
        RunLoop.main.run(until: Date() + 0.3)
        XCTAssertEqual(doc.calls.filter { $0 == "clip" }, [], "held")
        for _ in 1...3_000 {
            doc.catchUp()
            kb.pollCaret()
        }
        XCTAssertEqual(Self.at(doc), "x\nclip| end\ny")
    }

    /// Delete all goes on after the caret only once all before it went: a press that stops
    /// at its 10,000 deletes leaves the rest, and the text after the caret, to the next.
    func testDeleteAllTakesTheTextAfterTheCaretOnlyOnceAllBeforeWent() throws {
        let (kb, bar, doc) = rig(String(repeating: "ab\n", count: 3_400), after: "kept")
        doc.lagsEdits = true
        try edit("delAll", kb, bar, doc)
        XCTAssertEqual(doc.text.count, 200)
        XCTAssertEqual(doc.after, "kept")
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
    /// past the extent goes (#553 QA: dd took Characters of the line above). So too two
    /// edits behind, on plain text, a run of one Character and a context starting at
    /// Safari's space: one edit behind, the batch sized from that context is what's left, so
    /// the anchor decides only where the context shows more of the batch (#553 QA: no fake
    /// showed it, so nothing checked the anchor).
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
        doc.behindBy = 2
        for (text, what) in [("top\nfoo bar", "plain text"), ("top\naaaab", "a run")] {
            doc.text = text; doc.after = ""
            try edit("delHome", kb, bar, doc, every: 3)
            XCTAssertEqual(Self.at(doc), "top\n|", "two edits behind: \(what)")
        }
        let (wkb, wbar, safari) = rig("top\nabcdef")
        safari.window = 7; safari.breakSpace = true; safari.behind = true
        for by in [1, 2] {
            safari.text = "top\nabcdef"; safari.behindBy = by
            try edit("delHome", wkb, wbar, safari, every: 3)
            XCTAssertEqual(safari.text, "top\n", "a context starting at Safari's space, \(by) behind")
        }
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
