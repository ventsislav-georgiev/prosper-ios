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
        XCTAssertEqual(fresh.toolbarRows, .one, "#1501: One unless picked")
        XCTAssertEqual(KeyboardSettings(defaults).toolbarRows, .one, "unset is One")
        XCTAssertEqual(KeyboardSettings(defaults).numbers, .row, "unset is Row")
        defaults.set("key", forKey: KeyboardSettings.Key.numbers)
        defaults.set(true, forKey: KeyboardSettings.Key.numpadHidesToolbar)
        defaults.set("one", forKey: KeyboardSettings.Key.toolbarRows)
        let set = KeyboardSettings(defaults)
        XCTAssertEqual(set.numbers, .key)
        XCTAssertTrue(set.numpadHidesToolbar)
        XCTAssertEqual(set.toolbarRows, .one)
        defaults.set("two", forKey: KeyboardSettings.Key.toolbarRows)
        XCTAssertEqual(KeyboardSettings(defaults).toolbarRows, .two, "a picked Two stays Two (#1501)")
        defaults.set("pad", forKey: KeyboardSettings.Key.numbers)
        defaults.set("three", forKey: KeyboardSettings.Key.toolbarRows)
        XCTAssertEqual(KeyboardSettings(defaults).numbers, .row, "an unknown value is Row")
        XCTAssertEqual(KeyboardSettings(defaults).toolbarRows, .one, "an unknown value is One")
        XCTAssertEqual(KeyboardSettings.current(fullAccess: false).numbers, .row, "no Full Access: defaults")
    }

    // MARK: Row and Key

    func testRowKeepsTheDigitRowAndABareKeyboardAlwaysDoes() {
        let (kb, bar, _, _) = rig(numbers: .row)
        XCTAssertEqual(kb.shownKeys.map(chars), ["1234567890", "qwertyuiop", "asdfghjkl", "|zxcvbnm|", ".,/||"])
        XCTAssertFalse(kb.shownKeys.joined().contains(.numbers))
        XCTAssertEqual(kb.toolbarRowHeight, 0, "One by default")
        bar.showsToolbar = true
        XCTAssertFalse(try XCTUnwrap(bar.toolbar).twoRows)
        kb.settings.toolbarRows = .two
        let m = TerminalKeyboard.metrics(compact: false)
        XCTAssertEqual(kb.toolbarRowHeight, m.row + m.gap, "#1501: Toolbar Rows: Two with Row too")
        bar.showsToolbar = false
        bar.showsToolbar = true
        XCTAssertTrue(try XCTUnwrap(bar.toolbar).twoRows)

        let app = TerminalKeyboard()   // `allowsNumbersKey` never set; the terminal's sets it (#692)
        app.settings.numbers = .key
        XCTAssertEqual(app.shownKeys.first.map(chars), "1234567890", "a bare keyboard keeps its digits")
        XCTAssertFalse(app.shownKeys.joined().contains(.numbers))
    }

    func testKeyDropsTheDigitRowForA123KeyAndTheKeysKeepTheirHeight() throws {
        for size in KeyboardSettings.KeySize.allCases {
            let (kb, bar, _, view) = rig(numbers: .row)
            kb.settings.keySize = size
            let rowTotal = fit(view), rowBar = bar.frame.height, rowKeys = kb.frame.height
            kb.settings.numbers = .key
            XCTAssertEqual(fit(view), rowTotal, accuracy: 1, "\(size): #1501 the same keyboard height")
            XCTAssertEqual(bar.frame.height, rowBar, accuracy: 0.5, "\(size): #1501 the bar as with Row")
            XCTAssertEqual(kb.frame.height, rowKeys, accuracy: 0.5, "\(size): #1501 the keys' height kept")
            XCTAssertEqual(kb.shownKeys.map(chars), ["qwertyuiop", "asdfghjkl", "|zxcvbnm|", "|.,/||"])
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

        kb.settings.toolbarRows = .two
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

    /// Toolbar Rows (#694), live, at every Key Size and in landscape, with Row or Key alike (#1501):
    /// One by default, Two adds a row and gap to the bar; the keys keep their five rows' height.
    func testToolbarRowsSetTheBarAndNumbersNeverTheHeight() throws {
        for compact in [false, true] {
            for size in KeyboardSettings.KeySize.allCases {
                for numbers in KeyboardSettings.Numbers.allCases {
                    let label = "\(size) \(numbers) \(compact ? "landscape" : "portrait")"
                    let (kb, bar, _, view) = rig(numbers: numbers, width: compact ? 874 : 402, compact: compact)
                    kb.settings.keySize = size
                    let m = TerminalKeyboard.metrics(compact: compact, size: size)
                    let one = SuggestionBar.height(compact: compact) + TerminalKeyboard.keysHeight(compact: compact, size: size)
                        + TerminalKeyboard.extensionBottomInset
                    XCTAssertEqual(fit(view), one, accuracy: 1, "\(label): One by default")
                    XCTAssertEqual(bar.frame.height, SuggestionBar.height(compact: compact), accuracy: 0.5, "\(label): one row's bar")
                    kb.settings.toolbarRows = .two
                    XCTAssertEqual(fit(view), one + m.row + m.gap, accuracy: 1, "\(label): Two, a bar row more")
                    XCTAssertEqual(bar.frame.height, SuggestionBar.height(compact: compact) + m.row + m.gap, accuracy: 0.5, "\(label): Two's bar")
                    kb.settings.toolbarRows = .one
                    XCTAssertEqual(fit(view), one, accuracy: 1, "\(label): One again")
                }
            }
        }
    }

    /// #1501 (OQ-171): Row and Key always the same total height, at One and at Two, at every Key
    /// Size and in landscape; Two adds the same bar row to either.
    func testRowAndKeyHaveTheSameHeightAtOneAndTwo() throws {
        for compact in [false, true] {
            for size in KeyboardSettings.KeySize.allCases {
                for rows in KeyboardSettings.ToolbarRows.allCases {
                    let label = "\(size) \(rows) \(compact ? "landscape" : "portrait")"
                    let (kb, bar, _, view) = rig(numbers: .row, width: compact ? 874 : 402, compact: compact)
                    kb.settings.keySize = size
                    kb.settings.toolbarRows = rows
                    let row = fit(view), rowBar = bar.frame.height, rowKeys = kb.frame.height
                    kb.settings.numbers = .key
                    XCTAssertEqual(fit(view), row, accuracy: 0.5, "\(label): Key as tall as Row")
                    XCTAssertEqual(bar.frame.height, rowBar, accuracy: 0.5, "\(label): the same bar")
                    XCTAssertEqual(kb.frame.height, rowKeys, accuracy: 0.5, "\(label): the same keys")
                    let m = TerminalKeyboard.metrics(compact: compact, size: size)
                    XCTAssertEqual(rowBar, SuggestionBar.height(compact: compact) + (rows == .two ? m.row + m.gap : 0), accuracy: 0.5, label)
                }
            }
        }
    }

    /// #1501: Numbers: Key's four rows fill the five's height, mostly taller keys, the gaps a
    /// little wider; the letters and the numpad span the same keys area, top to bottom.
    func testKeysFourRowsFillTheFiveRowsHeight() throws {
        XCTAssertTrue(TerminalKeyboard.metrics(compact: false) == (38, 13, 6), "Row's metrics unchanged")
        for compact in [false, true] {
            for size in KeyboardSettings.KeySize.allCases {
                let label = "\(size) \(compact ? "landscape" : "portrait")"
                let five = TerminalKeyboard.metrics(compact: compact, size: size)
                let four = TerminalKeyboard.metrics(compact: compact, size: size, rows: 4)
                XCTAssertEqual(4 * four.row + 3 * four.gap, 5 * five.row + 4 * five.gap, accuracy: 0.001, label)
                XCTAssertEqual(four.top, five.top, label)
                XCTAssertGreaterThan(four.gap, five.gap, "\(label): a wider gap")
                XCTAssertLessThan(four.gap - five.gap, 0.25 * (four.row - five.row), "\(label): mostly into the keys")

                let (kb, _, _, view) = rig(numbers: .row, width: compact ? 874 : 402, compact: compact)
                kb.settings.keySize = size
                func span() -> (top: CGFloat, bottom: CGFloat, height: CGFloat) {
                    fit(view)
                    let caps = kb.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden }
                    return (caps.map(\.frame.minY).min() ?? 0, caps.map(\.frame.maxY).max() ?? 0, caps.map(\.frame.height).min() ?? 0)
                }
                let row = span()
                XCTAssertEqual(row.height, five.row, accuracy: 0.01, label)
                kb.settings.numbers = .key
                let key = span()
                XCTAssertEqual(key.top, row.top, accuracy: 0.01, "\(label): from the same top")
                XCTAssertEqual(key.bottom, row.bottom, accuracy: 0.01, "\(label): to the same bottom")
                XCTAssertEqual(key.height, four.row, accuracy: 0.01, "\(label): taller keys")
                XCTAssertEqual(try cap(kb, "q").frame.maxY + four.gap, try cap(kb, "a").frame.minY, accuracy: 0.01, "\(label): the wider gap")
                kb.press(.numbers)
                let pad = span()
                XCTAssertEqual(pad.top, row.top, accuracy: 0.01, "\(label): the numpad from the same top")
                XCTAssertEqual(pad.bottom, row.bottom, accuracy: 0.01, "\(label): the numpad to the same bottom")
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
            let (kb, bar, _, view) = rig(width: width, compact: compact)
            kb.settings.toolbarRows = .two
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

    /// #1523: with Key the letter rows sit 5 pt apart, not 9, so their keys are wider than Row's at
    /// the same width, within the same side margins and centred as before; the numpad keeps 9.
    func testKeysLetterRowsAreCloserAndWiderThanRows() throws {
        XCTAssertEqual(TerminalKeyboard.numbersKeyGap, 5)
        for layout in [TerminalKeyboard.Layout.english, .bulgarian] {
            for (width, compact) in [(402, false), (874, true)] as [(CGFloat, Bool)] {
                let what = "\(layout) \(width)"
                let (kb, _, _, view) = rig(layout, numbers: .row, width: width, compact: compact)
                func top() throws -> [CGRect] {   // the top letter row, q's or я's
                    fit(view)
                    let y = try cap(kb, layout == .english ? "q" : "я").frame.minY
                    return kb.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden && $0.frame.minY == y }.map(\.frame).sorted { $0.minX < $1.minX }
                }
                let row = try top()
                XCTAssertEqual(kb.letterGap, TerminalKeyboard.keyGap, what)
                kb.settings.numbers = .key
                let key = try top()
                XCTAssertEqual(kb.letterGap, 5, what)
                XCTAssertEqual(key.count, row.count, what)
                XCTAssertGreaterThan(key[0].width, row[0].width + 3, "\(what): wider letters")
                for (a, b) in zip(key, key.dropFirst()) { XCTAssertEqual(b.minX - a.maxX, 5, accuracy: 0.01, "\(what): a 5 pt gap") }
                XCTAssertEqual(key.first!.minX, row.first!.minX, accuracy: 0.01, "\(what): the same left margin")
                XCTAssertEqual(key.last!.maxX, row.last!.maxX, accuracy: 0.01, "\(what): the same right margin")
                let shift = try cap(kb, "shift").frame, delete = try cap(kb, "delete").frame
                XCTAssertEqual(shift.minX + delete.maxX, kb.bounds.width, accuracy: 0.01, "\(what): the shift row centred")
                kb.press(.numbers)
                fit(view)
                XCTAssertEqual(try cap(kb, "2").frame.minX - cap(kb, "1").frame.maxX, TerminalKeyboard.keyGap, accuracy: 0.01, "\(what): the numpad's gap")
            }
        }
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
        XCTAssertNil(kb.previewText, "no previews on a tap")
    }

    /// #1525: the numpad's hold is the digit row's, in both languages; a tap is still the digit.
    func testHoldingANumpadDigitTypesTheDigitRowsSymbol() throws {
        for layout in TerminalKeyboard.Layout.allCases {
            let (kb, _, doc, _) = rig(layout)
            try tap(kb, "123")
            for d in "1234567890" {
                let f = try cap(kb, String(d)).frame, at = CGPoint(x: f.midX, y: f.midY)
                kb.track(.began, id: 1, at: at)
                kb.fireHold()
                kb.track(.ended, id: 1, at: at)
                XCTAssertEqual(doc.text.last.map(String.init), layout.holdSymbol[String(d)], "\(layout) \(d)")
                try tap(kb, String(d))
                XCTAssertEqual(doc.text.last, d, "\(layout): a tap is the digit")
            }
            XCTAssertEqual(doc.text, "!1@2#3$4%5^6&7*8(9)0")
            let hints = try cap(kb, "5").subviews.compactMap { ($0 as? UILabel)?.text }
            XCTAssertTrue(hints.contains("%"), "\(layout): the corner hint")
            let before = doc.text
            let f = try cap(kb, ",").frame
            kb.track(.began, id: 1, at: CGPoint(x: f.midX, y: f.midY))
            kb.fireHold()
            kb.track(.ended, id: 1, at: CGPoint(x: f.midX, y: f.midY))
            XCTAssertEqual(doc.text, before + ",", "the numpad's symbols have no hold")
        }
    }

    /// #1525: with Numbers: Key every digit-row hold symbol is a numpad hold or a letter hold.
    func testEveryDigitRowHoldIsReachableInKeyMode() {
        for layout in TerminalKeyboard.Layout.allCases {
            let digits = (1...10).map { String($0 % 10) }
            let digitRow = Set(digits.compactMap { layout.holdSymbol[$0] })
            XCTAssertEqual(digitRow, Set("!@#$%^&*()".map(String.init)))
            let numpad = Set(TerminalKeyboard.numpadRows.joined().compactMap { k -> String? in
                if case .char(let c) = k, c.first?.isNumber == true { return layout.holdSymbol[c] } else { return nil }
            })
            let letters = Set(layout.rows[1...3].joined().compactMap { k -> String? in
                if case .char(let c) = k { return layout.holdSymbol[c] } else { return nil }
            })
            XCTAssertTrue(digitRow.isSubset(of: numpad.union(letters)), "\(layout)")
            XCTAssertTrue(Set(["!", "%", "^"]).isSubset(of: numpad), "\(layout): only the numpad has these")
        }
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

    /// At Two, with Row or Key alike (#1501).
    func testHideToolbarGivesTheNumpadTheBarsHeightAndTakesItBack() throws {
        for numbers in KeyboardSettings.Numbers.allCases {
            let (kb, bar, _, view) = rig(numbers: numbers)
            kb.settings.toolbarRows = .two
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
            let m = TerminalKeyboard.metrics(compact: false)
            XCTAssertEqual(barHeight, SuggestionBar.height(compact: false) + m.row + m.gap, accuracy: 0.5, "\(numbers): Two's bar")
        }
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

    /// #1608: the period's hold (?) is the letters'; the numpad's own period has none.
    func testNumpadPeriodHasNoHold() throws {
        let (kb, _, doc, view) = rig(numbers: .key)
        try tap(kb, "123")
        fit(view)
        let dot = try cap(kb, ".")
        XCTAssertTrue(dot.subviews.compactMap { $0 as? UILabel }.allSatisfy { $0 === dot.titleLabel || ($0.text ?? "").isEmpty })
        XCTAssertNil(dot.accessibilityCustomActions)
        let f = dot.frame, p = CGPoint(x: f.midX, y: f.midY)
        kb.track(.began, id: 5, at: p)
        kb.fireHold()
        kb.track(.ended, id: 5, at: p)
        XCTAssertEqual(doc.text, ".", "no hold on the numpad")
    }

    func testBulgarianHasTheKeyTooAndTheSameNumpad() throws {
        let (kb, _, doc, view) = rig(.bulgarian, numbers: .row)
        _ = fit(view)
        let keys = kb.frame.height
        kb.settings.numbers = .key
        fit(view)
        XCTAssertEqual(kb.frame.height, keys, accuracy: 0.5, "#1501: the keys' height kept")
        XCTAssertEqual(kb.shownKeys.map(chars), ["явертъуиопю", "асдфгхйклшщ", "|зьцжбнмч|", "|.,/||"])
        try tap(kb, "123")
        XCTAssertEqual(kb.shownKeys, TerminalKeyboard.numpadRows)
        try tap(kb, "5")
        try tap(kb, "ABC")
        try tap(kb, "я")
        XCTAssertEqual(doc.text, "5я")
    }


    // MARK: Fit (#1524)

    /// The numpad's caps, every one inside `kb`'s bounds (and the screen's, in `space`), its
    /// four rows one under the other and no two caps of a row overlapping.
    private func assertNumpadFits(_ kb: TerminalKeyboard, in space: UICoordinateSpace? = nil, _ what: String, line: UInt = #line) {
        let caps = kb.subviews.compactMap { $0 as? UIButton }.filter { !$0.isHidden }
        XCTAssertEqual(caps.count, TerminalKeyboard.numpadRows.joined().count, what, line: line)
        for c in caps {
            let label = "\(what): \(c.title(for: .normal) ?? c.accessibilityLabel ?? "?") \(c.frame) in \(kb.bounds)"
            XCTAssertTrue(kb.bounds.contains(c.frame), label, line: line)
            if let space { XCTAssertTrue(space.bounds.contains(c.convert(c.bounds, to: space)), "\(label): off the screen", line: line) }
        }
        let rows = Dictionary(grouping: caps, by: \.frame.minY).sorted { $0.key < $1.key }.map { $0.value.sorted { $0.frame.minX < $1.frame.minX } }
        XCTAssertEqual(rows.count, TerminalKeyboard.numpadRows.count, "\(what): four rows", line: line)
        for (a, b) in zip(rows, rows.dropFirst()) {
            XCTAssertLessThanOrEqual(a.map(\.frame.maxY).max()!, b.map(\.frame.minY).min()! + 0.001, "\(what): rows overlap", line: line)
        }
        for row in rows {
            for (a, b) in zip(row, row.dropFirst()) {
                XCTAssertLessThanOrEqual(a.frame.maxX, b.frame.minX + 0.001, "\(what): caps overlap", line: line)
            }
        }
    }

    /// #1524: the extension's numpad in the keyboard, at every Key Size, portrait and landscape,
    /// Toolbar Rows One and Two, the toolbar shown or hidden on it.
    func testTheExtensionsNumpadFitsTheKeyboard() throws {
        for compact in [false, true] {
            for size in KeyboardSettings.KeySize.allCases {
                for rows in KeyboardSettings.ToolbarRows.allCases {
                    for hides in [false, true] {
                        let what = "\(size) \(rows) hides \(hides) \(compact ? "landscape" : "portrait")"
                        let (kb, _, _, view) = rig(width: compact ? 874 : 402, compact: compact)
                        kb.settings.keySize = size
                        kb.settings.toolbarRows = rows
                        kb.settings.numpadHidesToolbar = hides
                        kb.press(.numbers)
                        fit(view)
                        assertNumpadFits(kb, what)
                    }
                }
            }
        }
    }

    /// #1524: the terminal's numpad on the screen, its keyboard in the app's own input host, which
    /// never sizes it past its first frame (`tallest`): Hide Toolbar on the Numpad lent the shortcut
    /// bar's height to five rows (#1501), past that, and the bottom row fell off the screen. Every Key
    /// Size, Toolbar Rows One and Two, the bar shown or hidden, portrait and landscape; the keyboard
    /// at its full height, the lent bar's included.
    func testTheTerminalsNumpadFitsTheScreen() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone only")
        guard #available(iOS 16, *) else { throw XCTSkip("requestGeometryUpdate is iOS 16") }
        let saved = (TerminalKeyboard.hardwareKeyboardConnected, KeyboardSettings.store)
        TerminalKeyboard.hardwareKeyboardConnected = { false }
        KeyboardSettings.store = { [defaults] in defaults! }
        defer { (TerminalKeyboard.hardwareKeyboardConnected, KeyboardSettings.store) = saved }
        defaults.set(KeyboardSettings.Numbers.key.rawValue, forKey: KeyboardSettings.Key.numbers)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let vc = TerminalHostVC(conn: SessionConnection(transport: SpyTransport(), session: DchSession(name: "t", alias: nil)),
                                handle: TermHandle())
        window.rootViewController = vc
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let kb = try XCTUnwrap(vc.keyboardInputView as? TerminalKeyboard)
        let screen = scene.screen.coordinateSpace
        func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        /// Till the keyboard's frame holds still a moment (the host reloads it a turn later).
        func settle() {
            var last = CGRect.null, still = 0
            for _ in 0..<60 where still < 4 {
                spin(0.05)
                let f = kb.convert(kb.bounds, to: screen)
                still = f == last ? still + 1 : 0
                last = f
            }
        }
        func rotate(_ o: UIInterfaceOrientationMask) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: o)) { XCTFail("rotation: \($0)") }
            spin(1.5)
        }
        defer { rotate(.portrait) }
        for compact in [false, true] {
            if compact { rotate(.landscapeRight) }
            for size in compact ? [.normal] : KeyboardSettings.KeySize.allCases {
                for rows in KeyboardSettings.ToolbarRows.allCases {
                    for hides in [false, true] {
                        let what = "\(size) \(rows) hides \(hides) \(compact ? "landscape" : "portrait")"
                        defaults.set(size.rawValue, forKey: KeyboardSettings.Key.keySize)
                        defaults.set(rows.rawValue, forKey: KeyboardSettings.Key.toolbarRows)
                        defaults.set(hides, forKey: KeyboardSettings.Key.numpadHidesToolbar)
                        vc.toggleKeyboard()
                        settle()
                        XCTAssertTrue(kb.numbersKey, what)
                        kb.press(.numbers)
                        settle()
                        XCTAssertTrue(kb.showsNumpad, what)
                        kb.layoutIfNeeded()
                        XCTAssertEqual(kb.lentHeight > 0, hides, what)
                        XCTAssertEqual(kb.frame.height, TerminalKeyboard.keysHeight(compact: compact, size: size) + kb.lentHeight
                                       + TerminalKeyboard.bottomPadding, accuracy: 0.5, "\(what): the full height")
                        assertNumpadFits(kb, in: screen, what)
                        vc.toggleKeyboard()
                        settle()
                    }
                }
            }
        }
    }
}
