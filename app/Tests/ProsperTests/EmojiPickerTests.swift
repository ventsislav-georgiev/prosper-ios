import XCTest
import UIKit
@testable import Prosper

/// The emoji key and its picker (#515): the key among Keys Beside Space, the picker in
/// place of the caps, what it types, its recents and its data.
@MainActor
final class EmojiPickerTests: XCTestCase {

    private final class SpyInput: NSObject, UIKeyInput {
        var calls: [String] = []
        var hasText: Bool { true }
        func insertText(_ text: String) { calls.append(text) }
        func deleteBackward() { calls.append("⌫") }
    }

    private var suite = ""
    private var defaults: UserDefaults!
    private var store = KeyboardSettings.store

    /// Recents go to a suite of the test's own.
    override func setUp() {
        super.setUp()
        suite = "EmojiPickerTests.\(UUID().uuidString)"
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

    private func laidOut(_ kb: TerminalKeyboard = TerminalKeyboard()) -> [String: UIButton] {
        kb.frame = CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.height)
        kb.layoutIfNeeded()
        var caps: [String: UIButton] = [:]
        for case let b as UIButton in kb.subviews { caps[b.accessibilityLabel ?? ""] = b }
        return caps
    }

    private func tap(_ kb: TerminalKeyboard, _ cap: UIButton?, id: Int = 1) throws {
        let f = try XCTUnwrap(cap).frame
        kb.track(.began, id: id, at: CGPoint(x: f.midX, y: f.midY))
        kb.track(.ended, id: id, at: CGPoint(x: f.midX, y: f.midY))
    }

