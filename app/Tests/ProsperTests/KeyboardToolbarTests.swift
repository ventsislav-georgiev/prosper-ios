import XCTest
import UIKit
@testable import Prosper

/// The app's shortcut keys as the system keyboard's toolbar (`SuggestionBar.addToolbar`):
/// what each key does in a host field, the toggle and its pick, AutoFill and Paste over
/// the toolbar, and the keys' move to the App Group (`Shortcuts.shared`).
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
    private func rig(_ text: String = "", after: String = "") -> (TerminalKeyboard, SuggestionBar, Proxy) {
        let doc = Proxy()
        doc.text = text; doc.after = after
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults)))
        bar.attach(kb)
        bar.addToolbar { Shortcuts.defaults }
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
            ("slash", .key(.char("/"))), ("pipe", .key(.char("|"))), ("paste", nil), ("pasteImg", nil),
            ("insert", nil), ("snl", .key(.ret)), ("enter", .key(.ret)), ("redraw", nil),
        ]
        XCTAssertEqual(Shortcuts.catalog.map(\.id), want.map(\.0), "a new catalog key needs a mapping here")
        for (id, action) in want { XCTAssertEqual(Shortcuts.hostKey(id), action, id) }
        let (_, bar, _) = rig()
        XCTAssertEqual(Self.caps(try XCTUnwrap(bar.toolbar)).compactMap(\.accessibilityLabel),
                       ["↑", "↓", "tab", "home", "←", "→", "end", "send"], "the hidden ones aren't caps")
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
}
