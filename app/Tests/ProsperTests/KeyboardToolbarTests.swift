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

    /// A login field and a fresh clip show AutoFill and Paste over the toolbar, the toggle
    /// out of the way; away from them the toolbar is back, and the pick never changed.
    func testAutoFillAndPasteShowOverTheToolbarAndGoBack() throws {
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
        XCTAssertEqual(bar.state, .paste)
        XCTAssertTrue(toolbar.isHidden)
        XCTAssertFalse(bar.pasteControl.isHidden)
        bar.suggestions.pasteboard = { nil }
        bar.refresh()
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

    /// A toolbar edit pressed, then the host answering and the walk polling until it lands.
    private func edit(_ id: String, _ kb: TerminalKeyboard, _ bar: SuggestionBar, _ doc: Proxy) throws {
        bar.press(try XCTUnwrap(Shortcuts.Bar.toolbar.catalog.first { $0.id == id }, id))
        for _ in 0..<2_000 { doc.catchUp(); kb.pollCaret() }
    }

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
        XCTAssertEqual(doc.text + "|" + (doc.after ?? ""), "one|")
    }

    /// A host whose context lags the edits: deleting stops once the context stops changing,
    /// rather than deleting again from a context that still shows what went. Moves that lag
    /// are waited for, so the deletes after them start in the right place.
    func testEditsStopWhenTheContextLags() throws {
        let (kb, bar, doc) = rig("abc\ndef", after: "")
        doc.lineBefore = true
        doc.lagsEdits = true
        bar.press(try XCTUnwrap(Shortcuts.Bar.toolbar.catalog.first { $0.id == "delAll" }))
        for _ in 0..<100 { kb.pollCaret() }   // the host never answers the deletes
        XCTAssertEqual(doc.text, "abc\n", "one batch: the frozen context repeats")
        try edit("delAll", kb, bar, doc)   // caught up, a second press goes on
        XCTAssertEqual(doc.text, "abc", "and stops again")

        let (lkb, lbar, late) = rig("x the qu", after: "ick fox\nnext")
        late.lags = true
        late.window = 3
        try edit("delEnd", lkb, lbar, late)
        XCTAssertEqual(late.text + "|" + (late.after ?? ""), "x the qu|\nnext")
        try edit("delLine", lkb, lbar, late)
        XCTAssertEqual(late.text + "|" + (late.after ?? ""), "|next")
    }
}