    private func button(_ picker: EmojiPicker, _ label: String) throws -> UIButton {
        func all(_ v: UIView) -> [UIView] { [v] + v.subviews.flatMap(all) }
        return try XCTUnwrap(all(picker).compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }, label)
    }

    /// Types `e` as its cell would.
    private func pick(_ picker: EmojiPicker, _ e: String) throws {
        let section = try XCTUnwrap(picker.sections.firstIndex { $0.contains(e) }, e)
        let item = try XCTUnwrap(picker.sections[section].firstIndex(of: e))
        picker.collectionView(picker.grid, didSelectItemAt: IndexPath(item: item, section: section))
    }

    // MARK: The key

    /// On by default, last before return; an order or hidden set stored before #515 still
    /// shows it, at the end; hiding it works like the other keys.
    func testEmojiKeyIsAKeyBesideSpace() {
        var s = KeyboardSettings()
        XCTAssertEqual(s.bottomRow, [.char("."), .char(","), .char("/"), .space, .char("?"), .emoji, .ret])
        s.bottomOrder = ".,? /"
        XCTAssertEqual(s.bottomRow, [.char("."), .char(","), .char("?"), .space, .char("/"), .emoji, .ret],
                       "a stored order gets it appended")
        s.bottomHidden = "?"
        XCTAssertEqual(s.bottomRow, [.char("."), .char(","), .space, .char("/"), .emoji, .ret],
                       "a stored hidden set without it still shows it")
        s.bottomHidden = "?" + String(KeyboardSettings.emojiKey)
        XCTAssertEqual(s.bottomRow, [.char("."), .char(","), .space, .char("/"), .ret], "hidden")
        s.bottomOrder = String(KeyboardSettings.emojiKey) + ".,? /"
        s.bottomHidden = ""
        XCTAssertEqual(s.bottomRow.first, .emoji, "dragged first")
        defaults.set("/ ?.,", forKey: KeyboardSettings.Key.bottomOrder)
        XCTAssertEqual(KeyboardSettings(defaults).bottomRow,
                       [.char("/"), .space, .char("?"), .char("."), .char(","), .emoji, .ret], "read back")
    }

    /// The extension's emoji key opens the keyboard list, like the globe: its cap takes
    /// its own touches, the tracker never yields it, and it never opens the picker; where
    /// the globe shows, it gives way. The app's opens the picker.
    func testOnlyTheAppsEmojiKeyPicks() throws {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        kb.picksEmoji = false
        let caps = laidOut(kb)
        let key = try XCTUnwrap(caps["emoji"], "kept where the setting has it")
        XCTAssertTrue(key.isUserInteractionEnabled, "it takes its own touches")
        XCTAssertEqual(key.actions(forTarget: nil, forControlEvent: .touchDown),
                       ["handleInputModeListFromView:withEvent:"])
        XCTAssertFalse(TerminalKeyboard.feeds(kb.hitTest(CGPoint(x: key.frame.midX, y: key.frame.midY), with: nil)))
        XCTAssertNotNil(key.accessibilityHint)
        // A touch in the gap beside it goes to the key before, never to it.
        let p = CGPoint(x: key.frame.minX - 1, y: key.frame.midY)   // nearer emoji than ?
        kb.track(.began, id: 1, at: p)
        kb.track(.ended, id: 1, at: p)
        XCTAssertEqual(spy.calls, ["?"])
        kb.press(.emoji)
        XCTAssertNil(kb.emojiPicker, "no picker in the extension")
        kb.showsGlobe = true
        XCTAssertNil(laidOut(kb)["emoji"], "the globe does the same")
        XCTAssertTrue(kb.settings.bottomRow.contains(.emoji), "the setting still has it")
        kb.showsGlobe = false
        kb.picksEmoji = true
        let apps = try XCTUnwrap(laidOut(kb)["emoji"])
        XCTAssertFalse(apps.isUserInteractionEnabled, "the app's is the tracker's")
        XCTAssertNil(apps.accessibilityHint)
        try tap(kb, apps)
        XCTAssertTrue(kb.showsEmoji, "the app's opens the picker")
    }

    /// The key opens the picker at the caps' height and hides them; ABC brings them back.
    func testEmojiKeyShowsThePickerAndABCReturns() throws {
        let kb = TerminalKeyboard()
        let caps = laidOut(kb)
        let key = try XCTUnwrap(caps["emoji"])
        XCTAssertEqual(key.frame.width, try XCTUnwrap(caps["?"]).frame.width, accuracy: 0.001, "one unit")
        XCTAssertNil(kb.emojiPicker, "built on first use")
        try tap(kb, key)
        kb.layoutIfNeeded()
        let picker = try XCTUnwrap(kb.emojiPicker)
        XCTAssertTrue(kb.showsEmoji)
        XCTAssertEqual(picker.frame.height, TerminalKeyboard.keysHeight)
        let height = try XCTUnwrap(kb.constraints.first { $0.firstItem === kb && $0.firstAttribute == .height })
        XCTAssertEqual(height.constant, TerminalKeyboard.height, "no new height")
        XCTAssertTrue(caps.values.allSatisfy(\.isHidden))
        try button(picker, "letters").sendActions(for: .touchUpInside)
        XCTAssertFalse(kb.showsEmoji)
        XCTAssertTrue(picker.isHidden)
        XCTAssertTrue(caps.values.allSatisfy { !$0.isHidden })
    }

    /// A settings change rebuilding the caps under the open picker keeps them hidden.
    func testNewBottomRowUnderThePickerStaysHidden() throws {
        let kb = TerminalKeyboard()
        _ = laidOut(kb)
        kb.showEmoji(true)
        var s = KeyboardSettings()
        s.bottomHidden = "?"
        kb.settings = s
        let caps = laidOut(kb)
        XCTAssertNil(caps["?"], "rebuilt")
        XCTAssertFalse(caps.isEmpty)
        XCTAssertTrue(caps.values.allSatisfy(\.isHidden))
    }

    /// Delete held, the emoji key under a second finger: the picker opens, the delete's lift
    /// never reaches the tracker, and still the repeat stops.
    func testOpeningThePickerStopsADeleteRepeat() throws {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        let caps = laidOut(kb)
        let delete = try XCTUnwrap(caps["delete"]).frame
        kb.track(.began, id: 1, at: CGPoint(x: delete.midX, y: delete.midY))
        try tap(kb, caps["emoji"], id: 2)
        XCTAssertTrue(kb.showsEmoji)
        let typed = spy.calls
        kb.track(.ended, id: 1, at: CGPoint(x: delete.midX, y: delete.midY))
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(spy.calls, typed, "no repeat past the picker opening")
    }

    /// While the picker shows, a touch where a letter was types nothing; back on the caps
    /// it types again.
    func testPickerTouchesNeverReachTheCaps() throws {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        let caps = laidOut(kb)
        try tap(kb, caps["emoji"])
        try tap(kb, caps["q"], id: 2)
        try tap(kb, caps["space"], id: 3)
        XCTAssertEqual(spy.calls, [], "the hidden caps type nothing")
        kb.showEmoji(false)
        try tap(kb, caps["q"], id: 4)
        XCTAssertEqual(spy.calls, ["q"])
    }

    // MARK: Typing

    /// A cell types its emoji the way a character key does, and delete deletes.
    func testCellTypesAndDeleteDeletes() throws {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        _ = laidOut(kb)
        kb.showEmoji(true)
        let picker = try XCTUnwrap(kb.emojiPicker)
        try pick(picker, "😀")
        try pick(picker, "👨‍👩‍👧")
        try button(picker, "delete").sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.calls, ["😀", "👨‍👩‍👧", "⌫"])
        XCTAssertEqual(defaults.stringArray(forKey: EmojiRecents.key), ["👨‍👩‍👧", "😀"], "stored newest first")
        XCTAssertEqual(picker.sections[0], [], "the grid doesn't reorder under the finger")
        kb.showEmoji(false)
        kb.showEmoji(true)
        XCTAssertEqual(picker.sections[0], ["👨‍👩‍👧", "😀"], "recents on the next open")
        kb.layoutIfNeeded()
        picker.grid.layoutIfNeeded()
        let cell = try XCTUnwrap(picker.grid.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(cell.accessibilityLabel, "👨‍👩‍👧", "the emoji itself: VoiceOver speaks its name")
        XCTAssertTrue(cell.accessibilityTraits.contains(.keyboardKey))
    }

    /// In the terminal, a double space after an emoji is two spaces, even after one Swift
    /// calls a digit (1️⃣) or a letter (Ⓜ️); after a letter it's still the mark.
    func testDoubleSpaceAfterAnEmojiSendsNoMark() throws {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        var sent: [[UInt8]] = []
        kb.sendBytes = { sent.append($0) }
        kb.showEmoji(true)
        let picker = try XCTUnwrap(kb.emojiPicker)
        for e in ["1️⃣", "Ⓜ️", "😀"] {
            kb.showEmoji(true)
            try pick(picker, e)
            kb.showEmoji(false)
            kb.press(.space)
            kb.press(.space)
        }
        XCTAssertEqual(sent, [])
        XCTAssertEqual(spy.calls, ["1️⃣", " ", " ", "Ⓜ️", " ", " ", "😀", " ", " "])
        kb.press(.char("a")); kb.press(.space); kb.press(.space)
        XCTAssertEqual(sent, [[0x7f] + Array(". ".utf8)], "a letter still gets it")
    }

    /// ABC fits its bar key, on the narrowest iPhone, by shrinking.
    func testABCFitsItsKey() throws {
        let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 375, height: TerminalKeyboard.keysHeight))
        picker.layoutIfNeeded()
        let abc = try button(picker, "letters")
        abc.layoutIfNeeded()
        let label = try XCTUnwrap(abc.titleLabel)
        XCTAssertTrue(label.adjustsFontSizeToFitWidth)
        let smallest = label.font.withSize(label.font.pointSize * label.minimumScaleFactor)
        XCTAssertLessThan(("ABC" as NSString).size(withAttributes: [.font: smallest]).width, abc.bounds.width)
        XCTAssertGreaterThanOrEqual(smallest.pointSize, 9, "legible")
    }

    // MARK: Recents and data

    func testRecentsNewestFirstOnceAndCapped() {
        var r = EmojiRecents()
        r.add("😀"); r.add("🐶"); r.add("😀")
        XCTAssertEqual(r.emoji, ["😀", "🐶"], "newest first, once")
        let many = EmojiPicker.groups[3].prefix(40).map { $0 }
        for e in many { r.add(e) }
        XCTAssertEqual(r.emoji.count, EmojiRecents.limit)
        XCTAssertEqual(EmojiRecents.limit, 32)
        XCTAssertEqual(r.emoji, Array(many.reversed().prefix(32)), "the oldest dropped")
        XCTAssertEqual(EmojiRecents(many).emoji.count, 32, "a longer stored list is cut")
    }

    /// Nine groups, none empty; every entry one Character, none twice, no skin tones; a
    /// bar icon for Recents and each group.
    func testDataIsSane() {
        XCTAssertEqual(EmojiData.groups.map(\.name), ["Smileys & Emotion", "People & Body", "Animals & Nature",
                                                     "Food & Drink", "Travel & Places", "Activities", "Objects",
                                                     "Symbols", "Flags"])
        let all = EmojiPicker.groups.joined()
        XCTAssertTrue(EmojiPicker.groups.allSatisfy { !$0.isEmpty })
        XCTAssertGreaterThan(all.count, 1500)
        XCTAssertEqual(all.filter { $0.count != 1 }, [], "one Character each")
        XCTAssertEqual(Set(all).count, all.count, "no duplicates")
        XCTAssertEqual(all.filter { $0.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } }, [],
                       "no skin tones")
        XCTAssertEqual(EmojiPicker.symbols.count, EmojiData.groups.count + 1)
        for s in EmojiPicker.symbols + ["face.smiling"] { XCTAssertNotNil(UIImage(systemName: s), s) }
    }
}
