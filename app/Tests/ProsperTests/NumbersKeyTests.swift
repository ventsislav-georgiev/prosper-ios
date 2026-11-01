import XCTest
import UIKit
@testable import Prosper

/// Numbers: Key (#625): the system keyboard's digit row as a 123 key that swaps the letters
/// for a numpad, the row's height the toolbar's second row, the keyboard's height the same,
/// and Hide Toolbar on the Numpad lending the numpad the bar's height. Driven as the
/// extension's controller wires it: a fake field, the bar attached and hosted, its toolbar.
@MainActor
final class NumbersKeyTests: XCTestCase {
    typealias Proxy = KeyboardExtensionTests.FakeProxy
    typealias Key = TerminalKeyboard.Key

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "NumbersKeyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The extension's keyboard, its bar and toolbar, hosted in a `width` pt wide view in a window,
    /// `compact` the landscape size class. Keep all four: the keyboard holds the proxy and the bar weakly.
    private func rig(_ layout: TerminalKeyboard.Layout = .english, numbers: KeyboardSettings.Numbers = .key,
                     width: CGFloat = 402, compact: Bool = false) -> (TerminalKeyboard, SuggestionBar, Proxy, UIView) {
        let doc = Proxy()
        doc.autocapitalizationType = .none
        let kb = TerminalKeyboard(layout: layout)
        kb.target = doc
        kb.bottomInset = TerminalKeyboard.extensionBottomInset
        kb.offersEmoji = false
        let bar = SuggestionBar(suggestions: Suggestions(memory: TypingMemory(defaults: defaults), layout: layout))
        bar.attach(kb)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: compact ? 402 : 874))
        // A window with no scene takes its size class from its own size; the phone's is regular.
        if #available(iOS 17, *) { window.traitOverrides.verticalSizeClass = compact ? .compact : .regular }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
        window.addSubview(view)
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        bar.host(kb, in: view)
        bar.addToolbar { Shortcuts.Bar.arrowsToolbar }
        kb.allowsNumbersKey = true
        kb.settings.numbers = numbers
        fit(view)
        return (kb, bar, doc, view)
    }

    /// The view at the height its bar and keys add up to, laid out; that height.
    @discardableResult
    private func fit(_ view: UIView) -> CGFloat {
        let h = view.systemLayoutSizeFitting(CGSize(width: view.bounds.width, height: 0), withHorizontalFittingPriority: .required,
                                             verticalFittingPriority: .fittingSizeLevel).height
        view.frame.size.height = h
        view.layoutIfNeeded()
        return h
    }

    private func chars(_ keys: [Key]) -> String {
        keys.map { if case .char(let c) = $0 { return c } else { return "|" } }.joined()
    }

    /// The cap showing `title` (its accessibility label for a glyph cap).
    private func cap(_ kb: TerminalKeyboard, _ title: String) throws -> UIButton {
        try XCTUnwrap(kb.subviews.compactMap { $0 as? UIButton }
            .first { !$0.isHidden && ($0.title(for: .normal) ?? $0.accessibilityLabel) == title }, title)
    }

    /// A finger down and up on `title`'s cap.
    private func tap(_ kb: TerminalKeyboard, _ title: String) throws {
        kb.superview?.layoutIfNeeded()   // a swap lays out before the next touch
        let f = try cap(kb, title).frame
        kb.track(.began, id: 1, at: CGPoint(x: f.midX, y: f.midY))
        kb.track(.ended, id: 1, at: CGPoint(x: f.midX, y: f.midY))
    }

    /// The toolbar's shown rows: the stacks holding its caps, less a hidden one.
    private func toolbarRows(_ bar: SuggestionBar) throws -> Int {
        func caps(_ v: UIView) -> [KeyCapButton] { v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) } }
        let toolbar = try XCTUnwrap(bar.toolbar)
        return Set(caps(toolbar).compactMap { $0.superview }.filter { !$0.isHidden }.map(ObjectIdentifier.init)).count
    }

    // MARK: Setting

    func testNumbersSettingDecodesWithRowAndShownToolbarByDefault() {
        let fresh = KeyboardSettings()
        XCTAssertEqual(fresh.numbers, .row, "nobody's keys change unasked")
        XCTAssertFalse(fresh.numpadHidesToolbar)
        XCTAssertEqual(fresh.toolbarRows, .two, "#694: today's two rows")
        XCTAssertEqual(KeyboardSettings(defaults).numbers, .row, "unset is Row")
        defaults.set("key", forKey: KeyboardSettings.Key.numbers)
        defaults.set(true, forKey: KeyboardSettings.Key.numpadHidesToolbar)
        defaults.set("one", forKey: KeyboardSettings.Key.toolbarRows)
        let set = KeyboardSettings(defaults)
        XCTAssertEqual(set.numbers, .key)
        XCTAssertTrue(set.numpadHidesToolbar)
        XCTAssertEqual(set.toolbarRows, .one)
        defaults.set("pad", forKey: KeyboardSettings.Key.numbers)
        defaults.set("three", forKey: KeyboardSettings.Key.toolbarRows)
        XCTAssertEqual(KeyboardSettings(defaults).numbers, .row, "an unknown value is Row")
        XCTAssertEqual(KeyboardSettings(defaults).toolbarRows, .two, "an unknown value is Two")
        XCTAssertEqual(KeyboardSettings.current(fullAccess: false).numbers, .row, "no Full Access: defaults")
    }

    // MARK: Row and Key

    func testRowKeepsTheDigitRowAndABareKeyboardAlwaysDoes() {
        let (kb, bar, _, _) = rig(numbers: .row)
        XCTAssertEqual(kb.shownKeys.map(chars), ["1234567890", "qwertyuiop", "asdfghjkl", "|zxcvbnm|", ".,/|?|"])
        XCTAssertFalse(kb.shownKeys.joined().contains(.numbers))
        XCTAssertEqual(kb.numberRowHeight, 0)
        bar.showsToolbar = true
        XCTAssertFalse(try XCTUnwrap(bar.toolbar).twoRows)

        let app = TerminalKeyboard()   // `allowsNumbersKey` never set; the terminal's sets it (#692)
        app.settings.numbers = .key
        XCTAssertEqual(app.shownKeys.first.map(chars), "1234567890", "a bare keyboard keeps its digits")
        XCTAssertFalse(app.shownKeys.joined().contains(.numbers))
    }

    func testKeyDropsTheDigitRowForA123KeyAndTheToolbarTakesItsHeight() throws {
        for size in KeyboardSettings.KeySize.allCases {
            let (kb, bar, _, view) = rig(numbers: .row)
            kb.settings.keySize = size
            let rowTotal = fit(view), rowBar = bar.frame.height
            kb.settings.numbers = .key
            XCTAssertEqual(fit(view), rowTotal, accuracy: 1, "\(size): the same keyboard height")
            let m = TerminalKeyboard.metrics(compact: false, size: size)
            XCTAssertEqual(bar.frame.height, rowBar + m.row + m.gap, accuracy: 0.5, "\(size): the bar has the row's")
            XCTAssertEqual(kb.shownKeys.map(chars), ["qwertyuiop", "asdfghjkl", "|zxcvbnm|", "|.,/|?|"])
            XCTAssertEqual(kb.shownKeys.last?.first, .numbers, "123 leads the bottom row, as on iOS")
            XCTAssertEqual(try cap(kb, "123").frame.minY, try cap(kb, "space").frame.minY)
        }

        let (kb, bar, _, view) = rig()
        kb.settings.bottomHidden = "/?"
        kb.showsGlobe = true
        XCTAssertEqual(kb.shownKeys.last, [.numbers, .globe, .char("."), .char(","), .space, .ret],
                       "Keys Beside Space still applies; 123 before the globe")
        kb.settings.bottomOrder = " .,/?"
        XCTAssertEqual(kb.shownKeys.last, [.numbers, .globe, .space, .char("."), .char(","), .ret])

        bar.showsToolbar = true
        fit(view)
        XCTAssertTrue(try XCTUnwrap(bar.toolbar).twoRows)
        XCTAssertEqual(try toolbarRows(bar), 2, "the toolbar in two rows")
        XCTAssertEqual(try XCTUnwrap(bar.toolbar).frame.height, bar.frame.height)
        bar.showsToolbar = false
        fit(view)
        XCTAssertEqual(try toolbarRows(bar), 1, "one toolbar row over the suggestions")
        XCTAssertFalse(try XCTUnwrap(bar.toolbar).isHidden)
        XCTAssertFalse(bar.slotButtons[0].isHidden)
        XCTAssertGreaterThanOrEqual(bar.slotButtons[0].frame.minY, try XCTUnwrap(bar.toolbar).frame.maxY,
                                    "the slots under the toolbar's row")
        XCTAssertEqual(ShortcutBar.balancedSplit([40, 40, 40, 40, 100], spacing: 6), 3, "the longer row is shortest")
        XCTAssertEqual(ShortcutBar.balancedSplit([50, 50], spacing: 6), 1)
    }

    /// Toolbar Rows (#694), live, at every Key Size and in landscape: Two gives the bar the digit
    /// row's height, the keyboard Row's height; One gives it nothing, the keyboard that row shorter.
    func testToolbarRowsOneMakesTheKeyboardARowShorterAndTwoKeepsItsHeight() throws {
        for compact in [false, true] {
            for size in KeyboardSettings.KeySize.allCases {
                let label = "\(size) \(compact ? "landscape" : "portrait")"
                let (kb, bar, _, view) = rig(width: compact ? 874 : 402, compact: compact)
                kb.settings.keySize = size
                let m = TerminalKeyboard.metrics(compact: compact, size: size)
                let one = SuggestionBar.height(compact: compact) + TerminalKeyboard.keysHeight(compact: compact, size: size, rows: 4)
                    + TerminalKeyboard.extensionBottomInset
                XCTAssertEqual(fit(view), one + m.row + m.gap, accuracy: 1, "\(label): Two, Row's height")
                kb.settings.toolbarRows = .one
                XCTAssertEqual(fit(view), one, accuracy: 1, "\(label): One, a row shorter")
                XCTAssertEqual(bar.frame.height, SuggestionBar.height(compact: compact), accuracy: 0.5, "\(label): one row's bar")
                kb.settings.toolbarRows = .two
                XCTAssertEqual(fit(view), one + m.row + m.gap, accuracy: 1, "\(label): Two again")
            }
        }
    }

    /// At One (#694) the bar is Row's: no toolbar band over the slots, the toolbar in one row,
    /// the numpad lent that one row's height, the keyboard's height kept.
    func testOneRowsBarIsRowsAndTheNumpadIsLentIt() throws {
        let (kb, bar, _, view) = rig()
        kb.settings.toolbarRows = .one
        let total = fit(view), barHeight = bar.frame.height, keys = kb.frame.height
        let toolbar = try XCTUnwrap(bar.toolbar)
        XCTAssertTrue(toolbar.isHidden, "no band over the slots")
        XCTAssertFalse(bar.slotButtons[0].isHidden)
        XCTAssertEqual(bar.slotButtons[0].frame.minY, 4, accuracy: 0.5, "the slots at the bar's top")
        bar.showsToolbar = true
        fit(view)
        XCTAssertFalse(toolbar.twoRows)
        XCTAssertEqual(try toolbarRows(bar), 1, "the toolbar in one row")
        XCTAssertEqual(toolbar.frame.height, barHeight)
        bar.showsToolbar = false

        kb.settings.numpadHidesToolbar = true
        kb.press(.numbers)
        XCTAssertEqual(fit(view), total, accuracy: 1, "the same keyboard height")
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(kb.frame.height, keys + barHeight, accuracy: 0.5, "the numpad has the one row's height")
        kb.press(.numbers)
        XCTAssertEqual(fit(view), total, accuracy: 1)
        XCTAssertEqual(bar.frame.height, barHeight, accuracy: 0.5)
    }

    /// Each of the two rows spans the bar at every width, as the one row a portrait phone squeezes
    /// to fit does, and no fit drops a key: they were left at natural widths, a third of a
    /// landscape bar (#636).
    func testTwoRowsSpanTheBarWithTheSameKeysAtEveryWidth() throws {
        func caps(_ v: UIView) -> [KeyCapButton] { v.subviews.flatMap { ($0 as? KeyCapButton).map { [$0] } ?? caps($0) } }
        var sets: [[String]] = []
        for (width, compact) in [(402, false), (874, true), (874, false)] as [(CGFloat, Bool)] {
            let (_, bar, _, view) = rig(width: width, compact: compact)
            bar.showsToolbar = true
            fit(view)
            let toolbar = try XCTUnwrap(bar.toolbar)
            XCTAssertTrue(toolbar.twoRows)
            let shown = caps(toolbar).filter { !($0.superview?.isHidden ?? true) }
            let rows = Set(shown.compactMap(\.superview).map(ObjectIdentifier.init))
            XCTAssertEqual(rows.count, 2, "\(width): two rows")
            for row in shown.compactMap(\.superview) {
                XCTAssertGreaterThanOrEqual(row.frame.width, 0.9 * (toolbar.bounds.width - 16), "\(width): a row spans the bar")
            }
            sets.append(shown.map { $0.accessibilityLabel ?? $0.title(for: .normal) ?? "" })
        }
        XCTAssertEqual(Set(sets).count, 1, "the same keys at every width: \(sets)")
        XCTAssertEqual(sets.first?.count, Shortcuts.Bar.arrowsToolbar.filter { $0.kind != .pasteText }.count)
    }

    // MARK: Numpad

    func testThe123KeyOpensTheNumpadWhoseDigitsTypeUncorrected() throws {
        let (kb, _, doc, _) = rig()
        for c in "teh" { kb.press(.char(String(c))) }
        try tap(kb, "123")
        XCTAssertTrue(kb.showsNumpad)
        XCTAssertEqual(kb.shownKeys, TerminalKeyboard.numpadRows)
        kb.superview?.layoutIfNeeded()   // as the next frame does
        let seven = try cap(kb, "7").frame, q = TerminalKeyboard.keyGap
        XCTAssertGreaterThan(seven.width, 1.5 * (402 - 6 - 9 * q) / 10, "a numpad key is wider than a letter key")
        XCTAssertGreaterThanOrEqual(seven.height, TerminalKeyboard.rowHeight - 0.5)
        try tap(kb, ",")
        XCTAssertEqual(doc.text, "teh,", "the numpad never autocorrects")
        try tap(kb, "7")
        try tap(kb, "space")
        try tap(kb, "1")
        XCTAssertEqual(doc.text, "teh,7 1", "the digits and the space as typed")
        let one = try cap(kb, "1")
        XCTAssertEqual(one.subviews.compactMap { $0 === one.titleLabel ? nil : ($0 as? UILabel)?.text ?? nil }.filter { !$0.isEmpty }, [],
                       "no hold symbols on the numpad")
        XCTAssertNil(kb.previewText, "nor previews")
    }

    func testABCGoesBackToTheLetters() throws {
        let (kb, _, doc, _) = rig()
        kb.press(.numbers)
        XCTAssertEqual(try cap(kb, "ABC").accessibilityLabel, "letters")
        try tap(kb, "ABC")
        XCTAssertFalse(kb.showsNumpad)
        XCTAssertEqual(kb.shownKeys.first.map(chars), "qwertyuiop")
        try tap(kb, "q")
        XCTAssertEqual(doc.text, "q")
        kb.press(.numbers)
        kb.settings.numbers = .row
        XCTAssertFalse(kb.showsNumpad, "Row puts the numpad away")
        XCTAssertEqual(kb.shownKeys.first.map(chars), "1234567890")
    }

    func testHideToolbarGivesTheNumpadTheBarsHeightAndTakesItBack() throws {
        let (kb, bar, _, view) = rig()
        let total = fit(view), barHeight = bar.frame.height, keys = kb.frame.height
        kb.press(.numbers)
        XCTAssertEqual(fit(view), total, accuracy: 0.5)
        XCTAssertEqual(bar.frame.height, barHeight, "off: the bar stays on the numpad")
        XCTAssertFalse(bar.isHidden)

        kb.settings.numpadHidesToolbar = true
        XCTAssertEqual(fit(view), total, accuracy: 1, "the same keyboard height")
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(bar.frame.height, 0, accuracy: 0.5)
        XCTAssertEqual(kb.frame.height, keys + barHeight, accuracy: 0.5, "the numpad has the bar's height")
        let seven = try cap(kb, "7").frame.height
        XCTAssertGreaterThan(seven, TerminalKeyboard.rowHeight + 10, "its keys grow into it")

        kb.press(.numbers)
        XCTAssertEqual(fit(view), total, accuracy: 0.5)
        XCTAssertFalse(bar.isHidden, "the letters get the bar back")
        XCTAssertEqual(bar.frame.height, barHeight, accuracy: 0.5)
        XCTAssertEqual(kb.frame.height, keys, accuracy: 0.5)
    }

    // MARK: Bulgarian

    /// The hold menu's Numbers (#650), beside Emoji, beside a 123 key too (#691): it opens the
    /// numpad as 123 does, pushed in, the bar hidden with Hide Toolbar on the Numpad and the
    /// height kept; ABC brings the digit row, the bottom row and the bar back.
    func testTheMenusNumbersOpensTheNumpadWithTheDigitRow() throws {
        let (kb, bar, doc, view) = rig(numbers: .row)
        let titles = bar.menuItems.map(\.title)
        XCTAssertEqual(titles.firstIndex(of: "Numbers"), titles.firstIndex(of: "Emoji").map { $0 + 1 }, "next to Emoji")
        XCTAssertNotNil(UIImage(systemName: try XCTUnwrap(bar.menuItems.first { $0.title == "Numbers" }).symbol))
        kb.settings.numpadHidesToolbar = true
        let total = fit(view), barHeight = bar.frame.height, letters = kb.shownKeys
        bar.showMenu(true)
        try XCTUnwrap(bar.menuPanel?.tiles.first { $0.accessibilityLabel == "Numbers" }).sendActions(for: .touchUpInside)
        XCTAssertNil(bar.menuPanel, "the pick closes the menu")
        XCTAssertTrue(kb.showsNumpad)
        XCTAssertEqual(kb.shownKeys, TerminalKeyboard.numpadRows)
        XCTAssertEqual((kb.layer.animation(forKey: kCATransition) as? CATransition)?.type, .push, "pushed in, as from 123")
        XCTAssertEqual(fit(view), total, accuracy: 1, "the same keyboard height")
        XCTAssertTrue(bar.isHidden, "Hide Toolbar on the Numpad applies")
        try tap(kb, "7")
        try tap(kb, "ABC")
        XCTAssertFalse(kb.showsNumpad)
        XCTAssertEqual(kb.shownKeys, letters, "the digit row and the bottom row back")
        XCTAssertEqual(fit(view), total, accuracy: 1)
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.frame.height, barHeight, accuracy: 0.5)
        XCTAssertEqual(doc.text, "7")

        kb.settings.numbers = .key
        XCTAssertTrue(kb.numbersKey)
        XCTAssertEqual(bar.menuItems.map(\.title), titles, "beside a 123 key too (#691)")
        let app = TerminalKeyboard()   // without `allowsNumbersKey` the numpad works too
        app.showNumpad(true, animated: false)
        XCTAssertEqual(app.shownKeys, TerminalKeyboard.numpadRows)
        app.press(.numbers)
        XCTAssertEqual(app.shownKeys.first.map(chars), "1234567890")
    }

    func testBulgarianHasTheKeyTooAndTheSameNumpad() throws {
        let (kb, _, doc, view) = rig(.bulgarian, numbers: .row)
        let total = fit(view)
        kb.settings.numbers = .key
        XCTAssertEqual(fit(view), total, accuracy: 1)
        XCTAssertEqual(kb.shownKeys.map(chars), ["явертъуиопю", "асдфгхйклшщ", "|зьцжбнмч|", "|.,/|?|"])
        try tap(kb, "123")
        XCTAssertEqual(kb.shownKeys, TerminalKeyboard.numpadRows)
        try tap(kb, "5")
        try tap(kb, "ABC")
        try tap(kb, "я")
        XCTAssertEqual(doc.text, "5я")
    }
}
