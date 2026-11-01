import XCTest
import UIKit
import CoreText
import Accelerate
import CryptoKit
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

    /// The extension's keyboard has no emoji key, globe or not, though the setting keeps
    /// it: the app's has, and it opens the picker.
    func testOnlyTheAppsKeyboardOffersEmoji() throws {
        let kb = TerminalKeyboard()
        kb.offersEmoji = false
        for globe in [false, true] {
            kb.showsGlobe = globe
            XCTAssertNil(laidOut(kb)["emoji"], "globe \(globe)")
        }
        XCTAssertTrue(kb.settings.bottomRow.contains(.emoji), "the setting still has it")
        kb.showsGlobe = false
        kb.offersEmoji = true
        let key = try XCTUnwrap(laidOut(kb)["emoji"], "the app's")
        try tap(kb, key)
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
    /// calls a digit (1️⃣) or a letter (Ⓜ️).
    func testTwoSpacesAfterAnEmojiAreTwoSpaces() throws {
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

    /// The group the bar lights.
    private func lit(_ picker: EmojiPicker) throws -> String? {
        let accent = TerminalKeyboard.Style.accent
        return try (["Recents"] + EmojiPicker.native.map(\.name)).filter { try button(picker, $0).tintColor == accent }.first
    }

    /// The bar lights the group at the grid's left edge as it scrolls, both ways; a tap
    /// scrolls to its group and lights it (#664).
    func testTheBarFollowsTheScroll() throws {
        defaults.set(["😀"], forKey: EmojiRecents.key)
        let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.keysHeight))
        picker.layoutIfNeeded()
        XCTAssertEqual(try lit(picker), "Recents")
        try button(picker, "Food & Drink").sendActions(for: .touchUpInside)
        let food = picker.grid.contentOffset.x
        XCTAssertGreaterThan(food, 0)
        XCTAssertEqual(try lit(picker), "Food & Drink")
        picker.grid.contentOffset.x = food - 10
        XCTAssertEqual(try lit(picker), "Animals & Nature", "scrolled back a column")
        picker.grid.contentOffset.x = food + 10
        XCTAssertEqual(try lit(picker), "Food & Drink")
        picker.grid.contentOffset.x = picker.grid.contentSize.width - picker.grid.bounds.width
        XCTAssertEqual(try lit(picker), "Flags", "the end")
        picker.grid.contentOffset.x = 0
        XCTAssertEqual(try lit(picker), "Recents", "back to the start")
        defaults.removeObject(forKey: EmojiRecents.key)
        picker.reload()
        picker.grid.layoutIfNeeded()
        picker.grid.contentOffset.x = 1
        XCTAssertEqual(try lit(picker), "Smileys & People", "no recents: the first group")
    }

    // MARK: Memory

    /// The process's footprint in MB, what jetsam measures against a keyboard's limit.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// Scrolled through every group, each page's cells shown at 3x, the picker grows the
    /// footprint by under 15 MB (#664): its share of a system keyboard's limit, ~48 MB on
    /// older iPhones, over the ~27 MB the letters take. One font for them all took 96.
    func testEveryGroupDrawsWithinTheMemoryBudget() throws {
        let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.keysHeight))
        let window = UIWindow(frame: picker.frame)
        window.addSubview(picker)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        picker.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        var seen = Set<String>()
        func drawPage() {
            picker.grid.layoutIfNeeded()
            for cell in picker.grid.visibleCells {
                seen.insert(cell.accessibilityLabel ?? "")
                _ = UIGraphicsImageRenderer(size: cell.bounds.size, format: format).image { cell.layer.render(in: $0.cgContext) }
            }
        }
        drawPage()
        let before = Self.footprint()
        var peak = 0.0
        for x in stride(from: 0, to: picker.grid.contentSize.width, by: picker.grid.bounds.width / 2) {
            picker.grid.contentOffset.x = x
            autoreleasepool { drawPage() }
            peak = max(peak, Self.footprint() - before)
        }
        XCTAssertEqual(seen.subtracting(EmojiPicker.groups.joined()), [], "only emoji")
        XCTAssertEqual(Set(EmojiPicker.groups.joined()).subtracting(seen), [], "every group drawn")
        print("#664 groups: peak \(peak) MB")
        XCTAssertLessThan(peak, 15)
    }

    /// Every emoji's image holds all its ink, not only its advance's width: 🫡 inks past
    /// its right side and was drawn cut off (#673). Its ink summed over the image's pixels
    /// against the same line drawn in a roomy canvas. A fresh font per group, as the picker renews.
    func testNoEmojiIsClipped() throws {
        func ink(_ image: UIImage) -> Int {   // its pixels' alpha, summed, in 8-bit RGBA whatever it was drawn in
            guard let cg = image.cgImage, let c = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = c.data
            else { XCTFail("no bitmap"); return 0 }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            var alpha = [Float](repeating: 0, count: cg.width * cg.height), sum: Float = 0
            vDSP_vfltu8(bytes.assumingMemoryBound(to: UInt8.self) + 3, 4, &alpha, 1, vDSP_Length(alpha.count))
            vDSP_sve(alpha, 1, &sum, vDSP_Length(alpha.count))
            return Int(sum)
        }
        var clipped: [String] = []
        for group in EmojiPicker.groups + [Self.tonedForms] {   // the strip's tones too (#667)
            let font = try XCTUnwrap(EmojiPicker.emojiFont(size: 30))
            for e in group {
                let drawn = EmojiPicker.image(e, font: font)
                let format = UIGraphicsImageRendererFormat()
                format.scale = drawn.scale
                let roomy = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 90), format: format).image { c in
                    c.cgContext.translateBy(x: 30, y: 60)
                    c.cgContext.scaleBy(x: 1, y: -1)
                    c.cgContext.textPosition = .zero
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: e, attributes: [.font: font])), c.cgContext)
                }
                let all = ink(roomy)
                if all - ink(drawn) > all / 100 { clipped.append(e) }
            }
        }
        XCTAssertEqual(clipped, [], "\(clipped.count) clipped")
    }

    /// Every emoji's runs are Apple Color Emoji's, the private instance's glyphs the shared
    /// one's; and a glyph that is an outline, not a bitmap (♀️ ♂️ ⚕️), is drawn in the label's
    /// colour, as the system keyboard's, on dark keys and light: it was black on the dark (#676).
    func testEveryEmojiDrawsInAppleColorEmojiAndOutlinesInTheLabelsColour() throws {
        let palette = TerminalKeyboard.Style.palette
        addTeardownBlock { TerminalKeyboard.Style.palette = palette }
        let shared = CTFontCreateWithName("AppleColorEmoji" as CFString, 30, nil)
        func runs(_ e: String, _ font: CTFont) -> [(font: String, glyphs: [CGGlyph])] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: e, attributes: [.font: font]))
            return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map { run in
                let used = (CTRunGetAttributes(run) as? [NSAttributedString.Key: Any])?[.font] as! CTFont
                var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(), &g)
                return (CTFontCopyPostScriptName(used) as String, g)
            }
        }
        /// Whether every opaque pixel is `colour`, within 8 a channel of 255, and there is one.
        func inked(_ image: UIImage, in colour: UIColor) -> Bool {
            guard let cg = image.cgImage, let c = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let bytes = c.data
            else { XCTFail("no bitmap"); return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            colour.getRed(&r, green: &g, blue: &b, alpha: nil)
            let want = [r, g, b].map { Int(($0 * 255).rounded()) }
            let p = bytes.assumingMemoryBound(to: UInt8.self)
            let opaque = stride(from: 0, to: cg.width * cg.height * 4, by: 4).filter { p[$0 + 3] == 255 }
            return !opaque.isEmpty && opaque.allSatisfy { i in (0..<3).allSatisfy { abs(Int(p[i + $0]) - want[$0]) <= 8 } }
        }
        var notColourEmoji: [String] = [], outlines: [String] = []
        for group in EmojiPicker.groups + [Self.tonedForms] {   // the strip's tones too (#667)
            let font = try XCTUnwrap(EmojiPicker.emojiFont(size: 30)) as CTFont
            for e in group {
                let own = runs(e, font)
                if own.map(\.font) != own.map({ _ in "AppleColorEmoji" }) || own.map(\.glyphs) != runs(e, shared).map(\.glyphs) {
                    notColourEmoji.append(e)
                }
                if own.flatMap(\.glyphs).contains(where: { CTFontCreatePathForGlyph(font, $0, nil) != nil }) { outlines.append(e) }
            }
        }
        XCTAssertEqual(notColourEmoji, [], "\(notColourEmoji.count) not Apple Color Emoji's glyph")
        let font = try XCTUnwrap(EmojiPicker.emojiFont(size: 30))
        for (name, p) in [("dark", TerminalKeyboard.Style.Palette.dark), ("light", .light)] {
            TerminalKeyboard.Style.palette = p
            let wrong = outlines.filter { !inked(EmojiPicker.image($0, font: font), in: p.label) }
            XCTAssertEqual(wrong, [], "\(wrong.count) outlines not in the \(name) label's colour")
        }
    }

    // MARK: Search (#666)

    /// Each character's key in filter mode tapped.
    private func type(_ text: String, _ filter: PanelFilter) throws {
        for c in text {
            let key = try XCTUnwrap(filter.rows.joined().first { $0.configuration?.title == String(c) }, "no \(c) key")
            key.sendActions(for: .touchUpInside)
        }
    }

    /// The name, then a name's prefix, then an exact keyword, then a keyword's prefix, then a
    /// name's word: "pie" is 🥧's name and keyword,
    /// starts 🥟's "pierogi" and 🧩's "piece", and is a word of 🇵🇲's name only. Folded as the
    /// query is; ties recents first, the more used next (#684), then in the order given. The Bulgarian keys match
    /// Bulgarian's words and English's; the English keys English's only.
    func testSearchRanksAnExactKeywordThenAPrefixThenANameWord() {
        let all = Array(EmojiPicker.groups.joined())
        let en = EmojiKeywords(.english), bg = EmojiKeywords(.bulgarian)
        func ranked(_ q: String, _ words: EmojiKeywords) -> [String] { words.rank(q, all).map { all[$0] } }
        XCTAssertEqual(ranked("pie", en), ["🥧", "🥟", "🧩", "🇵🇲"])
        XCTAssertEqual(en.rank("pie", ["🧩", "🇵🇲", "🥟", "🥧"]), [3, 0, 2, 1], "ties keep the order given")
        XCTAssertEqual(ranked("PIÉ", en), ranked("pie", en), "case- and diacritic-insensitive")
        XCTAssertEqual(en.rank("", all), Array(all.indices), "a blank query keeps every emoji")
        XCTAssertEqual(en.rank("  ", all), Array(all.indices))
        XCTAssertEqual(ranked("qzx", en), [])
        XCTAssertEqual(ranked("ден", en), [], "no Bulgarian on the English keys")

        // "ден" (day) is 🌞's keyword, starts 🏪's "денонощен" (the more used, #684), 🧖's "ден за спа",
        // 🦃's "денят на благодарността" and 🪥's "дентален", and is a word of 🎂's name only.
        XCTAssertEqual(ranked("ден", bg), ["🌞", "🏪", "🧖", "🦃", "🪥", "🎂"])
        XCTAssertEqual(ranked("ДЕН", bg), ranked("ден", bg))
        XCTAssertEqual(ranked("пуйка", bg).first, "🦃", "й folded as CLDR's is")
        XCTAssertEqual(ranked("pie", bg), ranked("pie", en), "English's too")
        XCTAssertEqual(ranked("балон", bg).first, "🎈")
        XCTAssertEqual(ranked("балон", bg).last, "🐡", "риба балон: a name's word only")

        // #679: the name itself, then the name's first words, shorter first, then the keywords:
        // 🐈 is "cat", 🐱 "cat face", 😼 "cat with wry smile", 😹 "cat with tears of joy",
        // and the other cat faces have "cat" as a keyword only, 😻 the most used (#684).
        XCTAssertEqual(Array(ranked("cat", en).prefix(5)), ["🐈", "🐱", "😼", "😹", "😻"])
        XCTAssertEqual(ranked("Cat", bg).prefix(4), ranked("cat", en).prefix(4))
        // A whole word only: "car" is 🚗's keyword and only starts 🥕's "carrot", a name's word.
        let car = ranked("car", en)
        XCTAssertLessThan(car.firstIndex(of: "🚗") ?? .max, car.firstIndex(of: "🥕") ?? .max)
        // #684: 🚗 🚃 🚞 🚋 🚓 🚔 🚕 all have "car" as a keyword, nothing else between them: the
        // most used first. "star": ✨ and 🌟 before 🤩 and 🧑‍🎤, newer than the counts.
        XCTAssertEqual(car.first, "🚗")
        XCTAssertEqual(Array(ranked("star", en).prefix(5)), ["⭐", "✡️", "☪️", "✨", "🌟"])
        XCTAssertEqual(en.rank("car", ["🚓"] + all, recents: 1).first, 0, "recents before the more used")
        // 🐈 is "котка", 🐱 "муцуна на котка" with "котка" a keyword; ☀️ is "слънце", then
        // 🌞 "слънце с лице" before ⛅ "слънце зад облак", the shorter first.
        XCTAssertEqual(ranked("котка", bg).first, "🐈")
        // #683: among the keyword ties, 🐱 says "котка" twice (the keyword and its name), the cat
        // faces once, then 😻 the most used (#684).
        XCTAssertEqual(Array(ranked("котка", bg).prefix(3)), ["🐈", "🐱", "😻"])
        XCTAssertEqual(Array(ranked("слънце", bg).prefix(3)), ["☀️", "🌞", "⛅"])
    }

    /// The app's keyboard: the search row over the grid opens filter mode over the picker,
    /// its keys typing into the query, never into the terminal, two rows of results drawn as
    /// cells. A result, tapped or by return, types as a cell does and goes first in recents;
    /// Done gives the grid back and drops the words, parsed only while it searched.
    func testTheAppsSearchTypesAPickAndAddsItToRecents() throws {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        _ = laidOut(kb)
        kb.showEmoji(true)
        kb.layoutIfNeeded()
        let picker = try XCTUnwrap(kb.emojiPicker)
        XCTAssertNil(picker.keywords, "nothing parsed till a search opens")
        XCTAssertGreaterThanOrEqual(picker.grid.frame.minY, picker.searchRow.frame.maxY, "the search row over the grid")
        XCTAssertEqual(picker.searchRow.accessibilityLabel, "Describe an emoji")

        picker.searchRow.sendActions(for: .touchUpInside)
        let filter = try XCTUnwrap(picker.filter)
        XCTAssertNotNil(picker.keywords)
        XCTAssertTrue(kb.searchesEmoji)
        XCTAssertTrue(filter.superview === picker)
        XCTAssertEqual(filter.frame, picker.bounds)
        filter.layoutIfNeeded()
        let results = try XCTUnwrap(filter.grid)
        XCTAssertTrue(filter.results.isHidden, "a grid in the table's place")
        XCTAssertEqual(filter.shown, 2)
        XCTAssertGreaterThanOrEqual(results.frame.height, 2 * PanelFilter.rowHeight)
        XCTAssertLessThanOrEqual(filter.contentSize.height, filter.bounds.height + 0.5, "no scroll")
        XCTAssertEqual(filter.matches.count, Set(picker.sections.joined()).count, "every emoji before a key")

        try type("pie", filter)
        XCTAssertEqual(spy.calls, [], "no key reaches the terminal")
        XCTAssertEqual(filter.matches.map { filter.fields[$0][0] }, ["🥧", "🥟", "🧩", "🇵🇲"])
        results.layoutIfNeeded()
        let cell = try XCTUnwrap(results.cellForItem(at: IndexPath(item: 1, section: 0)))
        XCTAssertEqual(cell.accessibilityLabel, "🥟")
        XCTAssertGreaterThanOrEqual(cell.frame.maxY, PanelFilter.rowHeight * 2 - 0.5, "two rows")

        picker.collectionView(results, didSelectItemAt: IndexPath(item: 1, section: 0))
        XCTAssertEqual(spy.calls, ["🥟"])
        XCTAssertEqual(defaults.stringArray(forKey: EmojiRecents.key), ["🥟"], "in recents")
        filter.go.sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.calls, ["🥟", "🥧"], "return types the first")
        XCTAssertEqual(defaults.stringArray(forKey: EmojiRecents.key), ["🥧", "🥟"])
        XCTAssertTrue(picker.filter === filter, "a pick keeps the search")

        filter.done.sendActions(for: .touchUpInside)
        XCTAssertNil(picker.filter)
        XCTAssertNil(filter.superview)
        XCTAssertNil(picker.keywords, "dropped")
        XCTAssertTrue(kb.showsEmoji, "the grid back")
        kb.showEmoji(false)
        kb.showEmoji(true)
        XCTAssertEqual(picker.sections[0], ["🥧", "🥟"], "recents on the next open")

        picker.search(true)
        kb.showEmoji(false)
        XCTAssertNil(picker.filter, "ABC's way out closes it too")
    }

    /// The user's recents lead their ties, before the more used (#684): "car" gives 🚓 once
    /// typed, 🚗 with no recents.
    func testSearchRecentsLeadTheirTies() throws {
        func first(_ recents: [String]) throws -> String? {
            defaults.set(recents, forKey: EmojiRecents.key)
            let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.keysHeight))
            picker.search(true)
            let filter = try XCTUnwrap(picker.filter)
            filter.type("car")
            return filter.matches.first.map { filter.fields[$0][0] }
        }
        XCTAssertEqual(try first(["🚓"]), "🚓")
        XCTAssertEqual(try first([]), "🚗")
    }

    /// On the Bulgarian keys the language key types English's words (#680): "pie" finds 🥧.
    func testBulgarianSearchTypesEnglishAfterTheLanguageKey() throws {
        let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.keysHeight))
        picker.layout = .bulgarian
        picker.search(true)
        let filter = try XCTUnwrap(picker.filter)
        XCTAssertNil(filter.rows.joined().first { $0.configuration?.title == "p" }, "Cyrillic keys first")
        filter.language.sendActions(for: .touchUpInside)
        try type("pie", filter)
        XCTAssertEqual(filter.matches.first.map { filter.fields[$0][0] }, "🥧")
    }

    /// The search's words parse into slices of the literals as it opens (#666): English and
    /// Bulgarian's under 1 MB of heap, the search with its keys under 3 MB of footprint. Then
    /// every page of a query matching hundreds, drawn at 3x, keeps the grid's budget: the same
    /// font under the same cap.
    func testSearchStaysWithinTheMemoryBudget() throws {
        _ = EmojiData.keywords   // the dictionary of two literals, not what this measures
        let heap = mstats().bytes_used
        let both = EmojiKeywords(.bulgarian)
        let words = Double(mstats().bytes_used - heap) / 1_048_576
        withExtendedLifetime(both) {}
        XCTAssertLessThan(words, 1)

        let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.keysHeight))
        picker.layout = .bulgarian
        let window = UIWindow(frame: picker.frame)
        window.addSubview(picker)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        picker.layoutIfNeeded()
        let before = Self.footprint()
        let start = Date()
        picker.search(true)
        let parse = Date().timeIntervalSince(start)
        let opened = Self.footprint() - before
        print("#666 words: \(words) MB of heap; search open: \(opened) MB, \(Int(parse * 1000)) ms")
        XCTAssertLessThan(opened, 3)

        let filter = try XCTUnwrap(picker.filter)
        filter.type("a")
        XCTAssertGreaterThan(filter.matches.count, 300)
        filter.layoutIfNeeded()
        let results = try XCTUnwrap(filter.grid)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        var seen = Set<String>()
        func drawPage() {
            results.layoutIfNeeded()
            for cell in results.visibleCells {
                seen.insert(cell.accessibilityLabel ?? "")
                _ = UIGraphicsImageRenderer(size: cell.bounds.size, format: format).image { cell.layer.render(in: $0.cgContext) }
            }
        }
        drawPage()
        let shown = Self.footprint()   // as the grid's budget: past the first page
        var peak = 0.0
        for x in stride(from: 0, to: results.contentSize.width, by: results.bounds.width / 2) {
            results.contentOffset.x = x
            autoreleasepool { drawPage() }
            peak = max(peak, Self.footprint() - shown)
        }
        print("#666 results: \(seen.count) drawn, peak \(peak) MB")
        XCTAssertEqual(seen.count, filter.matches.count, "every result drawn")
        XCTAssertLessThan(peak, 15)
    }

    // MARK: Skin tones (#667)

    /// Each tone-taking emoji's five tones, light to dark.
    static let tonedForms = EmojiPicker.toneable.values.sorted().flatMap { b in (1...5).map { EmojiPicker.toned(b, $0) } }

    /// `e`'s cell in the groups (not Recents) scrolled into view, and its centre in the picker's coordinates.
    private func centre(_ picker: EmojiPicker, _ e: String) throws -> (IndexPath, CGPoint) {
        let s = try XCTUnwrap(picker.sections.indices.dropFirst().first { picker.sections[$0].contains(e) }, e)
        let ip = IndexPath(item: try XCTUnwrap(picker.sections[s].firstIndex(of: e)), section: s)
        picker.grid.layoutIfNeeded()
        picker.grid.scrollToItem(at: ip, at: .centeredHorizontally, animated: false)
        picker.grid.layoutIfNeeded()
        let f = try XCTUnwrap(picker.grid.layoutAttributesForItem(at: ip)).frame
        return (ip, picker.grid.convert(CGPoint(x: f.midX, y: f.midY), to: picker))
    }

    /// The centre of the strip's item `t` (0 the default), in the picker's coordinates.
    private func item(_ picker: EmojiPicker, _ t: Int) throws -> CGPoint {
        let b = try XCTUnwrap(picker.toneStrip?.subviews[t])
        return b.convert(CGPoint(x: b.bounds.midX, y: b.bounds.midY), to: picker)
    }

    /// The generator marks the emoji taking a tone: 👍 and 🤝 do, 😀 doesn't, and the
    /// multi-person ones take one tone for everyone. Each one's five, derived here, are the
    /// uniform toned forms emoji-test.txt has fully-qualified (the generator hashed those),
    /// and every one offered this iOS draws as one glyph.
    func testToneData() {
        let base = EmojiPicker.toneBase
        XCTAssertEqual(base("👍"), "👍")
        XCTAssertEqual(base("🤝"), "🤝")
        XCTAssertNil(base("😀"))
        XCTAssertNil(base("❤️"))
        XCTAssertNil(base("👪"), "a family takes no tone")
        for e in ["🧑‍🤝‍🧑", "👫", "💏", "👩‍❤️‍👨", "🧑‍⚕️", "⛹️‍♀️", "☝️"] { XCTAssertEqual(base(e), e) }
        XCTAssertEqual(base("👍🏽"), "👍", "a toned recent's base")
        XCTAssertEqual(base("\u{261D}\u{1F3FB}"), "☝️", "its U+FE0F back")
        XCTAssertEqual(EmojiPicker.toned("👍", 0), "👍")
        XCTAssertEqual(EmojiPicker.toned("👍", 3), "👍🏽")
        XCTAssertEqual(EmojiPicker.toned("☝️", 1), "\u{261D}\u{1F3FB}", "U+FE0F dropped")
        XCTAssertEqual(EmojiPicker.toned("⛹️‍♀️", 2), "\u{26F9}\u{1F3FC}\u{200D}\u{2640}\u{FE0F}")
        XCTAssertEqual(EmojiPicker.toned("🧑‍🤝‍🧑", 5), "🧑🏿‍🤝‍🧑🏿", "every person")
        XCTAssertEqual(EmojiPicker.toned("🤝", 4), "🤝🏾")

        let all = (EmojiData.toned.split(whereSeparator: \.isWhitespace) + EmojiData.newerToned.flatMap { $0.emoji.split(separator: " ") }).map(String.init)
        XCTAssertGreaterThan(all.count, 300)
        let forms = all.flatMap { b in (1...5).map { EmojiPicker.toned(b, $0) } }
        let hash = SHA256.hash(data: Data(forms.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, EmojiData.tonedHash, "every base x tone is a fully-qualified emoji-test.txt sequence")
        XCTAssertEqual(Set(forms).count, forms.count)
        // Drawn as its base is, the tone in its glyphs, not a swatch beside them: as many glyphs
        // (a couple's ZWJ forms are two halves, toned or not), none of them .notdef.
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        func glyphs(_ e: String) -> [CGGlyph] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: e, attributes: [.font: font]))
            return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).flatMap { run in
                var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(), &g)
                return g
            }
        }
        let undrawn = EmojiPicker.toneable.values.flatMap { b in (1...5).map { EmojiPicker.toned(b, $0) }.filter {
            glyphs($0).count != glyphs(b).count || glyphs($0).contains(0)
        } }
        XCTAssertEqual(undrawn, [], "this iOS draws every tone it offers")
        XCTAssertEqual(Set(EmojiPicker.toneable.values).subtracting(EmojiPicker.groups.joined()), [], "each in the grid")
        XCTAssertGreaterThan(EmojiPicker.toneable.count, 300)
    }

    /// Held, 👍 shows the default and the five tones over its cell, named; a slide to medium
    /// and the lift types 👍🏽 and remember it: the grid and search show it, a tap types it,
    /// it reads back from the store, Recents keep what was typed. A lift on the cell keeps
    /// the strip for a tap, and the default forgets the tone; a lift elsewhere closes it.
    /// 😀 takes no hold.
    func testAPickedToneIsTypedRememberedAndShown() throws {
        let kb = TerminalKeyboard()
        let spy = SpyInput()
        kb.target = spy
        _ = laidOut(kb)
        kb.showEmoji(true)
        kb.layoutIfNeeded()
        let picker = try XCTUnwrap(kb.emojiPicker)
        var (ip, p) = try centre(picker, "👍")
        XCTAssertTrue(picker.holds(at: picker.convert(p, to: picker.grid), in: picker.grid))
        picker.hold(.began, at: p, in: picker.grid)
        let strip = try XCTUnwrap(picker.toneStrip)
        XCTAssertEqual(strip.subviews.map(\.accessibilityLabel), EmojiPicker.toneNames)
        XCTAssertEqual(strip.subviews[3].accessibilityLabel, "medium skin tone")
        XCTAssertTrue(picker.bounds.contains(strip.convert(strip.bounds, to: picker)), "inside the picker")
        let medium = try item(picker, 3)
        picker.hold(.changed, at: medium, in: picker.grid)
        XCTAssertEqual(strip.subviews[3].backgroundColor, TerminalKeyboard.Style.special, "lit under the finger")
        picker.hold(.ended, at: medium, in: picker.grid)
        XCTAssertEqual(spy.calls, ["👍🏽"])
        XCTAssertNil(picker.toneStrip, "closed")
        XCTAssertEqual(defaults.dictionary(forKey: EmojiTones.key) as? [String: Int], ["👍": 3])
        XCTAssertEqual(defaults.stringArray(forKey: EmojiRecents.key), ["👍🏽"])
        picker.grid.layoutIfNeeded()
        XCTAssertEqual(picker.grid.cellForItem(at: ip)?.accessibilityLabel, "👍🏽", "the grid shows the tone")
        picker.collectionView(picker.grid, didSelectItemAt: ip)
        XCTAssertEqual(spy.calls.last, "👍🏽", "a tap types it")

        picker.search(true)
        let filter = try XCTUnwrap(picker.filter)
        filter.type("+1")
        filter.layoutIfNeeded()
        let results = try XCTUnwrap(filter.grid)
        results.layoutIfNeeded()
        XCTAssertEqual(results.cellForItem(at: IndexPath(item: 0, section: 0))?.accessibilityLabel, "👍🏽", "search shows it")
        picker.search(false)

        XCTAssertEqual(EmojiTones.load().apply("👍"), "👍🏽", "read back")
        kb.showEmoji(false)
        kb.showEmoji(true)
        XCTAssertEqual(picker.sections[0], ["👍🏽"], "Recents as typed")
        XCTAssertEqual(picker.emoji(picker.grid, ip), "👍🏽", "remembered on the next open")

        (ip, p) = try centre(picker, "👍")
        picker.hold(.began, at: p, in: picker.grid)
        picker.hold(.ended, at: p, in: picker.grid)
        let kept = try XCTUnwrap(picker.toneStrip?.subviews[0] as? UIButton, "a lift on the cell keeps it")
        kept.sendActions(for: .touchUpInside)
        XCTAssertEqual(spy.calls.last, "👍", "the default, tapped")
        XCTAssertEqual(defaults.dictionary(forKey: EmojiTones.key) as? [String: Int], [:], "forgotten")
        XCTAssertEqual(picker.emoji(picker.grid, ip), "👍")

        let typed = spy.calls
        picker.hold(.began, at: p, in: picker.grid)
        XCTAssertNotNil(picker.toneStrip)
        picker.hold(.ended, at: CGPoint(x: p.x, y: picker.bounds.maxY - 1), in: picker.grid)
        XCTAssertNil(picker.toneStrip, "a lift outside closes it")
        XCTAssertEqual(spy.calls, typed, "typing nothing")

        let (_, smile) = try centre(picker, "😀")
        XCTAssertFalse(picker.holds(at: picker.convert(smile, to: picker.grid), in: picker.grid), "😀 takes no hold")
    }

    /// In the system keyboard's picker (its Frequent page, no font of its own) without Full
    /// Access, tones are picked and remembered where Recents go then: the extension's own
    /// defaults, not the App Group.
    func testTonesWithoutFullAccessFollowRecents() throws {
        let standard = UserDefaults.standard
        let saved = [EmojiTones.key, EmojiRecents.key].map { ($0, standard.object(forKey: $0)) }
        addTeardownBlock { for (k, v) in saved { standard.set(v, forKey: k) } }
        let make = EmojiPicker.makeFont
        EmojiPicker.makeFont = { _ in nil }
        defer { EmojiPicker.makeFont = make }
        let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.keysHeight), inApp: false)
        XCTAssertFalse(picker.full, "the system keyboard's page")
        picker.fullAccess = false
        picker.reload()
        picker.layoutIfNeeded()
        var typed: [String] = []
        picker.pick = { typed.append($0) }
        let (_, p) = try centre(picker, "🤝")
        picker.hold(.began, at: p, in: picker.grid)
        picker.hold(.ended, at: try item(picker, 5), in: picker.grid)
        XCTAssertEqual(typed, ["🤝🏿"])
        XCTAssertNil(defaults.object(forKey: EmojiTones.key), "not the App Group")
        XCTAssertEqual(EmojiTones.load(fullAccess: false).apply("🤝"), "🤝🏿")
        XCTAssertEqual(standard.stringArray(forKey: EmojiRecents.key)?.first, "🤝🏿", "as Recents")
        picker.reload()
        XCTAssertEqual(picker.emoji(picker.grid, try centre(picker, "🤝").0), "🤝🏿", "Frequent shows it")
    }

    /// The strip stays inside the picker: centred over a middle cell, slid in at either
    /// edge, and under a cell with no room above it, never over the cell.
    func testToneStripStaysInsideTheBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 200), size = CGSize(width: 240, height: 40)
        func strip(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            EmojiPicker.stripFrame(over: CGRect(x: x, y: y, width: 40, height: 40), size: size, in: bounds)
        }
        XCTAssertEqual(strip(181, 100), CGRect(x: 81, y: 60, width: 240, height: 40), "centred over")
        XCTAssertEqual(strip(0, 10), CGRect(x: 0, y: 50, width: 240, height: 40), "top left, under")
        XCTAssertEqual(strip(362, 10), CGRect(x: 162, y: 50, width: 240, height: 40), "top right, under")
        XCTAssertEqual(strip(181, 40), CGRect(x: 81, y: 0, width: 240, height: 40), "just room above")
        XCTAssertEqual(strip(0, 160), CGRect(x: 0, y: 120, width: 240, height: 40), "bottom left")
        XCTAssertEqual(strip(362, 160), CGRect(x: 162, y: 120, width: 240, height: 40), "bottom right")
    }

    /// Every tone strip shown in turn, drawn at 3x, keeps the grid's budget (#664): drawn in
    /// the cells' font, under the same cap.
    func testEveryToneStripDrawsWithinTheMemoryBudget() throws {
        let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.keysHeight))
        let window = UIWindow(frame: picker.frame)
        window.addSubview(picker)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        picker.layoutIfNeeded()
        picker.grid.layoutIfNeeded()
        let attributes = try XCTUnwrap(picker.grid.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)))
        let cell = picker.grid.convert(attributes.frame, to: picker)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let before = Self.footprint()
        var peak = 0.0
        for base in EmojiPicker.toneable.values.sorted() {
            autoreleasepool {
                picker.showTones(base, over: cell)
                if let strip = picker.toneStrip {
                    _ = UIGraphicsImageRenderer(size: strip.bounds.size, format: format).image { strip.layer.render(in: $0.cgContext) }
                }
            }
            RunLoop.main.run(until: Date())   // a hold apiece: the closed strip's layers go as the transaction commits
            peak = max(peak, Self.footprint() - before)
        }
        picker.closeTones()
        print("#667 tone strips: \(EmojiPicker.toneable.count), peak \(peak) MB")
        XCTAssertLessThan(peak, 15)
    }

    /// A held cell's tones draw at its glyph's size (#687): the grid's 56 pt landscape cells,
    /// a search's 38 pt and 38x47 ones, whichever size the shared font was renewed to last.
    func testTonesDrawAtTheHeldCellsSize() throws {
        let picker = EmojiPicker(frame: CGRect(x: 0, y: 0, width: 402, height: TerminalKeyboard.keysHeight))
        let window = UIWindow(frame: picker.frame)
        window.addSubview(picker)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        picker.layoutIfNeeded()
        picker.grid.layoutIfNeeded()
        for size in [CGSize(width: 56, height: 56), CGSize(width: 38, height: 38), CGSize(width: 38, height: 47), CGSize(width: 56, height: 56)] {
            picker.showTones("👍", over: CGRect(origin: CGPoint(x: 100, y: 100), size: size))
            let tone = try XCTUnwrap((picker.toneStrip?.subviews.first as? UIButton)?.image(for: .normal))
            let font = try XCTUnwrap(EmojiPicker.emojiFont(size: min(size.width, size.height) * 0.7))
            XCTAssertEqual(tone.size.width, EmojiPicker.image("👍", font: font).size.width, accuracy: 0.5, "\(size)")
        }
        picker.closeTones()
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

    /// Unicode's nine groups, none empty; every entry one Character, none twice, no skin
    /// tones; a bar icon for Recents and each of the picker's groups.
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
        XCTAssertEqual(EmojiPicker.symbols.count, EmojiPicker.native.count + 1)
        for s in EmojiPicker.symbols + ["face.smiling"] { XCTAssertNotNil(UIImage(systemName: s), s) }
    }

    /// Apple Color Emoji itself draws an emoji as one glyph; a private-use scalar, or a ZWJ
    /// join of two emoji it has no glyph for, it doesn't. A newer emoji is in the groups
    /// exactly when it draws (#664).
    func testNewerEmojiOnlyWhereThisIOSDrawsThem() {
        XCTAssertTrue(EmojiPicker.draws("🫠"), "14.0")
        XCTAssertTrue(EmojiPicker.draws("🫨"), "15.0")
        XCTAssertFalse(EmojiPicker.draws("\u{F0000}"), "private use")
        XCTAssertFalse(EmojiPicker.draws("🍕\u{200D}🐶"), "not a sequence it has")
        let all = Set(EmojiPicker.groups.joined())
        for (version, emoji) in EmojiData.newer {
            for e in emoji.split(separator: " ").map(String.init) {
                XCTAssertEqual(all.contains(e), EmojiPicker.draws(e), "E\(version) \(e)")
            }
        }
    }
}
