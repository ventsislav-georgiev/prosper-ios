import XCTest
import UIKit
@testable import Prosper

/// The toggle menu's Emoji (#629): the system keyboard can't switch to iOS's emoji, so the
/// menu opens the app's picker in the keys' place, the bottom row still without an emoji
/// key, and the picker and the numpad never show at once. Driven as the extension wires it.
@MainActor
final class EmojiMenuTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy

    private var suite = ""
    private var defaults: UserDefaults!
    private var store = KeyboardSettings.store

    /// Recents go to a suite of the test's own.
    override func setUp() {
        super.setUp()
        suite = "EmojiMenuTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = KeyboardSettings.store
        let d = defaults
        KeyboardSettings.store = { d }
    }

    override func tearDown() {
        KeyboardSettings.store = store
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The extension's keyboard (no emoji key, the 123 key), its bar and toolbar, hosted in a
    /// window. Keep all four: the keyboard holds the proxy and the bar weakly.
    private func rig() -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard()
        kb.target = doc
        kb.offersEmoji = false
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults), layout: .english))
        bar.attach(kb)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        if #available(iOS 17, *) { window.traitOverrides.verticalSizeClass = .regular }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        window.addSubview(view)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.toolbar.defaults }
        kb.allowsNumbersKey = true
        kb.settings.numbers = .key
        view.layoutIfNeeded()
        return (kb, bar, doc, view)
    }

    private func pickEmoji(_ bar: SuggestionBar) throws {
        bar.showMenu(true)
        let menu = try XCTUnwrap(bar.menuPanel)
        try XCTUnwrap(menu.tiles.first { $0.accessibilityLabel == "Emoji" }).sendActions(for: .touchUpInside)
        XCTAssertNil(bar.menuPanel, "the pick closes the menu")
    }

    private func button(_ picker: EmojiPicker, _ label: String) throws -> UIButton {
        func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }
        return try XCTUnwrap(all(picker).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }, label)
    }

    private func capsShown(_ kb: TerminalKeyboard) -> Bool {
        kb.subviews.contains { $0 is UIButton && !$0.isHidden }
    }

    /// Without Full Access the menu still has Emoji, a real symbol; its pick puts the picker
    /// in the caps' place, a cell types into the field, and ABC brings the letters back.
    func testTheMenusEmojiOpensThePickerWithoutTheEmojiKey() throws {
        let (kb, bar, doc, view) = rig()
        XCTAssertFalse(kb.shownKeys.joined().contains(.emoji), "the bottom row stays without it")
        XCTAssertNil(bar.suggestions.pasteboard(), "no Full Access")
        let item = try XCTUnwrap(bar.menuItems.first { $0.title == "Emoji" })
        XCTAssertEqual(item.symbol, "face.smiling")
        XCTAssertNotNil(UIImage(systemName: item.symbol))

        try pickEmoji(bar)
        let picker = try XCTUnwrap(kb.emojiPicker)
        XCTAssertTrue(kb.showsEmoji)
        XCTAssertFalse(capsShown(kb), "the caps hide")
        XCTAssertNil(bar.panel)

        let e = "😀"
        let section = try XCTUnwrap(picker.sections.firstIndex { $0.contains(e) })
        let item2 = try XCTUnwrap(picker.sections[section].firstIndex(of: e))
        picker.collectionView(picker.grid, didSelectItemAt: IndexPath(item: item2, section: section))
        XCTAssertEqual(doc.text, e)
        XCTAssertEqual(EmojiRecents.load().emoji, [e], "recents shared through the App Group")

        try button(picker, "letters").sendActions(for: .touchUpInside)
        XCTAssertFalse(kb.showsEmoji)
        XCTAssertTrue(capsShown(kb), "the letters back")
        XCTAssertTrue(kb.shownKeys.joined().contains(.char("q")))
        withExtendedLifetime(view) {}
    }

    /// From the numpad, with Hide Toolbar on the Numpad: the picker shows, the numpad closes
    /// and the bar comes back; ABC goes to the letters. The numpad opened over the picker
    /// closes it.
    func testThePickerAndTheNumpadNeverShowAtOnce() throws {
        let (kb, bar, _, view) = rig()
        kb.settings.numpadHidesToolbar = true
        kb.press(.numbers)
        XCTAssertTrue(kb.showsNumpad)
        XCTAssertTrue(bar.isHidden, "hidden for the numpad")

        bar.showMenu(true)   // the menu's toggle is the bar's; VoiceOver's More reaches it hidden too
        try XCTUnwrap(bar.menuPanel?.tiles.first { $0.accessibilityLabel == "Emoji" }).sendActions(for: .touchUpInside)
        XCTAssertTrue(kb.showsEmoji)
        XCTAssertFalse(kb.showsNumpad, "the numpad closes")
        XCTAssertFalse(bar.isHidden, "the bar comes back")
        XCTAssertFalse(capsShown(kb))

        try button(try XCTUnwrap(kb.emojiPicker), "letters").sendActions(for: .touchUpInside)
        XCTAssertFalse(kb.showsNumpad)
        XCTAssertTrue(kb.shownKeys.joined().contains(.char("q")), "ABC goes to the letters")

        kb.showEmoji(true)
        kb.showNumpad(true, animated: false)
        XCTAssertTrue(kb.showsNumpad)
        XCTAssertFalse(kb.showsEmoji, "the numpad closes the picker")
        XCTAssertTrue(capsShown(kb), "the numpad's keys show")
        withExtendedLifetime(view) {}
    }

    /// A panel over the keys gives way to the picker: the menu replaces it, and its pick
    /// leaves no panel stacked over the picker.
    func testAPanelGivesWayToThePicker() throws {
        let (kb, bar, _, view) = rig()
        let pb = try XCTUnwrap(UIPasteboard(name: .init("prosper.test.\(UUID())"), create: true))
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        bar.suggestions.pasteboard = { pb }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EmojiMenu-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        bar.history = ClipboardHistory(dir: dir)
        bar.showClips(true)
        XCTAssertNotNil(bar.clipsPanel)
        try pickEmoji(bar)
        XCTAssertNil(bar.panel, "no panel over the picker")
        XCTAssertTrue(kb.showsEmoji)
        XCTAssertEqual(view.subviews.filter { $0 is KeysPanel }.count, 0)
    }

    /// The system keyboards' picker (#629): Recents and Frequent only, at most 150 emoji
    /// beside Recents, each one the full grid has; the app's keyboard keeps every group.
    func testTheExtensionsPickerIsRecentsAndFrequentOnly() throws {
        let (kb, bar, _, view) = rig()
        try pickEmoji(bar)
        let picker = try XCTUnwrap(kb.emojiPicker)
        XCTAssertFalse(picker.full)
        XCTAssertEqual(picker.sections.count, 2)
        XCTAssertEqual(picker.sections[1], EmojiPicker.frequent)
        XCTAssertLessThanOrEqual(EmojiPicker.frequent.count, 150)
        XCTAssertLessThanOrEqual(picker.sections.joined().count, 150 + EmojiRecents.limit)
        XCTAssertEqual(Set(EmojiPicker.frequent).count, EmojiPicker.frequent.count, "each once")
        XCTAssertEqual(Set(EmojiPicker.frequent).subtracting(EmojiPicker.groups.joined()), [])
        func buttons(_ v: UIView) -> [UIButton] { ((v as? UIButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
        XCTAssertEqual(buttons(picker).map(\.accessibilityLabel), ["letters", "Recents", "Frequent", "delete"], "the bar")

        let app = TerminalKeyboard()
        app.showEmoji(true)
        let all = try XCTUnwrap(app.emojiPicker)
        XCTAssertTrue(all.full)
        XCTAssertEqual(Array(all.sections.dropFirst()), EmojiPicker.groups, "the app's keyboard: every group")
        withExtendedLifetime(view) {}
    }

    /// Without Full Access the group may not keep a write: recents go to the extension's own
    /// defaults, and are read back from there; with it, to the group.
    func testRecentsWithoutFullAccessStayInTheExtensionsDefaults() throws {
        let standard = UserDefaults.standard, old = standard.stringArray(forKey: EmojiRecents.key)
        addTeardownBlock { standard.set(old, forKey: EmojiRecents.key) }
        standard.removeObject(forKey: EmojiRecents.key)
        let (kb, bar, doc, view) = rig()
        kb.fullAccess = false
        try pickEmoji(bar)
        let picker = try XCTUnwrap(kb.emojiPicker)
        picker.collectionView(picker.grid, didSelectItemAt: IndexPath(item: 0, section: 1))
        let e = EmojiPicker.frequent[0]
        XCTAssertEqual(doc.text, e)
        XCTAssertEqual(standard.stringArray(forKey: EmojiRecents.key), [e])
        XCTAssertNil(defaults.stringArray(forKey: EmojiRecents.key), "not the group")
        kb.showEmoji(false)
        kb.showEmoji(true)
        XCTAssertEqual(picker.sections[0], [e], "read back from there")

        kb.fullAccess = true
        kb.showEmoji(true)
        XCTAssertEqual(picker.sections[0], [], "the group's own")
        picker.collectionView(picker.grid, didSelectItemAt: IndexPath(item: 1, section: 1))
        XCTAssertEqual(defaults.stringArray(forKey: EmojiRecents.key), [EmojiPicker.frequent[1]])
        withExtendedLifetime(view) {}
    }
}
